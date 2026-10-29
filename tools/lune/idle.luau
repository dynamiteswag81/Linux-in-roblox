--[[
	Measures what an idle computer costs: boots Brick Linux to a shell, then runs
	it in 60 Hz frames for 10 seconds like the server does.

	lune run tools/lune/idle.luau [ImageName]
]]
local process = require("@lune/process")
local Shim = require("./RobloxShim")
local root = Shim.mountMany({ LinuxVM = "src/shared", LinuxImages = "src/images" })
local Machine = Shim.require(root.LinuxVM.Emulator.Machine)
local Disk = Shim.require(root.LinuxVM.Emulator.Disk)
local ImageLoader = Shim.require(root.LinuxVM.Emulator.ImageLoader)
local mod = root.LinuxImages[process.args[1] or "BrickLinux"]
local info = Shim.require(mod)
local chunks = {}
for n = 1, info.chunks do
	chunks[n] = Shim.require(mod[string.format("Chunk%03d", n)])
end
local m = Machine.new({
	disk = Disk.new(32 * 1024 * 1024),
	mac = "\2\0\10\0\0\2",
	cmdline = "console=ttyS0 brick.live=1 brick.hostname=idle brick.ip=10.0.0.2 brick.rows=25 brick.cols=80",
})
m:boot(ImageLoader.fromChunks(info, chunks))
local out = ""
local t = os.clock()
while not (string.find(out, "@idle", 1, true) or string.find(out, "# ", 1, true)) and os.clock() - t < 60 do
	m:run(0.02, true)
	out ..= m:takeOutput()
end
print(string.format("booted in %.1fM instructions", m.instructions / 1e6))
local before = m.instructions
local busy = 0
t = os.clock()
while os.clock() - t < 10 do
	local f = os.clock()
	m:run(0.008)
	m:takeOutput()
	busy += os.clock() - f
	local wake = f + 1 / 60
	while os.clock() < wake do
	end
end
print(string.format("idle: %.0fK instructions/s, %.2f%% of one core", (m.instructions - before) / 10 / 1e3, busy / 10 * 100))
