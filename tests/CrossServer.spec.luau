-- Networking between game servers: address translation, batching, rate limits.
return function(test, root, require)
	local NetworkService = require(root.LinuxServer.NetworkService)
	local Packet = require(root.LinuxServer.Net.Packet)
	local Config = require(root.LinuxVM.Config)

	-- Builds `count` servers linked by an in-process bus. Each has one computer.
	local function servers(count)
		local clock = 0
		local directory, serverOf, sent = {}, {}, {}
		local list = {}
		for i = 1, count do
			local ns = NetworkService.new(function()
				return clock
			end)
			local inbox = {}
			local _, ip, mac = ns:allocateAddress()
			local name = "player" .. i
			local e = {
				hostname = name,
				ip = ip,
				mac = mac,
				owner = name,
				userId = 100 + i,
				deliver = function(frame)
					table.insert(inbox, frame)
				end,
			}
			ns:setRemote({
				lookup = function(h)
					return directory[h]
				end,
				list = function()
					local out = {}
					for _, v in directory do
						table.insert(out, v)
					end
					return out
				end,
				register = function(entry)
					directory[entry.hostname] = entry
					serverOf[entry.userId] = ns
				end,
				unregister = function(entry)
					directory[entry.hostname] = nil
				end,
				send = function(toUserId, message)
					table.insert(sent, { to = toUserId, message = message })
				end,
			})
			ns:attach(e)
			list[i] = { ns = ns, e = e, inbox = inbox }
		end
		local function deliver()
			local batch = sent
			sent = {}
			for _, item in batch do
				serverOf[item.to]:receiveRemote(item.message)
			end
			return #batch, batch
		end
		local function advance(seconds)
			clock += seconds
		end
		return list, deliver, advance
	end

	local function tcpSyn(src, dst, mss)
		local options = string.pack(">BBI2", 2, 4, mss) .. "\1\1\1\0" -- MSS, NOP, NOP, NOP, EOL
		local header = string.pack(">I2I2I4I4BBI2I2I2", 40000, 80, 1, 0, (20 + #options) // 4 * 16, 0x02, 64240, 0, 0)
			.. options
		local sum = Packet.checksum(src .. dst .. string.pack(">BBI2", 0, 6, #header) .. header)
		header = string.sub(header, 1, 16) .. string.pack(">I2", sum) .. string.sub(header, 19)
		return Packet.ipv4(src, dst, Packet.PROTO_TCP, header)
	end

	test("translate rewrites addresses, clamps MSS, keeps checksums valid", function()
		local a, b = "\10\0\0\2", "\10\1\0\1"
		local x, y = "\10\1\0\7", "\10\0\0\2"
		local out = Packet.translate(tcpSyn(a, b, 1460), x, y, 600) :: string
		local ip = Packet.parseIpv4(out) :: Packet.Ipv4
		assert(ip.src == x and ip.dst == y, "addresses")
		assert(Packet.checksum(string.sub(out, 1, 20)) == 0, "ip header checksum")
		local seg = ip.payload
		assert(Packet.checksum(x .. y .. string.pack(">BBI2", 0, 6, #seg) .. seg) == 0, "tcp checksum")
		assert(Packet.u16(seg, 23) == 600, "mss clamped, got " .. Packet.u16(seg, 23))
		-- A smaller MSS is left alone; fragments are refused.
		local small = Packet.parseIpv4(Packet.translate(tcpSyn(a, b, 500), x, y, 600) :: string) :: Packet.Ipv4
		assert(Packet.u16(small.payload, 23) == 500)
		local frag = string.sub(tcpSyn(a, b, 500), 1, 6) .. "\32\0" .. string.sub(tcpSyn(a, b, 500), 9)
		assert(Packet.translate(frag, x, y) == nil, "fragments are not translated")
	end)

	test("ping reaches a computer in another server, translated both ways", function()
		local s, deliver = servers(2)
		local alice, bob = s[1], s[2]
		-- Both computers have the same address in their own servers.
		assert(alice.e.ip == bob.e.ip)
		local bobAlias = alice.ns:resolve("player2") :: string
		assert(string.sub(bobAlias, 1, 2) == "\10\1", "other servers' computers are in 10.1.0.0/16")
		local icmp = "\8\0\0\0\0\1\0\1hi"
		icmp = string.sub(icmp, 1, 2) .. string.pack(">I2", Packet.checksum(icmp)) .. string.sub(icmp, 5)
		local packet = Packet.ipv4(alice.e.ip, bobAlias, Packet.PROTO_ICMP, icmp)
		alice.ns:transmit(alice.e, Packet.ethernet(NetworkService.GATEWAY_MAC, alice.e.mac, Packet.ETH_IPV4, packet))
		alice.ns:tick()
		assert(deliver() == 1, "one relay message")
		local eth = Packet.parseEthernet(bob.inbox[1]) :: Packet.Ethernet
		assert(eth.dst == bob.e.mac and eth.src == NetworkService.GATEWAY_MAC)
		local ip = Packet.parseIpv4(eth.payload) :: Packet.Ipv4
		assert(ip.dst == bob.e.ip, "delivered to bob's own address")
		assert(string.sub(ip.src, 1, 2) == "\10\1", "from alice's address in bob's server")
		assert(Packet.checksum(string.sub(eth.payload, 1, 20)) == 0)
		assert(string.sub(ip.payload, 9) == "hi")
		-- Bob's reply to that address goes back to alice.
		local reply = Packet.ipv4(bob.e.ip, ip.src, Packet.PROTO_ICMP, icmp)
		bob.ns:transmit(bob.e, Packet.ethernet(NetworkService.GATEWAY_MAC, bob.e.mac, Packet.ETH_IPV4, reply))
		bob.ns:tick()
		deliver()
		local back = Packet.parseIpv4((Packet.parseEthernet(alice.inbox[1]) :: Packet.Ethernet).payload) :: Packet.Ipv4
		assert(back.src == bobAlias and back.dst == alice.e.ip)
	end)

	test("packets are batched under the message size and rate limits", function()
		local s, deliver, advance = servers(2)
		local alice = s[1]
		local bobAlias = alice.ns:resolve("player2") :: string
		advance(1)
		for i = 1, 40 do
			local udp = Packet.udp(1000, 2000, string.rep("x", 100) .. i)
			local packet = Packet.ipv4(alice.e.ip, bobAlias, Packet.PROTO_UDP, udp)
			alice.ns:transmit(alice.e, Packet.ethernet(NetworkService.GATEWAY_MAC, alice.e.mac, Packet.ETH_IPV4, packet))
		end
		alice.ns:tick()
		local count, batch = deliver()
		assert(count >= 4 and count <= Config.RELAY_MESSAGES_PER_SECOND, "messages: " .. count)
		for _, item in batch do
			assert(#item.message <= 1000, "message too big: " .. #item.message)
		end
		assert(#s[2].inbox == 40, "every packet arrived: " .. #s[2].inbox)
		-- Over the rate limit, packets wait for the next second.
		for i = 1, 200 do
			local packet = Packet.ipv4(alice.e.ip, bobAlias, Packet.PROTO_UDP, Packet.udp(1000, 2000, string.rep("y", 100)))
			alice.ns:transmit(alice.e, Packet.ethernet(NetworkService.GATEWAY_MAC, alice.e.mac, Packet.ETH_IPV4, packet))
		end
		advance(0.1)
		alice.ns:tick()
		local burst = deliver()
		assert(count + burst <= Config.RELAY_MESSAGES_PER_SECOND + 1, "rate limited, sent " .. count + burst)
		assert(#s[2].inbox < 240, "some packets are still waiting")
		advance(1)
		alice.ns:tick()
		assert(deliver() > 0, "sends again after a second")
	end)

	test("names resolve across servers; unknown names don't", function()
		local s = servers(3)
		local ip = s[1].ns:resolve("player3.brick")
		assert(ip and string.sub(ip, 1, 2) == "\10\1")
		assert(s[1].ns:resolve("player1") == s[1].e.ip, "own computer stays local")
		assert(s[1].ns:resolve("nobody") == nil)
		local all = s[1].ns:listAll()
		assert(#all == 3, "listAll sees every server: " .. #all)
	end)
end
