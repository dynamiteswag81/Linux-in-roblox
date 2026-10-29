--!strict
--[[
	One player's computer: the virtual machine, its disk, the firmware, and the
	server's copy of the screen (a Terminal) that viewers are kept in sync with.

	Engine-agnostic (no Roblox services) so it can be driven headless in tests;
	ComputerService wires it to players, desks and remotes.
]]

local LinuxVM = require(script.Parent.Deps) :: any

local Config = require(LinuxVM.Config)
local Disk = require(LinuxVM.Emulator.Disk)
local HostLink = require(LinuxVM.Emulator.HostLink)
local Machine = require(LinuxVM.Emulator.Machine)
local Terminal = require(LinuxVM.Terminal.Terminal)
local Firmware = require(script.Parent.Firmware)

local Computer = {}
Computer.__index = Computer

export type State = "off" | "firmware" | "running"

export type StreamItem = { kind: "data", payload: string } | { kind: "snapshot", payload: Terminal.Snapshot }

export type Options = {
	id: string,
	ownerName: string,
	hostname: string,
	ip: string?,
	mac: string?,
	disk: Disk.Disk,
	-- Returns the kernel image with this name, or nil if the game doesn't have it.
	loadImage: (name: string) -> buffer?,
	-- Image on the flash drive in the USB port at power on, if any (see setFlashDrive).
	flashDrive: string?,
}

export type Computer = typeof(setmetatable(
	{} :: {
		id: string,
		ownerName: string,
		hostname: string,
		ip: string?,
		mac: string?,
		disk: Disk.Disk,
		loadImage: (name: string) -> buffer?,
		flashDrive: string?,
		machine: Machine.Machine?,
		terminal: Terminal.Terminal,
		firmware: Firmware.Firmware?,
		state: State,
		bootedImage: string?,
		-- Streaming to viewers
		stream: { string },
		streamBytes: number,
		needsSnapshot: boolean,
		lastSnapshotAt: number,
		-- Hooks set by services
		onStateChanged: ((state: State) -> ())?,
		hostLinkHandler: HostLink.Handler?,
		onFrame: ((frame: string) -> ())?,
		onFlush: (() -> ())?,
		-- Stats
		instructions: number,
	},
	Computer
))

function Computer.new(options: Options): Computer
	local self = setmetatable({
		id = options.id,
		ownerName = options.ownerName,
		hostname = options.hostname,
		ip = options.ip,
		mac = options.mac,
		disk = options.disk,
		loadImage = options.loadImage,
		flashDrive = options.flashDrive,
		machine = nil,
		terminal = Terminal.new(Config.COLS, Config.ROWS),
		firmware = nil,
		state = "off" :: State,
		bootedImage = nil,
		stream = {},
		streamBytes = 0,
		needsSnapshot = false,
		lastSnapshotAt = -math.huge,
		onStateChanged = nil,
		hostLinkHandler = nil,
		onFrame = nil,
		onFlush = nil,
		instructions = 0,
	}, Computer)

	-- Replies to terminal queries (cursor position etc.) go back to the guest.
	self.terminal.onResponse = function(data: string)
		local machine = self.machine
		if self.state == "running" and machine then
			machine:sendInput(data)
		end
	end
	return self
end

function Computer._setState(self: Computer, state: State)
	if self.state == state then
		return
	end
	self.state = state
	local callback = self.onStateChanged
	if callback then
		callback(state)
	end
end

-- Everything shown on screen goes through here: updates the server's screen
-- and queues the bytes for viewers.
function Computer._emit(self: Computer, data: string)
	if data == "" then
		return
	end
	self.terminal:write(data)
	if self.needsSnapshot then
		return
	end
	if self.streamBytes + #data > Config.MAX_STREAM_BYTES_PER_FRAME then
		-- Too much to stream: viewers get a snapshot of the result instead.
		self.needsSnapshot = true
		table.clear(self.stream)
		self.streamBytes = 0
		return
	end
	table.insert(self.stream, data)
	self.streamBytes += #data
end

