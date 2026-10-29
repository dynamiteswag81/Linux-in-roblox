--!strict
--[[
	The on-screen keyboard shown while using a computer.

	Roblox keeps some keys for itself (Esc opens the menu, F9 the console...),
	so they are clickable here, along with sticky Ctrl/Alt, common shortcuts,
	and the computer's buttons. On touch devices it also offers a text box to
	type into.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local OnScreenKeyboard = {}
OnScreenKeyboard.__index = OnScreenKeyboard

export type Callbacks = {
	key: (keyName: string) -> (), -- a KeyCode name, e.g. "Escape", "Up", "F5"
	text: (text: string) -> (), -- literal text (touch typing box)
	action: (action: string) -> (), -- "leave" | "power" | "reset" | "zoom" | "workshop"
}

export type OnScreenKeyboard = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		callbacks: Callbacks,
		latched: { ctrl: boolean, alt: boolean },
		latchButtons: { [string]: TextButton },
		showFKeys: boolean,
		fRow: Frame,
		status: TextLabel,
	},
	OnScreenKeyboard
))

local BAR_COLOR = Color3.fromRGB(24, 24, 28)
local KEY_COLOR = Color3.fromRGB(52, 52, 60)
local KEY_ACTIVE = Color3.fromRGB(70, 130, 220)
local TEXT_COLOR = Color3.fromRGB(235, 235, 235)

local function makeButton(parent: Instance, text: string, width: number, order: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = text
	b.Text = text
	b.AutoButtonColor = true
	b.BackgroundColor3 = KEY_COLOR
	b.TextColor3 = TEXT_COLOR
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 14
	b.Size = UDim2.fromOffset(width, 30)
	b.LayoutOrder = order
	b.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = b
	return b
end

local function makeRow(parent: Instance, name: string, order: number): Frame
	local row = Instance.new("Frame")
	row.Name = name
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 30)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.LayoutOrder = order
	row.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Wraps = true -- small (phone) screens get extra lines
	layout.Parent = row
	return row
end

