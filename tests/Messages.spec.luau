return function(test, root, require)
	local HostLinkCommands = require(root.LinuxServer.HostLinkCommands)
	local NetworkService = require(root.LinuxServer.NetworkService)
	local WorkshopService = require(root.LinuxServer.WorkshopService)

	local function setup()
		local clock = 100
		local network = NetworkService.new(function() return 0 end)
		for i, name in { "Alice", "Bob" } do
			local _, ip, mac = network:allocateAddress()
			network:attach({ hostname = string.lower(name), ip = ip, mac = mac, owner = name, userId = i, deliver = function() end })
		end
		local toasts = {}
		local store = { GetAsync = function() return nil end }
		local commands = HostLinkCommands.new(WorkshopService.new({ store = store :: any }), network, {
			now = function() return clock end,
			filterMessage = function(text, from, to)
				assert(from ~= to)
				return (string.gsub(text, "badword", "#######"))
			end,
			notifyMessage = function(to, from, text)
				table.insert(toasts, { to, from, text })
			end,
		})
		local function run(owner, cmd, ...)
			local result
			commands:run(owner, cmd, { ... }, "", function(ok, data)
				result = { ok, data }
			end)
			return result[1], result[2]
		end
		return run, toasts, function(dt) clock += dt end
	end

	local alice = { userId = 1, name = "Alice" }
	local bob = { userId = 2, name = "Bob" }

	test("messages are filtered, delivered once, and toast the recipient", function()
		local run, toasts = setup()
		local ok, reply = run(alice, "msg.send", "bob", "hi", "badword", "there")
		assert(ok and string.find(reply, "Sent to Bob"), reply)
		assert(toasts[1][1] == 2 and toasts[1][2] == "Alice" and toasts[1][3] == "hi ####### there")
		local ok2, inbox = run(bob, "msg.recv")
		assert(ok2 and string.find(inbox, "Alice: hi ####### there", 1, true), inbox)
		local _, again = run(bob, "msg.recv")
		assert(again == "", "inbox is emptied after reading")
	end)

	test("unknown users, empty messages and flooding are refused", function()
		local run, _, advance = setup()
		assert(not run(alice, "msg.send", "carol", "hello"))
		assert(not run(alice, "msg.send", "bob"))
		assert(run(alice, "msg.send", "Bob", "one"))
		assert(not run(alice, "msg.send", "bob", "two"), "rate limited")
		advance(2)
		assert(run(alice, "msg.send", "bob", "three"))
	end)
end
