--!strict
--[[
	Sparse block storage for a virtual disk.

	Only blocks that have been written take memory; everything else reads as
	zeros. Written blocks are tracked as dirty so the owner can persist just the
	changes (see DiskStore on the server).
]]

local Lz4 = require(script.Parent.Parent.Util.Lz4)

local Disk = {}
Disk.__index = Disk

local MAGIC = "BDSK"
local FORMAT_VERSION = 1

local function isZero(b: buffer, offset: number, len: number): boolean
	local readu32 = buffer.readu32
	for i = offset, offset + len - 4, 4 do
		if readu32(b, i) ~= 0 then
			return false
		end
	end
	return true
end

export type Disk = typeof(setmetatable(
	{} :: {
		size: number,
		blockSize: number,
		blocks: { [number]: buffer },
		dirty: { [number]: boolean },
		-- Bumped on every write; lets savers notice changes cheaply.
		generation: number,
	},
	Disk
))

function Disk.new(size: number, blockSize: number?): Disk
	local bs = blockSize or 4096
	assert(size % bs == 0, "disk size must be a multiple of the block size")
	return setmetatable({
		size = size,
		blockSize = bs,
		blocks = {},
		dirty = {},
		generation = 0,
	}, Disk)
end

-- Copies `len` bytes at disk offset `offset` into `dst` at `dstOffset`.
function Disk.readInto(self: Disk, offset: number, len: number, dst: buffer, dstOffset: number)
	local bs = self.blockSize
	while len > 0 do
		local index = offset // bs
		local within = offset % bs
		local n = math.min(len, bs - within)
		local block = self.blocks[index]
		if block then
			buffer.copy(dst, dstOffset, block, within, n)
		else
			buffer.fill(dst, dstOffset, 0, n)
		end
		offset += n
		dstOffset += n
		len -= n
	end
end

-- Copies `len` bytes from `src` at `srcOffset` to disk offset `offset`.
function Disk.writeFrom(self: Disk, offset: number, len: number, src: buffer, srcOffset: number)
	local bs = self.blockSize
	while len > 0 do
		local index = offset // bs
		local within = offset % bs
		local n = math.min(len, bs - within)
		local block = self.blocks[index]
		if n == bs and isZero(src, srcOffset, n) then
			-- A whole block of zeros (mkfs does lots of these): store nothing.
			if block then
				self.blocks[index] = nil
				self.dirty[index] = true
			end
		else
			if not block then
				block = buffer.create(bs)
				self.blocks[index] = block
			end
			buffer.copy(block, within, src, srcOffset, n)
			self.dirty[index] = true
		end
		offset += n
		srcOffset += n
		len -= n
	end
	self.generation += 1
end

-- Number of blocks currently holding data.
function Disk.usedBlocks(self: Disk): number
	local n = 0
	for _ in self.blocks do
		n += 1
	end
	return n
end

--[[
	Serializes the disk contents into one compressed buffer:
		"BDSK", version u8, blockSize u32, size u32, count u32,
		count x block index u32, count x block data
	then LZ4-compressed, prefixed by the uncompressed length (u32).
]]
function Disk.serialize(self: Disk): buffer
	local indices = {}
	for index in self.blocks do
		table.insert(indices, index)
	end
	table.sort(indices)
	local count = #indices
	local bs = self.blockSize
	local headerSize = 17 + 4 * count
	local raw = buffer.create(headerSize + count * bs)
	buffer.writestring(raw, 0, MAGIC)
	buffer.writeu8(raw, 4, FORMAT_VERSION)
	buffer.writeu32(raw, 5, bs)
	buffer.writeu32(raw, 9, self.size)
	buffer.writeu32(raw, 13, count)
	for i, index in indices do
		buffer.writeu32(raw, 17 + 4 * (i - 1), index)
		buffer.copy(raw, headerSize + (i - 1) * bs, self.blocks[index], 0, bs)
	end
	local packed = Lz4.compress(raw)
	local out = buffer.create(4 + buffer.len(packed))
	buffer.writeu32(out, 0, buffer.len(raw))
	buffer.copy(out, 4, packed, 0, buffer.len(packed))
	return out
end

function Disk.deserialize(data: buffer): Disk
	local rawSize = buffer.readu32(data, 0)
	local packed = buffer.create(buffer.len(data) - 4)
	buffer.copy(packed, 0, data, 4, buffer.len(packed))
	local raw = Lz4.decompress(packed, rawSize)
	assert(buffer.readstring(raw, 0, 4) == MAGIC, "not a disk image")
	assert(buffer.readu8(raw, 4) == FORMAT_VERSION, "unsupported disk image version")
	local bs = buffer.readu32(raw, 5)
	local disk = Disk.new(buffer.readu32(raw, 9), bs)
	local count = buffer.readu32(raw, 13)
	local headerSize = 17 + 4 * count
	for i = 1, count do
		local index = buffer.readu32(raw, 17 + 4 * (i - 1))
		local block = buffer.create(bs)
		buffer.copy(block, 0, raw, headerSize + (i - 1) * bs, bs)
		disk.blocks[index] = block
	end
	return disk
end

-- Returns and clears the set of dirty block indices.
function Disk.takeDirty(self: Disk): { number }
	local list = {}
	for index in self.dirty do
		table.insert(list, index)
	end
	table.clear(self.dirty)
	table.sort(list)
	return list
end

return Disk
