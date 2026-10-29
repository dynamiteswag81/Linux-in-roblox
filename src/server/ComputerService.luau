--!strict
--[[
	Runs everyone's computers on the server and connects them to the world.

	- Each player owns one computer (VM + disk). It is created the first time
	  they use a desk and keeps running while they're in the server, so things
	  like web servers stay reachable for other players.
	- Desks are Models tagged "LinuxComputer" (CollectionService) with a part
	  named "Screen". Using a desk shows *your* computer on it. See docs/SETUP.md.
	- The installer flash drive is the desk's "FlashDrive" attribute (true when
	  plugged in), set by the game's own flash drive mechanic or through
	  ComputerService.insertFlashDrive / ejectFlashDrive.
	- Every frame the running computers share Config.FRAME_BUDGET of CPU time,
	  and new console output is streamed to whoever is looking at the screen.
]]

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TextService = game:GetService("TextService")

local LinuxVM = require(script.Parent.Deps) :: any
local Config = require(LinuxVM.Config)
local Disk = require(LinuxVM.Emulator.Disk)
local ImageLoader = require(LinuxVM.Emulator.ImageLoader)
local Remotes = require(LinuxVM.Remotes)

local Computer = require(script.Parent.Computer)
local DiskStore = require(script.Parent.DiskStore)
local HostLinkCommands = require(script.Parent.HostLinkCommands)
local NetworkService = require(script.Parent.NetworkService)
local OfficialPackages = require(script.Parent.OfficialPackages)
local WorkshopService = require(script.Parent.WorkshopService)
local WorkshopWeb = require(script.Parent.WorkshopWeb)

local DESK_TAG = "LinuxComputer"

type Session = {
	player: Player,
	computer: Computer.Computer?,
	disk: Disk.Disk?,
	diskLoaded: boolean,
	diskPersistent: boolean,
	desk: Model?,
	endpoint: NetworkService.Endpoint?,
	lastSaveGeneration: number,
	lastSaveAt: number,
	saveRequested: boolean,
	inputWindow: number,
	inputCount: number,
}

local ComputerService = {}

local sessions: { [Player]: Session } = {}
local deskOwner: { [Model]: Player } = {}

local terminalOutput = Remotes.event("TerminalOutput")
local terminalInput = Remotes.event("TerminalInput")
local computerAction = Remotes.event("ComputerAction")
local notify = Remotes.event("Notify")
local workshopRemote = Remotes.func("Workshop")

---------------------------------------------------------------------------
-- Storage: DataStores when available (published games, or Studio with API
-- access enabled), otherwise an in-memory store so everything still works.
---------------------------------------------------------------------------

local function memoryStore()
	local data = {}
	return {
		GetAsync = function(_, key)
			return data[key]
		end,
		SetAsync = function(_, key, value)
			data[key] = value
		end,
		RemoveAsync = function(_, key)
			data[key] = nil
		end,
		UpdateAsync = function(_, key, fn)
			data[key] = fn(data[key])
			return data[key]
		end,
	}
end

local function openStore(name: string): (any, boolean)
	local ok, store = pcall(function()
		local s = DataStoreService:GetDataStore(name)
		s:GetAsync("probe")
		return s
	end)
	if ok then
		return store, true
	end
	warn(
		string.format(
			"[Linux] DataStore '%s' unavailable (%s). Using memory: nothing will be saved. "
				.. "In Studio, enable Game Settings > Security > Enable Studio Access to API Services.",
			name,
			tostring(store)
		)
	)
	return memoryStore(), false
end

local diskStoreBackend, disksPersistent = openStore(Config.DISK_DATASTORE)
local workshopBackend = openStore(Config.WORKSHOP_DATASTORE)
local diskStore = DiskStore.new(diskStoreBackend)

local workshop = WorkshopService.new({
	store = workshopBackend,
	official = OfficialPackages.build(),
	filterText = function(text: string, userId: number): string
		if userId <= 0 then
			return text
		end
		local result = TextService:FilterStringAsync(text, userId, Enum.TextFilterContext.PublicChat)
		return result:GetNonChatStringForBroadcastAsync()
	end,
})
local network = NetworkService.new()
local commands = HostLinkCommands.new(workshop, network, {
	-- Player-to-player messages (`msg`) are filtered like private chat.
	filterMessage = function(text: string, fromUserId: number, toUserId: number): string
		local result = TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PrivateChat)
		return result:GetChatForUserAsync(toUserId)
	end,
	notifyMessage = function(toUserId: number, fromName: string, text: string)
		local target = Players:GetPlayerByUserId(toUserId)
		if target then
			notify:FireClient(target, "📨 " .. fromName .. ": " .. text)
		end
	end,
})

