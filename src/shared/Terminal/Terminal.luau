--!strict
--[[
	VT100 / xterm-subset terminal emulator.

	Feed it the bytes a program writes (`terminal:write(data)`) and it maintains
	a grid of cells with characters and attributes, a cursor, scroll regions,
	the alternate screen, and the replies programs expect (cursor position
	reports, device attributes). Covers what busybox's shell line editing, vi,
	less, top and friends use, plus colors from `ls --color`.

	Rendering is someone else's job: read `terminal.lines[row]`/`attrs[row]`
	and the `dirty` flags (see TerminalView on the client, or `toText()`).

	Cell attributes are packed into one number:
		fg (0..255, 256 = default) + bg * 512 + flags * 262144
	where flags: 1 bold, 2 underline, 4 reverse, 8 blink, 16 dim, 32 italic, 64 hidden.
]]

local Terminal = {}
Terminal.__index = Terminal

local DEFAULT_COLOR = 256
local BG_MUL = 512
local FLAG_MUL = 262144

local F_BOLD = 1
local F_UNDERLINE = 2
local F_REVERSE = 4
local F_BLINK = 8
local F_DIM = 16
local F_ITALIC = 32
local F_HIDDEN = 64

Terminal.FLAG_BOLD = F_BOLD
Terminal.FLAG_UNDERLINE = F_UNDERLINE
Terminal.FLAG_REVERSE = F_REVERSE
Terminal.FLAG_BLINK = F_BLINK
Terminal.FLAG_DIM = F_DIM
Terminal.FLAG_ITALIC = F_ITALIC
Terminal.FLAG_HIDDEN = F_HIDDEN
Terminal.DEFAULT_COLOR = DEFAULT_COLOR

local DEFAULT_ATTR = DEFAULT_COLOR + DEFAULT_COLOR * BG_MUL

