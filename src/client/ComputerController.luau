--!strict
--[[
	Client side of the computers:

	- Puts a screen (SurfaceGui + TerminalView) on every desk tagged "LinuxComputer".
	- Keeps a Terminal per computer this player can see, fed by the server's
	  TerminalOutput stream (raw bytes or snapshots).
	- "Focus mode" while using a desk: the camera looks at the screen, the real
	  keyboard types into the computer (movement keys are captured), and the
	  on-screen keyboard offers the keys Roblox reserves (Esc, F-keys...).
	- Parts named Key_<KeyCode> inside a desk (e.g. Key_Escape, Key_A) are
	  clickable keys on a physical keyboard model.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LinuxVM = ReplicatedStorage:WaitForChild("LinuxVM")
local Config = require(LinuxVM.Config)
local KeyMap = require(LinuxVM.Terminal.KeyMap)
local Remotes = require(LinuxVM.Remotes)
local Terminal = require(LinuxVM.Terminal.Terminal)

local OnScreenKeyboard = require(script.Parent.OnScreenKeyboard)
local TerminalView = require(script.Parent.TerminalView)

local DESK_TAG = "LinuxComputer"
local ACTION_NAME = "LinuxComputerKeyboard"
local REPEAT_DELAY = 0.45
local REPEAT_INTERVAL = 0.035

local player = Players.LocalPlayer
local terminalOutput = Remotes.event("TerminalOutput")
local terminalInput = Remotes.event("TerminalInput")
local computerAction = Remotes.event("ComputerAction")
local notify = Remotes.event("Notify")

local ComputerController = {}

type DeskView = {
	desk: Model,
	gui: SurfaceGui,
	view: TerminalView.TerminalView,
}

type Focus = {
	desk: Model,
	computerId: string,
	keyboard: OnScreenKeyboard.OnScreenKeyboard,
	zoomGui: ScreenGui?,
	zoomView: TerminalView.TerminalView?,
	savedCameraType: Enum.CameraType,
	savedCameraCFrame: CFrame,
	savedChatEnabled: boolean?,
	connections: { RBXScriptConnection },
}

local terminals: { [string]: Terminal.Terminal } = {}
local states: { [string]: string } = {}
local deskViews: { [Model]: DeskView } = {}
local focus: Focus? = nil
local pendingInput = ""
local capsLock = false
local held: { keyName: string, nextAt: number }? = nil

-- Called by the Workshop GUI so the toolbar button can open it.
ComputerController.openWorkshop = nil :: (() -> ())?

local function getTerminal(id: string): Terminal.Terminal
	local term = terminals[id]
	if not term then
		term = Terminal.new(Config.COLS, Config.ROWS)
		terminals[id] = term
	end
	return term
end

---------------------------------------------------------------------------
-- Desk screens
---------------------------------------------------------------------------

local function screenFace(desk: Model): Enum.NormalId
	local face = desk:GetAttribute("ScreenFace")
	if type(face) == "string" then
		local ok, value = pcall(function()
			return (Enum.NormalId :: any)[face]
		end)
		if ok and value then
			return value
		end
	end
	return Enum.NormalId.Front
end

local function findScreen(desk: Model): BasePart?
	local screen = desk:FindFirstChild("Screen", true)
	if screen and screen:IsA("BasePart") then
		return screen
	end
	return desk.PrimaryPart
end

-- Width and height (studs) of a part's face.
local function faceSize(part: BasePart, face: Enum.NormalId): Vector2
	local s = part.Size
	if face == Enum.NormalId.Front or face == Enum.NormalId.Back then
		return Vector2.new(s.X, s.Y)
	elseif face == Enum.NormalId.Left or face == Enum.NormalId.Right then
		return Vector2.new(s.Z, s.Y)
	end
	return Vector2.new(s.X, s.Z)
end

local function addDesk(instance: Instance)
	if not instance:IsA("Model") or deskViews[instance] then
		return
	end
	local desk = instance :: Model
	local screen = findScreen(desk)
	if not screen then
		return
	end
	local face = screenFace(desk)
	local size = faceSize(screen, face)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "LinuxScreen"
	gui.Adornee = screen
	gui.Face = face
	gui.LightInfluence = 0
	gui.Brightness = 1.4
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(1200, math.floor(1200 * size.Y / math.max(size.X, 0.01)))
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Parent = gui

	deskViews[desk] = { desk = desk, gui = gui, view = TerminalView.new(frame) }
end

local function removeDesk(instance: Instance)
	local dv = deskViews[instance :: Model]
	if dv then
		dv.view:destroy()
		dv.gui:Destroy()
		deskViews[instance :: Model] = nil
	end
end

local OFF_TEXT = "<b>" .. Config.OS_NAME .. "</b>\n\n<font transparency=\"0.4\">Press E to use this computer</font>"

-- Decides what each desk screen shows: your terminal, someone else's (if
-- screens are shared), "in use", or the idle screen.
local function updateDesk(dv: DeskView)
	local desk = dv.desk
	local id = desk:GetAttribute("ComputerId")
	local userName = desk:GetAttribute("UserName")
	local view = dv.view
	if type(id) == "string" and id ~= "" and terminals[id] then
		local state = states[id] or desk:GetAttribute("ComputerState")
		if state == "off" then
			view:setTerminal(nil)
			view:setOverlay("Power is off.\n\n<font transparency=\"0.4\">Click ⏻ Power to turn the computer on.</font>")
		else
			view:setOverlay(nil)
			view:setTerminal(terminals[id])
			view:render()
		end
	elseif type(id) == "string" and id ~= "" then
		view:setTerminal(nil)
		view:setOverlay("In use by " .. tostring(userName))
	else
		view:setTerminal(nil)
		view:setOverlay(OFF_TEXT)
	end
	view:setFocused(focus ~= nil and focus.desk == desk)
end

---------------------------------------------------------------------------
-- Keyboard input
---------------------------------------------------------------------------

local function send(bytes: string)
	pendingInput ..= bytes
end

local function flushInput()
	while #pendingInput > 0 do
		local piece = string.sub(pendingInput, 1, Config.MAX_INPUT_BYTES)
		pendingInput = string.sub(pendingInput, Config.MAX_INPUT_BYTES + 1)
		terminalInput:FireServer(piece)
	end
end

local function currentModes(): KeyMap.Modes
	local f = focus
	local term = f and terminals[f.computerId]
	if term then
		return { applicationCursor = term.applicationCursor, applicationKeypad = term.applicationKeypad }
	end
	return {}
end

-- Sends a key by KeyCode name, applying held and on-screen (latched) modifiers.
local function pressKey(keyName: string, extraCtrl: boolean?)
	local f = focus
	if not f then
		return
	end
	local latchedCtrl, latchedAlt = f.keyboard:consumeLatches()
	local mods: KeyMap.Modifiers = {
		shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift),
		ctrl = extraCtrl
			or latchedCtrl
			or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightControl),
		alt = latchedAlt or UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(
			Enum.KeyCode.RightAlt
		),
		capsLock = capsLock,
	}
	local bytes = KeyMap.encode(keyName, mods, currentModes())
	if bytes then
		send(bytes)
	end
