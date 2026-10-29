--!strict
--[[
	The in-game "internet": a virtual Ethernet switch connecting every running
	computer's network card, plus a gateway at 10.0.0.1 run by the game itself.

	The gateway answers ARP, ping and DNS: a computer's name (its owner's
	username) resolves to its address, so `ping alice` or `browse alice` work.
	Other traffic between computers is forwarded untouched: real TCP/IP from
	the guests' Linux kernels.
]]

local LinuxVM = require(script.Parent.Deps) :: any
local Config = require(LinuxVM.Config)
local Packet = require(script.Parent.Net.Packet)
local TcpServer = require(script.Parent.Net.TcpServer)

local GATEWAY_MAC = "\2\0\10\0\0\1"

export type Endpoint = {
	hostname: string,
	ip: string, -- 4 raw bytes
	mac: string, -- 6 raw bytes
	owner: string,
	userId: number?,
	deliver: (frame: string) -> (),
}

local NetworkService = {}
NetworkService.__index = NetworkService

export type NetworkService = typeof(setmetatable(
	{} :: {
		gatewayIp: string,
		byMac: { [string]: Endpoint },
		byIp: { [string]: Endpoint },
		byName: { [string]: Endpoint },
		nextHost: number,
		freeHosts: { number },
		frameCounts: { [Endpoint]: number },
		windowStart: number,
		now: () -> number,
		dropped: number,
		web: TcpServer.TcpServer?,
	},
	NetworkService
))

function NetworkService.new(now: (() -> number)?): NetworkService
	return setmetatable({
		web = nil,
		gatewayIp = Packet.ipFromString(Config.GATEWAY_IP) :: string,
		byMac = {},
		byIp = {},
		byName = {},
		nextHost = 2,
		freeHosts = {},
		frameCounts = {},
		windowStart = 0,
		now = now or os.clock,
		dropped = 0,
	}, NetworkService)
end

-- Serves HTTP on the gateway's port 80 (e.g. the Community Workshop website).
-- The handler gets the raw request and calls `respond` with the full HTTP
-- response, now or later.
function NetworkService.serveHttp(self: NetworkService, handler: TcpServer.Handler)
	self.web = TcpServer.new(self.gatewayIp, 80, handler, self.now)
end

-- Housekeeping for the gateway's TCP connections (retransmits, timeouts).
function NetworkService.tick(self: NetworkService)
	local web = self.web
	if web then
		web:tick()
	end
end

-- Picks the next free address: 10.0.0.2 ... 10.0.255.254. Returns (ipText, ipBytes, mac).
function NetworkService.allocateAddress(self: NetworkService): (string, string, string)
	local host = table.remove(self.freeHosts, 1)
	if not host then
		host = self.nextHost
		self.nextHost += 1
		if self.nextHost % 256 == 255 then
			self.nextHost += 3 -- skip .255, .0 and .1 in the next block
		end
	end
	local hi, lo = host // 256, host % 256
	local ipBytes = string.char(10, 0, hi, lo)
	local mac = string.char(2, 0, 10, 0, hi, lo)
	return Packet.ipToString(ipBytes), ipBytes, mac
end

-- Turns a username into a valid hostname (lowercase letters, digits, hyphens).
function NetworkService.hostnameFor(name: string): string
	local h = string.lower(name)
	h = string.gsub(h, "[^a-z0-9%-]", "-")
	h = string.gsub(h, "^%-+", "")
	h = string.sub(h, 1, 63)
	return if h == "" then "computer" else h
end

function NetworkService.attach(self: NetworkService, endpoint: Endpoint)
	self.byMac[endpoint.mac] = endpoint
	self.byIp[endpoint.ip] = endpoint
	self.byName[endpoint.hostname] = endpoint
end

function NetworkService.detach(self: NetworkService, endpoint: Endpoint)
	if self.byMac[endpoint.mac] == endpoint then
		self.byMac[endpoint.mac] = nil
	end
	if self.byIp[endpoint.ip] == endpoint then
		self.byIp[endpoint.ip] = nil
		table.insert(self.freeHosts, string.byte(endpoint.ip, 3) * 256 + string.byte(endpoint.ip, 4))
	end
	if self.byName[endpoint.hostname] == endpoint then
		self.byName[endpoint.hostname] = nil
	end
	self.frameCounts[endpoint] = nil
end

