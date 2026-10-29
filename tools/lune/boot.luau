--[[
	Headless boot test: runs a Linux image in the Luau emulator and prints the console.

	lune run tools/lune/boot.luau -- <Image> [options]
		--ram <MB>          guest RAM (default 16)
		--seconds <n>       stop after n host seconds (default 600)
		--interp            disable native codegen (closer to Roblox client speed)
		--realtime          don't skip guest idle time
		--until <text>      stop once the console prints <text>
		--type <text>       after the shell prompt appears, type <text> ("\n" escapes ok)
		--save <file>       write a RAM snapshot when stopping
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local Shim = require("./RobloxShim")

local args = process.args
local imagePath = args[1]
assert(imagePath, "usage: boot.luau <Image> [--ram MB] [--seconds N] [--interp] [--until TEXT] [--type TEXT]")

local opts = { ram = 32, seconds = 600, native = true, realtime = false }
local i = 2
while i <= #args do
	local a = args[i]
	if a == "--ram" then
		opts.ram = tonumber(args[i + 1]); i += 1
	elseif a == "--seconds" then
		opts.seconds = tonumber(args[i + 1]); i += 1
	elseif a == "--interp" then
		opts.native = false
	elseif a == "--realtime" then
		opts.realtime = true
	elseif a == "--until" then
		opts.untilText = args[i + 1]; i += 1
	elseif a == "--type" then
		opts.typeText = string.gsub(args[i + 1], "\\n", "\n"); i += 1
	elseif a == "--save" then
		opts.save = args[i + 1]; i += 1
	end
	i += 1
end

local root = Shim.mount("src/shared", "LinuxVM", { native = opts.native })
local Machine = Shim.require(root.Emulator.Machine)
local Disk = Shim.require(root.Emulator.Disk)

local machine = Machine.new({
	ramSize = opts.ram * 1024 * 1024,
	disk = Disk.new(32 * 1024 * 1024),
	mac = "\x02\x00\x0a\x00\x00\x02",
	cmdline = "earlycon=uart8250,mmio,0x10000000,1000000 console=ttyS0 brick.ip=10.0.0.2 brick.hostname=tester brick.root=/dev/vda1",
})
machine:boot(buffer.fromstring(fs.readFile(imagePath)))

local start = os.clock()
local lastReport = start
local lastInstr = 0
local transcript = {}
local typed = false
local promptSeenAt = nil

while true do
	machine:run(0.05, not opts.realtime)
	local out = machine:takeOutput()
	if #out > 0 then
		stdio.write(out)
		table.insert(transcript, out)
	end
	local now = os.clock()
	if now - lastReport >= 5 then
		local mips = (machine.instructions - lastInstr) / (now - lastReport) / 1e6
		stdio.ewrite(string.format("\n[%.0fs] %.1fM instr, %.2f MIPS, guest time %.2fs\n",
			now - start, machine.instructions / 1e6, mips, machine.cpu.timer / 1e6))
		lastReport, lastInstr = now, machine.instructions
	end
	local all = table.concat(transcript)
	if opts.typeText and not typed and (string.find(all, "# $") or string.find(all, "login: $")) then
		promptSeenAt = promptSeenAt or now
		if now - promptSeenAt > 0.5 then
			typed = true
			stdio.ewrite(string.format("\n[prompt after %.1fs host, %.1fM instr]\n", now - start, machine.instructions / 1e6))
			machine:sendInput(opts.typeText)
		end
	end
	if opts.untilText and string.find(all, opts.untilText, 1, true) then
		break
	end
	if machine.state ~= "running" or now - start > opts.seconds then
		break
	end
end

local elapsed = os.clock() - start
stdio.ewrite(string.format("\n[done] state=%s, %.1fM instructions in %.1fs = %.2f MIPS, pc=%08x\n",
	machine.state, machine.instructions / 1e6, elapsed, machine.instructions / elapsed / 1e6, machine.cpu.pc))