function OnScreenKeyboard.new(callbacks: Callbacks): OnScreenKeyboard
	local gui = Instance.new("ScreenGui")
	gui.Name = "LinuxKeyboard"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 20
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -8)
	bar.Size = UDim2.new(1, -16, 0, 0)
	bar.AutomaticSize = Enum.AutomaticSize.Y
	bar.BackgroundColor3 = BAR_COLOR
	bar.BackgroundTransparency = 0.15
	bar.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = bar
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = bar
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(860, math.huge)
	sizeLimit.Parent = bar
	local column = Instance.new("UIListLayout")
	column.FillDirection = Enum.FillDirection.Vertical
	column.Padding = UDim.new(0, 4)
	column.SortOrder = Enum.SortOrder.LayoutOrder
	column.Parent = bar

	local self = setmetatable({
		gui = gui,
		callbacks = callbacks,
		latched = { ctrl = false, alt = false },
		latchButtons = {},
		showFKeys = false,
		fRow = (nil :: any) :: Frame,
		status = (nil :: any) :: TextLabel,
	}, OnScreenKeyboard)

	-- Row 1: computer controls and status.
	local controls = makeRow(bar, "Controls", 1)
	local order = 0
	local function control(label: string, action: string, width: number?)
		order += 1
		local b = makeButton(controls, label, width or 80, order)
		b.Activated:Connect(function()
			callbacks.action(action)
		end)
		return b
	end
	control("⏏ Leave", "leave", 90).BackgroundColor3 = Color3.fromRGB(140, 50, 50)
	control("⏻ Power", "power")
	control("↻ Reset", "reset")
	control("🔍 Zoom", "zoom")
	control("📦 Workshop", "workshop", 110)
	order += 1
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.TextColor3 = Color3.fromRGB(170, 170, 180)
	status.Font = Enum.Font.Gotham
	status.TextSize = 13
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Size = UDim2.fromOffset(330, 30)
	status.LayoutOrder = order
	status.Text = "Your keyboard types into the computer."
	status.Parent = controls
	self.status = status

	-- Row 2: keys Roblox reserves, modifiers, navigation.
	local keys = makeRow(bar, "Keys", 2)
	order = 0
	local function keyIn(row: Frame, label: string, keyName: string, width: number?)
		order += 1
		local b = makeButton(row, label, width or 42, order)
		b.Activated:Connect(function()
			callbacks.key(keyName)
		end)
		return b
	end
	local function key(label: string, keyName: string, width: number?)
		return keyIn(keys, label, keyName, width)
	end
	local function latch(label: string, which: "ctrl" | "alt")
		order += 1
		local b = makeButton(keys, label, 52, order)
		self.latchButtons[which] = b
		b.Activated:Connect(function()
			self.latched[which] = not self.latched[which]
			self:_refreshLatches()
		end)
	end
	key("Esc", "Escape", 48)
	key("Tab", "Tab", 48)
	latch("Ctrl", "ctrl")
	latch("Alt", "alt")
	key("^C", "Ctrl+C")
	key("^D", "Ctrl+D")
	key("^Z", "Ctrl+Z")
	key("^L", "Ctrl+L")
	key("←", "Left", 34)
	key("↑", "Up", 34)
	key("↓", "Down", 34)
	key("→", "Right", 34)
	key("Home", "Home", 50)
	key("End", "End", 44)
	key("PgUp", "PageUp", 50)
	key("PgDn", "PageDown", 50)
	key("Del", "Delete", 42)
	order += 1
	local fToggle = makeButton(keys, "F1-12", 52, order)

	-- Row 3: function keys (hidden until asked for).
	local fRow = makeRow(bar, "FunctionKeys", 3)
	fRow.Visible = false
	self.fRow = fRow
	order = 0
	for i = 1, 12 do
		keyIn(fRow, "F" .. i, "F" .. i, 48)
	end
	fToggle.Activated:Connect(function()
		self.showFKeys = not self.showFKeys
		fRow.Visible = self.showFKeys
	end)

	-- Row 4 (touch devices): a box to type into.
	if UserInputService.TouchEnabled then
		local typeRow = makeRow(bar, "Typing", 4)
		local box = Instance.new("TextBox")
		box.Name = "TypeHere"
		box.PlaceholderText = "Tap here to type. Enter sends a newline."
		box.Text = ""
		box.ClearTextOnFocus = false
		box.BackgroundColor3 = KEY_COLOR
		box.TextColor3 = TEXT_COLOR
		box.Font = Enum.Font.RobotoMono
		box.TextSize = 16
		box.Size = UDim2.fromOffset(600, 30)
		box.Parent = typeRow
		local suppress = false
		box:GetPropertyChangedSignal("Text"):Connect(function()
			if suppress or box.Text == "" then
				return
			end
			local typed = box.Text
			suppress = true
			box.Text = ""
			suppress = false
			callbacks.text(typed)
		end)
		box.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				callbacks.key("Return")
				task.defer(function()
					box:CaptureFocus()
				end)
			end
		end)
		local bs = makeButton(typeRow, "⌫", 48, 2)
		bs.Activated:Connect(function()
			callbacks.key("Backspace")
		end)
		local enter = makeButton(typeRow, "Enter", 60, 3)
		enter.Activated:Connect(function()
			callbacks.key("Return")
		end)
	end

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return self
end

function OnScreenKeyboard._refreshLatches(self: OnScreenKeyboard)
	for which, b in self.latchButtons do
		b.BackgroundColor3 = if (self.latched :: any)[which] then KEY_ACTIVE else KEY_COLOR
	end
end

-- Returns and clears the sticky modifiers (they apply to the next key only).
function OnScreenKeyboard.consumeLatches(self: OnScreenKeyboard): (boolean, boolean)
	local ctrl, alt = self.latched.ctrl, self.latched.alt
	if ctrl or alt then
		self.latched.ctrl = false
		self.latched.alt = false
		self:_refreshLatches()
	end
	return ctrl, alt
end

function OnScreenKeyboard.setStatus(self: OnScreenKeyboard, text: string)
	self.status.Text = text
end

function OnScreenKeyboard.destroy(self: OnScreenKeyboard)
	self.gui:Destroy()
end

return OnScreenKeyboard
