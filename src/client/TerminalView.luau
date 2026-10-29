--!strict
--[[
	Draws a Terminal (ReplicatedStorage.LinuxVM.Terminal.Terminal) into a GUI
	frame: one RichText label per row, colors via <font>/<mark>, and a
	blinking cursor. Works inside a SurfaceGui (desk screens) or a ScreenGui
	(the zoomed 2D view).

		local view = TerminalView.new(parentFrame)
		view:setTerminal(terminal)
		-- each frame:
		view:render()
]]

local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LinuxVM = ReplicatedStorage:WaitForChild("LinuxVM")
local Terminal = require(LinuxVM.Terminal.Terminal)

local FONT = Font.fromEnum(Enum.Font.RobotoMono)
local PADDING = 8

-- 16-color palette (a softened xterm/Tango scheme) + defaults.
local BASE16 = {
	Color3.fromRGB(12, 12, 12),
	Color3.fromRGB(205, 49, 49),
	Color3.fromRGB(13, 188, 121),
	Color3.fromRGB(229, 229, 16),
	Color3.fromRGB(36, 114, 200),
	Color3.fromRGB(188, 63, 188),
	Color3.fromRGB(17, 168, 205),
	Color3.fromRGB(204, 204, 204),
	Color3.fromRGB(102, 102, 102),
	Color3.fromRGB(241, 76, 76),
	Color3.fromRGB(35, 209, 139),
	Color3.fromRGB(245, 245, 67),
	Color3.fromRGB(59, 142, 234),
	Color3.fromRGB(214, 112, 214),
	Color3.fromRGB(41, 184, 219),
	Color3.fromRGB(242, 242, 242),
}
local DEFAULT_FG = Color3.fromRGB(204, 204, 204)
local DEFAULT_BG = Color3.fromRGB(10, 10, 12)
local CURSOR_COLOR = Color3.fromRGB(220, 220, 220)

local hexCache: { [number]: string } = {}

-- Hex string for palette index 0..255, or 256 for the default color.
local function colorHex(index: number, isBackground: boolean): string
	local key = index + (if isBackground then 1000 else 0)
	local cached = hexCache[key]
	if cached then
		return cached
	end
	local c: Color3
	if index == Terminal.DEFAULT_COLOR then
		c = if isBackground then DEFAULT_BG else DEFAULT_FG
	elseif index < 16 then
		c = BASE16[index + 1]
	elseif index < 232 then
		local n = index - 16
		local levels = { 0, 95, 135, 175, 215, 255 }
		c = Color3.fromRGB(levels[n // 36 + 1], levels[(n // 6) % 6 + 1], levels[n % 6 + 1])
	else
		local v = 8 + (index - 232) * 10
		c = Color3.fromRGB(v, v, v)
	end
	local hex = "#" .. c:ToHex()
	hexCache[key] = hex
	return hex
end

local ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }

local function escape(s: string): string
	return (string.gsub(s, "[&<>\"']", ESCAPES))
end

-- Builds the RichText markup for one row.
local function rowMarkup(cells: { string }, attrs: { number }, cols: number): string
	local out = {}
	local c = 1
	while c <= cols do
		local attr = attrs[c]
		local runStart = c
		while c <= cols and attrs[c] == attr do
			c += 1
		end
		local text = table.concat(cells, "", runStart, c - 1)

		local fg = attr % 512
		local bg = (attr // 512) % 512
		local flags = attr // 262144
		if bit32.btest(flags, Terminal.FLAG_BOLD) and fg < 8 then
			fg += 8 -- bold brightens the basic colors, like most terminals
		end
		if bit32.btest(flags, Terminal.FLAG_HIDDEN) then
			text = string.rep(" ", c - runStart)
		end

		local fgHex: string
		local bgHex: string? = nil
		if bit32.btest(flags, Terminal.FLAG_REVERSE) then
			-- Swap colors; the defaults swap too (light background, dark text).
			fgHex = if bg == Terminal.DEFAULT_COLOR then colorHex(Terminal.DEFAULT_COLOR, true) else colorHex(bg, false)
			bgHex = if fg == Terminal.DEFAULT_COLOR then colorHex(Terminal.DEFAULT_COLOR, false) else colorHex(fg, true)
		else
			fgHex = colorHex(fg, false)
			if bg ~= Terminal.DEFAULT_COLOR then
				bgHex = colorHex(bg, true)
			end
		end
		local piece = escape(text)
		if bit32.btest(flags, Terminal.FLAG_BOLD) then
			piece = "<b>" .. piece .. "</b>"
		end
		if bit32.btest(flags, Terminal.FLAG_ITALIC) then
			piece = "<i>" .. piece .. "</i>"
		end
		if bit32.btest(flags, Terminal.FLAG_UNDERLINE) then
			piece = "<u>" .. piece .. "</u>"
		end
		local transparency = if bit32.btest(flags, Terminal.FLAG_DIM) then ' transparency="0.4"' else ""
		piece = '<font color="' .. fgHex .. '"' .. transparency .. ">" .. piece .. "</font>"
		if bgHex then
			piece = '<mark color="' .. bgHex .. '" transparency="0">' .. piece .. "</mark>"
		end
		table.insert(out, piece)
	end
	return table.concat(out)
end

local TerminalView = {}
TerminalView.__index = TerminalView

export type TerminalView = typeof(setmetatable(
	{} :: {
		root: Frame,
		rowsFrame: Frame,
		labels: { TextLabel },
		cursor: Frame,
		overlay: TextLabel,
		terminal: Terminal.Terminal?,
		renderedVersion: number,
		cellWidth: number,
		cellHeight: number,
		textSize: number,
		focused: boolean,
		connections: { RBXScriptConnection },
	},
	TerminalView
))

function TerminalView.new(parent: GuiObject): TerminalView
	local root = Instance.new("Frame")
	root.Name = "TerminalView"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = DEFAULT_BG
	root.BorderSizePixel = 0
	root.ClipsDescendants = true
	root.Parent = parent

	local rowsFrame = Instance.new("Frame")
	rowsFrame.Name = "Rows"
	rowsFrame.BackgroundTransparency = 1
	rowsFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	rowsFrame.Position = UDim2.fromScale(0.5, 0.5)
	rowsFrame.Parent = root

	local cursor = Instance.new("Frame")
	cursor.Name = "Cursor"
	cursor.BackgroundColor3 = CURSOR_COLOR
	cursor.BackgroundTransparency = 0.3
	cursor.BorderSizePixel = 0
	cursor.ZIndex = 3
	cursor.Parent = rowsFrame

	local overlay = Instance.new("TextLabel")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = DEFAULT_BG
	overlay.BackgroundTransparency = 0
	overlay.TextColor3 = DEFAULT_FG
	overlay.FontFace = FONT
	overlay.TextScaled = true
	overlay.RichText = true
	overlay.ZIndex = 10
	overlay.Visible = false
	overlay.Parent = root
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = 48
	constraint.Parent = overlay
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0.1, 0)
	padding.PaddingRight = UDim.new(0.1, 0)
	padding.Parent = overlay

	local self = setmetatable({
		root = root,
		rowsFrame = rowsFrame,
		labels = {},
		cursor = cursor,
		overlay = overlay,
		terminal = nil,
		renderedVersion = -1,
		cellWidth = 0,
		cellHeight = 0,
		textSize = 0,
		focused = false,
		connections = {},
	}, TerminalView)

	table.insert(
		self.connections,
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_layout()
		end)
	)
	table.insert(
		self.connections,
		RunService.RenderStepped:Connect(function()
			-- Blink the cursor twice a second.
			self.cursor.BackgroundTransparency = if self.focused and os.clock() % 1 < 0.5 then 0.2 else 0.65
		end)
	)
	return self
