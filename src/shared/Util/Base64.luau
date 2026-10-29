--!native
--!optimize 2
--[[
	Base64 encoding/decoding between buffers and strings (DataStores only hold
	text, and kernel images are stored as base64 in ModuleScripts).
]]

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENCODE = table.create(64)
local DECODE = table.create(256, 0)
for i = 1, 64 do
	local byte = string.byte(ALPHABET, i)
	ENCODE[i] = byte
	DECODE[byte + 1] = i - 1
end

-- Encodes `len` bytes of `src` (default: all) as base64 text.
function Base64.encode(src: buffer, len: number?): string
	local n = len or buffer.len(src)
	local readu8, writeu8 = buffer.readu8, buffer.writeu8
	local out = buffer.create((n + 2) // 3 * 4)
	local o = 0
	local i = 0
	while i + 3 <= n do
		local v = readu8(src, i) * 65536 + readu8(src, i + 1) * 256 + readu8(src, i + 2)
		writeu8(out, o, ENCODE[v // 262144 + 1])
		writeu8(out, o + 1, ENCODE[(v // 4096) % 64 + 1])
		writeu8(out, o + 2, ENCODE[(v // 64) % 64 + 1])
		writeu8(out, o + 3, ENCODE[v % 64 + 1])
		i += 3
		o += 4
	end
	local rest = n - i
	if rest == 1 then
		local v = readu8(src, i) * 65536
		writeu8(out, o, ENCODE[v // 262144 + 1])
		writeu8(out, o + 1, ENCODE[(v // 4096) % 64 + 1])
		writeu8(out, o + 2, 61)
		writeu8(out, o + 3, 61)
	elseif rest == 2 then
		local v = readu8(src, i) * 65536 + readu8(src, i + 1) * 256
		writeu8(out, o, ENCODE[v // 262144 + 1])
		writeu8(out, o + 1, ENCODE[(v // 4096) % 64 + 1])
		writeu8(out, o + 2, ENCODE[(v // 64) % 64 + 1])
		writeu8(out, o + 3, 61)
	end
	return buffer.tostring(out)
end

-- Number of bytes `text` decodes to.
function Base64.decodedSize(text: string): number
	local size = #text // 4 * 3
	if string.sub(text, -2) == "==" then
		size -= 2
	elseif string.sub(text, -1) == "=" then
		size -= 1
	end
	return size
end

-- Decodes base64 text into `out` starting at `offset`. Returns the new offset.
function Base64.decodeInto(text: string, out: buffer, offset: number): number
	local src = buffer.fromstring(text)
	local len = buffer.len(src)
	local readu8, writeu8 = buffer.readu8, buffer.writeu8
	local o = offset
	local i = 0
	while i + 4 <= len do
		local c3 = readu8(src, i + 2)
		local d3 = readu8(src, i + 3)
		local v = DECODE[readu8(src, i) + 1] * 262144 + DECODE[readu8(src, i + 1) + 1] * 4096
		writeu8(out, o, v // 65536)
		o += 1
		if c3 ~= 61 then -- '='
			v += DECODE[c3 + 1] * 64
			writeu8(out, o, (v // 256) % 256)
			o += 1
			if d3 ~= 61 then
				v += DECODE[d3 + 1]
				writeu8(out, o, v % 256)
				o += 1
			end
		end
		i += 4
	end
	return o
end

function Base64.decode(text: string): buffer
	local out = buffer.create(Base64.decodedSize(text))
	Base64.decodeInto(text, out, 0)
	return out
end

return Base64
