--[[
	A small Roblox runtime for Lune, good enough to run the game's server and
	client scripts headless.

	Instances are real @lune/roblox Instances (so property names, types and enum
	values are validated against Roblox's reflection database), wrapped in
	proxies that add what Lune lacks: events, GetPropertyChangedSignal,
	RemoteEvent/RemoteFunction routing between a server and a client "side",
	and a few derived properties. Services with behavior (Players, RunService,
	DataStoreService...) are mocked.
]]

local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Mock = {}
Mock.errors = {} :: { string }
Mock.log = {} :: { string }

---------------------------------------------------------------------------
-- Signals
---------------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal

function Signal.new(name: string?)
	return setmetatable({ handlers = {}, name = name or "?" }, Signal)
end

function Signal:Connect(fn)
	local handler = { fn = fn, connected = true }
	table.insert(self.handlers, handler)
	local connection = { Connected = true }
	function connection:Disconnect()
		handler.connected = false
		connection.Connected = false
	end
	return connection
end

function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

-- Fires handlers in new threads, like Roblox (handlers may yield).
function Signal:Fire(...)
	local args = table.pack(...)
	for _, h in table.clone(self.handlers) do
		if h.connected then
			task.spawn(function()
				local ok, err = pcall(h.fn, table.unpack(args, 1, args.n))
				if not ok then
					local msg = string.format("[signal %s] %s", self.name, tostring(err))
					table.insert(Mock.errors, msg)
					print("ERROR " .. msg)
				end
			end)
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

Mock.Signal = Signal

---------------------------------------------------------------------------
-- Instance proxies
---------------------------------------------------------------------------

local proxyOf = setmetatable({}, { __mode = "k" }) -- real -> proxy
local realOf = setmetatable({}, { __mode = "k" }) -- proxy -> real
local extra = setmetatable({}, { __mode = "k" }) -- proxy -> { signals, overrides, callbacks, mounts }

local EVENTS = {
	Triggered = true,
	MouseClick = true,
	Activated = true,
	MouseButton1Click = true,
	FocusLost = true,
	Focused = true,
	Changed = true,
	Died = true,
	CharacterAdded = true,
	CharacterRemoving = true,
	OnServerEvent = true,
	OnClientEvent = true,
	ChildAdded = true,
	ChildRemoved = true,
	AncestryChanged = true,
	Destroying = true,
	Event = true,
}
local CALLBACKS = { OnServerInvoke = true, OnClientInvoke = true, OnInvoke = true }

local wrap

local function unwrap(v)
	if type(v) == "table" and realOf[v] then
		return realOf[v]
	end
	return v
end

local function info(proxy)
	local e = extra[proxy]
	if not e then
		e = { signals = {}, overrides = {}, callbacks = {}, mounts = {} }
		extra[proxy] = e
	end
	return e
end

local function signalFor(proxy, name)
	local e = info(proxy)
	local s = e.signals[name]
	if not s then
		s = Signal.new(tostring(realOf[proxy]) .. "." .. name)
		e.signals[name] = s
	end
	return s
end

-- Which side (server/client) code is running on, for remotes.
Mock.side = "server"
Mock.localPlayer = nil

local METHODS = {}

function METHODS.GetPropertyChangedSignal(self, prop)
	return signalFor(self, "prop:" .. prop)
end

function METHODS.GetAttributeChangedSignal(self, name)
	return signalFor(self, "attr:" .. name)
end

function METHODS.SetAttribute(self, name, value)
	local real = realOf[self]
	local old = real:GetAttribute(name)
	real:SetAttribute(name, unwrap(value))
	if old ~= value then
		local s = info(self).signals["attr:" .. name]
		if s then
			s:Fire()
		end
	end
end

function METHODS.WaitForChild(self, name, timeout)
	local deadline = os.clock() + (timeout or 5)
	while true do
		local child = self:FindFirstChild(name)
		if child then
			return child
		end
		if os.clock() > deadline then
			error(string.format("Infinite yield: %s:WaitForChild(%q)", tostring(realOf[self]), name), 2)
		end
		task.wait(0.01)
	end
end

function METHODS.FindFirstChild(self, name, recursive)
	local mount = info(self).mounts[name]
	if mount then
		return mount
	end
	return wrap(realOf[self]:FindFirstChild(name, recursive))
end

function METHODS.FireClient(self, player, ...)
	table.insert(Mock.log, "FireClient " .. realOf[self].Name)
	if player == Mock.localPlayer then
		signalFor(self, "OnClientEvent"):Fire(...)
	end
end

function METHODS.FireAllClients(self, ...)
	signalFor(self, "OnClientEvent"):Fire(...)
end

function METHODS.FireServer(self, ...)
	table.insert(Mock.log, "FireServer " .. realOf[self].Name)
	signalFor(self, "OnServerEvent"):Fire(Mock.localPlayer, ...)
end

function METHODS.InvokeServer(self, ...)
	local cb = info(self).callbacks.OnServerInvoke
	assert(cb, "InvokeServer: no OnServerInvoke on " .. tostring(realOf[self]))
	return cb(Mock.localPlayer, ...)
end

function METHODS.Sit(self, humanoid)
	table.insert(Mock.log, "Sit " .. tostring(realOf[humanoid] and realOf[humanoid].Name))
end

function METHODS.CaptureFocus(self) end
function METHODS.ReleaseFocus(self) end

local function derived(real, key)
	if key == "Position" and real:IsA("BasePart") then
		return real.CFrame.Position
	elseif key == "AbsoluteSize" and real:IsA("GuiBase2d") then
		return roblox.Vector2.new(1200, 750)
	elseif key == "Occupant" and real:IsA("Seat") then
		return nil
	elseif key == "Character" and real:IsA("Player") then
		return nil
	end
	return nil
end

local proxyMeta = {}

proxyMeta.__index = function(proxy, key)
	local e = info(proxy)
	if e.overrides[key] ~= nil then
		return e.overrides[key]
	end
	if EVENTS[key] then
		return signalFor(proxy, key)
	end
	if CALLBACKS[key] then
		return e.callbacks[key]
	end
	local method = METHODS[key]
	if method then
		return method
	end
	local mount = e.mounts[key]
	if mount then
		return mount
	end
	local real = realOf[proxy]
	local ok, value = pcall(function()
		return real[key]
	end)
	if not ok then
		local d = derived(real, key)
		if d ~= nil or key == "Occupant" or key == "Character" then
			return d
		end
		error(value, 2)
	end
	if type(value) == "function" then
		return function(_, ...)
			local args = table.pack(...)
			for i = 1, args.n do
				args[i] = unwrap(args[i])
			end
			local results = table.pack(value(real, table.unpack(args, 1, args.n)))
			for i = 1, results.n do
				results[i] = wrap(results[i])
			end
			return table.unpack(results, 1, results.n)
		end
	end
	return wrap(value)
end

proxyMeta.__newindex = function(proxy, key, value)
	local e = info(proxy)
	if CALLBACKS[key] then
		e.callbacks[key] = value
		return
	end
	local real = realOf[proxy]
	local ok, err = pcall(function()
		real[key] = unwrap(value)
	end)
	if not ok then
		-- Read-only or default-less properties we fake (e.g. Player.UserId).
		if e.overrides[key] ~= nil or key == "Character" then
			e.overrides[key] = value
		else
			error(err, 2)
		end
	end
	local s = e.signals["prop:" .. key]
	if s then
		s:Fire()
	end
	local changed = e.signals.Changed
	if changed then
		changed:Fire(key)
	end
end

proxyMeta.__tostring = function(proxy)
	return tostring(realOf[proxy])
end

function wrap(v)
	if typeof(v) == "Instance" then
		local p = proxyOf[v]
		if not p then
			p = setmetatable({}, proxyMeta)
			proxyOf[v] = p
			realOf[p] = v
		end
		return p
	elseif type(v) == "table" and getmetatable(v) == nil then
		-- Arrays of instances (GetChildren etc.)
		local out = {}
		for k, item in v do
			out[k] = wrap(item)
		end
		return out
	end
	return v
end

Mock.wrap = wrap
Mock.unwrap = unwrap

-- Sets a fake value for a property Lune can't provide (UserId, Character...).
function Mock.override(proxy, key, value)
	info(proxy).overrides[key] = value
end

-- Makes `name` under `proxy` resolve to `node` (used to expose the Lune shim's
-- module trees, e.g. ReplicatedStorage.LinuxVM).
function Mock.mount(proxy, name, node)
	info(proxy).mounts[name] = node
end

-- A per-side view of an instance where some children resolve to module trees
-- mounted from disk (e.g. the server's and the client's own copy of LinuxVM).
function Mock.sideView(proxy, getMounts: () -> { [string]: any })
	local view = setmetatable({}, {
		__index = function(_, key)
			local mounts = getMounts()
			if key == "WaitForChild" or key == "FindFirstChild" then
				return function(_, name, ...)
					if mounts[name] then
						return mounts[name]
					end
					return proxy[key](proxy, name, ...)
				end
			end
			if mounts[key] then
				return mounts[key]
			end
			local v = proxy[key]
			if type(v) == "function" then
				return function(_, ...)
					return v(proxy, ...)
				end
			end
			return v
		end,
		__newindex = function(_, key, value)
			proxy[key] = value
		end,
		__tostring = function()
			return tostring(proxy)
		end,
	})
	realOf[view] = realOf[proxy]
	return view
end

function Mock.new(className: string)
	return wrap(roblox.Instance.new(className))
end

---------------------------------------------------------------------------
-- World and services
---------------------------------------------------------------------------

function Mock.createWorld()
	local world = {}
	local dm = roblox.Instance.new("DataModel")
	world.dataModel = dm
	world.Workspace = wrap(dm:GetService("Workspace"))
	world.ReplicatedStorage = wrap(dm:GetService("ReplicatedStorage"))
	world.ServerStorage = wrap(dm:GetService("ServerStorage"))
	world.ServerScriptService = wrap(dm:GetService("ServerScriptService"))

	local camera = {
		CFrame = roblox.CFrame.new(0, 10, 10),
		FieldOfView = 70,
		ViewportSize = roblox.Vector2.new(1280, 720),
		CameraType = roblox.Enum.CameraType.Custom,
	}
	Mock.override(world.Workspace, "CurrentCamera", camera)
	world.camera = camera

	-- Players
	local players = {
		PlayerAdded = Signal.new("PlayerAdded"),
		PlayerRemoving = Signal.new("PlayerRemoving"),
		list = {},
		LocalPlayer = nil,
	}
	function players:GetPlayers()
		return table.clone(self.list)
	end
	function players:GetPlayerByUserId(userId)
		for _, p in self.list do
			if p.UserId == userId then
				return p
			end
		end
		return nil
	end
	world.Players = players

	local function runService(isServer)
		local rs = {
			Heartbeat = world.heartbeat,
			RenderStepped = world.renderStepped,
		}
		function rs:IsServer()
			return isServer
		end
		function rs:IsClient()
			return not isServer
		end
		function rs:IsStudio()
			return true
		end
		return rs
	end
	world.heartbeat = Signal.new("Heartbeat")
	world.renderStepped = Signal.new("RenderStepped")

	local tagSignals = {}
	local function tagSignal(kind, tag)
		local key = kind .. ":" .. tag
		tagSignals[key] = tagSignals[key] or Signal.new(key)
		return tagSignals[key]
	end
	local collection = {}
	function collection:GetTagged(tag)
		local out = {}
		for _, inst in dm:GetDescendants() do
			if inst:HasTag(tag) then
				table.insert(out, wrap(inst))
			end
		end
		return out
	end
	function collection:GetInstanceAddedSignal(tag)
		return tagSignal("added", tag)
	end
	function collection:GetInstanceRemovedSignal(tag)
		return tagSignal("removed", tag)
	end
	function world.addTag(proxy, tag)
		realOf[proxy]:AddTag(tag)
		tagSignal("added", tag):Fire(proxy)
	end

	local stores = {}
	local dataStoreService = {}
	function dataStoreService:GetDataStore(name)
		if world.dataStoresFail then
			error("DataStore requests are disabled in this mock")
		end
		local store = stores[name]
		if not store then
			local data = {}
			store = {}
			function store:GetAsync(key)
				return data[key]
			end
			function store:SetAsync(key, value)
				data[key] = value
			end
			function store:RemoveAsync(key)
				data[key] = nil
			end
			function store:UpdateAsync(key, fn)
				data[key] = fn(data[key])
				return data[key]
			end
			stores[name] = store
		end
		return store
	end
	world.dataStores = stores

	local textService = {}
	function textService:FilterStringAsync(text, _fromUserId, context)
		assert(typeof(context) == "EnumItem" or context == nil, "bad TextFilterContext")
		local filtered = string.gsub(text, "badword", "#######")
		return {
			GetNonChatStringForBroadcastAsync = function()
				return filtered
			end,
			GetChatForUserAsync = function(_, toUserId)
				assert(type(toUserId) == "number", "GetChatForUserAsync needs a user id")
				return filtered
			end,
		}
	end
	function textService:GetTextSize(text, size)
		return roblox.Vector2.new(#text * size * 0.6, size)
	end

	local starterGui = {}
	function starterGui:SetCoreGuiEnabled() end
	function starterGui:SetCore(name, value)
		table.insert(Mock.log, "SetCore " .. name .. " " .. tostring(type(value) == "table" and value.Text or value))
	end

	local textChat = { ChatInputBarConfiguration = { Enabled = true } }

	world.boundActions = {}
	local contextActions = {}
	function contextActions:BindActionAtPriority(name, fn, _, priority, ...)
		assert(type(priority) == "number", "priority must be a number")
		for i = 1, select("#", ...) do
			local item = select(i, ...)
			assert(typeof(item) == "EnumItem", "bad input type")
		end
		world.boundActions[name] = fn
	end
	function contextActions:UnbindAction(name)
		world.boundActions[name] = nil
	end

	local tweenService = {}
	function tweenService:Create(target, _, goals)
		return {
			Play = function()
				for k, v in goals do
					target[k] = v
				end
			end,
		}
	end

	-- MemoryStore sorted maps (in memory) and MessagingService (loopback in
	-- this one server), enough for the cross-server network.
	local sortedMaps = {}
	local memoryStoreService = {}
	function memoryStoreService:GetSortedMap(name)
		local data = sortedMaps[name] or {}
		sortedMaps[name] = data
		local map = {}
		function map:SetAsync(key, value, _expiration)
			data[key] = value
			return true
		end
		function map:GetAsync(key)
			return data[key]
		end
		function map:RemoveAsync(key)
			data[key] = nil
		end
		function map:GetRangeAsync(_direction, count)
			local keys = {}
			for key in data do
				table.insert(keys, key)
			end
			table.sort(keys)
			local out = {}
			for i = 1, math.min(count, #keys) do
				out[i] = { key = keys[i], value = data[keys[i]] }
			end
			return out
		end
		return map
	end
	world.messages = {}
	local topics = {}
	local messagingService = {}
	function messagingService:SubscribeAsync(topic, callback)
		topics[topic] = callback
		return {
			Disconnect = function()
				if topics[topic] == callback then
					topics[topic] = nil
				end
			end,
		}
	end
	function messagingService:PublishAsync(topic, data)
		assert(#data <= 1024, "MessagingService messages are limited to 1 KB")
		table.insert(world.messages, topic)
		local callback = topics[topic]
		if callback then
			task.spawn(callback, { Data = data, Sent = os.time() })
		end
	end

	world.keysDown = {}
	local uis = { TouchEnabled = false }
	function uis:IsKeyDown(kc)
		return world.keysDown[kc.Name] == true
	end

	world.mounts = { server = {}, client = {} }
	local function serviceTable(isServer)
		local mounts = world.mounts[if isServer then "server" else "client"]
		return {
			Workspace = world.Workspace,
			ReplicatedStorage = Mock.sideView(world.ReplicatedStorage, function()
				return mounts.ReplicatedStorage or {}
			end),
			ServerStorage = Mock.sideView(world.ServerStorage, function()
				return mounts.ServerStorage or {}
			end),
			ServerScriptService = world.ServerScriptService,
			Players = players,
			RunService = runService(isServer),
			CollectionService = collection,
			DataStoreService = dataStoreService,
			MemoryStoreService = memoryStoreService,
			MessagingService = messagingService,
			TextService = textService,
			StarterGui = starterGui,
			TextChatService = textChat,
			ContextActionService = contextActions,
			TweenService = tweenService,
			UserInputService = uis,
		}
	end

	-- A `game` object for one side.
	function world.game(side: "server" | "client")
		local services = serviceTable(side == "server")
		local g = { bindToClose = {} }
		function g:GetService(name)
			local s = services[name]
			assert(s, "mock has no service " .. name)
			return s
		end
		function g:BindToClose(fn)
			table.insert(self.bindToClose, fn)
		end
		return g
	end

	-- Globals scripts expect, for the shim's `inject` option.
	function world.globals(side: "server" | "client")
		local Vector3 = setmetatable({
			FromNormalId = function(id)
				local map = {
					Front = roblox.Vector3.new(0, 0, -1),
					Back = roblox.Vector3.new(0, 0, 1),
					Left = roblox.Vector3.new(-1, 0, 0),
					Right = roblox.Vector3.new(1, 0, 0),
					Top = roblox.Vector3.new(0, 1, 0),
					Bottom = roblox.Vector3.new(0, -1, 0),
				}
				return map[id.Name]
			end,
		}, { __index = roblox.Vector3 })
		return {
			game = world.game(side),
			workspace = world.Workspace,
			Enum = roblox.Enum,
			Instance = {
				new = function(className, parent)
					local inst = Mock.new(className)
					if parent then
						inst.Parent = parent
					end
					return inst
				end,
			},
			Vector2 = roblox.Vector2,
			Vector3 = Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			UDim = roblox.UDim,
			UDim2 = roblox.UDim2,
			Font = roblox.Font,
			TweenInfo = { new = function(...) return { ... } end },
			task = task,
		}
	end

	-- Players
	local nextUserId = 1000
	function world.addPlayer(name: string)
		nextUserId += 1
		local player = Mock.new("Player")
		player.Name = name
		Mock.override(player, "UserId", nextUserId)
		Mock.override(player, "DisplayName", name)
		local gui = Mock.new("PlayerGui")
		gui.Parent = player
		local character = Mock.new("Model")
		character.Name = name
		local humanoid = Mock.new("Humanoid")
		humanoid.Parent = character
		character.Parent = world.Workspace
		Mock.override(player, "Character", character)
		table.insert(players.list, player)
		players.PlayerAdded:Fire(player)
		return player
	end

	return world
end

return Mock
