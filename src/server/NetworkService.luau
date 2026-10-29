--!strict
--[[
	The in-game "internet": a virtual Ethernet switch connecting every running
	computer's network card, plus a gateway at 10.0.0.1 run by the game itself.

	The gateway answers ARP, ping and DNS: a computer's name (its owner's
	username) resolves to its address, so `ping alice` or `browse alice` work.
	Other traffic between computers is forwarded untouched: real TCP/IP from
	the guests' Linux kernels.

	Computers in other game servers (each server has one player) are reached
	through a Remote (Net/CrossServer in the game). This server gives each of
	them a local address in 10.1.0.0/16, behind the gateway. Packets to those
	addresses are batched into relay messages, and packets that arrive get
	their addresses translated (NAT) on the way in.
]]

local LinuxVM = require(script.Parent.Deps) :: any
local Base64 = require(LinuxVM.Util.Base64)
local Config = require(LinuxVM.Config)
local Packet = require(script.Parent.Net.Packet)
local TcpServer = require(script.Parent.Net.TcpServer)

local GATEWAY_MAC = "\2\0\10\0\0\1"

-- Relay messages must stay under MessagingService's 1 KB limit.
local MAX_MESSAGE = 950
-- Largest packet that fits a message once base64 encoded, and the TCP MSS
-- that keeps segments under it (20 IP + 60 TCP header bytes at most).
local MAX_RELAY_PACKET = 680
local RELAY_MSS = 600
local MAX_QUEUED_PACKETS = 64
local FLUSH_INTERVAL = 0.05

export type Endpoint = {
	hostname: string,
	ip: string, -- 4 raw bytes
	mac: string, -- 6 raw bytes
	owner: string,
	userId: number?,
	deliver: (frame: string) -> (),
}

-- A computer in another game server.
export type RemoteEntry = { userId: number, hostname: string, owner: string }