end

local MODIFIERS = {
	LeftShift = true,
	RightShift = true,
	LeftControl = true,
	RightControl = true,
	LeftAlt = true,
	RightAlt = true,
	LeftSuper = true,
	RightSuper = true,
	LeftMeta = true,
	RightMeta = true,
	CapsLock = true,
}

local function onKeyAction(_: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return Enum.ContextActionResult.Pass
	end
	local name = input.KeyCode.Name
	if state == Enum.UserInputState.Begin then
		if name == "CapsLock" then
			capsLock = not capsLock
		elseif not MODIFIERS[name] then
			pressKey(name)
			held = { keyName = name, nextAt = os.clock() + REPEAT_DELAY }
		end
	elseif state == Enum.UserInputState.End then
		if held and held.keyName == name then
			held = nil
		end
	end
	return Enum.ContextActionResult.Sink
end

local KEYBOARD_KEYS: { Enum.KeyCode } = {}
for _, kc in Enum.KeyCode:GetEnumItems() do
	-- Keyboard keys only (gamepad buttons start at 1000).
	if kc.Value > 0 and kc.Value < 1000 then
		table.insert(KEYBOARD_KEYS, kc)
	end
end

---------------------------------------------------------------------------
-- Focus mode
---------------------------------------------------------------------------

local function cameraFor(desk: Model): CFrame?
	local screen = findScreen(desk)
	if not screen then
		return nil
	end
	local face = screenFace(desk)
	local normal = screen.CFrame:VectorToWorldSpace(Vector3.FromNormalId(face))
	local size = faceSize(screen, face)
	local depth = if face == Enum.NormalId.Front or face == Enum.NormalId.Back
		then screen.Size.Z
		elseif face == Enum.NormalId.Left or face == Enum.NormalId.Right then screen.Size.X
		else screen.Size.Y
	local center = screen.Position + normal * (depth / 2)
	local camera = workspace.CurrentCamera
	local fov = math.rad(camera.FieldOfView)
	local viewport = camera.ViewportSize
	local aspect = viewport.X / math.max(viewport.Y, 1)
	-- Fit the screen with some margin, leaving room for the keyboard bar.
	local distH = (size.Y * 0.5 * 1.35) / math.tan(fov / 2)
	local distW = (size.X * 0.5 * 1.1) / (math.tan(fov / 2) * aspect)
	local distance = math.max(distH, distW, 1)
	local up = if math.abs(normal.Y) > 0.9 then screen.CFrame.LookVector else Vector3.yAxis
	return CFrame.lookAt(center + normal * distance, center, up)
end

local function setZoom(enabled: boolean)
	local f = focus
	if not f then
		return
	end
	if enabled and not f.zoomGui then
		local gui = Instance.new("ScreenGui")
		gui.Name = "LinuxZoom"
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 15
		gui.IgnoreGuiInset = true
		local frame = Instance.new("Frame")
		frame.AnchorPoint = Vector2.new(0.5, 0)
		frame.Position = UDim2.new(0.5, 0, 0, 40)
		frame.Size = UDim2.new(0.96, 0, 1, -170)
		frame.BackgroundTransparency = 1
		frame.Parent = gui
		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 1.75
		aspect.Parent = frame
		gui.Parent = player:WaitForChild("PlayerGui")
		local view = TerminalView.new(frame)
		view:setTerminal(terminals[f.computerId])
		view:setFocused(true)
		f.zoomGui = gui
		f.zoomView = view
	elseif not enabled and f.zoomGui then
		if f.zoomView then
			f.zoomView:destroy()
		end
		f.zoomGui:Destroy()
		f.zoomGui = nil
		f.zoomView = nil
	end
end

local function exitFocus(tellServer: boolean)
	local f = focus
	if not f then
		return
	end
	focus = nil
	held = nil
	flushInput()
	ContextActionService:UnbindAction(ACTION_NAME)
	for _, c in f.connections do
		c:Disconnect()
	end
	setZoom(false)
	f.keyboard:destroy()
	local camera = workspace.CurrentCamera
	camera.CameraType = f.savedCameraType
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
	end)
	if f.savedChatEnabled ~= nil then
		pcall(function()
			(TextChatService :: any).ChatInputBarConfiguration.Enabled = f.savedChatEnabled
		end)
	end
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Sit then
		humanoid.Jump = true
	end
	if tellServer then
		computerAction:FireServer("leave")
	end
