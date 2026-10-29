--!strict
--[[
	Turns key presses into the bytes a terminal sends (xterm conventions,
	US keyboard layout).

	Works on Enum.KeyCode *names* (e.g. "A", "Return", "Up") so it can be tested
	outside Roblox. The client passes `keyCode.Name`.
]]

local KeyMap = {}

export type Modifiers = {
	shift: boolean?,
	ctrl: boolean?,
	alt: boolean?,
	capsLock: boolean?,
}

export type Modes = {
	applicationCursor: boolean?,
	applicationKeypad: boolean?,
}

-- Unshifted / shifted characters for printable keys.
local PRINTABLE: { [string]: { string } } = {
	Space = { " ", " " },
	One = { "1", "!" },
	Two = { "2", "@" },
	Three = { "3", "#" },
	Four = { "4", "$" },
	Five = { "5", "%" },
	Six = { "6", "^" },
	Seven = { "7", "&" },
	Eight = { "8", "*" },
	Nine = { "9", "(" },
	Zero = { "0", ")" },
	Minus = { "-", "_" },
	Equals = { "=", "+" },
	LeftBracket = { "[", "{" },
	RightBracket = { "]", "}" },
	BackSlash = { "\\", "|" },
	Semicolon = { ";", ":" },
	Quote = { "'", '"' },
	Comma = { ",", "<" },
	Period = { ".", ">" },
	Slash = { "/", "?" },
	Backquote = { "`", "~" },
	KeypadZero = { "0", "0" },
	KeypadOne = { "1", "1" },
	KeypadTwo = { "2", "2" },
	KeypadThree = { "3", "3" },
	KeypadFour = { "4", "4" },
	KeypadFive = { "5", "5" },
	KeypadSix = { "6", "6" },
	KeypadSeven = { "7", "7" },
	KeypadEight = { "8", "8" },
	KeypadNine = { "9", "9" },
	KeypadPeriod = { ".", "." },
	KeypadDivide = { "/", "/" },
	KeypadMultiply = { "*", "*" },
	KeypadMinus = { "-", "-" },
	KeypadPlus = { "+", "+" },
	KeypadEquals = { "=", "=" },
}

local SPECIAL: { [string]: string } = {
	Return = "\r",
	KeypadEnter = "\r",
	Backspace = "\127",
	Tab = "\t",
	Escape = "\27",
	Insert = "\27[2~",
	Delete = "\27[3~",
	Home = "\27[H",
	End = "\27[F",
	PageUp = "\27[5~",
	PageDown = "\27[6~",
	F1 = "\27OP",
	F2 = "\27OQ",
	F3 = "\27OR",
	F4 = "\27OS",
	F5 = "\27[15~",
	F6 = "\27[17~",
	F7 = "\27[18~",
	F8 = "\27[19~",
	F9 = "\27[20~",
	F10 = "\27[21~",
	F11 = "\27[23~",
	F12 = "\27[24~",
}

local ARROWS: { [string]: string } = { Up = "A", Down = "B", Right = "C", Left = "D" }

-- Control characters for Ctrl + punctuation.
local CTRL_PUNCT: { [string]: string } = {
	Space = "\0",
	Two = "\0",
	LeftBracket = "\27",
	BackSlash = "\28",
	RightBracket = "\29",
	Six = "\30",
	Minus = "\31",
	Slash = "\31",
	Backspace = "\8",
}

-- Keys that should auto-repeat when held.
KeyMap.REPEATS = {
	Backspace = true,
	Delete = true,
	Up = true,
	Down = true,
	Left = true,
	Right = true,
	PageUp = true,
	PageDown = true,
	Space = true,
	Return = true,
	Tab = true,
}

function KeyMap.isLetter(name: string): boolean
	return #name == 1 and string.match(name, "%u") ~= nil
end

-- Bytes for a key press, or nil if the key produces nothing (e.g. Shift alone).
function KeyMap.encode(name: string, mods: Modifiers?, modes: Modes?): string?
	local m: Modifiers = mods or {}
	local md: Modes = modes or {}
	local out: string? = nil

	local arrow = ARROWS[name]
	if arrow then
		if m.ctrl or m.shift or m.alt then
			-- xterm modifier encoding: 2 shift, 3 alt, 5 ctrl (+ combinations).
			local code = 1 + (if m.shift then 1 else 0) + (if m.alt then 2 else 0) + (if m.ctrl then 4 else 0)
			return string.format("\27[1;%d%s", code, arrow)
		end
		return (if md.applicationCursor then "\27O" else "\27[") .. arrow
	end

	if KeyMap.isLetter(name) then
		if m.ctrl then
			out = string.char(string.byte(name) - 64)
		else
			local upper = (m.shift and not m.capsLock) or (m.capsLock and not m.shift)
			out = if upper then name else string.lower(name)
		end
	elseif m.ctrl and CTRL_PUNCT[name] then
		out = CTRL_PUNCT[name]
	elseif PRINTABLE[name] then
		local pair = PRINTABLE[name]
		if md.applicationKeypad and string.sub(name, 1, 6) == "Keypad" then
			-- Application keypad mode (rare in busybox programs): send as SS3.
			local digit = string.match(name, "^Keypad(%a+)$")
			local map = {
				Zero = "p", One = "q", Two = "r", Three = "s", Four = "t", Five = "u",
				Six = "v", Seven = "w", Eight = "x", Nine = "y", Period = "n",
				Divide = "o", Multiply = "j", Minus = "m", Plus = "k",
			}
			local final = digit and map[digit]
			if final then
				return "\27O" .. final
			end
		end
		out = if m.shift then pair[2] else pair[1]
	elseif SPECIAL[name] then
		out = SPECIAL[name]
		if name == "Tab" and m.shift then
			out = "\27[Z"
		end
	end

	if out and m.alt then
		out = "\27" .. out
	end
	return out
end

return KeyMap
