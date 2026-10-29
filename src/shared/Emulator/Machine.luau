--!strict
--[[
	A complete virtual RISC-V computer: CPU + RAM + devices + boot logic.

	Memory map (a superset of mini-rv32ima's, so its Linux images boot too):
		0x10000000  UART0, 8250/16550 subset, irq 3  -> console, /dev/ttyS0
		0x10001000  Host link mailbox                 -> `hostlink` tool (packages, workshop)
		0x10002000  virtio-mmio block device, irq 1   -> /dev/vda
		0x10003000  virtio-mmio network card, irq 2   -> eth0
		0x10400000  PLIC interrupt controller
		0x11000000  CLINT (mtimecmp @ +0x4000, mtime @ +0xBFF8)
		0x11100000  SYSCON (write 0x5555 = power off, 0x7777 = reboot)
		0x80000000  RAM (kernel image at the start, device tree at the end)

	The Machine only uses Luau builtins, so it runs the same in Roblox (server,
	client, or an Actor) and in the Lune test harness.
]]

local Cpu = require(script.Parent.Cpu)
local Disk = require(script.Parent.Disk)
local Fdt = require(script.Parent.Fdt)
local HostLink = require(script.Parent.HostLink)
local Plic = require(script.Parent.Plic)
local Uart = require(script.Parent.Uart)
local VirtioBlk = require(script.Parent.VirtioBlk)
local VirtioNet = require(script.Parent.VirtioNet)

local RAM_BASE = 0x80000000
local DTB_AREA = 16 * 1024

local STEP_WFI = 1
local STEP_POWEROFF = 0x5555
local STEP_REBOOT = 0x7777

local IRQ_BLK = 1
local IRQ_NET = 2
local IRQ_UART = 3

export type MachineConfig = {
	-- Bytes of guest RAM. 32 MB leaves room for a few programs on an installed system.
	ramSize: number?,
	-- Kernel command line passed through the device tree.
	cmdline: string?,
	-- Guest timer ticks (microseconds) per executed instruction while busy.
	-- Idle time (WFI) always follows the host clock, so `sleep 1` stays accurate.
	usPerInstruction: number?,
	-- Instructions per CPU step call (interrupt latency vs. overhead).
	batchSize: number?,
	-- Attach a disk (virtio-blk, /dev/vda).
	disk: Disk.Disk?,
	-- Attach a network card (virtio-net, eth0) with this 6-byte MAC address.
	mac: string?,
}

local Machine = {}
Machine.__index = Machine

export type PowerEvent = "poweroff" | "reboot"

export type Machine = typeof(setmetatable(
	{} :: {
		config: MachineConfig,
		ram: buffer,
		ramSize: number,
		cpu: Cpu.Cpu,
		console: Uart.Uart,
		hostLink: HostLink.HostLink,
		plic: Plic.Plic,
		blk: VirtioBlk.VirtioBlk?,
		net: VirtioNet.VirtioNet?,
		kernel: buffer?,
		state: "off" | "running" | "halted",
		instructions: number,
		pendingUs: number,
		usPerInstruction: number,
		batchSize: number,
		lastWall: number?,
		onPower: ((event: PowerEvent) -> ())?,
		debugOutput: { string },
	},
	Machine
))

function Machine.new(config: MachineConfig?): Machine
	local cfg: MachineConfig = config or {}
	local ramSize = cfg.ramSize or 32 * 1024 * 1024
	local ram = buffer.create(ramSize)

	local self = setmetatable({
		config = cfg,
		ram = ram,
		ramSize = ramSize,
		cpu = (nil :: any) :: Cpu.Cpu,
		console = Uart.new(),
		hostLink = HostLink.new(ram),
		plic = (nil :: any) :: Plic.Plic,
		blk = nil,
		net = nil,
		kernel = nil,
		state = "off",
		instructions = 0,
		pendingUs = 0,
		usPerInstruction = cfg.usPerInstruction or 0.25,
		batchSize = cfg.batchSize or 2048,
		lastWall = nil,
		onPower = nil,
		debugOutput = {},
	}, Machine)

	local cpu: Cpu.Cpu
	local plic = Plic.new(function(asserted)
		cpu.meip = asserted
	end)
	self.plic = plic
	self.console.onIrq = function(asserted)
		plic:setLevel(IRQ_UART, asserted)
	end

	local blk: VirtioBlk.VirtioBlk? = nil
	if cfg.disk then
		blk = VirtioBlk.new(ram, cfg.disk, function(high)
			plic:setLevel(IRQ_BLK, high)
		end)
	end
	self.blk = blk

	local net: VirtioNet.VirtioNet? = nil
	if cfg.mac then
		net = VirtioNet.new(ram, cfg.mac, function(high)
			plic:setLevel(IRQ_NET, high)
		end)
	end
	self.net = net

	local console = self.console
	local hostLink = self.hostLink

	local mmio = {
		load = function(addr: number): number
			if addr < 0x10000100 then
				return console:read(addr - 0x10000000)
			elseif addr < 0x10001000 then
				return 0
			elseif addr < 0x10001100 then
				return hostLink:read(addr - 0x10001000)
			elseif addr >= 0x10002000 and addr < 0x10003000 then
				return if blk then blk.transport:read(addr - 0x10002000) else 0
			elseif addr >= 0x10003000 and addr < 0x10004000 then
				return if net then net.transport:read(addr - 0x10003000) else 0
			elseif addr >= 0x10400000 and addr < 0x10800000 then
				return plic:read(addr - 0x10400000)
			elseif addr == 0x1100BFF8 then
				return cpu.timer % 4294967296
			elseif addr == 0x1100BFFC then
				return (cpu.timer // 4294967296) % 4294967296
			elseif addr == 0x11004000 then
				return cpu.timermatch % 4294967296
			elseif addr == 0x11004004 then
				return (cpu.timermatch // 4294967296) % 4294967296
			end
			return 0
		end,
		store = function(addr: number, value: number): number?
			if addr < 0x10000100 then
				console:write(addr - 0x10000000, value)
			elseif addr >= 0x10001000 and addr < 0x10001100 then
				hostLink:write(addr - 0x10001000, value)
			elseif addr >= 0x10002000 and addr < 0x10003000 then
				if blk then
					blk.transport:write(addr - 0x10002000, value)
				end
			elseif addr >= 0x10003000 and addr < 0x10004000 then
				if net then
					net.transport:write(addr - 0x10003000, value)
				end
			elseif addr >= 0x10400000 and addr < 0x10800000 then
				plic:write(addr - 0x10400000, value)
			elseif addr == 0x11004000 then
				local hi = cpu.timermatch // 4294967296
				cpu.timermatch = hi * 4294967296 + value
			elseif addr == 0x11004004 then
				local lo = cpu.timermatch % 4294967296
				cpu.timermatch = value * 4294967296 + lo
			elseif addr == 0x11100000 then
				if value == STEP_POWEROFF or value == STEP_REBOOT then
					return value
				end
			end
			return nil
		end,
		csrRead = function(csr: number): number
			if csr == 0x140 then
				-- mini-rv32ima "HVC" console input.
				local b = console:popInput()
				return if b then b else 0xFFFFFFFF
			end
			return 0
		end,
		csrWrite = function(csr: number, value: number)
			if csr == 0x139 then
				console:emit(bit32.band(value, 0xFF))
			elseif csr == 0x136 or csr == 0x137 then
				table.insert(self.debugOutput, if csr == 0x136 then tostring(value) else string.format("%08x", value))
			end
		end,
	}

	cpu = Cpu.new(ram, mmio)
	self.cpu = cpu
	return self
end

-- Builds the device tree describing this machine. Returns the DTB blob.
function Machine.buildDeviceTree(self: Machine, usableRam: number): buffer
	local cfg = self.config
	local fdt = Fdt.new()
	local cpuIntc = fdt:phandle("cpu-intc")
	local cpu0 = fdt:phandle("cpu0")
	local syscon = fdt:phandle("syscon")
	local plic = fdt:phandle("plic")

	fdt:beginNode("")
	fdt:propU32("#address-cells", 2)
	fdt:propU32("#size-cells", 2)
	fdt:propString("compatible", "riscv-minimal-nommu")
	fdt:propString("model", "Brick Computer (roblox-rv32ima)")

	fdt:beginNode("chosen")
	fdt:propString("bootargs", cfg.cmdline or "earlycon=uart8250,mmio,0x10000000,1000000 console=ttyS0")
	fdt:endNode()

	fdt:beginNode("memory@80000000")
	fdt:propString("device_type", "memory")
	fdt:propCells("reg", { 0, RAM_BASE, 0, usableRam })
	fdt:endNode()

	fdt:beginNode("cpus")
	fdt:propU32("#address-cells", 1)
	fdt:propU32("#size-cells", 0)
	fdt:propU32("timebase-frequency", 1000000)
	fdt:beginNode("cpu@0")
	fdt:propU32("phandle", cpu0)
	fdt:propString("device_type", "cpu")
	fdt:propU32("reg", 0)
	fdt:propString("status", "okay")
	fdt:propString("compatible", "riscv")
	fdt:propString("riscv,isa", "rv32ima")
	fdt:propString("mmu-type", "riscv,none")
	fdt:beginNode("interrupt-controller")
	fdt:propU32("#interrupt-cells", 1)
	fdt:propEmpty("interrupt-controller")
	fdt:propString("compatible", "riscv,cpu-intc")
	fdt:propU32("phandle", cpuIntc)
	fdt:endNode()
	fdt:endNode()
	fdt:beginNode("cpu-map")
	fdt:beginNode("cluster0")
	fdt:beginNode("core0")
	fdt:propU32("cpu", cpu0)
	fdt:endNode()
	fdt:endNode()
	fdt:endNode()
	fdt:endNode()

	fdt:beginNode("soc")
	fdt:propU32("#address-cells", 2)
	fdt:propU32("#size-cells", 2)
	fdt:propString("compatible", "simple-bus")
	fdt:propEmpty("ranges")

	fdt:beginNode("uart@10000000")
	fdt:propU32("clock-frequency", 0x1000000)
	fdt:propCells("reg", { 0, 0x10000000, 0, 0x100 })
	fdt:propString("compatible", "ns16850")
	-- An interrupt line means Linux doesn't have to poll the console.
	fdt:propU32("interrupt-parent", plic)
	fdt:propU32("interrupts", IRQ_UART)
	fdt:endNode()

	fdt:beginNode("interrupt-controller@10400000")
	fdt:propU32("phandle", plic)
	fdt:propStrings("compatible", { "sifive,plic-1.0.0", "riscv,plic0" })
	fdt:propCells("reg", { 0, 0x10400000, 0, 0x400000 })
	fdt:propCells("interrupts-extended", { cpuIntc, 11 })
	fdt:propEmpty("interrupt-controller")
	fdt:propU32("#interrupt-cells", 1)
	fdt:propU32("#address-cells", 0)
	fdt:propU32("riscv,ndev", 31)
	fdt:endNode()

	if self.blk then
		fdt:beginNode("virtio_mmio@10002000")
		fdt:propString("compatible", "virtio,mmio")
		fdt:propCells("reg", { 0, 0x10002000, 0, 0x1000 })
		fdt:propU32("interrupt-parent", plic)
		fdt:propU32("interrupts", IRQ_BLK)
		fdt:endNode()
	end

	if self.net then
		fdt:beginNode("virtio_mmio@10003000")
		fdt:propString("compatible", "virtio,mmio")
		fdt:propCells("reg", { 0, 0x10003000, 0, 0x1000 })
		fdt:propU32("interrupt-parent", plic)
		fdt:propU32("interrupts", IRQ_NET)
		fdt:endNode()
	end

	fdt:beginNode("poweroff")
	fdt:propU32("value", STEP_POWEROFF)
	fdt:propU32("offset", 0)
	fdt:propU32("regmap", syscon)
	fdt:propString("compatible", "syscon-poweroff")
	fdt:endNode()

	fdt:beginNode("reboot")
	fdt:propU32("value", STEP_REBOOT)
	fdt:propU32("offset", 0)
	fdt:propU32("regmap", syscon)
	fdt:propString("compatible", "syscon-reboot")
	fdt:endNode()

	fdt:beginNode("syscon@11100000")
	fdt:propU32("phandle", syscon)
	fdt:propCells("reg", { 0, 0x11100000, 0, 0x1000 })
	fdt:propString("compatible", "syscon")
	fdt:endNode()

	fdt:beginNode("clint@11000000")
	fdt:propCells("interrupts-extended", { cpuIntc, 3, cpuIntc, 7 })
	fdt:propCells("reg", { 0, 0x11000000, 0, 0x10000 })
	fdt:propStrings("compatible", { "sifive,clint0", "riscv,clint0" })
	fdt:endNode()

	fdt:endNode() -- soc
	fdt:endNode() -- root
	return fdt:finish()
end

-- Loads a kernel image (raw RISC-V "Image" with embedded initramfs) and resets everything.
function Machine.boot(self: Machine, kernel: buffer?, cmdline: string?)
	local image = kernel or self.kernel
	assert(image, "Machine.boot: no kernel image")
	self.kernel = image
	if cmdline then
		self.config.cmdline = cmdline
	end

	local ramSize = self.ramSize
	local imageSize = buffer.len(image)
	assert(imageSize < ramSize - DTB_AREA - 1024 * 1024, "kernel image does not fit in RAM")
	buffer.fill(self.ram, 0, 0)
	buffer.copy(self.ram, 0, image, 0, imageSize)

	-- The DTB sits in the last 16 KB of RAM, outside the memory Linux manages.
	local usableRam = ramSize - DTB_AREA
	local dtb = self:buildDeviceTree(usableRam)
	assert(buffer.len(dtb) <= DTB_AREA, "device tree too large")
	buffer.copy(self.ram, usableRam, dtb, 0, buffer.len(dtb))

	self.cpu:reset(RAM_BASE, 0, RAM_BASE + usableRam)
	self.console:reset()
	self.hostLink:reset()
	self.plic:reset()
	if self.blk then
		self.blk.transport:reset()
	end
	if self.net then
		self.net.transport:reset()
	end
	self.instructions = 0
	self.pendingUs = 0
	self.lastWall = nil
	self.state = "running"
end

function Machine.powerOff(self: Machine)
	self.state = "off"
	self.lastWall = nil
end

--[[
	Runs the machine for up to `budgetSeconds` of host time.

	When the guest is idle (WFI) the call returns early so the host frame isn't
	wasted; guest time then advances with the host clock between calls. Set
	`fastForward` to skip idle time instead (headless boots and tests).

	Returns the number of instructions executed.
]]
function Machine.run(self: Machine, budgetSeconds: number, fastForward: boolean?): number
	if self.state ~= "running" then
		return 0
	end

	local cpu = self.cpu
	local batch = self.batchSize
	local usPerInstruction = self.usPerInstruction
	local clock = os.clock
	local start = clock()
	local deadline = start + budgetSeconds

	-- Guest idle time follows the host clock between run() calls.
	local lastWall = self.lastWall
	if lastWall and cpu.wfi then
		self.pendingUs += math.min(start - lastWall, 0.25) * 1e6
	end

	local executed = 0
	while true do
		local before = cpu.cycle
		local elapsed = self.pendingUs // 1
		self.pendingUs -= elapsed
		local ret = cpu:step(batch, elapsed)
		local ran = cpu.cycle - before
		executed += ran
		self.pendingUs += ran * usPerInstruction

		if ret == STEP_WFI then
			if fastForward then
				-- Jump straight to the next timer interrupt.
				local wait = cpu.timermatch - cpu.timer + 1
				if wait > 0 then
					self.pendingUs += wait
				end
			else
				break
			end
		elseif ret == STEP_POWEROFF or ret == STEP_REBOOT then
			local event: PowerEvent = if ret == STEP_POWEROFF then "poweroff" else "reboot"
			self.state = "halted"
			local onPower = self.onPower
			if onPower then
				onPower(event)
			end
			break
		end

		if clock() >= deadline then
			break
		end
	end

	self.instructions += executed
	self.lastWall = clock()
	return executed
end

-- Queue keyboard bytes for the guest console.
function Machine.sendInput(self: Machine, data: string)
	self.console:pushInput(data)
end

-- Take everything the guest printed on the console since the last call.
function Machine.takeOutput(self: Machine): string
	return self.console:takeOutput()
end

return Machine