-- The Community Workshop website at http://workshop/ on the in-game network.
network:serveHttp(function(request, respond)
	task.spawn(function()
		local ok, result = pcall(WorkshopWeb.handle, workshop, request)
		respond(if ok then result else "HTTP/1.0 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
	end)
end)

ComputerService.workshop = workshop
ComputerService.network = network

---------------------------------------------------------------------------
-- Kernel images (ServerStorage.LinuxImages, made by tools/image2luau.py)
---------------------------------------------------------------------------

local imageCache: { [string]: buffer | false } = {}

local function loadImage(name: string): buffer?
	local cached = imageCache[name]
	if cached ~= nil then
		return cached or nil
	end
	local folder = ServerStorage:FindFirstChild("LinuxImages")
	local module = folder and folder:FindFirstChild(name)
	local image: buffer? = nil
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(ImageLoader.load, module)
		if ok then
			image = result
		else
			warn("[Linux] Failed to load image " .. name .. ": " .. tostring(result))
		end
	end
	imageCache[name] = image or false
	return image
end

---------------------------------------------------------------------------
-- Viewers and streaming
---------------------------------------------------------------------------

-- Players who should receive a computer's screen.
local function viewersOf(session: Session): { Player }
	if not session.desk then
		return {}
	end
	if Config.SHOW_SCREENS_TO_OTHERS then
		return Players:GetPlayers()
	end
	return { session.player }
end

local function sendSnapshot(session: Session, players: { Player })
	local computer = session.computer
	if not computer then
		return
	end
	local snapshot = computer.terminal:snapshot()
	for _, p in players do
		terminalOutput:FireClient(p, computer.id, "state", computer.state)
		terminalOutput:FireClient(p, computer.id, "snapshot", snapshot)
	end
end

local function notifyPlayer(player: Player, message: string)
	notify:FireClient(player, message)
end

---------------------------------------------------------------------------
-- Sessions, disks and computers
---------------------------------------------------------------------------

local function saveDisk(session: Session, reason: string)
	local disk = session.disk
	if not disk or not session.diskPersistent or not session.diskLoaded then
		return
	end
	if disk.generation == session.lastSaveGeneration then
		return
	end
	local generation = disk.generation
	session.lastSaveAt = os.clock()
	local ok, err = pcall(function()
		return diskStore:save(session.player.UserId, disk)
	end)
	if ok then
		session.lastSaveGeneration = generation
	else
		warn(string.format("[Linux] Saving %s's disk (%s) failed: %s", session.player.Name, reason, tostring(err)))
	end
end

local function getSession(player: Player): Session
	local session = sessions[player]
	if session then
		return session
	end
	session = {
		player = player,
		computer = nil,
		disk = nil,
		diskLoaded = false,
		diskPersistent = disksPersistent,
		desk = nil,
		endpoint = nil,
		lastSaveGeneration = 0,
		lastSaveAt = 0,
		saveRequested = false,
		inputWindow = 0,
		inputCount = 0,
	}
	sessions[player] = session
	-- Load the disk in the background as soon as the player joins.
	task.spawn(function()
		local ok, disk = pcall(function()
			return diskStore:load(player.UserId)
		end)
		if not ok then
			warn("[Linux] Loading " .. player.Name .. "'s disk failed: " .. tostring(disk) .. " (saving disabled)")
			session.diskPersistent = false
			disk = nil
		end
		if not session.disk then
			session.disk = disk or Disk.new(Config.DISK_MB * 1024 * 1024)
		end
		session.lastSaveGeneration = (session.disk :: Disk.Disk).generation
		session.diskLoaded = true
	end)
	return session
end

local function getComputer(session: Session): Computer.Computer?
	if session.computer then
		return session.computer
	end
	if not session.diskLoaded then
		return nil
	end
	local player = session.player
	local hostname = NetworkService.hostnameFor(player.Name)
	local ipText, ipBytes, mac = network:allocateAddress()
	local computer = Computer.new({
		id = tostring(player.UserId),
		ownerName = player.Name,
		hostname = hostname,
		ip = ipText,
		mac = mac,
		disk = session.disk :: Disk.Disk,
		loadImage = loadImage,
	})
	local owner = { userId = player.UserId, name = player.Name }
	computer.hostLinkHandler = function(command, args, payload, reply)
		task.spawn(function()
			local ok, err = pcall(commands.run, commands, owner, command, args, payload, reply)
			if not ok then
				reply(false, "hostlink: " .. tostring(err))
			end
		end)
	end
	computer.onFlush = function()
		session.saveRequested = true
	end
	computer.onStateChanged = function(state)
		if session.desk then
			session.desk:SetAttribute("ComputerState", state)
		end
		for _, p in viewersOf(session) do
			terminalOutput:FireClient(p, computer.id, "state", state)
		end
		if state == "off" then
			session.saveRequested = true
		end
	end
	local endpoint: NetworkService.Endpoint = {
		hostname = hostname,
		ip = ipBytes,
		mac = mac,
		owner = player.Name,
		userId = player.UserId,
		deliver = function(frame)
			computer:receiveFrame(frame)
		end,
	}
	computer.onFrame = function(frame)
		network:transmit(endpoint, frame)
	end
	network:attach(endpoint)
	session.endpoint = endpoint
	session.computer = computer
	return computer
end

---------------------------------------------------------------------------
-- Desks
---------------------------------------------------------------------------

local function findScreen(desk: Model): BasePart?
	local screen = desk:FindFirstChild("Screen", true)
	if screen and screen:IsA("BasePart") then
		return screen
	end
	return desk.PrimaryPart
end

-- The image on the flash drive plugged into a desk, if any.
local function deskFlashDrive(desk: Model): string?
	local value = desk:GetAttribute("FlashDrive")
	if value == true then
		return Config.IMAGE
	elseif type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function leaveDesk(player: Player)
	local session = sessions[player]
	if not session or not session.desk then
		return
	end
	local desk = session.desk
	session.desk = nil
	if session.computer then
		session.computer:setFlashDrive(nil)
	end
	if deskOwner[desk] == player then
		deskOwner[desk] = nil
		desk:SetAttribute("InUseBy", 0)
		desk:SetAttribute("UserName", "")
		desk:SetAttribute("ComputerId", "")
		desk:SetAttribute("ComputerState", "off")
	end
	computerAction:FireClient(player, "left")
end

local function useDesk(player: Player, desk: Model)
	local current = deskOwner[desk]
	if current and current ~= player then
		notifyPlayer(player, "This computer is being used by " .. current.DisplayName .. ".")
		return
	end
	local session = getSession(player)
	if session.desk and session.desk ~= desk then
		leaveDesk(player)
	end
	-- The disk may still be loading for a moment after joining.
	local deadline = os.clock() + 15
	while not session.diskLoaded and os.clock() < deadline do
		task.wait(0.1)
	end
	local computer = getComputer(session)
	if not computer then
		notifyPlayer(player, "Your disk is still loading. Try again in a moment.")
		return
	end
	if deskOwner[desk] and deskOwner[desk] ~= player then
		return -- someone else sat down while we waited
	end
	deskOwner[desk] = player
	session.desk = desk
	computer:setFlashDrive(deskFlashDrive(desk))
	desk:SetAttribute("InUseBy", player.UserId)
	desk:SetAttribute("UserName", player.DisplayName)
	desk:SetAttribute("ComputerId", computer.id)
	desk:SetAttribute("ComputerState", computer.state)

	local seat = desk:FindFirstChildWhichIsA("Seat", true)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if seat and humanoid and not seat.Occupant then
		seat:Sit(humanoid)
	end

	computerAction:FireClient(player, "using", desk, computer.id)
	sendSnapshot(session, viewersOf(session))
	if not session.diskPersistent then
		notifyPlayer(player, "Saving is unavailable right now: changes to your disk won't be kept.")
	end
end

local function setupDesk(desk: Instance)
	if not desk:IsA("Model") then
		warn("[Linux] " .. desk:GetFullName() .. " is tagged " .. DESK_TAG .. " but isn't a Model")
		return
	end
	local screen = findScreen(desk)
	if not screen then
		warn("[Linux] Desk " .. desk:GetFullName() .. " needs a part named Screen")
		return
	end
	desk:SetAttribute("InUseBy", 0)
	desk:SetAttribute("UserName", "")
	desk:SetAttribute("ComputerId", "")
	desk:SetAttribute("ComputerState", "off")
	if desk:GetAttribute("FlashDrive") == nil then
		desk:SetAttribute("FlashDrive", false)
	end
	desk:GetAttributeChangedSignal("FlashDrive"):Connect(function()
		local player = deskOwner[desk]
		local session = player and sessions[player]
		local computer = session and session.computer
		if computer then
			computer:setFlashDrive(deskFlashDrive(desk))
		end
	end)

	local prompt = desk:FindFirstChild("UseComputerPrompt", true)
	if not prompt then
		local newPrompt = Instance.new("ProximityPrompt")
		newPrompt.Name = "UseComputerPrompt"
		newPrompt.ActionText = "Use computer"
		newPrompt.ObjectText = Config.OS_NAME
		newPrompt.KeyboardKeyCode = Enum.KeyCode.E
		newPrompt.HoldDuration = 0
		newPrompt.MaxActivationDistance = 10
		newPrompt.RequiresLineOfSight = false
		newPrompt.Parent = screen
		prompt = newPrompt
	end
	(prompt :: ProximityPrompt).Triggered:Connect(function(player)
		useDesk(player, desk)
	end)

	-- Optional physical keyboard: parts named Key_<KeyCode name> become clickable
	-- (the client turns clicks into key presses for whoever is using the desk).
	for _, part in desk:GetDescendants() do
		if part:IsA("BasePart") and string.match(part.Name, "^Key_.+") and not part:FindFirstChildOfClass("ClickDetector") then
			local detector = Instance.new("ClickDetector")
			detector.MaxActivationDistance = 12
			detector.Parent = part
		end
	end

	-- Optional physical power button with a ClickDetector.
	local powerButton = desk:FindFirstChild("PowerButton", true)
	if powerButton and powerButton:IsA("BasePart") then
		local detector = powerButton:FindFirstChildOfClass("ClickDetector") or Instance.new("ClickDetector")
		detector.MaxActivationDistance = 12
		detector.Parent = powerButton
		detector.MouseClick:Connect(function(player)
			if deskOwner[desk] == player then
				local session = sessions[player]
				local computer = session and session.computer
				if computer then
					computer:pressPower(os.clock())
				end
			end
		end)
	end
end

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------

terminalInput.OnServerEvent:Connect(function(player: Player, data: any)
	if type(data) ~= "string" or #data == 0 or #data > Config.MAX_INPUT_BYTES then
		return
	end
	local session = sessions[player]
	if not session or not session.desk or not session.computer then
		return
	end
	local now = os.clock()
	if now - session.inputWindow >= 1 then
		session.inputWindow = now
		session.inputCount = 0
	end
	session.inputCount += 1
	if session.inputCount > Config.MAX_INPUT_RATE then
		return
	end
	session.computer:input(data)
end)

computerAction.OnServerEvent:Connect(function(player: Player, action: any)
	local session = sessions[player]
	if action == "leave" then
		leaveDesk(player)
		return
	end
	local computer = session and session.desk and session.computer
	if not computer then
		return
	end
	if action == "power" then
		computer:pressPower(os.clock())
	elseif action == "reset" then
		computer:reset(os.clock())
	elseif action == "refresh" then
		sendSnapshot(session, { player })
	end
end)

local function publicDetails(d: any)
	return {
		name = d.name,
		version = d.version,
		description = d.description,
		readme = d.readme,
		files = d.files,
		depends = d.depends,
		authorName = d.authorName,
		updated = d.updated,
		size = d.size,
		downloads = d.downloads,
		official = d.official,
	}
end

workshopRemote.OnServerInvoke = function(player: Player, action: any, arg1: any, arg2: any): any
	if action == "search" then
		local query = if type(arg1) == "string" then string.sub(arg1, 1, 64) else ""
		local sort = if arg2 == "new" or arg2 == "name" then arg2 else "popular"
		local ok, results = pcall(workshop.search, workshop, query, sort, 100)
		return if ok then results else {}
	elseif action == "details" and type(arg1) == "string" then
		local ok, d = pcall(workshop.getDetails, workshop, arg1)
		return if ok and d then publicDetails(d) else nil
	elseif action == "install" and type(arg1) == "string" and WorkshopService.validName(arg1) then
		local session = sessions[player]
		local computer = session and session.computer
		if computer and computer.state == "running" then
			computer:input("brick install " .. arg1)
			return "Typed \"brick install " .. arg1 .. "\" on your computer. Press Enter there to install."
		end
		return "Turn on your computer and run: brick install " .. arg1
	end
	return nil
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------

local function step()
	local now = os.clock()
	local active = {}
	for _, session in sessions do
		local computer = session.computer
		if computer and computer.state ~= "off" then
			table.insert(active, session)
		end
	end
	if #active > 0 then
		local budget = math.min(Config.MAX_COMPUTER_BUDGET, Config.FRAME_BUDGET / #active)
		for _, session in active do
			local computer = session.computer :: Computer.Computer
			local ok, err = pcall(computer.update, computer, now, budget)
			if not ok then
				warn("[Linux] " .. session.player.Name .. "'s computer crashed: " .. tostring(err))
				computer:pressPower(now) -- turn it off
			end
		end
	end
	network:tick()
	-- Stream output (including computers that just turned off).
	for _, session in sessions do
		local computer = session.computer
		if computer then
			local item = computer:takeStream(now)
			if item then
				-- Console output can be any bytes (not valid UTF-8), so send it as a buffer.
				local payload = if item.kind == "data" then buffer.fromstring(item.payload) else item.payload
				for _, p in viewersOf(session) do
					terminalOutput:FireClient(p, computer.id, item.kind, payload)
				end
			end
		end
	end
end

local function saveLoop()
	while true do
		task.wait(5)
		local now = os.clock()
		for _, session in sessions do
			local due = now - session.lastSaveAt >= Config.AUTOSAVE_INTERVAL
			local requested = session.saveRequested and now - session.lastSaveAt >= Config.MIN_SAVE_INTERVAL
			if due or requested then
				session.saveRequested = false
				task.spawn(saveDisk, session, if requested then "sync" else "autosave")
			end
		end
		workshop:flushDownloads()
	end
end

local function onPlayerRemoving(player: Player)
	leaveDesk(player)
	local session = sessions[player]
	if not session then
		return
	end
	local computer = session.computer
	if computer and computer.state ~= "off" then
		computer:pressPower(os.clock())
	end
	if session.endpoint then
		network:detach(session.endpoint)
	end
	commands:forget(player.UserId)
	saveDisk(session, "leaving")
	sessions[player] = nil
end

-- Plugs the installer flash drive into a desk (for the game's flash drive item).
function ComputerService.insertFlashDrive(desk: Model)
	desk:SetAttribute("FlashDrive", true)
end

-- Pulls the flash drive out of a desk.
function ComputerService.ejectFlashDrive(desk: Model)
	desk:SetAttribute("FlashDrive", false)
end

function ComputerService.start()
	for _, desk in CollectionService:GetTagged(DESK_TAG) do
		setupDesk(desk)
	end
	CollectionService:GetInstanceAddedSignal(DESK_TAG):Connect(setupDesk)
	CollectionService:GetInstanceRemovedSignal(DESK_TAG):Connect(function(desk)
		local player = deskOwner[desk :: Model]
		if player then
			leaveDesk(player)
		end
	end)

	for _, player in Players:GetPlayers() do
		getSession(player)
	end
	Players.PlayerAdded:Connect(getSession)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	RunService.Heartbeat:Connect(step)
	task.spawn(saveLoop)

	game:BindToClose(function()
		for player in sessions do
			task.spawn(onPlayerRemoving, player)
		end
		-- Give saves time to finish (BindToClose allows ~30 seconds).
		local deadline = os.clock() + 25
		while next(sessions) and os.clock() < deadline do
			task.wait(0.5)
		end
		workshop:flushDownloads()
	end)

	if not loadImage(Config.IMAGE) then
		warn(
			"[Linux] Image "
				.. Config.IMAGE
				.. " not found in ServerStorage.LinuxImages; computers have nothing to boot."
		)
	end
end

return ComputerService
