--!strict
--[[
	Helpers for reading and building the few packet types the game's virtual
	gateway understands: Ethernet, ARP, IPv4, ICMP echo, UDP, DNS, TCP resets.
	Frames are Luau strings.
]]

local Packet = {}

Packet.BROADCAST = string.rep("\255", 6)
Packet.ETH_IPV4 = 0x0800
Packet.ETH_ARP = 0x0806
Packet.PROTO_ICMP = 1
Packet.PROTO_TCP = 6
Packet.PROTO_UDP = 17

function Packet.u16(s: string, pos: number): number
	return string.unpack(">I2", s, pos)
end

function Packet.u32(s: string, pos: number): number
	return string.unpack(">I4", s, pos)
end

function Packet.ipToString(ip: string): string
	return string.format("%d.%d.%d.%d", string.byte(ip, 1, 4))
end

function Packet.ipFromString(text: string): string?
	local a, b, c, d = string.match(text, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then
		return nil
	end
	return string.char(tonumber(a) :: number, tonumber(b) :: number, tonumber(c) :: number, tonumber(d) :: number)
end

function Packet.macToString(mac: string): string
	local parts = {}
	for i = 1, 6 do
		parts[i] = string.format("%02x", string.byte(mac, i))
	end
	return table.concat(parts, ":")
end

-- Internet checksum (RFC 1071) over `data`, optionally continuing from `initial`.
function Packet.checksum(data: string, initial: number?): number
	local sum = initial or 0
	local n = #data
	local i = 1
	while i < n do
		sum += string.byte(data, i) * 256 + string.byte(data, i + 1)
		i += 2
	end
	if i == n then
		sum += string.byte(data, i) * 256
	end
	while sum > 0xFFFF do
		sum = (sum % 65536) + (sum // 65536)
	end
	return 0xFFFF - sum
end

export type Ethernet = { dst: string, src: string, type: number, payload: string }

function Packet.parseEthernet(frame: string): Ethernet?
	if #frame < 14 then
		return nil
	end
	return {
		dst = string.sub(frame, 1, 6),
		src = string.sub(frame, 7, 12),
		type = Packet.u16(frame, 13),
		payload = string.sub(frame, 15),
	}
end

function Packet.ethernet(dst: string, src: string, etherType: number, payload: string): string
	return dst .. src .. string.pack(">I2", etherType) .. payload
end

export type Arp = { op: number, senderMac: string, senderIp: string, targetMac: string, targetIp: string }

function Packet.parseArp(payload: string): Arp?
	if #payload < 28 or Packet.u16(payload, 1) ~= 1 or Packet.u16(payload, 3) ~= 0x0800 then
		return nil
	end
	return {
		op = Packet.u16(payload, 7),
		senderMac = string.sub(payload, 9, 14),
		senderIp = string.sub(payload, 15, 18),
		targetMac = string.sub(payload, 19, 24),
		targetIp = string.sub(payload, 25, 28),
	}
end

function Packet.arp(op: number, senderMac: string, senderIp: string, targetMac: string, targetIp: string): string
	return string.pack(">I2I2BBI2", 1, 0x0800, 6, 4, op) .. senderMac .. senderIp .. targetMac .. targetIp
end

export type Ipv4 = { src: string, dst: string, proto: number, ttl: number, id: number, payload: string }

function Packet.parseIpv4(payload: string): Ipv4?
	if #payload < 20 then
		return nil
	end
	local verIhl = string.byte(payload, 1)
	if verIhl // 16 ~= 4 then
		return nil
	end
	local ihl = (verIhl % 16) * 4
	local total = Packet.u16(payload, 3)
	if ihl < 20 or total < ihl or total > #payload then
		return nil
	end
	return {
		id = Packet.u16(payload, 5),
		ttl = string.byte(payload, 9),
		proto = string.byte(payload, 10),
		src = string.sub(payload, 13, 16),
		dst = string.sub(payload, 17, 20),
		payload = string.sub(payload, ihl + 1, total),
	}
end

local nextId = 1

function Packet.ipv4(src: string, dst: string, proto: number, payload: string): string
	nextId = nextId % 65535 + 1
	local header = string.pack(">BBI2I2I2BBI2", 0x45, 0, 20 + #payload, nextId, 0x4000, 64, proto, 0) .. src .. dst
	local sum = Packet.checksum(header)
	header = string.sub(header, 1, 10) .. string.pack(">I2", sum) .. string.sub(header, 13)
	return header .. payload
end

-- ICMP echo reply for an echo request payload, or nil if it isn't one.
function Packet.icmpEchoReply(icmp: string): string?
	if #icmp < 8 or string.byte(icmp, 1) ~= 8 then
		return nil
	end
	local body = "\0\0\0\0" .. string.sub(icmp, 5)
	local sum = Packet.checksum(body)
	return "\0\0" .. string.pack(">I2", sum) .. string.sub(icmp, 5)
end

export type Udp = { srcPort: number, dstPort: number, payload: string }

function Packet.parseUdp(payload: string): Udp?
	if #payload < 8 then
		return nil
	end
	local len = Packet.u16(payload, 5)
	return {
		srcPort = Packet.u16(payload, 1),
		dstPort = Packet.u16(payload, 3),
		payload = string.sub(payload, 9, math.min(len, #payload)),
	}
end

function Packet.udp(srcPort: number, dstPort: number, payload: string): string
	-- Checksum 0 = "not computed", allowed for UDP over IPv4.
	return string.pack(">I2I2I2I2", srcPort, dstPort, 8 + #payload, 0) .. payload
end

-- TCP RST+ACK answering a segment (so connections to closed ports fail fast).
function Packet.tcpReset(src: string, dst: string, segment: string): string?
	if #segment < 20 then
		return nil
	end
	local srcPort, dstPort, seq, ack, offsetFlags = string.unpack(">I2I2I4I4I2", segment)
	local flags = offsetFlags % 256
	if bit32.btest(flags, 0x04) then
		return nil -- never answer a reset
	end
	local header
	if bit32.btest(flags, 0x10) then
		-- RFC 793: the reset takes its sequence number from the segment's ACK.
		header = string.pack(">I2I2I4I4I2I2I2I2", dstPort, srcPort, ack, 0, 0x5000 + 0x04, 0, 0, 0)
	else
		local dataLen = #segment - (offsetFlags // 4096) * 4
		local ackNum = (seq + dataLen + (if bit32.btest(flags, 0x02) then 1 else 0) + (if bit32.btest(flags, 0x01) then 1 else 0))
			% 4294967296
		header = string.pack(">I2I2I4I4I2I2I2I2", dstPort, srcPort, 0, ackNum, 0x5000 + 0x14, 0, 0, 0)
	end
	local pseudo = dst .. src .. string.pack(">BBI2", 0, Packet.PROTO_TCP, #header)
	local sum = Packet.checksum(pseudo .. header)
	return string.sub(header, 1, 16) .. string.pack(">I2", sum) .. string.sub(header, 19)
end

export type DnsQuestion = { id: number, name: string, qtype: number, raw: string }

-- Parses the first question of a DNS query.
function Packet.parseDnsQuery(data: string): DnsQuestion?
	if #data < 17 then
		return nil
	end
	local id, flags, qdcount = string.unpack(">I2I2I2", data)
	if bit32.btest(flags, 0x8000) or qdcount < 1 then
		return nil -- a response, or no question
	end
	local labels = {}
	local pos = 13
	while true do
		local len = string.byte(data, pos)
		if not len then
			return nil
		end
		if len == 0 then
			pos += 1
			break
		end
		if len >= 64 then
			return nil -- compression in a query: not expected
		end
		table.insert(labels, string.sub(data, pos + 1, pos + len))
		pos += len + 1
	end
	if pos + 3 > #data then
		return nil
	end
	local qtype = Packet.u16(data, pos)
	return {
		id = id,
		name = string.lower(table.concat(labels, ".")),
		qtype = qtype,
		raw = string.sub(data, 13, pos + 3), -- the question section, echoed back
	}
end

-- DNS response: an A record when `ip` is given, NXDOMAIN when `found` is false.
function Packet.dnsResponse(q: DnsQuestion, found: boolean, ip: string?): string
	local rcode = if found then 0 else 3
	local answers = if ip and q.qtype == 1 then 1 else 0
	local out = string.pack(">I2I2I2I2I2I2", q.id, 0x8180 + rcode, 1, answers, 0, 0) .. q.raw
	if answers == 1 then
		out ..= string.pack(">I2I2I2I4I2", 0xC00C, 1, 1, 60, 4) .. (ip :: string)
	end
	return out
end

return Packet
