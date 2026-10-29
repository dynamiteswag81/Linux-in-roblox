return function(test, root, require)
	local DiskStore = require(root.LinuxServer.DiskStore)
	local Disk = require(root.LinuxVM.Emulator.Disk)

	local function memoryStore()
		local data = {}
		return {
			data = data,
			GetAsync = function(_, key) return data[key] end,
			SetAsync = function(_, key, value) data[key] = value end,
			RemoveAsync = function(_, key) data[key] = nil end,
		}
	end

	test("disk save/load round trip with slot alternation", function()
		local store = memoryStore()
		local ds = DiskStore.new(store)
		local disk = Disk.new(4 * 1024 * 1024)
		disk:writeFrom(1000, 5, buffer.fromstring("hello"), 0)
		assert(ds:save(42, disk))
		assert(store.data.disk_42.slot == "a")
		disk:writeFrom(9000, 5, buffer.fromstring("world"), 0)
		assert(ds:save(42, disk))
		assert(store.data.disk_42.slot == "b")
		local loaded = ds:load(42)
		local out = buffer.create(5)
		loaded:readInto(9000, 5, out, 0)
		assert(buffer.tostring(out) == "world")
		assert(ds:load(7) == nil)
	end)
end
