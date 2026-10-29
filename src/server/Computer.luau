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

function Computer._bootEntries(self: Computer): { Firmware.BootEntry }
	local entries: { Firmware.BootEntry } = {}
	local primary = Config.IMAGES[1]
	local hasPrimary = self.loadImage(primary) ~= nil
	if hasPrimary then
		table.insert(entries, {
			id = "disk",
			label = Config.OS_NAME,
			hint = "Starts the system installed on your disk, or the live installer if there isn't one.",
		})
		table.insert(entries, {
			id = "live",
			label = Config.OS_NAME .. " (live installer)",
			hint = "Always starts the live environment. Your disk is left alone.",
		})
	end
	for i = 2, #Config.IMAGES do
		local name = Config.IMAGES[i]
		if self.loadImage(name) then
			table.insert(entries, {
				id = "image:" .. name,
				label = name .. if hasPrimary then " (fallback)" else "",
				hint = "A tiny prebuilt Linux without disk or network support.",
			})
		end
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
	if #entries == 0 then
		self:_emit("\27[2J\27[HNo operating system images were found.\r\n")
		self:_setState("firmware")
		return
	end
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
	}, function(entry)
		self:_boot(entry)
	end, Config.BOOT_COUNTDOWN)
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
	local imageName = Config.IMAGES[1]
	local live = entry.id == "live"
	local custom = string.match(entry.id, "^image:(.+)$")
	if custom then
		imageName = custom
	end
	local image = self.loadImage(imageName)
	if not image then
		self:_emit("\r\nBoot failed: image " .. imageName .. " is missing.\r\n")
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
