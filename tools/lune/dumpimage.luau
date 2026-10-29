--[[
	Writes a kernel image stored as Luau modules (src/images/<name>) back to a
	file, e.g. to boot it in QEMU and compare with the emulator.

	lune run tools/lune/dumpimage.luau <name> <out file>
]]
local fs = require("@lune/fs")
local process = require("@lune/process")
local Shim = require("./RobloxShim")

local name, out = process.args[1], process.args[2]
assert(name and out, "usage: dumpimage.luau <name> <out file>")

local root = Shim.mountMany({ LinuxVM = "src/shared", LinuxImages = "src/images" })
local ImageLoader = Shim.require(root.LinuxVM.Emulator.ImageLoader)

local mod = root.LinuxImages:FindFirstChild(name)
assert(mod, "no image named " .. name)
local info = Shim.require(mod)
local chunks = {}
for n = 1, info.chunks do
	chunks[n] = Shim.require(mod[string.format("Chunk%03d", n)])
end
local image = ImageLoader.fromChunks(info, chunks)
fs.writeFile(out, buffer.tostring(image))
print(string.format("%s: %d bytes -> %s", name, buffer.len(image), out))
