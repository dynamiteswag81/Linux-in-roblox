return function(test, root, require)
	local NetworkService = require(root.LinuxServer.NetworkService)
	local Packet = require(root.LinuxServer.Net.Packet)

	local function setup()
		local ns = NetworkService.new(function() return 0 end)
		local inbox = {}
		local function make(name)
			local ipText, ip, mac = ns:allocateAddress()
			inbox[name] = {}
			local e = {
				hostname = NetworkService.hostnameFor(name),
				ip = ip,
				ipText = ipText,
				mac = mac,
				owner = name,
				deliver = function(frame) table.insert(inbox[name], frame) end,
			}
			ns:attach(e)
			return e
		end
		return ns, make, inbox
	end

	test("addresses and hostnames", function()
		local ns, make = setup()
		local a = make("Alice")
		local b = make("Bob_The_Builder")
		assert(a.ipText == "10.0.0.2" and b.ipText == "10.0.0.3", a.ipText .. " " .. b.ipText)
		assert(a.hostname == "alice" and b.hostname == "bob-the-builder")
		assert(ns:lookup("alice") == a.ip and ns:lookup("ALICE.brick") == a.ip)
		assert(ns:lookup("nobody") == nil)
	end)

	test("gateway answers ARP", function()
		local ns, make, inbox = setup()
		local a = make("alice")
		local req = Packet.arp(1, a.mac, a.ip, string.rep("\0", 6), ns.gatewayIp)
		ns:transmit(a, Packet.ethernet(Packet.BROADCAST, a.mac, Packet.ETH_ARP, req))
		local eth = Packet.parseEthernet(inbox.alice[1])
		local arp = Packet.parseArp(eth.payload)
		assert(arp.op == 2 and arp.senderIp == ns.gatewayIp and arp.senderMac == NetworkService.GATEWAY_MAC)
	end)

	test("gateway answers ping with valid checksums", function()
		local ns, make, inbox = setup()
		local a = make("alice")
		local icmp = "\8\0\0\0\0\1\0\1pingdata"
		icmp = string.sub(icmp, 1, 2) .. string.pack(">I2", Packet.checksum(icmp)) .. string.sub(icmp, 5)
		local ip = Packet.ipv4(a.ip, ns.gatewayIp, Packet.PROTO_ICMP, icmp)
		ns:transmit(a, Packet.ethernet(NetworkService.GATEWAY_MAC, a.mac, Packet.ETH_IPV4, ip))
		local eth = Packet.parseEthernet(inbox.alice[1])
		local reply = Packet.parseIpv4(eth.payload)
		assert(reply.src == ns.gatewayIp and reply.dst == a.ip and reply.proto == 1)
		assert(string.byte(reply.payload, 1) == 0, "echo reply type")
		assert(Packet.checksum(reply.payload) == 0, "icmp checksum")
		assert(Packet.checksum(string.sub(eth.payload, 1, 20)) == 0, "ip header checksum")
		assert(string.sub(reply.payload, 9) == "pingdata")
	end)

	test("gateway resolves computer names over DNS", function()
		local ns, make, inbox = setup()
		local a = make("alice")
		local b = make("bob")
		local function query(name, qtype)
			local q = string.pack(">I2I2I2I2I2I2", 0x1234, 0x0100, 1, 0, 0, 0)
			for label in string.gmatch(name, "[^.]+") do
				q ..= string.char(#label) .. label
			end
			q ..= "\0" .. string.pack(">I2I2", qtype or 1, 1)
			local ip = Packet.ipv4(a.ip, ns.gatewayIp, Packet.PROTO_UDP, Packet.udp(40000, 53, q))
			ns:transmit(a, Packet.ethernet(NetworkService.GATEWAY_MAC, a.mac, Packet.ETH_IPV4, ip))
			local eth = Packet.parseEthernet(table.remove(inbox.alice))
			local udp = Packet.parseUdp(Packet.parseIpv4(eth.payload).payload)
			assert(udp.dstPort == 40000 and udp.srcPort == 53)
			return udp.payload
		end
		local r = query("bob")
		local _, flags, _, ancount = string.unpack(">I2I2I2I2", r)
		assert(flags % 16 == 0 and ancount == 1)
		assert(string.sub(r, -4) == b.ip)
		r = query("nobody.brick")
		_, flags, _, ancount = string.unpack(">I2I2I2I2", r)
		assert(flags % 16 == 3 and ancount == 0, "NXDOMAIN")
		r = query("bob", 28)
		_, flags, _, ancount = string.unpack(">I2I2I2I2", r)
		assert(flags % 16 == 0 and ancount == 0, "AAAA: name exists, no records")
	end)

	test("switch forwards unicast and floods broadcast", function()
		local ns, make, inbox = setup()
		local a = make("alice")
		local b = make("bob")
		local c = make("carol")
		ns:transmit(a, Packet.ethernet(b.mac, a.mac, 0x0800, "hello bob"))
		assert(#inbox.bob == 1 and #inbox.carol == 0 and #inbox.alice == 0)
		ns:transmit(a, Packet.ethernet(Packet.BROADCAST, a.mac, 0x88B5, "hello all"))
		assert(#inbox.bob == 2 and #inbox.carol == 1 and #inbox.alice == 0)
	end)

	test("gateway resets TCP connections", function()
		local ns, make, inbox = setup()
		local a = make("alice")
		local syn = string.pack(">I2I2I4I4I2I2I2I2", 5555, 80, 1000, 0, 0x5002, 1024, 0, 0)
		local ip = Packet.ipv4(a.ip, ns.gatewayIp, Packet.PROTO_TCP, syn)
		ns:transmit(a, Packet.ethernet(NetworkService.GATEWAY_MAC, a.mac, Packet.ETH_IPV4, ip))
		local reply = Packet.parseIpv4(Packet.parseEthernet(inbox.alice[1]).payload)
		local sp, dp, seq, ack, offFlags = string.unpack(">I2I2I4I4I2", reply.payload)
		assert(sp == 80 and dp == 5555 and ack == 1001 and offFlags % 256 == 0x14)
		local pseudo = reply.src .. reply.dst .. string.pack(">BBI2", 0, 6, #reply.payload)
		assert(Packet.checksum(pseudo .. reply.payload) == 0, "tcp checksum")
	end)
end