-- DEC special graphics (ESC ( 0) to Unicode box drawing.
local DEC_GRAPHICS: { [string]: string } = {
	["`"] = "◆", a = "▒", f = "°", g = "±", j = "┘", k = "┐", l = "┌", m = "└", n = "┼",
	o = "⎺", p = "⎻", q = "─", r = "⎼", s = "⎽", t = "├", u = "┤", v = "┴", w = "┬",
	x = "│", y = "≤", z = "≥", ["{"] = "π", ["|"] = "≠", ["}"] = "£", ["~"] = "·",
}

type ScreenBuffer = {
	lines: { { string } },
	attrs: { { number } },
}

export type Terminal = typeof(setmetatable(
	{} :: {
		cols: number,
		rows: number,
		lines: { { string } },
		attrs: { { number } },
		dirty: { boolean },
		-- Bumped whenever anything visible changes.
		version: number,
		cursorRow: number,
		cursorCol: number,
		cursorVisible: boolean,
		wrapPending: boolean,
		attr: number,
		scrollTop: number,
		scrollBottom: number,
		tabStops: { boolean },
		savedCursor: { row: number, col: number, attr: number, origin: boolean, g0: string, g1: string }?,
		autoWrap: boolean,
		insertMode: boolean,
		originMode: boolean,
		applicationCursor: boolean,
		applicationKeypad: boolean,
		bracketedPaste: boolean,
		altScreen: ScreenBuffer?,
		mainScreen: ScreenBuffer?,
		g0: string,
		g1: string,
		shiftOut: boolean,
		lastChar: string,
		title: string,
		-- Parser state
		state: string,
		params: string,
		intermediate: string,
		oscBuffer: string,
		utf8Need: number,
		utf8Buffer: string,
		-- Callbacks
		onResponse: ((data: string) -> ())?,
		onBell: (() -> ())?,
		onTitle: ((title: string) -> ())?,
	},
	Terminal
))

function Terminal.new(cols: number?, rows: number?): Terminal
	local self = setmetatable({}, Terminal) :: any
	self.cols = cols or 80
	self.rows = rows or 25
	self.onResponse = nil
	self.onBell = nil
	self.onTitle = nil
	self:reset()
	return self :: Terminal
end

local function blankLine(cols: number): ({ string }, { number })
	return table.create(cols, " "), table.create(cols, DEFAULT_ATTR)
end

function Terminal.reset(self: Terminal)
	self.lines = {}
	self.attrs = {}
	self.dirty = {}
	for r = 1, self.rows do
		self.lines[r], self.attrs[r] = blankLine(self.cols)
		self.dirty[r] = true
	end
	self.version = (self.version or 0) + 1
	self.cursorRow = 1
	self.cursorCol = 1
	self.cursorVisible = true
	self.wrapPending = false
	self.attr = DEFAULT_ATTR
	self.scrollTop = 1
	self.scrollBottom = self.rows
	self.tabStops = {}
	for c = 9, self.cols, 8 do
		self.tabStops[c] = true
	end
	self.savedCursor = nil
	self.autoWrap = true
	self.insertMode = false
	self.originMode = false
	self.applicationCursor = false
	self.applicationKeypad = false
	self.bracketedPaste = false
	self.altScreen = nil
	self.mainScreen = nil
	self.g0 = "B"
	self.g1 = "B"
	self.shiftOut = false
	self.lastChar = " "
	self.title = ""
	self.state = "ground"
	self.params = ""
	self.intermediate = ""
	self.oscBuffer = ""
	self.utf8Need = 0
	self.utf8Buffer = ""
end

function Terminal._markDirty(self: Terminal, row: number)
	self.dirty[row] = true
	self.version += 1
end

function Terminal._markAllDirty(self: Terminal)
	for r = 1, self.rows do
		self.dirty[r] = true
	end
	self.version += 1
end

function Terminal._respond(self: Terminal, data: string)
	local onResponse = self.onResponse
	if onResponse then
		onResponse(data)
	end
end

-- Erase cells use the current background color, like xterm.
function Terminal._blankAttr(self: Terminal): number
	local bg = (self.attr // BG_MUL) % 512
	return DEFAULT_COLOR + bg * BG_MUL
end

function Terminal._clearCells(self: Terminal, row: number, fromCol: number, toCol: number)
	local line, attrs = self.lines[row], self.attrs[row]
	local blank = self:_blankAttr()
	for c = math.max(fromCol, 1), math.min(toCol, self.cols) do
		line[c] = " "
		attrs[c] = blank
	end
	self:_markDirty(row)
end

-- Scrolls rows top..bottom up by n lines (new blank lines at the bottom).
function Terminal._scrollUp(self: Terminal, top: number, bottom: number, n: number)
	n = math.min(n, bottom - top + 1)
	for _ = 1, n do
		table.remove(self.lines, top)
		table.remove(self.attrs, top)
		local line, attrs = blankLine(self.cols)
		local blank = self:_blankAttr()
		if blank ~= DEFAULT_ATTR then
			for c = 1, self.cols do
				attrs[c] = blank
			end
		end
		table.insert(self.lines, bottom, line)
		table.insert(self.attrs, bottom, attrs)
	end
	for r = top, bottom do
		self.dirty[r] = true
	end
	self.version += 1
end

-- Scrolls rows top..bottom down by n lines (new blank lines at the top).
function Terminal._scrollDown(self: Terminal, top: number, bottom: number, n: number)
	n = math.min(n, bottom - top + 1)
	for _ = 1, n do
		table.remove(self.lines, bottom)
		table.remove(self.attrs, bottom)
		local line, attrs = blankLine(self.cols)
		table.insert(self.lines, top, line)
		table.insert(self.attrs, top, attrs)
	end
	for r = top, bottom do
		self.dirty[r] = true
	end
	self.version += 1
end

function Terminal._lineFeed(self: Terminal)
	if self.cursorRow == self.scrollBottom then
		self:_scrollUp(self.scrollTop, self.scrollBottom, 1)
	elseif self.cursorRow < self.rows then
		self.cursorRow += 1
		self.version += 1
	end
end

function Terminal._reverseIndex(self: Terminal)
	if self.cursorRow == self.scrollTop then
		self:_scrollDown(self.scrollTop, self.scrollBottom, 1)
	elseif self.cursorRow > 1 then
		self.cursorRow -= 1
		self.version += 1
	end
end

function Terminal._putChar(self: Terminal, ch: string)
	local charset = if self.shiftOut then self.g1 else self.g0
	if charset == "0" then
		ch = DEC_GRAPHICS[ch] or ch
	end
	if self.wrapPending then
		self.wrapPending = false
		if self.autoWrap then
			self.cursorCol = 1
			self:_lineFeed()
		end
	end
	local row = self.cursorRow
	local line, attrs = self.lines[row], self.attrs[row]
	local col = self.cursorCol
	if self.insertMode then
		table.insert(line, col, ch)
		table.insert(attrs, col, self.attr)
		table.remove(line)
		table.remove(attrs)
	else
		line[col] = ch
		attrs[col] = self.attr
	end
	self.lastChar = ch
	self:_markDirty(row)
	if col == self.cols then
		self.wrapPending = true
	else
		self.cursorCol = col + 1
	end
end

function Terminal._setCursor(self: Terminal, row: number, col: number)
	local top, bottom = 1, self.rows
	if self.originMode then
		row += self.scrollTop - 1
		top, bottom = self.scrollTop, self.scrollBottom
	end
	self.cursorRow = math.clamp(row, top, bottom)
	self.cursorCol = math.clamp(col, 1, self.cols)
	self.wrapPending = false
	self.version += 1
end

function Terminal._switchScreen(self: Terminal, alt: boolean, clear: boolean)
	if alt and not self.altScreen then
		self.mainScreen = { lines = self.lines, attrs = self.attrs }
		self.lines, self.attrs = {}, {}
		for r = 1, self.rows do
			self.lines[r], self.attrs[r] = blankLine(self.cols)
		end
		self.altScreen = { lines = self.lines, attrs = self.attrs }
	elseif not alt and self.altScreen then
		local main = self.mainScreen :: ScreenBuffer
		self.lines, self.attrs = main.lines, main.attrs
		self.altScreen = nil
		self.mainScreen = nil
	elseif alt and clear then
		for r = 1, self.rows do
			self.lines[r], self.attrs[r] = blankLine(self.cols)
		end
	end
	self:_markAllDirty()
end

function Terminal._saveCursor(self: Terminal)
	self.savedCursor = {
		row = self.cursorRow,
		col = self.cursorCol,
		attr = self.attr,
		origin = self.originMode,
		g0 = self.g0,
		g1 = self.g1,
	}
end

function Terminal._restoreCursor(self: Terminal)
	local saved = self.savedCursor
	if saved then
		self.cursorRow = math.clamp(saved.row, 1, self.rows)
		self.cursorCol = math.clamp(saved.col, 1, self.cols)
		self.attr = saved.attr
		self.originMode = saved.origin
		self.g0 = saved.g0
		self.g1 = saved.g1
	else
		self.cursorRow, self.cursorCol = 1, 1
	end
	self.wrapPending = false
	self.version += 1
end

-- Maps an xterm 256-color index or RGB triple to a palette index (0..255).
local function rgbTo256(r: number, g: number, b: number): number
	local function level(v: number): number
		if v < 48 then
			return 0
		elseif v < 115 then
			return 1
		end
		return math.min(5, (v - 35) // 40)
	end
	return 16 + 36 * level(r) + 6 * level(g) + level(b)
end

function Terminal._sgr(self: Terminal, params: { number })
	local fg = self.attr % BG_MUL
	local bg = (self.attr // BG_MUL) % 512
	local flags = self.attr // FLAG_MUL
	if #params == 0 then
		params = { 0 }
	end
	local i = 1
	while i <= #params do
		local p = params[i]
		if p == 0 then
			fg, bg, flags = DEFAULT_COLOR, DEFAULT_COLOR, 0
		elseif p == 1 then
			flags = bit32.bor(flags, F_BOLD)
		elseif p == 2 then
			flags = bit32.bor(flags, F_DIM)
		elseif p == 3 then
			flags = bit32.bor(flags, F_ITALIC)
		elseif p == 4 then
			flags = bit32.bor(flags, F_UNDERLINE)
		elseif p == 5 or p == 6 then
			flags = bit32.bor(flags, F_BLINK)
		elseif p == 7 then
			flags = bit32.bor(flags, F_REVERSE)
		elseif p == 8 then
			flags = bit32.bor(flags, F_HIDDEN)
		elseif p == 21 or p == 22 then
			flags = bit32.band(flags, bit32.bnot(F_BOLD + F_DIM))
		elseif p == 23 then
			flags = bit32.band(flags, bit32.bnot(F_ITALIC))
		elseif p == 24 then
			flags = bit32.band(flags, bit32.bnot(F_UNDERLINE))
		elseif p == 25 then
			flags = bit32.band(flags, bit32.bnot(F_BLINK))
		elseif p == 27 then
			flags = bit32.band(flags, bit32.bnot(F_REVERSE))
		elseif p == 28 then
			flags = bit32.band(flags, bit32.bnot(F_HIDDEN))
		elseif p >= 30 and p <= 37 then
			fg = p - 30
		elseif p == 39 then
			fg = DEFAULT_COLOR
		elseif p >= 40 and p <= 47 then
			bg = p - 40
		elseif p == 49 then
			bg = DEFAULT_COLOR
		elseif p >= 90 and p <= 97 then
			fg = p - 90 + 8
		elseif p >= 100 and p <= 107 then
			bg = p - 100 + 8
		elseif p == 38 or p == 48 then
			local color: number? = nil
			if params[i + 1] == 5 and params[i + 2] then
				color = math.clamp(params[i + 2], 0, 255)
				i += 2
			elseif params[i + 1] == 2 and params[i + 4] then
				color = rgbTo256(params[i + 2], params[i + 3], params[i + 4])
				i += 4
			end
			if color then
				if p == 38 then
					fg = color
				else
					bg = color
				end
			end
		end
		i += 1
	end
	self.attr = fg + bg * BG_MUL + flags * FLAG_MUL
end

function Terminal._setMode(self: Terminal, private: boolean, params: { number }, on: boolean)
	for _, p in params do
		if private then
			if p == 1 then
				self.applicationCursor = on
			elseif p == 6 then
				self.originMode = on
				self:_setCursor(1, 1)
			elseif p == 7 then
				self.autoWrap = on
			elseif p == 25 then
				self.cursorVisible = on
				self.version += 1
			elseif p == 47 or p == 1047 then
				self:_switchScreen(on, false)
			elseif p == 1048 then
				if on then
					self:_saveCursor()
				else
					self:_restoreCursor()
				end
			elseif p == 1049 then
				if on then
					self:_saveCursor()
					self:_switchScreen(true, true)
				else
					self:_switchScreen(false, false)
					self:_restoreCursor()
				end
			elseif p == 2004 then
				self.bracketedPaste = on
			end
		elseif p == 4 then
			self.insertMode = on
		end
	end
end

local function parseParams(s: string): { number }
	local out = {}
	if s == "" then
		return out
	end
	for part in string.gmatch(s .. ";", "([^;:]*)[;:]") do
		table.insert(out, tonumber(part) or 0)
	end
	return out
end

function Terminal._csi(self: Terminal, final: string)
	local raw = self.params
	local private = false
	local prefix = string.sub(raw, 1, 1)
	if prefix == "?" or prefix == ">" or prefix == "=" then
		private = prefix == "?"
		raw = string.sub(raw, 2)
	end
	local params = parseParams(raw)
	local p1 = params[1] or 0
	local n = math.max(p1, 1)

	if prefix == ">" then
		if final == "c" then
			self:_respond("\27[>0;10;0c") -- secondary device attributes
		end
		return
	end

	if final == "A" then
		self.cursorRow = math.max(self.cursorRow - n, if self.cursorRow >= self.scrollTop then self.scrollTop else 1)
		self.wrapPending = false
		self.version += 1
	elseif final == "B" or final == "e" then
		self.cursorRow = math.min(self.cursorRow + n, if self.cursorRow <= self.scrollBottom then self.scrollBottom else self.rows)
		self.wrapPending = false
		self.version += 1
	elseif final == "C" or final == "a" then
		self.cursorCol = math.min(self.cursorCol + n, self.cols)
		self.wrapPending = false
		self.version += 1
	elseif final == "D" then
		self.cursorCol = math.max(self.cursorCol - n, 1)
		self.wrapPending = false
		self.version += 1
	elseif final == "E" then
		self.cursorCol = 1
		self.cursorRow = math.min(self.cursorRow + n, self.scrollBottom)
		self.wrapPending = false
		self.version += 1
	elseif final == "F" then
		self.cursorCol = 1
		self.cursorRow = math.max(self.cursorRow - n, self.scrollTop)
		self.wrapPending = false
		self.version += 1
	elseif final == "G" or final == "`" then
		self.cursorCol = math.clamp(n, 1, self.cols)
		self.wrapPending = false
		self.version += 1
	elseif final == "H" or final == "f" then
		self:_setCursor(math.max(params[1] or 1, 1), math.max(params[2] or 1, 1))
	elseif final == "d" then
		self:_setCursor(n, self.cursorCol)
	elseif final == "J" then
		local row = self.cursorRow
		if p1 == 0 then
			self:_clearCells(row, self.cursorCol, self.cols)
			for r = row + 1, self.rows do
				self:_clearCells(r, 1, self.cols)
			end
		elseif p1 == 1 then
			for r = 1, row - 1 do
				self:_clearCells(r, 1, self.cols)
			end
			self:_clearCells(row, 1, self.cursorCol)
		elseif p1 == 2 or p1 == 3 then
			for r = 1, self.rows do
				self:_clearCells(r, 1, self.cols)
			end
		end
	elseif final == "K" then
		local row = self.cursorRow
		if p1 == 0 then
			self:_clearCells(row, self.cursorCol, self.cols)
		elseif p1 == 1 then
			self:_clearCells(row, 1, self.cursorCol)
		elseif p1 == 2 then
			self:_clearCells(row, 1, self.cols)
		end
	elseif final == "L" then
		if self.cursorRow >= self.scrollTop and self.cursorRow <= self.scrollBottom then
			self:_scrollDown(self.cursorRow, self.scrollBottom, n)
			self.cursorCol = 1
		end
	elseif final == "M" then
		if self.cursorRow >= self.scrollTop and self.cursorRow <= self.scrollBottom then
			self:_scrollUp(self.cursorRow, self.scrollBottom, n)
			self.cursorCol = 1
		end
	elseif final == "P" then
		local line, attrs = self.lines[self.cursorRow], self.attrs[self.cursorRow]
		local blank = self:_blankAttr()
		for _ = 1, math.min(n, self.cols - self.cursorCol + 1) do
			table.remove(line, self.cursorCol)
			table.remove(attrs, self.cursorCol)
			table.insert(line, " ")
			table.insert(attrs, blank)
		end
		self:_markDirty(self.cursorRow)
	elseif final == "@" then
		local line, attrs = self.lines[self.cursorRow], self.attrs[self.cursorRow]
		local blank = self:_blankAttr()
		for _ = 1, math.min(n, self.cols - self.cursorCol + 1) do
			table.insert(line, self.cursorCol, " ")
			table.insert(attrs, self.cursorCol, blank)
			table.remove(line)
			table.remove(attrs)
		end
		self:_markDirty(self.cursorRow)
	elseif final == "X" then
		self:_clearCells(self.cursorRow, self.cursorCol, self.cursorCol + n - 1)
	elseif final == "S" then
		self:_scrollUp(self.scrollTop, self.scrollBottom, n)
	elseif final == "T" then
		self:_scrollDown(self.scrollTop, self.scrollBottom, n)
	elseif final == "b" then
		for _ = 1, math.min(n, self.cols * self.rows) do
			self:_putChar(self.lastChar)
		end
	elseif final == "r" then
		local top = math.max(params[1] or 1, 1)
		local bottom = math.min(if (params[2] or 0) > 0 then params[2] else self.rows, self.rows)
		if top < bottom then
			self.scrollTop, self.scrollBottom = top, bottom
			self:_setCursor(1, 1)
		end
	elseif final == "s" then
		self:_saveCursor()
	elseif final == "u" then
		self:_restoreCursor()
	elseif final == "m" then
		self:_sgr(params)
	elseif final == "h" then
		self:_setMode(private, params, true)
	elseif final == "l" then
		self:_setMode(private, params, false)
	elseif final == "n" then
		if p1 == 6 then
			local row = self.cursorRow
			if self.originMode then
				row -= self.scrollTop - 1
			end
			self:_respond(string.format("\27[%d;%dR", row, self.cursorCol))
		elseif p1 == 5 then
			self:_respond("\27[0n")
		end
	elseif final == "c" then
		self:_respond("\27[?1;2c") -- VT100 with advanced video option
	elseif final == "g" then
		if p1 == 0 then
			self.tabStops[self.cursorCol] = nil
		elseif p1 == 3 then
			table.clear(self.tabStops)
		end
	elseif final == "t" then
		-- Window manipulation: report the size in characters when asked.
		if p1 == 18 then
			self:_respond(string.format("\27[8;%d;%dt", self.rows, self.cols))
		end
	end
	-- Others (q cursor style, p modes...) are ignored.
end

function Terminal._esc(self: Terminal, final: string)
	local inter = self.intermediate
	if inter == "(" then
		self.g0 = final
	elseif inter == ")" then
		self.g1 = final
	elseif inter == "#" then
		if final == "8" then -- DECALN: fill the screen with E
			for r = 1, self.rows do
				for c = 1, self.cols do
					self.lines[r][c] = "E"
				end
			end
			self:_markAllDirty()
		end
	elseif inter == "" then
		if final == "7" then
			self:_saveCursor()
		elseif final == "8" then
			self:_restoreCursor()
		elseif final == "D" then
			self:_lineFeed()
		elseif final == "E" then
			self.cursorCol = 1
			self:_lineFeed()
		elseif final == "M" then
			self:_reverseIndex()
		elseif final == "H" then
			self.tabStops[self.cursorCol] = true
		elseif final == "c" then
			local onResponse, onBell, onTitle = self.onResponse, self.onBell, self.onTitle
			self:reset()
			self.onResponse, self.onBell, self.onTitle = onResponse, onBell, onTitle
		elseif final == "=" then
			self.applicationKeypad = true
		elseif final == ">" then
			self.applicationKeypad = false
		end
	end
end

function Terminal._control(self: Terminal, b: number)
	if b == 7 then
		local onBell = self.onBell
		if onBell then
			onBell()
		end
	elseif b == 8 then
		if self.cursorCol > 1 then
			self.cursorCol -= 1
		end
		self.wrapPending = false
		self.version += 1
	elseif b == 9 then
		local c = self.cursorCol + 1
		while c < self.cols and not self.tabStops[c] do
			c += 1
		end
		self.cursorCol = math.min(c, self.cols)
		self.version += 1
	elseif b == 10 or b == 11 or b == 12 then
		self.wrapPending = false
		self:_lineFeed()
	elseif b == 13 then
		self.cursorCol = 1
		self.wrapPending = false
		self.version += 1
	elseif b == 14 then
		self.shiftOut = true
	elseif b == 15 then
		self.shiftOut = false
	end
end

-- Feeds program output into the terminal.
function Terminal.write(self: Terminal, data: string)
	for i = 1, #data do
		local b = string.byte(data, i)
		local state = self.state

		if state == "ground" then
			if self.utf8Need > 0 then
				if b >= 0x80 and b < 0xC0 then
					self.utf8Buffer ..= string.char(b)
					self.utf8Need -= 1
					if self.utf8Need == 0 then
						self:_putChar(self.utf8Buffer)
					end
					continue
				end
				-- Malformed sequence: drop it and process this byte normally.
				self.utf8Need = 0
			end
			if b >= 32 and b < 127 then
				self:_putChar(string.char(b))
			elseif b == 27 then
				self.state = "escape"
				self.intermediate = ""
			elseif b < 32 then
				self:_control(b)
			elseif b >= 0xC2 and b < 0xF5 then
				self.utf8Buffer = string.char(b)
				self.utf8Need = if b < 0xE0 then 1 elseif b < 0xF0 then 2 else 3
			end
		elseif state == "escape" then
			if b == 91 then -- [
				self.state = "csi"
				self.params = ""
				self.intermediate = ""
			elseif b == 93 then -- ]
				self.state = "osc"
				self.oscBuffer = ""
			elseif b == 80 or b == 94 or b == 95 then -- DCS / PM / APC: skip until ST
				self.state = "string"
			elseif b >= 32 and b <= 47 then
				self.intermediate ..= string.char(b)
			elseif b == 24 or b == 26 then
				self.state = "ground"
			elseif b == 27 then
				self.intermediate = ""
			elseif b < 32 then
				self:_control(b)
			else
				self.state = "ground"
				self:_esc(string.char(b))
			end
		elseif state == "csi" then
			if b >= 48 and b <= 63 then -- parameters and private markers
				self.params ..= string.char(b)
			elseif b >= 32 and b <= 47 then
				self.intermediate ..= string.char(b)
			elseif b >= 64 and b <= 126 then
				self.state = "ground"
				if self.intermediate == "" then
					self:_csi(string.char(b))
				end
			elseif b == 27 then
				self.state = "escape"
				self.intermediate = ""
			elseif b == 24 or b == 26 then
				self.state = "ground"
			elseif b < 32 then
				self:_control(b)
			end
		elseif state == "osc" then
			if b == 7 then
				self:_finishOsc()
				self.state = "ground"
			elseif b == 27 then
				self.state = "oscEscape"
			elseif #self.oscBuffer < 512 then
				self.oscBuffer ..= string.char(b)
			end
		elseif state == "oscEscape" then
			self:_finishOsc()
			self.state = "ground"
			if b ~= 92 then -- not ST: treat as a new escape
				self.state = "escape"
				self.intermediate = ""
			end
		elseif state == "string" then
			if b == 27 then
				self.state = "stringEscape"
			elseif b == 7 then
				self.state = "ground"
			end
		elseif state == "stringEscape" then
			self.state = if b == 92 then "ground" else "string"
		end
	end
end

function Terminal._finishOsc(self: Terminal)
	local num, text = string.match(self.oscBuffer, "^(%d+);(.*)$")
	if num == "0" or num == "2" then
		self.title = text :: string
		local onTitle = self.onTitle
		if onTitle then
			onTitle(self.title)
		end
	end
end

function Terminal.getLineText(self: Terminal, row: number): string
	return table.concat(self.lines[row])
end

-- Plain-text snapshot of the screen (trailing spaces trimmed), for tests and logs.
function Terminal.toText(self: Terminal): string
	local out = table.create(self.rows)
	for r = 1, self.rows do
		out[r] = (string.gsub(table.concat(self.lines[r]), "%s+$", ""))
	end
	return table.concat(out, "\n")
end

type EncodedScreen = {
	lines: { string },
	attrs: { { number } }, -- run-length: { attr, count, attr, count, ... } per row
}

export type Snapshot = {
	cols: number,
	rows: number,
	screen: EncodedScreen,
	-- The saved main screen while a full-screen program uses the alternate one.
	mainScreen: EncodedScreen?,
	cursor: { number },
	cursorVisible: boolean,
	modes: { [string]: boolean },
	parser: { string },
	utf8Need: number,
	attr: number,
	scroll: { number },
	savedCursor: { row: number, col: number, attr: number, origin: boolean, g0: string, g1: string }?,
}

local function encodeScreen(screenLines: { { string } }, screenAttrs: { { number } }, cols: number): EncodedScreen
	local lines = table.create(#screenLines)
	local attrs = table.create(#screenLines)
	for r, cells in screenLines do
		-- Cells can hold multi-byte UTF-8, so join with a separator.
		lines[r] = table.concat(cells, "\0")
		local runs = {}
		local rowAttrs = screenAttrs[r]
		local current, count = rowAttrs[1], 0
		for c = 1, cols do
			local a = rowAttrs[c]
			if a == current then
				count += 1
			else
				table.insert(runs, current)
				table.insert(runs, count)
				current, count = a, 1
			end
		end
		table.insert(runs, current)
		table.insert(runs, count)
		attrs[r] = runs
	end
	return { lines = lines, attrs = attrs }
end

local function decodeScreen(encoded: EncodedScreen, rows: number, cols: number): ScreenBuffer
	local out: ScreenBuffer = { lines = {}, attrs = {} }
	for r = 1, rows do
		local cells = string.split(encoded.lines[r] or "", "\0")
		local line = table.create(cols, " ")
		for c = 1, math.min(#cells, cols) do
			line[c] = cells[c]
		end
		out.lines[r] = line
		local rowAttrs = table.create(cols, DEFAULT_ATTR)
		local runs = encoded.attrs[r] or {}
		local c = 1
		for i = 1, #runs, 2 do
			for _ = 1, runs[i + 1] do
				if c <= cols then
					rowAttrs[c] = runs[i]
				end
				c += 1
			end
		end
		out.attrs[r] = rowAttrs
	end
	return out
end

--[[
	Captures everything needed to reproduce the screen and keep parsing the byte
	stream exactly where this terminal is. Sent to players who start watching a
	computer, and instead of raw output when output floods.
]]
function Terminal.snapshot(self: Terminal): Snapshot
	local main = self.mainScreen
	return {
		cols = self.cols,
		rows = self.rows,
		screen = encodeScreen(self.lines, self.attrs, self.cols),
		mainScreen = if main then encodeScreen(main.lines, main.attrs, self.cols) else nil,
		cursor = { self.cursorRow, self.cursorCol },
		cursorVisible = self.cursorVisible,
		modes = {
			wrapPending = self.wrapPending,
			autoWrap = self.autoWrap,
			insertMode = self.insertMode,
			originMode = self.originMode,
			applicationCursor = self.applicationCursor,
			applicationKeypad = self.applicationKeypad,
			shiftOut = self.shiftOut,
		},
		parser = { self.state, self.params, self.intermediate, self.oscBuffer, self.utf8Buffer, self.g0, self.g1 },
		utf8Need = self.utf8Need,
		attr = self.attr,
		scroll = { self.scrollTop, self.scrollBottom },
		savedCursor = if self.savedCursor then table.clone(self.savedCursor) else nil,
	}
end

function Terminal.loadSnapshot(self: Terminal, snap: Snapshot)
	if snap.cols ~= self.cols or snap.rows ~= self.rows then
		self.cols, self.rows = snap.cols, snap.rows
		self:reset()
	end
	local screen = decodeScreen(snap.screen, self.rows, self.cols)
	self.lines, self.attrs = screen.lines, screen.attrs
	if snap.mainScreen then
		self.mainScreen = decodeScreen(snap.mainScreen, self.rows, self.cols)
		self.altScreen = screen
	else
		self.mainScreen = nil
		self.altScreen = nil
	end
	self.cursorRow, self.cursorCol = snap.cursor[1], snap.cursor[2]
	self.cursorVisible = snap.cursorVisible
	local m = snap.modes
	self.wrapPending = m.wrapPending
	self.autoWrap = m.autoWrap
	self.insertMode = m.insertMode
	self.originMode = m.originMode
	self.applicationCursor = m.applicationCursor
	self.applicationKeypad = m.applicationKeypad
	self.shiftOut = m.shiftOut
	local p = snap.parser
	self.state, self.params, self.intermediate, self.oscBuffer, self.utf8Buffer, self.g0, self.g1 =
		p[1], p[2], p[3], p[4], p[5], p[6], p[7]
	self.utf8Need = snap.utf8Need
	self.attr = snap.attr
	self.scrollTop, self.scrollBottom = snap.scroll[1], snap.scroll[2]
	self.savedCursor = if snap.savedCursor then table.clone(snap.savedCursor) else nil
	self:_markAllDirty()
end

-- Returns the list of dirty rows and clears the flags.
function Terminal.takeDirtyRows(self: Terminal): { number }
	local list = {}
	for r = 1, self.rows do
		if self.dirty[r] then
			table.insert(list, r)
			self.dirty[r] = false
		end
	end
	return list
end

return Terminal