--[[
	How this server reaches the others. register, unregister and send must not
	yield (the game's implementation spawns its own threads); lookup and list
	may yield.
]]
export type Remote = {
	-- Finds an online computer by hostname in any server.
	lookup: (hostname: string) -> RemoteEntry?,
	-- Every online computer.
	list: () -> { RemoteEntry },
	-- Announces or withdraws one of this server's computers.
	register: (entry: RemoteEntry) -> (),
	unregister: (entry: RemoteEntry) -> (),
	-- Delivers a message (at most MAX_MESSAGE characters) to the server of `toUserId`.
	send: (toUserId: number, message: string) -> (),
}

type Outbox = { from: Endpoint, packets: { string } }
type CachedName = { entry: RemoteEntry?, expires: number }

local NetworkService = {}
NetworkService.__index = NetworkService

export type NetworkService = typeof(setmetatable(
	{} :: {
		gatewayIp: string,
		byMac: { [string]: Endpoint },
		byIp: { [string]: Endpoint },
		byName: { [string]: Endpoint },
		byUser: { [number]: Endpoint },
		nextHost: number,
		freeHosts: { number },
		frameCounts: { [Endpoint]: number },
		windowStart: number,
		now: () -> number,
		dropped: number,
		web: TcpServer.TcpServer?,
		-- Other servers
		remote: Remote?,
		aliasByUser: { [number]: string },
		entryByAlias: { [string]: RemoteEntry },
		nextAlias: number,
		nameCache: { [string]: CachedName },
		outbox: { [number]: Outbox },
		tokens: number,
		lastRefill: number,
		lastFlush: number,
		-- A chat message from another server for one of our players.
		onChat: ((toUserId: number, fromName: string, text: string) -> ())?,
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
		byUser = {},
		nextHost = 2,
		freeHosts = {},
		frameCounts = {},
		windowStart = 0,
		now = now or os.clock,
		dropped = 0,
		remote = nil,
		aliasByUser = {},
		entryByAlias = {},
		nextAlias = 1,
		nameCache = {},
		outbox = {},
		tokens = Config.RELAY_MESSAGES_PER_SECOND,
		lastRefill = 0,
		lastFlush = -math.huge,
		onChat = nil,
	}, NetworkService)
end

local function entryOf(endpoint: Endpoint): RemoteEntry?
	local userId = endpoint.userId
	if not userId then
		return nil
	end
	return { userId = userId, hostname = endpoint.hostname, owner = endpoint.owner }
end

-- Connects this server's network to the other servers.
function NetworkService.setRemote(self: NetworkService, remote: Remote)
	self.remote = remote
	for _, endpoint in self.byName do
		local entry = entryOf(endpoint)
		if entry then
			remote.register(entry)
		end
	end
end

-- Serves HTTP on the gateway's port 80 (e.g. the Community Workshop website).
-- The handler gets the raw request and calls `respond` with the full HTTP
-- response, now or later.
function NetworkService.serveHttp(self: NetworkService, handler: TcpServer.Handler)
	self.web = TcpServer.new(self.gatewayIp, 80, handler, self.now)
end

-- Housekeeping: the gateway's TCP connections (retransmits, timeouts) and
-- sending queued packets to other servers.
function NetworkService.tick(self: NetworkService)
	local web = self.web
	if web then
		web:tick()
	end
	self:_flushRemote()
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
	if endpoint.userId then
		self.byUser[endpoint.userId] = endpoint
	end
	local remote, entry = self.remote, entryOf(endpoint)
	if remote and entry then
		remote.register(entry)
	end
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
	if endpoint.userId and self.byUser[endpoint.userId] == endpoint then
		self.byUser[endpoint.userId] = nil
	end
	self.frameCounts[endpoint] = nil
	local remote, entry = self.remote, entryOf(endpoint)
	if remote and entry then
		remote.unregister(entry)
	end
end

local function stripSuffix(name: string): string
	name = string.lower(name)
	local suffix = "." .. Config.DNS_SUFFIX
	if string.sub(name, -#suffix) == suffix then
		name = string.sub(name, 1, -#suffix - 1)
	end
	return name
end

-- Resolves a name on this server only (gateway and local computers).
function NetworkService.lookup(self: NetworkService, name: string): string?
	name = stripSuffix(name)
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

-- The address this server uses for a computer in another server (10.1.x.y).
function NetworkService._aliasFor(self: NetworkService, entry: RemoteEntry): string
	local ip = self.aliasByUser[entry.userId]
	if not ip then
		local n = self.nextAlias
		self.nextAlias += if n % 256 == 254 then 3 else 1 -- skip .255 and .0
		ip = string.char(10, 1, (n // 256) % 256, n % 256)
		self.aliasByUser[entry.userId] = ip
	end
	self.entryByAlias[ip] = entry
	return ip
end

-- Looks a hostname up in the other servers, with a short cache. May yield.
function NetworkService.lookupRemote(self: NetworkService, hostname: string): RemoteEntry?
	local remote = self.remote
	if not remote then
		return nil
	end
	local now = self.now()
	local cached = self.nameCache[hostname]
	if cached and cached.expires > now then
		return cached.entry
	end
	local ok, found = pcall(remote.lookup, hostname)
	local entry: RemoteEntry? = if ok then found else nil
	if entry and self.byUser[entry.userId] then
		entry = nil -- that player's computer is in this server
	end
	self.nameCache[hostname] = { entry = entry, expires = now + (if entry then 30 else 5) }
	return entry
end

-- Resolves a name anywhere: this server's computers, then the other servers'
-- (as their local 10.1.x.y address). May yield.
function NetworkService.resolve(self: NetworkService, name: string): string?
	local ip = self:lookup(name)
	if ip then
		return ip
	end
	local entry = self:lookupRemote(stripSuffix(name))
	return if entry then self:_aliasFor(entry) else nil
end

-- Finds a player's computer by hostname or username, in this server or any
-- other. May yield.
function NetworkService.findAnywhere(self: NetworkService, name: string): RemoteEntry?
	local endpoint = self:find(name)
	if endpoint then
		return entryOf(endpoint)
	end
	return self:lookupRemote(NetworkService.hostnameFor(name))
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

export type Listing = { hostname: string, ip: string, owner: string }

-- Every computer online in any server, with the address this server uses for
-- it. May yield.
function NetworkService.listAll(self: NetworkService): { Listing }
	local out: { Listing } = {}
	local seen = {}
	for _, e in self:list() do
		table.insert(out, { hostname = e.hostname, ip = e.ip, owner = e.owner })
		seen[e.hostname] = true
	end
	local remote = self.remote
	if remote then
		local ok, entries = pcall(remote.list)
		if ok then
			for _, entry in entries do
				if not seen[entry.hostname] and not self.byUser[entry.userId] then
					seen[entry.hostname] = true
					table.insert(out, { hostname = entry.hostname, ip = self:_aliasFor(entry), owner = entry.owner })
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.hostname < b.hostname
	end)
	return out
end

-- Sends a chat message (already filtered) to a player's computer in another server.
function NetworkService.sendChat(self: NetworkService, from: RemoteEntry, toUserId: number, text: string): boolean
	local remote = self.remote
	if not remote then
		return false
	end
	local header = string.format("m %d %d %s %s\n", from.userId, toUserId, from.hostname, from.owner)
	remote.send(toUserId, header .. string.sub(text, 1, MAX_MESSAGE - #header))
	return true
end

-- Queues a packet from one of our computers for a computer in another server.
function NetworkService._queueRemote(self: NetworkService, from: Endpoint, to: RemoteEntry, packet: string)
	if not self.remote or not from.userId or #packet > MAX_RELAY_PACKET then
		self.dropped += 1
		return
	end
	local box = self.outbox[to.userId]
	if not box then
		box = { from = from, packets = {} }
		self.outbox[to.userId] = box
	end
	table.insert(box.packets, Base64.encode(buffer.fromstring(packet)))
	if #box.packets > MAX_QUEUED_PACKETS then
		table.remove(box.packets, 1)
		self.dropped += 1
	end
end

-- Sends queued packets, several per message, within the message rate limit.
function NetworkService._flushRemote(self: NetworkService)
	local remote = self.remote
	if not remote or next(self.outbox) == nil then
		return
	end
	local now = self.now()
	if now - self.lastFlush < FLUSH_INTERVAL then
		return
	end
	self.lastFlush = now
	local rate = Config.RELAY_MESSAGES_PER_SECOND
	self.tokens = math.min(rate, self.tokens + (now - self.lastRefill) * rate)
	self.lastRefill = now
	for toUserId, box in self.outbox do
		local from = box.from
		local header = string.format("p %d %d %s %s\n", from.userId :: number, toUserId, from.hostname, from.owner)
		while #box.packets > 0 and self.tokens >= 1 do
			local parts = { header }
			local size = #header
			while #box.packets > 0 and size + #box.packets[1] + 1 <= MAX_MESSAGE do
				local packet = table.remove(box.packets, 1) :: string
				table.insert(parts, packet)
				table.insert(parts, "\n")
				size += #packet + 1
			end
			self.tokens -= 1
			remote.send(toUserId, table.concat(parts))
		end
		if #box.packets == 0 then
			self.outbox[toUserId] = nil
		end
	end
end

local function decodeBase64(text: string): string?
	if #text % 4 ~= 0 or string.find(text, "[^%w%+/=]") then
		return nil
	end
	local out = buffer.create(Base64.decodedSize(text))
	Base64.decodeInto(text, out, 0)
	return buffer.tostring(out)
end

-- A message from another server's network (see _flushRemote and sendChat).
function NetworkService.receiveRemote(self: NetworkService, message: string)
	local header, body = string.match(message, "^([^\n]*)\n(.*)$")
	if not header or not body then
		return
	end
	local kind, fromText, toText, fromHost, fromOwner = string.match(header, "^(%a) (%d+) (%d+) (%S+) (%S+)$")
	local fromUserId, toUserId = tonumber(fromText), tonumber(toText)
	if not kind or not fromUserId or not toUserId then
		return
	end
	local target = self.byUser[toUserId]
	if not target then
		return
	end
	local entry: RemoteEntry = { userId = fromUserId, hostname = fromHost, owner = fromOwner }
	if kind == "p" then
		local alias = self:_aliasFor(entry)
		self.nameCache[fromHost] = { entry = entry, expires = self.now() + 30 }
		for line in string.gmatch(body, "[^\n]+") do
			local packet = decodeBase64(line)
			local translated = packet and Packet.translate(packet, alias, target.ip, RELAY_MSS)
			if translated then
				target.deliver(Packet.ethernet(target.mac, GATEWAY_MAC, Packet.ETH_IPV4, translated))
			end
		end
	elseif kind == "m" then
		local onChat = self.onChat
		if onChat then
			onChat(toUserId, fromOwner, body)
		end
	end
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
		-- A computer in another server, or nowhere (there's no real outside).
		local to = self.entryByAlias[ip.dst]
		if to then
			self:_queueRemote(from, to, string.sub(eth.payload, 1, Packet.u16(eth.payload, 3)))
		end
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
				if address or not self.remote then
					reply(Packet.PROTO_UDP, Packet.udp(53, udp.srcPort, Packet.dnsResponse(q, address ~= nil, address)))
				else
					-- Maybe a computer in another server: ask the directory without blocking the VM.
					local srcPort = udp.srcPort
					task.spawn(function()
						local found = self:resolve(q.name)
						reply(Packet.PROTO_UDP, Packet.udp(53, srcPort, Packet.dnsResponse(q, found ~= nil, found)))
					end)
				end
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