function NetworkService.lookup(self: NetworkService, name: string): string?
	name = string.lower(name)
	local suffix = "." .. Config.DNS_SUFFIX
	if string.sub(name, -#suffix) == suffix then
		name = string.sub(name, 1, -#suffix - 1)
	end
	if name == "gateway" or name == "workshop" then
		return self.gatewayIp
	end
	local endpoint = self.byName[name]
	return if endpoint then endpoint.ip else nil
end

-- Finds the computer of a player by hostname or username (case-insensitive).
function NetworkService.find(self: NetworkService, name: string): Endpoint?
	local lower = string.lower(name)
	local byName = self.byName[NetworkService.hostnameFor(name)]
	if byName then
		return byName
	end
	for _, e in self.byName do
		if string.lower(e.owner) == lower then
			return e
		end
	end
	return nil
end

-- Lists computers on the network (for `hostlink net.who` and /etc/hosts).
function NetworkService.list(self: NetworkService): { Endpoint }
	local out = {}
	for _, e in self.byName do
		table.insert(out, e)
	end
	table.sort(out, function(a, b)
		return a.hostname < b.hostname
	end)
	return out
end

function NetworkService._rateLimited(self: NetworkService, from: Endpoint): boolean
	local now = self.now()
	if now - self.windowStart >= 1 then
		self.windowStart = now
		table.clear(self.frameCounts)
	end
	local count = (self.frameCounts[from] or 0) + 1
	self.frameCounts[from] = count
	return count > Config.MAX_FRAMES_PER_SECOND
end

-- A frame sent by `from`'s network card.
function NetworkService.transmit(self: NetworkService, from: Endpoint, frame: string)
	if #frame < 14 or #frame > 1600 then
		return
	end
	if self:_rateLimited(from) then
		self.dropped += 1
		return
	end
	local dst = string.sub(frame, 1, 6)
	if dst == GATEWAY_MAC then
		self:_gateway(from, frame)
	elseif string.byte(dst, 1) % 2 == 1 then
		-- Broadcast/multicast: everyone else, and the gateway (ARP requests).
		for mac, endpoint in self.byMac do
			if endpoint ~= from then
				endpoint.deliver(frame)
			end
		end
		self:_gateway(from, frame)
	else
		local target = self.byMac[dst]
		if target and target ~= from then
			target.deliver(frame)
		end
	end
end

function NetworkService._gateway(self: NetworkService, from: Endpoint, frame: string)
	local eth = Packet.parseEthernet(frame)
	if not eth then
		return
	end
	if eth.type == Packet.ETH_ARP then
		local arp = Packet.parseArp(eth.payload)
		if arp and arp.op == 1 and arp.targetIp == self.gatewayIp then
			local reply = Packet.arp(2, GATEWAY_MAC, self.gatewayIp, arp.senderMac, arp.senderIp)
			from.deliver(Packet.ethernet(eth.src, GATEWAY_MAC, Packet.ETH_ARP, reply))
		end
		return
	end
	if eth.type ~= Packet.ETH_IPV4 or eth.dst ~= GATEWAY_MAC then
		return
	end
	local ip = Packet.parseIpv4(eth.payload)
	if not ip then
		return
	end
	local function reply(proto: number, payload: string)
		local packet = Packet.ipv4(ip.dst, ip.src, proto, payload)
		from.deliver(Packet.ethernet(eth.src, GATEWAY_MAC, Packet.ETH_IPV4, packet))
	end
	if ip.dst ~= self.gatewayIp then
		-- Routing beyond the local network: there is no "outside".
		return
	end
	if ip.proto == Packet.PROTO_ICMP then
		local echo = Packet.icmpEchoReply(ip.payload)
		if echo then
			reply(Packet.PROTO_ICMP, echo)
		end
	elseif ip.proto == Packet.PROTO_UDP then
		local udp = Packet.parseUdp(ip.payload)
		if udp and udp.dstPort == 53 then
			local q = Packet.parseDnsQuery(udp.payload)
			if q then
				local address = self:lookup(q.name)
				local answer = Packet.dnsResponse(q, address ~= nil, address)
				reply(Packet.PROTO_UDP, Packet.udp(53, udp.srcPort, answer))
			end
		end
	elseif ip.proto == Packet.PROTO_TCP then
		local web = self.web
		local dstPort = if #ip.payload >= 4 then Packet.u16(ip.payload, 3) else 0
		if web and dstPort == 80 then
			web:receive(ip.src, ip.payload, function(segment)
				reply(Packet.PROTO_TCP, segment)
			end)
		else
			local rst = Packet.tcpReset(ip.src, ip.dst, ip.payload)
			if rst then
				reply(Packet.PROTO_TCP, rst)
			end
		end
	end
end

NetworkService.GATEWAY_MAC = GATEWAY_MAC

return NetworkService