end

local function enterFocus(desk: Model, computerId: string)
	exitFocus(false)
	getTerminal(computerId)
	local camera = workspace.CurrentCamera

	local keyboard = OnScreenKeyboard.new({
		key = function(keyName: string)
			local ctrlKey = string.match(keyName, "^Ctrl%+(.+)$")
			if ctrlKey then
				pressKey(ctrlKey, true)
			else
				pressKey(keyName)
			end
		end,
		text = function(text: string)
			send(text)
		end,
		action = function(action: string)
			if action == "leave" then
				exitFocus(true)
			elseif action == "zoom" then
				setZoom(focus ~= nil and focus.zoomGui == nil)
			elseif action == "workshop" then
				local open = ComputerController.openWorkshop
				if open then
					open()
				end
			else
				computerAction:FireServer(action)
			end
		end,
	})

	local f: Focus = {
		desk = desk,
		computerId = computerId,
		keyboard = keyboard,
		zoomGui = nil,
		zoomView = nil,
		savedCameraType = camera.CameraType,
		savedCameraCFrame = camera.CFrame,
		savedChatEnabled = nil,
		connections = {},
	}
	focus = f

	-- Point the camera at the screen.
	local target = cameraFor(desk)
	if target then
		camera.CameraType = Enum.CameraType.Scriptable
		TweenService:Create(camera, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = target,
		}):Play()
	end

	-- Keys that would otherwise open the player list or the chat box.
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)
	pcall(function()
		local bar = (TextChatService :: any).ChatInputBarConfiguration
		f.savedChatEnabled = bar.Enabled
		bar.Enabled = false
	end)

	ContextActionService:BindActionAtPriority(
		ACTION_NAME,
		onKeyAction,
		false,
		Enum.ContextActionPriority.High.Value + 100,
		table.unpack(KEYBOARD_KEYS)
	)

	-- Leave if the character dies or is removed.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(
			f.connections,
			humanoid.Died:Connect(function()
				exitFocus(true)
			end)
		)
	end
	table.insert(
		f.connections,
		player.CharacterRemoving:Connect(function()
			exitFocus(true)
		end)
	)
	keyboard:setStatus("Typing goes to the computer. Esc and F-keys are on this bar.")
