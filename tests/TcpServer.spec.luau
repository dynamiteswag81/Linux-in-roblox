return function(test, root, require)
	local TcpServer = require(root.LinuxServer.Net.TcpServer)
	local Packet = require(root.LinuxServer.Net.Packet)

	local SERVER_IP = "\10\0\0\1"
	local CLIENT_IP = "\10\0\0\2"

	local function segment(seq, ack, flags, window, data)
		data = data or ""
		local header = string.pack(">I2I2I4I4I2I2I2I2", 40000, 80, seq, ack, 0x5000 + flags, window, 0, 0)
		local pseudo = CLIENT_IP .. SERVER_IP .. string.pack(">BBI2", 0, 6, #header + #data)
		local sum = Packet.checksum(pseudo .. header .. data)
		return string.sub(header, 1, 16) .. string.pack(">I2", sum) .. string.sub(header, 19) .. data
	end

	local function parse(seg)
		local _, _, seq, ack, offFlags = string.unpack(">I2I2I4I4I2", seg)
		local pseudo = SERVER_IP .. CLIENT_IP .. string.pack(">BBI2", 0, 6, #seg)
		assert(Packet.checksum(pseudo .. seg) == 0, "bad checksum from server")
		return { seq = seq, ack = ack, flags = offFlags % 256, data = string.sub(seg, (offFlags // 4096) * 4 + 1) }
	end

	test("handshake, request, windowed response, retransmit and close", function()
		local clock = 0
		local body = string.rep("x", 5000)
		local server = TcpServer.new(SERVER_IP, 80, function(request, respond)
			assert(string.find(request, "GET / HTTP/1.0", 1, true))
			respond(body)
		end, function() return clock end)
		local out = {}
		local function send(seg)
			server:receive(CLIENT_IP, seg, function(s) table.insert(out, parse(s)) end)
		end

		send(segment(1000, 0, 0x02, 2000)) -- SYN, small window
		local synack = table.remove(out, 1)
		assert(synack.flags == 0x12 and synack.ack == 1001, "SYN-ACK")
		local isn = synack.seq
		send(segment(1001, isn + 1, 0x10, 2000))
		send(segment(1001, isn + 1, 0x18, 2000, "GET / HTTP/1.0\r\n\r\n"))

		-- Only 2000 bytes may be in flight.
		local received, inFlight = "", 0
		for _, s in out do
			received ..= s.data
			inFlight += #s.data
		end
		table.clear(out)
		assert(#received == 2000, "window respected, got " .. #received)

		-- Pretend the second segment was lost: ack only the first 1400 bytes, then stall.
		send(segment(1019, isn + 1 + 1400, 0x10, 2000))
		table.clear(out)
		clock = 1
		server:tick()
		assert(out[1] and out[1].seq == (isn + 1 + 1400) % 2^32, "retransmits from the first unacked byte")
		received = string.sub(received, 1, 1400)

		-- Keep acking everything until the FIN arrives.
		local fin = false
		for _ = 1, 20 do
			for _, s in out do
				if s.seq == (isn + 1 + #received) % 2^32 then
					received ..= s.data
				end
				if s.flags % 2 == 1 then
					fin = true
				end
			end
			table.clear(out)
			if fin then
				break
			end
			send(segment(1019, (isn + 1 + #received) % 2^32, 0x10, 2000))
		end
		assert(received == body, "whole body received (" .. #received .. ")")
		assert(fin, "server closed")
		send(segment(1019, (isn + 2 + #received) % 2^32, 0x11, 2000)) -- ack FIN + our FIN
		assert(next(server.conns) == nil, "connection cleaned up")
	end)
end
