--[[
	Boots an image, types commands, and prints what the in-game screen would show.

	lune run tools/lune/screen.luau <Image> "<command 1>" "<command 2>" ...
	Each command waits for the guest to go idle before the next one.
	A command of the form "@sleep <seconds>" just runs the machine.
]]
local fs = require("@lune/fs")
local process = require("@lune/process")
local Shim = require("./RobloxShim")

local root = Shim.mount("src/shared", "LinuxVM", { native = true })
local Machine = Shim.require(root.Emulator.Machine)
local Disk = Shim.require(root.Emulator.Disk)
local Terminal = Shim.require(root.Terminal.Terminal)

local machine = Machine.new({
	disk = Disk.new(32 * 1024 * 1024),
	mac = "\x02\x00\x0a\x00\x00\x02",
	cmdline = "console=ttyS0 brick.live=1 brick.ip=10.0.0.2 brick.hostname=tester brick.root=/dev/vda1 brick.time=1793254000",
})
local term = Terminal.new(80, 25)
term.onResponse = function(data)
	machine:sendInput(data)
end
machine:boot(buffer.fromstring(fs.readFile(process.args[1])))

local function pump(seconds: number)
	local t = os.clock()
	while os.clock() - t < seconds do
		machine:run(0.02, true)
		term:write(machine:takeOutput())
	end
end

local function atPrompt(): boolean
	local line = string.sub(term:getLineText(term.cursorRow), 1, term.cursorCol - 1)
	return string.match(line, "[#$] $") ~= nil or string.match(line, "login: $") ~= nil
end

local function settle(needPrompt: boolean?)
	-- Run until output stops changing for a while (guest idle, at a prompt if asked).
	local lastVersion, still = -1, 0
	local t = os.clock()
	while os.clock() - t < 60 do
		pump(0.1)
		if term.version == lastVersion then
			still += 1
			if still >= 5 and (not needPrompt or atPrompt()) then
				return
			end
		else
			still = 0
			lastVersion = term.version
		end
	end
end

local function show(label)
	print(string.format("----- %s (cursor %d,%d) -----", label, term.cursorRow, term.cursorCol))
	print(term:toText())
end

settle(true)
show("after boot")
for i = 2, #process.args do
	local cmd = process.args[i]
	local secs = string.match(cmd, "^@sleep (.+)$")
	if secs then
		pump(tonumber(secs) :: number)
	else
		cmd = string.gsub(cmd, "\\e", "\27")
		cmd = string.gsub(cmd, "\\n", "\n")
		machine:sendInput(cmd)
		settle()
	end
	show(string.format("after %q", process.args[i]))
end
