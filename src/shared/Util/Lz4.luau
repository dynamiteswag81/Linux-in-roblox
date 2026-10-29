--!native
--!optimize 2
--[[
	LZ4 block format compressor and decompressor working on buffers.

	Used to keep disk images and workshop packages small in DataStores, and
	(via tools/image2luau.py, which writes the same format) for kernel images.
]]

local Lz4 = {}

local MIN_MATCH = 4
local MAX_OFFSET = 65535
local HASH_SIZE = 65536

-- Compresses `len` bytes of `src` (default: all of it). Returns a new buffer.
function Lz4.compress(src: buffer, len: number?): buffer
	local n = len or buffer.len(src)
	local readu8, readu32, writeu8 = buffer.readu8, buffer.readu32, buffer.writeu8
	-- Worst case output: n + n/255 + 16.
	local out = buffer.create(n + n // 255 + 16)
	local o = 0
	local hashTable = table.create(HASH_SIZE, -1)
	local anchor = 0
	local i = 0
	local matchLimit = n - 12
	local endLiterals = n - 5

	local function emitLength(rest: number)
		while rest >= 255 do
			writeu8(out, o, 255)
			o += 1
			rest -= 255
		end
		writeu8(out, o, rest)
		o += 1
	end

	local function emit(litStart: number, litLen: number, offset: number, matchLen: number)
		local tokenLit = math.min(litLen, 15)
		local tokenMatch = if matchLen < 0 then 0 else math.min(matchLen - MIN_MATCH, 15)
		writeu8(out, o, tokenLit * 16 + tokenMatch)
		o += 1
		if litLen >= 15 then
			emitLength(litLen - 15)
		end
		if litLen > 0 then
			buffer.copy(out, o, src, litStart, litLen)
			o += litLen
		end
		if matchLen < 0 then
			return
		end
		writeu8(out, o, offset % 256)
		writeu8(out, o + 1, offset // 256)
		o += 2
		if matchLen - MIN_MATCH >= 15 then
			emitLength(matchLen - MIN_MATCH - 15)
		end
	end

	while i < matchLimit do
		local seq = readu32(src, i)
		-- Multiplicative hash of the next 4 bytes, kept exact in doubles.
		local h = ((seq * 2654435761) // 65536) % HASH_SIZE + 1
		local candidate = hashTable[h]
		hashTable[h] = i
		if candidate >= 0 and i - candidate <= MAX_OFFSET and readu32(src, candidate) == seq then
			local length = 4
			while i + length < endLiterals and readu8(src, candidate + length) == readu8(src, i + length) do
				length += 1
			end
			emit(anchor, i - anchor, i - candidate, length)
			i += length
			anchor = i
		else
			i += 1
		end
	end
	emit(anchor, n - anchor, 0, -1)

	local result = buffer.create(o)
	buffer.copy(result, 0, out, 0, o)
	return result
end

-- Expands an LZ4 block into a new buffer of `size` bytes.
function Lz4.decompress(src: buffer, size: number, srcLen: number?): buffer
	local dst = buffer.create(size)
	local written = Lz4.decompressInto(src, srcLen or buffer.len(src), dst)
	assert(written == size, "lz4: corrupt data (wrong decompressed size)")
	return dst
end

-- Expands an LZ4 block (`srcLen` bytes of `src`) into `dst`. Returns bytes written.
function Lz4.decompressInto(src: buffer, srcLen: number, dst: buffer): number
	local readu8 = buffer.readu8
	local bcopy = buffer.copy
	local dstLen = buffer.len(dst)
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
			assert(o + lit <= dstLen and i + lit <= srcLen, "lz4: corrupt data (literal overrun)")
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
		mlen += MIN_MATCH
		local from = o - offset
		assert(offset > 0 and from >= 0 and o + mlen <= dstLen, "lz4: corrupt data (bad match)")
		if offset >= mlen then
			bcopy(dst, o, dst, from, mlen)
			o += mlen
		else
			-- Overlapping match (a repeating pattern): copy in offset-sized steps.
			while mlen > 0 do
				local step = math.min(offset, mlen)
				bcopy(dst, o, dst, from, step)
				o += step
				mlen -= step
			end
		end
	end
	return o
end

return Lz4
