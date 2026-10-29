--!strict
--[[
	virtio-mmio transport (virtio 1.x "modern" register layout) with split
	virtqueues. Concrete devices (VirtioBlk, VirtioNet) supply a device id,
	feature bits, a config space, and a notify handler; this module handles the
	register interface and walking descriptor chains in guest RAM.
]]

local RAM_BASE = 0x80000000

local DESC_F_NEXT = 1
local DESC_F_WRITE = 2

local VirtioMmio = {}
VirtioMmio.__index = VirtioMmio

export type Queue = {
	num: number,
	ready: boolean,
	desc: number, -- guest physical addresses
	avail: number,
	used: number,
	lastAvail: number,
}

export type Descriptor = {
	addr: number, -- offset into RAM
	len: number,
	write: boolean,
}

export type DeviceSpec = {
	deviceId: number,
	numQueues: number,
	queueMax: number,
	featuresLow: number,
	featuresHigh: number, -- VIRTIO_F_VERSION_1 (bit 0 here) is always added
	configRead: (offset: number) -> number,
	configWrite: ((offset: number, value: number) -> ())?,
	notify: (queue: number) -> (),
	reset: (() -> ())?,
}

export type VirtioMmio = typeof(setmetatable(
	{} :: {
		ram: buffer,
		ramSize: number,
		spec: DeviceSpec,
		queues: { Queue },
		status: number,
		interruptStatus: number,
		deviceFeaturesSel: number,
		driverFeaturesSel: number,
		driverFeatures: { number },
		queueSel: number,
		setIrq: (high: boolean) -> (),
	},
	VirtioMmio
))

function VirtioMmio.new(ram: buffer, spec: DeviceSpec, setIrq: (high: boolean) -> ()): VirtioMmio
	local self = setmetatable({
		ram = ram,
		ramSize = buffer.len(ram),
		spec = spec,
		queues = {},
		status = 0,
		interruptStatus = 0,
		deviceFeaturesSel = 0,
		driverFeaturesSel = 0,
		driverFeatures = { 0, 0 },
		queueSel = 0,
		setIrq = setIrq,
	}, VirtioMmio)
	self:reset()
	return self
end

function VirtioMmio.reset(self: VirtioMmio)
	table.clear(self.queues)
	for i = 1, self.spec.numQueues do
		self.queues[i] = { num = 0, ready = false, desc = 0, avail = 0, used = 0, lastAvail = 0 }
	end
	self.status = 0
	self.interruptStatus = 0
	self.driverFeatures = { 0, 0 }
	self.queueSel = 0
	self.setIrq(false)
	if self.spec.reset then
		self.spec.reset()
	end
end

function VirtioMmio.isReady(self: VirtioMmio): boolean
	return bit32.btest(self.status, 4) -- DRIVER_OK
end

function VirtioMmio.read(self: VirtioMmio, offset: number): number
	if offset >= 0x100 then
		return self.spec.configRead(offset - 0x100)
	elseif offset == 0x000 then
		return 0x74726976 -- "virt"
	elseif offset == 0x004 then
		return 2 -- modern interface
	elseif offset == 0x008 then
		return self.spec.deviceId
	elseif offset == 0x00C then
		return 0x4B435242 -- vendor "BRCK"
	elseif offset == 0x010 then
		if self.deviceFeaturesSel == 0 then
			return self.spec.featuresLow
		elseif self.deviceFeaturesSel == 1 then
			return bit32.bor(self.spec.featuresHigh, 1) -- VIRTIO_F_VERSION_1
		end
		return 0
	elseif offset == 0x034 then
		local q = self.queues[self.queueSel + 1]
		return if q then self.spec.queueMax else 0
	elseif offset == 0x044 then
		local q = self.queues[self.queueSel + 1]
		return if q and q.ready then 1 else 0
	elseif offset == 0x060 then
		return self.interruptStatus
	elseif offset == 0x070 then
		return self.status
	elseif offset == 0x0FC then
		return 0 -- config generation
	end
	return 0
end

