--!strict
--[[
	A deliberately small TCP server for the game's gateway (10.0.0.1), enough to
	serve HTTP to the guests' real Linux TCP stacks: handshake, receiving a
	request, sending a response within the client's window, retransmitting if
	acknowledgements stall, and closing.

	The network is lossless except when a guest's receive queue overflows, so
	there's no congestion control, just go-back-N after a timeout.
]]

local Packet = require(script.Parent.Packet)

local MSS = 1400
local RETRANSMIT_AFTER = 0.5
local IDLE_TIMEOUT = 30
local MAX_REQUEST = 16 * 1024

local SYN, ACK, FIN, RST, PSH = 0x02, 0x10, 0x01, 0x04, 0x08

export type Handler = (request: string, respond: (data: string) -> ()) -> ()

type Conn = {
	clientIp: string,
	clientPort: number,
	reply: (segment: string) -> (), -- sends a TCP segment back to the client
	rcvNext: number, -- next byte we expect from the client
	sndUna: number, -- oldest unacknowledged byte we sent
	sndNext: number, -- next byte we'll send
	iss: number, -- our initial sequence number
	clientWindow: number,
	request: string,
	responding: boolean,
	response: string?, -- everything we will send (data), once known
	finSent: boolean,
	lastProgress: number,
	lastActivity: number,
}

local TcpServer = {}
TcpServer.__index = TcpServer

export type TcpServer = typeof(setmetatable(
	{} :: {
		port: number,
		ip: string,
		handler: Handler,
		conns: { [string]: Conn },
		now: () -> number,
	},
	TcpServer
))

function TcpServer.new(ip: string, port: number, handler: Handler, now: (() -> number)?): TcpServer
	return setmetatable({
		port = port,
		ip = ip,
		handler = handler,
		conns = {},
		now = now or os.clock,
	}, TcpServer)
end

local function u32(n: number): number
	return n % 4294967296
end

-- Bytes of `a - b` in sequence space.
local function seqDiff(a: number, b: number): number
	local d = (a - b) % 4294967296
	if d >= 2147483648 then
		d -= 4294967296
	end
	return d
end

function TcpServer._segment(self: TcpServer, conn: Conn, seq: number, flags: number, data: string): string
	local header = string.pack(
		">I2I2I4I4I2I2I2I2",
		self.port,
		conn.clientPort,
		u32(seq),
		u32(conn.rcvNext),
		0x5000 + flags,
		65535,
		0,
		0
	)
	local pseudo = self.ip .. conn.clientIp .. string.pack(">BBI2", 0, Packet.PROTO_TCP, #header + #data)
	local sum = Packet.checksum(pseudo .. header .. data)
	return string.sub(header, 1, 16) .. string.pack(">I2", sum) .. string.sub(header, 19) .. data
end

-- Sends whatever response data (and FIN) the client's window allows.
function TcpServer._pump(self: TcpServer, conn: Conn)
	local response = conn.response
	if not response then
		return
	end
	local base = u32(conn.iss + 1) -- sequence number of response byte 1
	while true do
		local offset = seqDiff(conn.sndNext, base) -- bytes already sent
		local inFlight = seqDiff(conn.sndNext, conn.sndUna)
		if offset >= #response then
			break
		end
		local room = conn.clientWindow - inFlight
		if room <= 0 then
			return
		end
		local n = math.min(MSS, room, #response - offset)
		local data = string.sub(response, offset + 1, offset + n)
		conn.reply(self:_segment(conn, conn.sndNext, ACK + PSH, data))
		conn.sndNext = u32(conn.sndNext + n)
	end
	if not conn.finSent then
		conn.finSent = true
		conn.reply(self:_segment(conn, conn.sndNext, ACK + FIN, ""))
		conn.sndNext = u32(conn.sndNext + 1)
	end
end

-- Handles a TCP segment addressed to this server. `reply` sends a segment back.
function TcpServer.receive(self: TcpServer, srcIp: string, segment: string, reply: (segment: string) -> ())
	if #segment < 20 then
		return
	end
	local srcPort, _dstPort, seq, ack, offsetFlags, window = string.unpack(">I2I2I4I4I2I2", segment)
	local flags = offsetFlags % 256
	local dataOffset = (offsetFlags // 4096) * 4
	local data = string.sub(segment, dataOffset + 1)
	local key = srcIp .. string.pack(">I2", srcPort)
	local conn = self.conns[key]
	local now = self.now()

	if bit32.btest(flags, RST) then
		self.conns[key] = nil
		return
	end

	if bit32.btest(flags, SYN) and not bit32.btest(flags, ACK) then
		local iss = math.random(0, 0x7FFFFFFF)
		conn = {
			clientIp = srcIp,
			clientPort = srcPort,
			reply = reply,
			rcvNext = u32(seq + 1),
			sndUna = iss,
			sndNext = u32(iss + 1),
			iss = iss,
			clientWindow = window,
			request = "",
			responding = false,
			response = nil,
			finSent = false,
			lastProgress = now,
			lastActivity = now,
		}
		self.conns[key] = conn
		reply(self:_segment(conn, iss, SYN + ACK, ""))
		return
	end

	if not conn then
		-- Not ours (or forgotten): reset so the client doesn't hang.
		local rst = Packet.tcpReset(srcIp, self.ip, segment)
		if rst then
			reply(rst)
		end
		return
	end
	conn.lastActivity = now
	conn.clientWindow = window

	if bit32.btest(flags, ACK) and seqDiff(ack, conn.sndUna) > 0 and seqDiff(ack, conn.sndNext) <= 0 then
		conn.sndUna = ack
		conn.lastProgress = now
	end

	local needAck = false
	if #data > 0 then
		if seq == conn.rcvNext and not conn.responding then
			conn.request ..= data
			conn.rcvNext = u32(conn.rcvNext + #data)
			if #conn.request > MAX_REQUEST then
				self.conns[key] = nil
				reply(self:_segment(conn, conn.sndNext, RST, ""))
				return
			end
		end
		needAck = true
	end
	if bit32.btest(flags, FIN) and seq + #data == conn.rcvNext then
		conn.rcvNext = u32(conn.rcvNext + 1)
		needAck = true
	end
	if needAck then
		reply(self:_segment(conn, conn.sndNext, ACK, ""))
	end

	if not conn.responding and string.find(conn.request, "\r\n\r\n", 1, true) then
		conn.responding = true
		self.handler(conn.request, function(response: string)
			if self.conns[key] == conn then
				conn.response = response
				conn.lastProgress = self.now()
				self:_pump(conn)
			end
		end)
	else
		self:_pump(conn)
	end

	-- Done: everything we sent was acknowledged (including our FIN).
	if conn.finSent and conn.sndUna == conn.sndNext then
		self.conns[key] = nil
	end
end

-- Retransmits stalled connections and drops idle ones. Call periodically.
function TcpServer.tick(self: TcpServer)
	local now = self.now()
	for key, conn in self.conns do
		if now - conn.lastActivity > IDLE_TIMEOUT then
			self.conns[key] = nil
		elseif conn.response and conn.sndUna ~= conn.sndNext and now - conn.lastProgress > RETRANSMIT_AFTER then
			-- Go back to the oldest unacknowledged byte and send again.
			conn.sndNext = conn.sndUna
			conn.finSent = false
			conn.lastProgress = now
			self:_pump(conn)
		end
	end
end

return TcpServer