end

-- Clickable keys on a physical keyboard model: parts named Key_<KeyCode name>.
local function hookPhysicalKeys(desk: Model)
	for _, part in desk:GetDescendants() do
		local keyName = string.match(part.Name, "^Key_(.+)$")
		if keyName and part:IsA("BasePart") then
			local detector = part:FindFirstChildOfClass("ClickDetector")
			if detector then
				detector.MouseClick:Connect(function()
					local f = focus
					if f and f.desk == desk then
						if keyName == "Ctrl" or keyName == "LeftControl" then
							f.keyboard.latched.ctrl = not f.keyboard.latched.ctrl
							f.keyboard:_refreshLatches()
						elseif keyName == "Alt" or keyName == "LeftAlt" then
							f.keyboard.latched.alt = not f.keyboard.latched.alt
							f.keyboard:_refreshLatches()
						else
							pressKey(keyName)
						end
						-- A little press animation.
						local original = part.CFrame
						part.CFrame = original * CFrame.new(0, -0.03, 0)
						task.delay(0.08, function()
							part.CFrame = original
						end)
					end
				end)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------

function ComputerController.start()
	terminalOutput.OnClientEvent:Connect(function(computerId: string, kind: string, payload: any)
		local term = getTerminal(computerId)
		if kind == "data" then
			term:write(payload)
		elseif kind == "snapshot" then
			term:loadSnapshot(payload)
		elseif kind == "state" then
			states[computerId] = payload
		end
	end)

	computerAction.OnClientEvent:Connect(function(event: string, desk: Model?, computerId: string?)
		if event == "using" and desk and computerId then
			enterFocus(desk, computerId)
		elseif event == "left" then
			exitFocus(false)
		end
	end)

	notify.OnClientEvent:Connect(function(message: string)
		pcall(function()
			StarterGui:SetCore("SendNotification", {
				Title = Config.OS_NAME,
				Text = message,
				Duration = 5,
			})
		end)
	end)

	for _, desk in CollectionService:GetTagged(DESK_TAG) do
		addDesk(desk)
		hookPhysicalKeys(desk :: Model)
	end
	CollectionService:GetInstanceAddedSignal(DESK_TAG):Connect(function(desk)
		addDesk(desk)
		if desk:IsA("Model") then
			hookPhysicalKeys(desk)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(DESK_TAG):Connect(removeDesk)

	RunService.RenderStepped:Connect(function()
		for _, dv in deskViews do
			updateDesk(dv)
		end
		local f = focus
		if f and f.zoomView then
			f.zoomView:setTerminal(terminals[f.computerId])
			f.zoomView:render()
		end
	end)

	RunService.Heartbeat:Connect(function()
		local h = held
		if h and focus then
			local now = os.clock()
			if now >= h.nextAt then
				local keyCode = (Enum.KeyCode :: any)[h.keyName]
				if keyCode and UserInputService:IsKeyDown(keyCode) then
					pressKey(h.keyName)
					h.nextAt = now + REPEAT_INTERVAL
				else
					held = nil
				end
			end
		end
		flushInput()
	end)
end

return ComputerController
