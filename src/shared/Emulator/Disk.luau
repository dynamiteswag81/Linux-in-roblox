--!strict
--[[
	Sparse block storage for a virtual disk.

	Only blocks that have been written take memory; everything else reads as
	zeros. Written blocks are tracked as dirty so the owner can persist just the
	changes (see DiskStore on the server).
]]

local Disk = {}
Disk.__index = Disk

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
		if not block then
			block = buffer.create(bs)
			self.blocks[index] = block
		end
		buffer.copy(block, within, src, srcOffset, n)
		self.dirty[index] = true
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
