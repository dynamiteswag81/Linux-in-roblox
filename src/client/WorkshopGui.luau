--!strict
--[[
	The Community Workshop browser: search packages other players published,
	read their details, and send "brick install <name>" to your computer.

	Opens from the 📦 button (top left), the on-screen keyboard while using a
	computer, or any part tagged "WorkshopKiosk" (a ProximityPrompt is added).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LinuxVM = ReplicatedStorage:WaitForChild("LinuxVM")
local Config = require(LinuxVM.Config)
local Remotes = require(LinuxVM.Remotes)

local KIOSK_TAG = "WorkshopKiosk"

local BG = Color3.fromRGB(22, 23, 28)
local PANEL = Color3.fromRGB(32, 34, 41)
local CARD = Color3.fromRGB(42, 44, 53)
local CARD_SELECTED = Color3.fromRGB(55, 80, 130)
local ACCENT = Color3.fromRGB(80, 140, 240)
local TEXT = Color3.fromRGB(235, 236, 240)
local MUTED = Color3.fromRGB(160, 163, 175)

local player = Players.LocalPlayer
local workshopRemote = Remotes.func("Workshop")

local WorkshopGui = {}

type Result = {
	name: string,
	version: string,
	description: string,
	author: string,
	downloads: number,
	updated: number,
	size: number,
	official: boolean,
}

local function corner(parent: Instance, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = parent
end

local function label(parent: Instance, text: string, size: number, color: Color3?, font: Enum.Font?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color or TEXT
	l.Font = font or Enum.Font.Gotham
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.Size = UDim2.new(1, 0, 0, size + 4)
	l.Parent = parent
	return l
end

local function formatSize(bytes: number): string
	if bytes >= 1048576 then
		return string.format("%.1f MB", bytes / 1048576)
	elseif bytes >= 1024 then
		return string.format("%.1f KB", bytes / 1024)
	end
	return bytes .. " B"
end

function WorkshopGui.start(): () -> ()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Workshop"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 30
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Toggle button
	local toggle = Instance.new("TextButton")
	toggle.Name = "WorkshopButton"
	toggle.Text = "📦 Workshop"
	toggle.Font = Enum.Font.GothamBold
	toggle.TextSize = 15
	toggle.TextColor3 = TEXT
	toggle.BackgroundColor3 = PANEL
	toggle.BackgroundTransparency = 0.1
	toggle.Size = UDim2.fromOffset(120, 34)
	toggle.Position = UDim2.fromOffset(12, 12)
	toggle.Parent = gui
	corner(toggle, 8)

	-- Window
	local window = Instance.new("Frame")
	window.Name = "Window"
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = UDim2.new(0.9, 0, 0.8, 0)
	window.BackgroundColor3 = BG
	window.Visible = false
	window.Parent = gui
	corner(window, 10)
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(980, 620)
	maxSize.Parent = window
	local windowPad = Instance.new("UIPadding")
	for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		(windowPad :: any)[side] = UDim.new(0, 14)
	end
	windowPad.Parent = window

	local title = label(window, "Community Workshop", 22, TEXT, Enum.Font.GothamBold)
	title.Size = UDim2.new(1, -40, 0, 28)

	local close = Instance.new("TextButton")
	close.Text = "✕"
	close.Font = Enum.Font.GothamBold
	close.TextSize = 18
	close.TextColor3 = TEXT
	close.BackgroundColor3 = CARD
	close.Size = UDim2.fromOffset(30, 30)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, 0, 0, 0)
	close.Parent = window
	corner(close)

	-- Search row
	local search = Instance.new("TextBox")
	search.Name = "Search"
	search.PlaceholderText = "Search packages..."
	search.Text = ""
	search.ClearTextOnFocus = false
	search.Font = Enum.Font.Gotham
	search.TextSize = 16
	search.TextColor3 = TEXT
	search.PlaceholderColor3 = MUTED
	search.TextXAlignment = Enum.TextXAlignment.Left
	search.BackgroundColor3 = PANEL
	search.Position = UDim2.fromOffset(0, 40)
	search.Size = UDim2.new(0.5, -10, 0, 34)
	search.Parent = window
	corner(search)
	local searchPad = Instance.new("UIPadding")
	searchPad.PaddingLeft = UDim.new(0, 10)
	searchPad.Parent = search

	local sortButtons: { [string]: TextButton } = {}
	local currentSort = "popular"
	for i, entry in { { "popular", "Popular" }, { "new", "New" }, { "name", "A–Z" } } do
		local b = Instance.new("TextButton")
		b.Text = entry[2]
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 14
		b.TextColor3 = TEXT
		b.BackgroundColor3 = CARD
		b.Size = UDim2.fromOffset(80, 34)
		b.Position = UDim2.new(0.5, (i - 1) * 86, 0, 40)
		b.Parent = window
		corner(b)
		sortButtons[entry[1]] = b
	end

	-- Results list (left)
	local list = Instance.new("ScrollingFrame")
	list.Name = "Results"
	list.Position = UDim2.fromOffset(0, 84)
	list.Size = UDim2.new(0.42, -6, 1, -114)
	list.BackgroundColor3 = PANEL
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = window
	corner(list)
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 6)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list
	local listPad = Instance.new("UIPadding")
	listPad.PaddingTop = UDim.new(0, 6)
	listPad.PaddingLeft = UDim.new(0, 6)
	listPad.PaddingRight = UDim.new(0, 10)
	listPad.PaddingBottom = UDim.new(0, 6)
	listPad.Parent = list

	-- Details (right)
	local details = Instance.new("ScrollingFrame")
	details.Name = "Details"
	details.Position = UDim2.new(0.42, 6, 0, 84)
	details.Size = UDim2.new(0.58, -6, 1, -114)
	details.BackgroundColor3 = PANEL
	details.BorderSizePixel = 0
	details.ScrollBarThickness = 6
	details.AutomaticCanvasSize = Enum.AutomaticSize.Y
	details.CanvasSize = UDim2.new()
	details.Parent = window
	corner(details)
	local detailsLayout = Instance.new("UIListLayout")
	detailsLayout.Padding = UDim.new(0, 8)
	detailsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	detailsLayout.Parent = details
	local detailsPad = Instance.new("UIPadding")
	for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		(detailsPad :: any)[side] = UDim.new(0, 12)
	end
	detailsPad.Parent = details

	local footer = label(
		window,
		"Share your own: on your computer run  brick new mytool  then  brick publish mytool",
		13,
		MUTED
	)
	footer.Position = UDim2.new(0, 0, 1, -20)
	footer.Size = UDim2.new(1, 0, 0, 18)

	local selected: string? = nil
	local searchToken = 0

	local function clear(frame: Instance)
		for _, child in frame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	local function showMessage(frame: Instance, text: string)
		clear(frame)
		label(frame, text, 15, MUTED)
	end

	local function showDetails(name: string)
		selected = name
		showMessage(details, "Loading " .. name .. "...")
		local ok, d = pcall(function()
			return workshopRemote:InvokeServer("details", name)
		end)
		if selected ~= name then
			return
		end
		clear(details)
		if not ok or not d then
			label(details, "Couldn't load " .. name .. ".", 15, MUTED)
			return
		end
		local header = label(details, d.name .. "  " .. d.version, 22, TEXT, Enum.Font.GothamBold)
		header.LayoutOrder = 1
		local by = if d.official then "Official " .. Config.OS_NAME .. " package" else "by " .. d.authorName
		local meta = label(
			details,
			string.format("%s  •  %d downloads  •  %s", by, d.downloads or 0, formatSize(d.size or 0)),
			13,
			MUTED
		)
		meta.LayoutOrder = 2
		local desc = label(details, d.description ~= "" and d.description or "(no description)", 16)
		desc.AutomaticSize = Enum.AutomaticSize.Y
		desc.LayoutOrder = 3

		local install = Instance.new("TextButton")
		install.Text = "Install on my computer"
		install.Font = Enum.Font.GothamBold
		install.TextSize = 16
		install.TextColor3 = TEXT
		install.BackgroundColor3 = ACCENT
		install.Size = UDim2.fromOffset(240, 38)
		install.LayoutOrder = 4
		install.Parent = details
		corner(install)
		local result = label(details, "Or type on your computer:  brick install " .. d.name, 13, MUTED)
		result.AutomaticSize = Enum.AutomaticSize.Y
		result.LayoutOrder = 5
		install.Activated:Connect(function()
			local okInstall, message = pcall(function()
				return workshopRemote:InvokeServer("install", d.name)
			end)
			result.Text = if okInstall and message then message else "Couldn't reach your computer."
		end)

		if d.depends and #d.depends > 0 then
			local deps = label(details, "Needs: " .. table.concat(d.depends, ", "), 14, MUTED)
			deps.LayoutOrder = 6
		end
		if d.readme and d.readme ~= "" then
			local readmeTitle = label(details, "README", 14, MUTED, Enum.Font.GothamBold)
			readmeTitle.LayoutOrder = 7
			local readme = label(details, d.readme, 15, TEXT, Enum.Font.RobotoMono)
			readme.AutomaticSize = Enum.AutomaticSize.Y
			readme.LayoutOrder = 8
		end
		if d.files and #d.files > 0 then
			local filesTitle = label(details, "Files", 14, MUTED, Enum.Font.GothamBold)
			filesTitle.LayoutOrder = 9
			local files = label(details, table.concat(d.files, "\n"), 14, TEXT, Enum.Font.RobotoMono)
			files.AutomaticSize = Enum.AutomaticSize.Y
			files.LayoutOrder = 10
		end
	end

	local function refresh()
		searchToken += 1
		local token = searchToken
		for sort, b in sortButtons do
			b.BackgroundColor3 = if sort == currentSort then ACCENT else CARD
		end
		showMessage(list, "Searching...")
		local ok, results = pcall(function()
			return workshopRemote:InvokeServer("search", search.Text, currentSort)
		end)
		if token ~= searchToken then
			return
		end
		clear(list)
		if not ok or type(results) ~= "table" or #results == 0 then
			label(list, if ok then "No packages found." else "The Workshop is unavailable right now.", 15, MUTED)
			return
		end
		for i, r: Result in results do
			local card = Instance.new("TextButton")
			card.Name = r.name
			card.Text = ""
			card.AutoButtonColor = true
			card.BackgroundColor3 = if r.name == selected then CARD_SELECTED else CARD
			card.Size = UDim2.new(1, 0, 0, 64)
			card.LayoutOrder = i
			card.Parent = list
			corner(card)
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 10)
			pad.PaddingTop = UDim.new(0, 6)
			pad.PaddingRight = UDim.new(0, 8)
			pad.Parent = card
			local name = label(card, r.name .. "  " .. r.version, 16, TEXT, Enum.Font.GothamBold)
			name.Size = UDim2.new(1, 0, 0, 20)
			local by = if r.official then "official" else "by " .. r.author .. "  •  " .. r.downloads .. " downloads"
			local meta = label(card, by, 12, if r.official then ACCENT else MUTED)
			meta.Position = UDim2.fromOffset(0, 20)
			meta.Size = UDim2.new(1, 0, 0, 16)
			local desc = label(card, r.description, 13, MUTED)
			desc.Position = UDim2.fromOffset(0, 37)
			desc.Size = UDim2.new(1, 0, 0, 18)
			desc.TextTruncate = Enum.TextTruncate.AtEnd
			desc.TextWrapped = false
			card.Activated:Connect(function()
				for _, other in list:GetChildren() do
					if other:IsA("TextButton") then
						other.BackgroundColor3 = CARD
					end
				end
				card.BackgroundColor3 = CARD_SELECTED
				showDetails(r.name)
			end)
		end
	end

	local function setOpen(open: boolean)
		window.Visible = open
		if open then
			task.spawn(refresh)
			if not selected then
				showMessage(details, "Pick a package to see what it does.")
			end
		end
	end

	toggle.Activated:Connect(function()
		setOpen(not window.Visible)
	end)
	close.Activated:Connect(function()
		setOpen(false)
	end)
	for sort, b in sortButtons do
		b.Activated:Connect(function()
			currentSort = sort
			task.spawn(refresh)
		end)
	end
	local typingToken = 0
	search:GetPropertyChangedSignal("Text"):Connect(function()
		typingToken += 1
		local token = typingToken
		task.delay(0.35, function()
			if token == typingToken and window.Visible then
				refresh()
			end
		end)
	end)

	-- Workshop kiosks in the world.
	local function addKiosk(part: Instance)
		if not part:IsA("BasePart") and not part:IsA("Model") then
			return
		end
		local target = if part:IsA("Model") then (part.PrimaryPart or part:FindFirstChildWhichIsA("BasePart", true)) else part
		if not target then
			return
		end
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Browse"
		prompt.ObjectText = "Community Workshop"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.RequiresLineOfSight = false
		prompt.Parent = target
		prompt.Triggered:Connect(function()
			setOpen(true)
		end)
	end
	for _, kiosk in CollectionService:GetTagged(KIOSK_TAG) do
		addKiosk(kiosk)
	end
	CollectionService:GetInstanceAddedSignal(KIOSK_TAG):Connect(addKiosk)

	return function()
		setOpen(true)
	end
end

return WorkshopGui
