--!strict
--[[
	A complete virtual RISC-V computer: CPU + RAM + devices + boot logic.

	Memory map (compatible with mini-rv32ima Linux images):
		0x10000000  UART0 (8250/16550 subset)   -> console (/dev/ttyS0)
		0x10000100  UART1 (8250/16550 subset)   -> host link (/dev/ttyS1, custom images only)
		0x11000000  CLINT (mtimecmp @ +0x4000, mtime @ +0xBFF8)
		0x11100000  SYSCON (write 0x5555 = power off, 0x7777 = reboot)
		0x80000000  RAM (kernel image loaded at the start, DTB at the end)

	The Machine is engine-agnostic: it only uses Luau builtins, so it runs the same
	in Roblox (client, server or an Actor) and in the Lune test harness.
]]

local Cpu = require(script.Parent.Cpu)
local Fdt = require(script.Parent.Fdt)
local Uart = require(script.Parent.Uart)

local RAM_BASE = 0x80000000

local STEP_RUNNING = 0
local STEP_WFI = 1
local STEP_POWEROFF = 0x5555
local STEP_REBOOT = 0x7777

export type MachineConfig = {
	-- Bytes of guest RAM. 16 MB is plenty for a nommu busybox system.
	ramSize: number?,
	-- Kernel command line passed through the device tree.
	cmdline: string?,
	-- Guest timer ticks (microseconds) per executed instruction while busy.
	-- Idle time (WFI) always follows the wall clock, so `sleep 1` stays accurate.
	usPerInstruction: number?,
	-- Instructions per CPU step call (interrupt latency vs. overhead).
	batchSize: number?,
	-- Whether to expose UART1 (the host link) in the device tree.
	hostLink: boolean?,
}

local Machine = {}
Machine.__index = Machine

export type Machine = typeof(setmetatable(
	{} :: {
		config: MachineConfig,
		ram: buffer,
		ramSize: number,
		cpu: Cpu.Cpu,
		console: Uart.Uart,
		hostLink: Uart.Uart,
		kernel: buffer?,
		state: "off" | "running" | "halted",
		instructions: number,
		pendingUs: number,
		usPerInstruction: number,
		batchSize: number,
		lastWall: number?,
		onPowerOff: ((reason: "poweroff" | "reboot") -> ())?,
		debugOutput: { string },
	},
	Machine
))

function Machine.new(config: MachineConfig?): Machine
	local cfg: MachineConfig = config or {}
	local ramSize = cfg.ramSize or 16 * 1024 * 1024
	local ram = buffer.create(ramSize)

	local self = setmetatable({
		config = cfg,
		ram = ram,
		ramSize = ramSize,
		cpu = (nil :: any) :: Cpu.Cpu,
		console = Uart.new(),
		hostLink = Uart.new(),
		kernel = nil,
		state = "off",
		instructions = 0,
		pendingUs = 0,
		usPerInstruction = cfg.usPerInstruction or 0.25,
		batchSize = cfg.batchSize or 2048,
		lastWall = nil,
		onPowerOff = nil,
		debugOutput = {},
	}, Machine)

	local console = self.console
	local hostLink = self.hostLink
	local cpu: Cpu.Cpu

	local mmio = {
		load = function(addr: number): number
			if addr < 0x10000100 then
				return console:read(addr - 0x10000000)
			elseif addr < 0x10000200 then
				return hostLink:read(addr - 0x10000100)
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
			elseif addr < 0x10000200 then
				hostLink:write(addr - 0x10000100, value)
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

	fdt:beginNode("")
	fdt:propU32("#address-cells", 2)
	fdt:propU32("#size-cells", 2)
	fdt:propString("compatible", "riscv-minimal-nommu")
	fdt:propString("model", "roblox-rv32ima")

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
	fdt:endNode()

	if cfg.hostLink then
		fdt:beginNode("uart@10000100")
		fdt:propU32("clock-frequency", 0x1000000)
		fdt:propCells("reg", { 0, 0x10000100, 0, 0x100 })
		fdt:propString("compatible", "ns16850")
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

-- Loads a kernel image (raw RISC-V "Image" with embedded initramfs) and resets the CPU.
function Machine.boot(self: Machine, kernel: buffer?)
	local image = kernel or self.kernel
	assert(image, "Machine.boot: no kernel image")
	self.kernel = image

	local ramSize = self.ramSize
	local imageSize = buffer.len(image)
	buffer.fill(self.ram, 0, 0)

	assert(imageSize < ramSize - 64 * 1024, "kernel image does not fit in RAM")
	buffer.copy(self.ram, 0, image, 0, imageSize)

	-- Reserve the last 16 KB of RAM for the DTB (keeps the usable size page-aligned).
	local dtbArea = 16 * 1024
	local usableRam = ramSize - dtbArea
	local dtb = self:buildDeviceTree(usableRam)
	assert(buffer.len(dtb) <= dtbArea, "device tree too large")
	buffer.copy(self.ram, usableRam, dtb, 0, buffer.len(dtb))

	self.cpu:reset(RAM_BASE, 0, RAM_BASE + usableRam)
	self.console:reset()
	self.hostLink:reset()
	self.instructions = 0
	self.pendingUs = 0
	self.lastWall = nil
	self.state = "running"
end

--[[
	Runs the machine for up to `budgetSeconds` of host time.

	`now` is the host clock in seconds (os.clock() by default). When the guest is
	idle (WFI) the call returns early so the host frame isn't wasted; guest time
	then advances with the wall clock. Set `fastForward` to skip idle time
	entirely (useful for headless booting and tests).

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
				if self.console:hasInput() then
					self.pendingUs += 1000
				end
			else
				break
			end
		elseif ret == STEP_POWEROFF or ret == STEP_REBOOT then
			self.state = "halted"
			local callback = self.onPowerOff
			if callback then
				callback(if ret == STEP_POWEROFF then "poweroff" else "reboot")
			end
			if ret == STEP_REBOOT and self.kernel then
				self:boot()
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
