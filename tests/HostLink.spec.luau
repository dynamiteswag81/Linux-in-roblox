return function(test, root, require)
	local HostLink = require(root.LinuxVM.Emulator.HostLink)
	local BASE = 0x80000000

	local function setup(handler)
		local ram = buffer.create(1024 * 1024)
		local hl = HostLink.new(ram)
		hl.handler = handler
		return hl, ram
	end

	local function request(hl, ram, text, cap)
		buffer.writestring(ram, 0, text)
		hl:write(0x00, BASE)
		hl:write(0x04, #text)
		hl:write(0x08, BASE + 4096)
		hl:write(0x0C, cap)
		hl:write(0x10, 1)
	end

	test("parses command, args and payload; replies synchronously", function()
		local seen
		local hl, ram = setup(function(cmd, args, payload, reply)
			seen = { cmd, args, payload }
			reply(true, "pong")
		end)
		assert(hl:read(0x1C) == 0x4B435242)
		request(hl, ram, "ping\ta\tb c\npayload\0bytes", 100)
		assert(seen[1] == "ping" and seen[2][1] == "a" and seen[2][2] == "b c" and seen[3] == "payload\0bytes")
		assert(hl:read(0x14) == 2 and hl:read(0x18) == 4)
		assert(buffer.readstring(ram, 4096, 4) == "pong")
	end)

	test("async reply, errors, and the too-large retry", function()
		local pending
		local hl, ram = setup(function(_, _, _, reply)
			pending = reply
		end)
		request(hl, ram, "big\n", 16)
		assert(hl:read(0x14) == 1, "busy while waiting")
		local data = string.rep("x", 100)
		pending(true, data)
		assert(hl:read(0x14) == 4 and hl:read(0x18) == 100, "too large")
		hl:write(0x08, BASE + 8192)
		hl:write(0x0C, 100)
		hl:write(0x10, 2)
		assert(hl:read(0x14) == 2 and buffer.readstring(ram, 8192, 100) == data)
		pending(true, "late duplicate reply is ignored")
		assert(hl:read(0x18) == 100)

		local hl2, ram2 = setup(function()
			error("boom")
		end)
		request(hl2, ram2, "x\n", 100)
		assert(hl2:read(0x14) == 3)
		assert(string.find(buffer.readstring(ram2, 4096, hl2:read(0x18)), "boom"))
	end)

	test("reset invalidates replies to old requests", function()
		local pending
		local hl, ram = setup(function(_, _, _, reply)
			pending = reply
		end)
		request(hl, ram, "slow\n", 100)
		hl:reset()
		pending(true, "stale")
		assert(hl:read(0x14) == 0)
	end)
end
