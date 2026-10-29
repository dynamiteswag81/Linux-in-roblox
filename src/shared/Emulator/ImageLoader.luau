--!native
--!optimize 2
--[[
	Loads disk/kernel images stored as ModuleScripts by tools/image2luau.py.

	An image is a Folder/ModuleScript whose init returns metadata
	({ name, size, compressedSize, chunks, format = "lz4+base64" }) and whose
	children Chunk001, Chunk002, ... each return a base64 string. The decoded
	bytes are an LZ4 block that expands to the original image.
]]

local ImageLoader = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE = table.create(256, -1)
for i = 1, 64 do
	DECODE[string.byte(B64, i) + 1] = i - 1
end

-- Decodes base64 text into `out` starting at `offset`. Returns the new offset.
function ImageLoader.decodeBase64Into(text: string, out: buffer, offset: number): number
	local src = buffer.fromstring(text)
	local len = buffer.len(src)
	local readu8 = buffer.readu8
	local writeu8 = buffer.writeu8
	local o = offset
	local i = 0
	while i + 4 <= len do
		local a = DECODE[readu8(src, i) + 1]
		local b = DECODE[readu8(src, i + 1) + 1]
		local c3 = readu8(src, i + 2)
		local d3 = readu8(src, i + 3)
		local n = a * 262144 + b * 4096
		writeu8(out, o, n // 65536)
		o += 1
		if c3 ~= 61 then -- '='
			local c = DECODE[c3 + 1]
			n += c * 64
			writeu8(out, o, (n // 256) % 256)
			o += 1
			if d3 ~= 61 then
				n += DECODE[d3 + 1]
				writeu8(out, o, n % 256)
				o += 1
			end
		end
		i += 4
	end
	return o
end

function ImageLoader.base64Size(text: string): number
	local len = #text
	local size = len // 4 * 3
	if string.sub(text, -2) == "==" then
		size -= 2
	elseif string.sub(text, -1) == "=" then
		size -= 1
	end
	return size
end

-- Expands an LZ4 block (`src`, `srcLen` bytes) into `dst`. Returns bytes written.
function ImageLoader.lz4Decompress(src: buffer, srcLen: number, dst: buffer): number
	local readu8 = buffer.readu8
	local bcopy = buffer.copy
	local i = 0
	local o = 0
	while i < srcLen do
		local token = readu8(src, i)
		i += 1
		local lit = token // 16
		if lit == 15 then
			repeat
				local b = readu8(src, i)
				i += 1
				lit += b
			until b ~= 255
		end
		if lit > 0 then
			bcopy(dst, o, src, i, lit)
			i += lit
			o += lit
		end
		if i >= srcLen then
			break
		end
		local offset = readu8(src, i) + readu8(src, i + 1) * 256
		i += 2
		local mlen = token % 16
		if mlen == 15 then
			repeat
				local b = readu8(src, i)
				i += 1
				mlen += b
			until b ~= 255
		end
		mlen += 4
		local from = o - offset
		if offset >= mlen then
			bcopy(dst, o, dst, from, mlen)
			o += mlen
		else
			-- Overlapping match (a repeating pattern): copy in offset-sized steps.
			while mlen > 0 do
				local n = math.min(offset, mlen)
				bcopy(dst, o, dst, from, n)
				o += n
				mlen -= n
			end
		end
	end
	return o
end

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
		offset = ImageLoader.decodeBase64Into(chunk, packed, offset)
	end
	assert(offset == info.compressedSize, "image is truncated or corrupt")
	local out = buffer.create(info.size)
	local written = ImageLoader.lz4Decompress(packed, info.compressedSize, out)
	assert(written == info.size, "image decompressed to the wrong size")
	return out
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
