--!strict
--[[
	virtio network card. Shows up in Linux as eth0.

	Frames the guest sends are passed to `onTransmit` as raw Ethernet frames
	(strings); frames from the outside world are handed in with `receive`.
	The game connects these to a virtual switch so player computers can talk.
]]

local VirtioMmio = require(script.Parent.VirtioMmio)

local RX_QUEUE = 0
local TX_QUEUE = 1
local NET_HDR_SIZE = 12 -- struct virtio_net_hdr_v1
local VIRTIO_NET_F_MAC = bit32.lshift(1, 5)
local MAX_PENDING = 64

local VirtioNet = {}
VirtioNet.__index = VirtioNet

export type VirtioNet = typeof(setmetatable(
	{} :: {
		transport: VirtioMmio.VirtioMmio,
		mac: string,
		pending: { string },
		onTransmit: ((frame: string) -> ())?,
		txFrames: number,
		rxFrames: number,
		rxDropped: number,
	},
	VirtioNet
))

function VirtioNet.new(ram: buffer, mac: string, setIrq: (boolean) -> ()): VirtioNet
	assert(#mac == 6, "MAC address must be 6 bytes")
	local self = setmetatable({}, VirtioNet) :: any
	self.mac = mac
	self.pending = {}
	self.onTransmit = nil
	self.txFrames = 0
	self.rxFrames = 0
	self.rxDropped = 0

	local config = buffer.create(16)
	buffer.writestring(config, 0, mac)

	self.transport = VirtioMmio.new(ram, {
		deviceId = 1,
		numQueues = 2,
		queueMax = 64,
		featuresLow = VIRTIO_NET_F_MAC,
		featuresHigh = 0,
		configRead = function(offset: number): number
			if offset + 4 <= buffer.len(config) then
				return buffer.readu32(config, offset)
			end
			return 0
		end,
		notify = function(queue: number)
			if queue == TX_QUEUE then
				self:_transmit()
			else
				self:_deliver()
			end
		end,
		reset = function()
			table.clear(self.pending)
		end,
	}, setIrq)
	return self :: VirtioNet
end

function VirtioNet._transmit(self: VirtioNet)
	local transport = self.transport
	local ram = transport.ram
	local any = false
	while true do
		local head = transport:popAvail(TX_QUEUE)
		if not head then
			break
		end
		any = true
		local parts = {}
		for _, d in transport:readChain(TX_QUEUE, head) do
			if not d.write then
				table.insert(parts, buffer.readstring(ram, d.addr, d.len))
			end
		end
		local packet = table.concat(parts)
		transport:pushUsed(TX_QUEUE, head, 0)
		if #packet > NET_HDR_SIZE then
			self.txFrames += 1
			local onTransmit = self.onTransmit
			if onTransmit then
				onTransmit(string.sub(packet, NET_HDR_SIZE + 1))
			end
		end
	end
	if any then
		transport:interrupt()
	end
end

function VirtioNet._deliver(self: VirtioNet)
	local transport = self.transport
	if not transport:isReady() then
		return
	end
	local ram = transport.ram
	local any = false
	while #self.pending > 0 do
		local head = transport:popAvail(RX_QUEUE)
		if not head then
			break
		end
		local frame = table.remove(self.pending, 1) :: string
		-- Header: no checksum offload, no GSO, num_buffers = 1.
		local packet = string.rep("\0", NET_HDR_SIZE - 2) .. "\1\0" .. frame
		local pos = 1
		local written = 0
		for _, d in transport:readChain(RX_QUEUE, head) do
			if d.write and pos <= #packet then
				local piece = string.sub(packet, pos, pos + d.len - 1)
				buffer.writestring(ram, d.addr, piece)
				pos += #piece
				written += #piece
			end
		end
		transport:pushUsed(RX_QUEUE, head, written)
		self.rxFrames += 1
		any = true
	end
	if any then
		transport:interrupt()
	end
end

-- Queues an Ethernet frame for the guest.
function VirtioNet.receive(self: VirtioNet, frame: string)
	if #self.pending >= MAX_PENDING then
		self.rxDropped += 1
		return
	end
	table.insert(self.pending, frame)
	self:_deliver()
end

return VirtioNet
