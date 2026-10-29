--!strict
--[[
	Loads kernel images stored as ModuleScripts by tools/image2luau.py.

	An image is a ModuleScript whose init returns metadata
	({ name, size, compressedSize, chunks, format = "lz4+base64" }) and whose
	children Chunk001, Chunk002, ... each return a base64 string. The decoded
	bytes are an LZ4 block that expands to the original image.
]]

local Base64 = require(script.Parent.Parent.Util.Base64)
local Lz4 = require(script.Parent.Parent.Util.Lz4)

local ImageLoader = {}

export type ImageInfo = {
	name: string,
	description: string?,
	format: string,
	size: number,
	compressedSize: number,
	sha256: string?,
	chunks: number,
}

-- Decodes an image from its base64 chunk strings and metadata.
function ImageLoader.fromChunks(info: ImageInfo, chunks: { string }): buffer
	assert(info.format == "lz4+base64", "unsupported image format " .. tostring(info.format))
	local packed = buffer.create(info.compressedSize)
	local offset = 0
	for _, chunk in chunks do
		offset = Base64.decodeInto(chunk, packed, offset)
	end
	assert(offset == info.compressedSize, "image is truncated or corrupt")
	return Lz4.decompress(packed, info.size)
end

local cache: { [any]: buffer } = {}

-- Loads an image from a ModuleScript produced by tools/image2luau.py (cached).
function ImageLoader.load(module: ModuleScript): buffer
	local cached = cache[module]
	if cached then
		return cached
	end
	local info = (require :: any)(module) :: ImageInfo
	local chunks = table.create(info.chunks)
	for n = 1, info.chunks do
		local child = (module :: any):FindFirstChild(string.format("Chunk%03d", n))
		assert(child, string.format("image %s is missing Chunk%03d", info.name, n))
		chunks[n] = (require :: any)(child)
	end
	local image = ImageLoader.fromChunks(info, chunks)
	cache[module] = image
	return image
end

return ImageLoader