function VirtioMmio.write(self: VirtioMmio, offset: number, value: number)
	if offset >= 0x100 then
		local configWrite = self.spec.configWrite
		if configWrite then
			configWrite(offset - 0x100, value)
		end
		return
	end
	local q = self.queues[self.queueSel + 1]
	if offset == 0x014 then
		self.deviceFeaturesSel = value
	elseif offset == 0x020 then
		self.driverFeatures[self.driverFeaturesSel + 1] = value
	elseif offset == 0x024 then
		self.driverFeaturesSel = math.min(value, 1)
	elseif offset == 0x030 then
		self.queueSel = value
	elseif offset == 0x038 then
		if q then
			q.num = math.min(value, self.spec.queueMax)
		end
	elseif offset == 0x044 then
		if q then
			q.ready = value == 1
		end
	elseif offset == 0x050 then
		local queue = self.queues[value + 1]
		if queue and queue.ready and self:isReady() then
			self.spec.notify(value)
		end
	elseif offset == 0x064 then
		self.interruptStatus = bit32.band(self.interruptStatus, bit32.bnot(value))
		if self.interruptStatus == 0 then
			self.setIrq(false)
		end
	elseif offset == 0x070 then
		if value == 0 then
			self:reset()
		else
			self.status = value
		end
	elseif q then
		if offset == 0x080 then
			q.desc = value
		elseif offset == 0x090 then
			q.avail = value
		elseif offset == 0x0A0 then
			q.used = value
		end
		-- High halves (0x084, 0x094, 0x0A4) are always 0 on a 32-bit machine.
	end
end

-- Returns the head index of the next available descriptor chain, or nil.
function VirtioMmio.popAvail(self: VirtioMmio, queueIndex: number): number?
	local q = self.queues[queueIndex + 1]
	if not q or not q.ready or q.num == 0 then
		return nil
	end
	local ram = self.ram
	local availOfs = q.avail - RAM_BASE
	local availIdx = buffer.readu16(ram, availOfs + 2)
	if q.lastAvail == availIdx then
		return nil
	end
	local head = buffer.readu16(ram, availOfs + 4 + 2 * (q.lastAvail % q.num))
	q.lastAvail = (q.lastAvail + 1) % 65536
	return head
end

-- Whether the driver has posted buffers we haven't consumed yet.
function VirtioMmio.hasAvail(self: VirtioMmio, queueIndex: number): boolean
	local q = self.queues[queueIndex + 1]
	if not q or not q.ready or q.num == 0 then
		return false
	end
	return q.lastAvail ~= buffer.readu16(self.ram, q.avail - RAM_BASE + 2)
end

-- Reads the descriptor chain starting at `head` (addresses converted to RAM offsets).
function VirtioMmio.readChain(self: VirtioMmio, queueIndex: number, head: number): { Descriptor }
	local q = self.queues[queueIndex + 1]
	local ram = self.ram
	local descBase = q.desc - RAM_BASE
	local chain: { Descriptor } = {}
	local index = head
	for _ = 1, q.num do
		local d = descBase + 16 * index
		local addr = buffer.readu32(ram, d) - RAM_BASE
		local len = buffer.readu32(ram, d + 8)
		local flags = buffer.readu16(ram, d + 12)
		if addr < 0 or addr + len > self.ramSize then
			break -- bogus pointer: stop rather than fault the host
		end
		table.insert(chain, { addr = addr, len = len, write = bit32.btest(flags, DESC_F_WRITE) })
		if not bit32.btest(flags, DESC_F_NEXT) then
			break
		end
		index = buffer.readu16(ram, d + 14)
	end
	return chain
end

-- Returns a completed chain to the driver and raises the interrupt.
function VirtioMmio.pushUsed(self: VirtioMmio, queueIndex: number, head: number, written: number)
	local q = self.queues[queueIndex + 1]
	local ram = self.ram
	local usedOfs = q.used - RAM_BASE
	local usedIdx = buffer.readu16(ram, usedOfs + 2)
	local slot = usedOfs + 4 + 8 * (usedIdx % q.num)
	buffer.writeu32(ram, slot, head)
	buffer.writeu32(ram, slot + 4, written)
	buffer.writeu16(ram, usedOfs + 2, (usedIdx + 1) % 65536)
end

function VirtioMmio.interrupt(self: VirtioMmio)
	self.interruptStatus = bit32.bor(self.interruptStatus, 1)
	self.setIrq(true)
end

return VirtioMmio