-- Returns what to send to viewers this frame (raw bytes, a snapshot, or nothing).
function Computer.takeStream(self: Computer, now: number): StreamItem?
	if self.needsSnapshot then
		if now - self.lastSnapshotAt < Config.SNAPSHOT_INTERVAL then
			return nil
		end
		self.needsSnapshot = false
		self.lastSnapshotAt = now
		self.streamBytes = 0
		return { kind = "snapshot", payload = self.terminal:snapshot() }
	end
	if #self.stream == 0 then
		self.streamBytes = 0
		return nil
	end
	local data = table.concat(self.stream)
	table.clear(self.stream)
	self.streamBytes = 0
	return { kind = "data", payload = data }
end

function Computer._getMachine(self: Computer): Machine.Machine
	local machine = self.machine
	if machine then
		return machine
	end
	local m = Machine.new({
		ramSize = Config.RAM_MB * 1024 * 1024,
		disk = self.disk,
		mac = self.mac,
		usPerInstruction = Config.US_PER_INSTRUCTION,
	})
	m.hostLink.handler = function(command, args, payload, reply)
		local handler = self.hostLinkHandler
		if handler then
			handler(command, args, payload, reply)
		else
			reply(false, "hostlink: not available")
		end
	end
	local blk = m.blk
	if blk then
		blk.onFlush = function()
			local onFlush = self.onFlush
			if onFlush then
				onFlush()
			end
		end
	end
	local net = m.net
	if net then
		net.onTransmit = function(frame)
			local onFrame = self.onFrame
			if onFrame then
				onFrame(frame)
			end
		end
	end
	m.onPower = function(event)
		-- Show the guest's last words ("reboot: Restarting system") first.
		self:_emit(m:takeOutput())
		if event == "reboot" then
			self:_startFirmware(os.clock())
		else
			self:_halt()
		end
	end
	self.machine = m
	return m
end

-- Delivers a network frame to this computer's network card.
function Computer.receiveFrame(self: Computer, frame: string)
	local machine = self.machine
	if self.state == "running" and machine and machine.net then
		machine.net:receive(frame)
	end
end

-- Plugs in (image name) or pulls out (nil) the installer flash drive. The live
-- system runs from memory, so pulling it out only matters at the next boot.
function Computer.setFlashDrive(self: Computer, image: string?)
	if self.flashDrive == image then
		return
	end
	self.flashDrive = image
	-- A firmware waiting for something to boot notices the drive straight away.
	local firmware = self.firmware
	if self.state == "firmware" and firmware and firmware.mode == "nodevice" then
		self:_startFirmware(os.clock())
	end
end

-- The image the installer flash drive boots, or nil if there's no drive in.
function Computer._usbImage(self: Computer): string?
	if self.flashDrive then
		return self.flashDrive
	elseif not Config.REQUIRE_FLASH_DRIVE then
		return Config.IMAGE
	end
	return nil
end

--[[
	True if the disk looks like it holds an installed system: an MBR partition
	table whose first partition has an ext2 filesystem (what the install guide
	creates). Whether the system on it is complete is up to the guest's /init.
]]
function Computer.hasInstalledSystem(self: Computer): boolean
	local disk = self.disk
	local mbr = buffer.create(512)
	disk:readInto(0, 512, mbr, 0)
	if buffer.readu8(mbr, 510) ~= 0x55 or buffer.readu8(mbr, 511) ~= 0xAA then
		return false
	end
	local partType = buffer.readu8(mbr, 446 + 4)
	local startSector = buffer.readu32(mbr, 446 + 8)
	if partType == 0 or startSector == 0 then
		return false
	end
	local superblock = startSector * 512 + 1024
	if superblock + 1024 > disk.size then
		return false
	end
	local sb = buffer.create(64)
	disk:readInto(superblock, 64, sb, 0)
	return buffer.readu16(sb, 56) == 0xEF53
end