end

function TerminalView._layout(self: TerminalView)
	local term = self.terminal
	if not term then
		return
	end
	local available = self.root.AbsoluteSize
	if available.X < 10 or available.Y < 10 then
		return
	end
	-- Measure the font once at a large size and scale to fit the frame.
	local probe = TextService:GetTextSize(string.rep("M", 20), 100, Enum.Font.RobotoMono, Vector2.new(1e5, 1e5))
	local widthPerSize = probe.X / 20 / 100
	local heightPerSize = 1.12
	local sizeByWidth = (available.X - 2 * PADDING) / (term.cols * widthPerSize)
	local sizeByHeight = (available.Y - 2 * PADDING) / (term.rows * heightPerSize)
	local textSize = math.max(4, math.floor(math.min(sizeByWidth, sizeByHeight)))
	self.textSize = textSize
	self.cellWidth = textSize * widthPerSize
	self.cellHeight = math.floor(textSize * heightPerSize + 0.5)
	self.rowsFrame.Size = UDim2.fromOffset(self.cellWidth * term.cols, self.cellHeight * term.rows)

	for r = 1, term.rows do
		local label = self.labels[r]
		if not label then
			label = Instance.new("TextLabel")
			label.Name = "Row" .. r
			label.BackgroundTransparency = 1
			label.RichText = true
			label.FontFace = FONT
			label.TextColor3 = DEFAULT_FG
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.TextYAlignment = Enum.TextYAlignment.Center
			label.TextWrapped = false
			label.ZIndex = 2
			label.Parent = self.rowsFrame
			self.labels[r] = label
		end
		label.TextSize = textSize
		label.Position = UDim2.fromOffset(0, (r - 1) * self.cellHeight)
		label.Size = UDim2.fromOffset(self.cellWidth * term.cols + 4, self.cellHeight)
	end
	for r = term.rows + 1, #self.labels do
		self.labels[r]:Destroy()
		self.labels[r] = nil
	end
	self.renderedVersion = -1
	for r = 1, term.rows do
		term.dirty[r] = true
	end
end

function TerminalView.setTerminal(self: TerminalView, terminal: Terminal.Terminal?)
	if self.terminal == terminal then
		return
	end
	self.terminal = terminal
	self.renderedVersion = -1
	if terminal then
		self:_layout()
	end
	self.rowsFrame.Visible = terminal ~= nil
end

-- Shows a full-screen message instead of the terminal (nil to hide it).
function TerminalView.setOverlay(self: TerminalView, text: string?)
	self.overlay.Visible = text ~= nil
	if text then
		self.overlay.Text = text
	end
end

function TerminalView.setFocused(self: TerminalView, focused: boolean)
	self.focused = focused
end

function TerminalView.render(self: TerminalView)
	local term = self.terminal
	if not term or term.version == self.renderedVersion or self.cellHeight == 0 then
		return
	end
	self.renderedVersion = term.version
	for _, r in term:takeDirtyRows() do
		local label = self.labels[r]
		if label then
			label.Text = rowMarkup(term.lines[r], term.attrs[r], term.cols)
		end
	end
	local cursor = self.cursor
	cursor.Visible = term.cursorVisible
	cursor.Size = UDim2.fromOffset(math.max(2, self.cellWidth), self.cellHeight)
	cursor.Position = UDim2.fromOffset((term.cursorCol - 1) * self.cellWidth, (term.cursorRow - 1) * self.cellHeight)
end

function TerminalView.destroy(self: TerminalView)
	for _, c in self.connections do
		c:Disconnect()
	end
	self.root:Destroy()
end

return TerminalView
