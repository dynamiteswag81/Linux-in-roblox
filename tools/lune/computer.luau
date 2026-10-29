--[[
	Drives a server-side Computer headless: power on, firmware, boot, commands.
	lune run tools/lune/computer.luau [--key <firmware keys>] "<cmd>" ...
]]
local process = require("@lune/process")
local Shim = require("./RobloxShim")

local root = Shim.mountMany({ LinuxVM = "src/shared", LinuxServer = "src/server", LinuxImages = "src/images" })
local Computer = Shim.require(root.LinuxServer.Computer)
local Disk = Shim.require(root.LinuxVM.Emulator.Disk)
local ImageLoader = Shim.require(root.LinuxVM.Emulator.ImageLoader)
local Terminal = Shim.require(root.LinuxVM.Terminal.Terminal)

local function loadImage(name)
	local mod = root.LinuxImages:FindFirstChild(name)
	if not mod then
		return nil
	end
	local info = Shim.require(mod)
	local chunks = {}
	for n = 1, info.chunks do
		chunks[n] = Shim.require(mod[string.format("Chunk%03d", n)])
	end
	return ImageLoader.fromChunks(info, chunks)
end
local imageCache = {}
local function cachedImage(name)
	if imageCache[name] == nil then
		imageCache[name] = loadImage(name) or false
	end
	return imageCache[name] or nil
end

local computer = Computer.new({
	id = "1",
	ownerName = "Tester",
	hostname = "tester",
	ip = "10.0.0.2",
	mac = "\x02\x00\x0a\x00\x00\x02",
	disk = Disk.new(32 * 1024 * 1024),
	loadImage = cachedImage,
})
-- A viewer's terminal, fed only by the stream, must match the server's screen.
local viewer = Terminal.new(80, 25)
local states = {}
computer.onStateChanged = function(s) table.insert(states, s) end
computer.hostLinkHandler = function(cmd, args, payload, reply)
	reply(true, "host says hi to " .. cmd .. "\n")
end

local function step(seconds)
	local t = os.clock()
	while os.clock() - t < seconds do
		local now = os.clock()
		computer:update(now, 0.01)
		local item = computer:takeStream(now)
		if item then
			if item.kind == "data" then viewer:write(item.payload) else viewer:loadSnapshot(item.payload) end
		end
	end
end

computer:pressPower(os.clock())
step(0.5)
print("----- firmware screen -----")
print(viewer:toText())
local args = process.args
local i = 1
if args[1] == "--key" then
	computer:input((string.gsub(args[2], "\\r", "\r")))
	step(0.3)
	print("----- after firmware keys -----")
	print(viewer:toText())
	i = 3
end
step(8)
for j = i, #args do
	computer:input((string.gsub(args[j], "\\n", "\n")))
	step(3)
end
print("----- final screen -----")
print(viewer:toText())
print("states:", table.concat(states, " -> "), "image:", computer.bootedImage, "instr:", computer.instructions)
print("viewer matches server:", viewer:toText() == computer.terminal:toText())
