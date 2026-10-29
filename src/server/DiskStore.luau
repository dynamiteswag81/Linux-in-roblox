--!strict
--[[
	Saves and loads player disks in a DataStore.

	A disk is serialized (Disk:serialize, LZ4-compressed), base64 encoded and split
	into chunks below the 4 MB value limit. Saves alternate between two slots and
	the manifest is written last, so an interrupted save never corrupts the
	previous one:

		disk_<userId>               { v = 1, slot = "a" | "b", chunks, bytes, saved, slotChunks = { a, b } }
		disk_<userId>_<slot>_<i>    base64 text
]]

local LinuxVM = require(script.Parent.Deps) :: any
local Base64 = require(LinuxVM.Util.Base64)
local Disk = require(LinuxVM.Emulator.Disk)

local CHUNK_CHARS = 3_500_000

-- The subset of DataStore the store needs (easy to mock in tests).
export type Store = {
	GetAsync: (self: any, key: string) -> any,
	SetAsync: (self: any, key: string, value: any) -> any,
	RemoveAsync: (self: any, key: string) -> any,
}

local DiskStore = {}
DiskStore.__index = DiskStore

export type DiskStore = typeof(setmetatable(
	{} :: {
		store: Store,
		saving: { [string]: boolean },
	},
	DiskStore
))

function DiskStore.new(store: Store): DiskStore
	return setmetatable({ store = store, saving = {} }, DiskStore)
end

-- Retries DataStore calls a few times (they fail transiently under load).
local function retry<T>(fn: () -> T): T
	local lastErr
	for attempt = 1, 4 do
		local ok, result = pcall(fn)
		if ok then
			return result
		end
		lastErr = result
		if task then
			task.wait(attempt)
		end
	end
	error(lastErr, 0)
end

-- Loads a player's disk, or returns nil if they have never saved one.
function DiskStore.load(self: DiskStore, userId: number): Disk.Disk?
	local key = "disk_" .. userId
	local manifest = retry(function()
		return self.store:GetAsync(key)
	end)
	if type(manifest) ~= "table" or manifest.v ~= 1 then
		return nil
	end
	local parts = table.create(manifest.chunks)
	for i = 1, manifest.chunks do
		local part = retry(function()
			return self.store:GetAsync(string.format("%s_%s_%d", key, manifest.slot, i))
		end)
		assert(type(part) == "string", "disk chunk " .. i .. " is missing")
		parts[i] = part
	end
	local text = table.concat(parts)
	local blob = Base64.decode(text)
	assert(buffer.len(blob) == manifest.bytes, "disk data is truncated")
	return Disk.deserialize(blob)
end

-- Saves a player's disk. Returns false if a save for this player is already running.
function DiskStore.save(self: DiskStore, userId: number, disk: Disk.Disk): boolean
	local key = "disk_" .. userId
	if self.saving[key] then
		return false
	end
	self.saving[key] = true
	local ok, err = pcall(function()
		local blob = disk:serialize()
		local text = Base64.encode(blob)
		local previous = retry(function()
			return self.store:GetAsync(key)
		end)
		local slot = if type(previous) == "table" and previous.slot == "a" then "b" else "a"
		local chunks = math.max(1, math.ceil(#text / CHUNK_CHARS))
		for i = 1, chunks do
			local part = string.sub(text, (i - 1) * CHUNK_CHARS + 1, i * CHUNK_CHARS)
			retry(function()
				return self.store:SetAsync(string.format("%s_%s_%d", key, slot, i), part)
			end)
		end
		-- Remember how many chunks each slot holds so leftovers can be cleaned up.
		local slotChunks = if type(previous) == "table" and type(previous.slotChunks) == "table"
			then table.clone(previous.slotChunks)
			else {}
		local stale = slotChunks[slot] or 0
		slotChunks[slot] = chunks
		retry(function()
			return self.store:SetAsync(key, {
				v = 1,
				slot = slot,
				chunks = chunks,
				bytes = buffer.len(blob),
				saved = os.time(),
				slotChunks = slotChunks,
			})
		end)
		-- Drop chunks left over from an older, bigger save in this slot.
		for i = chunks + 1, stale do
			pcall(function()
				self.store:RemoveAsync(string.format("%s_%s_%d", key, slot, i))
			end)
		end
	end)
	self.saving[key] = nil
	if not ok then
		error(err, 0)
	end
	return true
end

-- Deletes a player's saved disk (used by the "wipe disk" option).
function DiskStore.erase(self: DiskStore, userId: number)
	retry(function()
		return self.store:RemoveAsync("disk_" .. userId)
	end)
end

return DiskStore
