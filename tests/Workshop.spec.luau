return function(test, root, require)
	local WorkshopService = require(root.LinuxServer.WorkshopService)
	local OfficialPackages = require(root.LinuxServer.OfficialPackages)
	local Tar = require(root.LinuxVM.Util.Tar)

	local function memoryStore()
		local data = {}
		return {
			data = data,
			GetAsync = function(_, key) return data[key] end,
			SetAsync = function(_, key, value) data[key] = value end,
			RemoveAsync = function(_, key) data[key] = nil end,
			UpdateAsync = function(_, key, fn) data[key] = fn(data[key]); return data[key] end,
		}
	end

	local clock = 1000
	local function newService(filter)
		return WorkshopService.new({
			store = memoryStore(),
			official = OfficialPackages.build(),
			filterText = filter,
			now = function() return clock end,
		})
	end

	local function package(name, version, extra)
		local entries = {
			{ name = "BRICK", data = "name=" .. name .. "\nversion=" .. version .. "\ndescription=A " .. name .. " tool\n" },
			{ name = "files", kind = "dir" },
			{ name = "files/usr/bin/" .. name, data = "#!/bin/sh\necho " .. name .. "\n", mode = 493 },
		}
		for _, e in extra or {} do
			table.insert(entries, e)
		end
		return Tar.build(entries)
	end

	test("official packages build and parse", function()
		for _, pkg in OfficialPackages.build() do
			local entries = Tar.parse(pkg.tar)
			assert(entries[1].name == "BRICK", pkg.name)
			assert(#pkg.files > 0, pkg.name)
		end
	end)

	test("publish, search, details, download", function()
		local ws = newService()
		local ok, msg = ws:publish(1, "alice", "zapper", package("zapper", "1.0", {
			{ name = "README", data = "Zaps things." },
		}))
		assert(ok, msg)
		local results = ws:search("zap")
		assert(#results == 1 and results[1].name == "zapper" and results[1].author == "alice")
		local d = ws:getDetails("zapper")
		assert(d.version == "1.0" and d.readme == "Zaps things." and d.files[1] == "/usr/bin/zapper")
		local tar = ws:download("zapper")
		assert(tar and Tar.parse(tar)[1].name == "BRICK")
		assert(ws:search("zap")[1].downloads == 1)
		ws:flushDownloads()
		assert(ws:getDetails("zapper").downloads == 1)
	end)

	test("search includes official packages and sorts official first", function()
		local ws = newService()
		ws:publish(1, "alice", "zapper", package("zapper", "1.0"))
		local all = ws:search("")
		assert(all[1].official)
		local found = false
		for _, r in all do
			if r.name == "zapper" then found = true end
		end
		assert(found)
		assert(ws:download("cowsay") ~= nil)
	end)

	test("only the author can update a package; official names are reserved", function()
		local ws = newService()
		assert(ws:publish(1, "alice", "zapper", package("zapper", "1.0")))
		local ok, msg = ws:publish(2, "bob", "zapper", package("zapper", "2.0"))
		assert(not ok and string.find(msg, "belongs to alice"), msg)
		ok = ws:publish(1, "alice", "zapper", package("zapper", "1.1"))
		assert(ok and ws:getDetails("zapper").version == "1.1")
		ok, msg = ws:publish(1, "alice", "cowsay", package("cowsay", "9"))
		assert(not ok and string.find(msg, "official"), msg)
	end)

	test("rejects bad packages", function()
		local ws = newService()
		assert(not ws:publish(1, "a", "Bad Name", package("x", "1")))
		assert(not ws:publish(1, "a", "x", "not a tar"))
		assert(not ws:publish(1, "a", "x", package("y", "1")), "manifest name mismatch")
		assert(not ws:publish(1, "a", "x", Tar.build({ { name = "files/a", data = "" } })), "no manifest")
	end)

	test("text is filtered and filtered names are rejected", function()
		local ws = newService(function(text)
			return (string.gsub(text, "badword", "#######"))
		end)
		local ok = ws:publish(1, "a", "tool", package("tool", "1", { { name = "README", data = "a badword here" } }))
		assert(ok)
		assert(ws:getDetails("tool").readme == "a ####### here")
		local ok2, msg = ws:publish(1, "a", "badword", package("badword", "1"))
		assert(not ok2 and string.find(msg, "isn't allowed"), msg)
	end)

	test("filter outage blocks publishing", function()
		local ws = newService(function() error("TextService down") end)
		local ok, msg = ws:publish(1, "a", "tool", package("tool", "1"))
		assert(not ok and string.find(msg, "unavailable"), msg)
	end)
end
