--!strict
--[[
	virtio block device backed by a sparse Disk. Shows up in Linux as /dev/vda.
]]

local Disk = require(script.Parent.Disk)
local VirtioMmio = require(script.Parent.VirtioMmio)

local VIRTIO_BLK_T_IN = 0
local VIRTIO_BLK_T_OUT = 1
local VIRTIO_BLK_T_FLUSH = 4
local VIRTIO_BLK_T_GET_ID = 8

local VIRTIO_BLK_F_FLUSH = bit32.lshift(1, 9)

local STATUS_OK = 0
local STATUS_IOERR = 1
local STATUS_UNSUPP = 2

local VirtioBlk = {}
VirtioBlk.__index = VirtioBlk

export type VirtioBlk = typeof(setmetatable(
	{} :: {
		disk: Disk.Disk,
		transport: VirtioMmio.VirtioMmio,
		config: buffer,
		-- Called when the guest flushes (e.g. `sync`): a good moment to save.
		onFlush: (() -> ())?,
	},
	VirtioBlk
))

function VirtioBlk.new(ram: buffer, disk: Disk.Disk, setIrq: (boolean) -> ()): VirtioBlk
	local self = setmetatable({}, VirtioBlk) :: any
	self.disk = disk
	self.onFlush = nil

	-- Config space: capacity (u64, in 512-byte sectors).
	local config = buffer.create(64)
	buffer.writeu32(config, 0, disk.size // 512)
	self.config = config

	self.transport = VirtioMmio.new(ram, {
		deviceId = 2,
		numQueues = 1,
		queueMax = 64,
		featuresLow = VIRTIO_BLK_F_FLUSH,
		featuresHigh = 0,
		configRead = function(offset: number): number
			if offset + 4 <= buffer.len(config) then
				return buffer.readu32(config, offset)
			end
			return 0
		end,
		notify = function()
			self:_process()
		end,
	}, setIrq)
	return self :: VirtioBlk
end

function VirtioBlk._process(self: VirtioBlk)
	local transport = self.transport
	local ram = transport.ram
	local disk = self.disk
	local any = false
	while true do
		local head = transport:popAvail(0)
		if not head then
			break
		end
		any = true
		local chain = transport:readChain(0, head)
		local written = 0
		local status = STATUS_OK
		local header = chain[1]
		local statusDesc = chain[#chain]
		if #chain < 2 or not header or header.len < 16 or not statusDesc.write then
			status = STATUS_IOERR
		else
			local kind = buffer.readu32(ram, header.addr)
			local sector = buffer.readu32(ram, header.addr + 8) + buffer.readu32(ram, header.addr + 12) * 4294967296
			local pos = sector * 512
			if kind == VIRTIO_BLK_T_IN or kind == VIRTIO_BLK_T_OUT then
				for i = 2, #chain - 1 do
					local d = chain[i]
					if pos + d.len > disk.size then
						status = STATUS_IOERR
						break
					end
					if kind == VIRTIO_BLK_T_IN then
						disk:readInto(pos, d.len, ram, d.addr)
						written += d.len
					else
						disk:writeFrom(pos, d.len, ram, d.addr)
					end
					pos += d.len
				end
			elseif kind == VIRTIO_BLK_T_FLUSH then
				local onFlush = self.onFlush
				if onFlush then
					onFlush()
				end
			elseif kind == VIRTIO_BLK_T_GET_ID then
				local d = chain[2]
				if d and d.write then
					local id = string.sub("brick-disk" .. string.rep("\0", 20), 1, math.min(20, d.len))
					buffer.writestring(ram, d.addr, id)
					written += #id
				end
			else
				status = STATUS_UNSUPP
			end
		end
		if statusDesc and statusDesc.write and statusDesc.len >= 1 then
			buffer.writeu8(ram, statusDesc.addr, status)
			written += 1
		end
		transport:pushUsed(0, head, written)
	end
	if any then
		transport:interrupt()
	end
end

return VirtioBlk
