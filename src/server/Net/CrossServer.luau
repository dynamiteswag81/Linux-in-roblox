--!strict
--[[
	Links this server's network to the other game servers (see the Remote type
	in NetworkService). Each server has one player, so every other player's
	computer is in another server.

	- Messages go through MessagingService. Each player has a topic,
	  "BrickNet_<userId>", which only their server subscribes to.
	- The directory of online computers is a MemoryStore sorted map
	  (Config.NET_DIRECTORY): hostname -> { u = userId, o = owner name }. Entries
	  expire unless their server refreshes them, so a crashed server's
	  computers disappear on their own.

	Every call is wrapped in pcall: without these services (e.g. Studio without
	API access) computers simply can't reach other servers.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")

local LinuxVM = require(script.Parent.Parent.Deps) :: any
local Config = require(LinuxVM.Config)
local NetworkService = require(script.Parent.Parent.NetworkService)

local ENTRY_TTL = 180
local REFRESH_INTERVAL = 60
local LIST_LIMIT = 200

local CrossServer = {}

local function topicFor(userId: number): string
	return "BrickNet_" .. tostring(userId)
end

function CrossServer.new(network: NetworkService.NetworkService): NetworkService.Remote
	local map = MemoryStoreService:GetSortedMap(Config.NET_DIRECTORY)
	local registered: { [string]: NetworkService.RemoteEntry } = {}
	local subscriptions: { [number]: RBXScriptConnection } = {}

	local function publish(entry: NetworkService.RemoteEntry)
		local ok, err = pcall(function()
			map:SetAsync(entry.hostname, { u = entry.userId, o = entry.owner }, ENTRY_TTL)
		end)
		if not ok then
			warn("[Linux] Network directory update failed: " .. tostring(err))
		end
	end

	local function subscribe(userId: number)
		if subscriptions[userId] then
			return
		end
		local ok, result = pcall(function()
			return MessagingService:SubscribeAsync(topicFor(userId), function(message)
				local data = message.Data
				if type(data) == "string" then
					network:receiveRemote(data)
				end
			end)
		end)
		if ok then
			subscriptions[userId] = result
		else
			warn("[Linux] Can't receive network traffic from other servers: " .. tostring(result))
		end
	end

	-- Keep our entries alive while their computers are attached.
	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			for _, entry in registered do
				publish(entry)
			end
		end
	end)

	local remote: NetworkService.Remote = {
		lookup = function(hostname: string): NetworkService.RemoteEntry?
			local ok, value = pcall(function()
				return map:GetAsync(hostname)
			end)
			if ok and type(value) == "table" and type(value.u) == "number" then
				return { userId = value.u, hostname = hostname, owner = tostring(value.o) }
			end
			return nil
		end,

		list = function(): { NetworkService.RemoteEntry }
			local out = {}
			local ok, items = pcall(function()
				return map:GetRangeAsync(Enum.SortDirection.Ascending, LIST_LIMIT)
			end)
			if ok and type(items) == "table" then
				for _, item in items do
					local value = item.value
					if type(item.key) == "string" and type(value) == "table" and type(value.u) == "number" then
						table.insert(out, { userId = value.u, hostname = item.key, owner = tostring(value.o) })
					end
				end
			end
			return out
		end,

		register = function(entry: NetworkService.RemoteEntry)
			registered[entry.hostname] = entry
			task.spawn(function()
				subscribe(entry.userId)
				publish(entry)
			end)
		end,

		unregister = function(entry: NetworkService.RemoteEntry)
			if registered[entry.hostname] ~= nil then
				registered[entry.hostname] = nil
			end
			local connection = subscriptions[entry.userId]
			subscriptions[entry.userId] = nil
			if connection then
				connection:Disconnect()
			end
			task.spawn(function()
				pcall(function()
					map:RemoveAsync(entry.hostname)
				end)
			end)
		end,

		send = function(toUserId: number, message: string)
			task.spawn(function()
				local ok, err = pcall(function()
					MessagingService:PublishAsync(topicFor(toUserId), message)
				end)
				if not ok then
					warn("[Linux] Relaying network traffic failed: " .. tostring(err))
				end
			end)
		end,
	}
	return remote
end

return CrossServer