-- What the firmware can boot, in boot order: the disk, then the flash drive.
function Computer._bootEntries(self: Computer): { Firmware.BootEntry }
	local entries: { Firmware.BootEntry } = {}
	if self.loadImage(Config.IMAGE) and self:hasInstalledSystem() then
		table.insert(entries, {
			id = "disk",
			label = "Disk 0: " .. Config.OS_NAME,
			hint = "Starts the system installed on your disk.",
		})
	end
	local usb = self:_usbImage()
	if usb and self.loadImage(usb) then
		table.insert(entries, {
			id = "usb",
			label = "USB: " .. Config.OS_NAME .. " installer",
			hint = "Starts the live installer from the flash drive. Your disk is left alone until you install.",
		})
	end
	return entries
end

function Computer._startFirmware(self: Computer, now: number)
	local machine = self.machine
	if machine then
		machine:powerOff()
	end
	self.terminal:reset()
	self.needsSnapshot = true
	local entries = self:_bootEntries()
	local usb = self:_usbImage()
	local firmware = Firmware.new(function(data)
		self:_emit(data)
	end, entries, {
		ramMB = Config.RAM_MB,
		diskMB = self.disk.size // (1024 * 1024),
		diskUsedKB = self.disk:usedBlocks() * self.disk.blockSize // 1024,
		mac = self.mac,
		ip = self.ip,
		owner = self.ownerName,
		hostname = self.hostname,
		usb = if usb then Config.OS_NAME .. " installer flash drive" else nil,
	}, function(entry)
		self:_boot(entry)
	end, Config.BOOT_COUNTDOWN, function()
		self:_startFirmware(os.clock())
	end)
	self.firmware = firmware
	self:_setState("firmware")
	firmware:start(now)
end

function Computer.kernelCommandLine(self: Computer, live: boolean): string
	local parts = {
		"console=ttyS0",
		"earlycon=uart8250,mmio,0x10000000,1000000",
		"brick.hostname=" .. self.hostname,
		"brick.time=" .. tostring(os.time()),
		"brick.rows=" .. Config.ROWS,
		"brick.cols=" .. Config.COLS,
		"brick.root=/dev/vda1",
	}
	if self.ip then
		table.insert(parts, "brick.ip=" .. self.ip)
	end
	if live then
		table.insert(parts, "brick.live=1")
	end
	return table.concat(parts, " ")
end

function Computer._boot(self: Computer, entry: Firmware.BootEntry)
	self.firmware = nil
	local live = entry.id == "usb"
	local imageName = if live then self:_usbImage() else Config.IMAGE
	local image = imageName and self.loadImage(imageName)
	if not image then
		-- The drive was pulled out during the countdown, or the image is missing.
		self:_emit("\r\nBoot failed: " .. entry.label .. " is gone.\r\n")
		self:_startFirmware(os.clock())
		return
	end
	local machine = self:_getMachine()
	machine:boot(image, self:kernelCommandLine(live))
	self.bootedImage = imageName
	self:_setState("running")
end

function Computer._halt(self: Computer)
	local machine = self.machine
	if machine then
		machine:powerOff()
	end
	self.firmware = nil
	self.terminal:reset()
	self.needsSnapshot = true
	self:_setState("off")
end

-- Power button: on when off, off otherwise (a hard power off, like holding the button).
function Computer.pressPower(self: Computer, now: number)
	if self.state == "off" then
		self:_startFirmware(now)
	else
		self:_halt()
	end
end

-- Reset button: restart from the firmware.
function Computer.reset(self: Computer, now: number)
	self:_startFirmware(now)
end

-- Keyboard input from the player using this computer.
function Computer.input(self: Computer, data: string)
	if self.state == "firmware" then
		local firmware = self.firmware
		if firmware then
			firmware:input(data)
		end
	elseif self.state == "running" then
		local machine = self.machine
		if machine then
			machine:sendInput(data)
		end
	end
end

-- Advances the computer by up to `budget` seconds of host CPU time.
-- Returns true if the guest was busy (wants more CPU time).
function Computer.update(self: Computer, now: number, budget: number): boolean
	if self.state == "firmware" then
		local firmware = self.firmware
		if firmware then
			firmware:update(now)
		end
		return false
	elseif self.state == "running" then
		local machine = self.machine :: Machine.Machine
		local ran = machine:run(budget)
		self.instructions += ran
		self:_emit(machine:takeOutput())
		return self.state == "running" and not machine.cpu.wfi
	end
	return false
end

return Computer
