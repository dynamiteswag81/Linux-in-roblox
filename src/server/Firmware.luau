--!strict
--[[
	The computer's firmware ("BrickBIOS"): the screen you see between pressing
	the power button and Linux starting. Shows a POST screen, counts down, and
	offers a boot menu (live installer, fallback kernel...).

	Engine-agnostic: output goes through `write`, keys come in through
	`input`, and `update` advances the countdown.
]]

local Firmware = {}
Firmware.__index = Firmware

export type BootEntry = {
	id: string,
	label: string,
	hint: string?,
}

export type Info = {
	ramMB: number,
	diskMB: number,
	diskUsedKB: number,
	mac: string?,
	ip: string?,
	owner: string,
	hostname: string,
}

export type Firmware = typeof(setmetatable(
	{} :: {
		write: (data: string) -> (),
		onBoot: (entry: BootEntry) -> (),
		entries: { BootEntry },
		info: Info,
		countdown: number,
		deadline: number?,
		mode: "post" | "menu" | "done",
		lastShown: number,
		selected: number,
		pendingInput: string,
	},
	Firmware
))

local ESC = "\27"
local CLEAR = ESC .. "[0m" .. ESC .. "[2J" .. ESC .. "[H"
local BOLD = ESC .. "[1m"
local RESET = ESC .. "[0m"
local DIM = ESC .. "[2m"
local CYAN = ESC .. "[1;36m"
local YELLOW = ESC .. "[1;33m"
local INVERSE = ESC .. "[7m"

function Firmware.new(
	write: (string) -> (),
	entries: { BootEntry },
	info: Info,
	onBoot: (entry: BootEntry) -> (),
	countdown: number?
): Firmware
	assert(#entries > 0, "firmware needs at least one boot entry")
	return setmetatable({
		write = write,
		onBoot = onBoot,
		entries = entries,
		info = info,
		countdown = countdown or 3,
		deadline = nil,
		mode = "post",
		lastShown = -1,
		selected = 1,
		pendingInput = "",
	}, Firmware)
end

local function formatMac(mac: string?): string
	if not mac or #mac ~= 6 then
		return "none"
	end
	local parts = {}
	for i = 1, 6 do
		parts[i] = string.format("%02x", string.byte(mac, i))
	end
	return table.concat(parts, ":")
end

function Firmware.start(self: Firmware, now: number)
	local info = self.info
	local lines = {
		CLEAR .. ESC .. "[?25l", -- hide the cursor while in firmware
		CYAN .. "  ____       _      _    ____ ___ ___  ____  " .. RESET,
		CYAN .. " | __ ) _ __(_) ___| | _| __ )_ _/ _ \\/ ___| " .. RESET,
		CYAN .. " |  _ \\| '__| |/ __| |/ /  _ \\| | | | \\___ \\ " .. RESET,
		CYAN .. " | |_) | |  | | (__|   <| |_) | | |_| |___) |" .. RESET,
		CYAN .. " |____/|_|  |_|\\___|_|\\_\\____/___\\___/|____/ " .. RESET .. "  v1.0",
		"",
		BOLD .. " CPU     " .. RESET .. ": RISC-V rv32ima, no MMU (emulated in Luau)",
		BOLD .. " Memory  " .. RESET .. string.format(": %dK OK", info.ramMB * 1024),
		BOLD .. " Disk 0  " .. RESET .. string.format(
			": %d MB virtio-blk, %s",
			info.diskMB,
			if info.diskUsedKB > 0 then string.format("%dK in use", info.diskUsedKB) else "empty"
		),
		BOLD .. " Network " .. RESET .. string.format(": virtio-net %s  %s", formatMac(info.mac), info.ip or "offline"),
		BOLD .. " Owner   " .. RESET .. ": " .. info.owner .. "  (" .. info.hostname .. ")",
		"",
	}
	self.write(table.concat(lines, "\r\n") .. "\r\n")
	self.mode = "post"
	self.deadline = now + self.countdown
	self:_drawCountdown(self.countdown)
end

function Firmware._drawCountdown(self: Firmware, secondsLeft: number)
	self.lastShown = secondsLeft
	self.write(
		"\r"
			.. ESC
			.. "[K "
			.. "Press "
			.. YELLOW
			.. "F2"
			.. RESET
			.. " or "
			.. YELLOW
			.. "Esc"
			.. RESET
			.. " for the boot menu. Booting "
			.. BOLD
			.. self.entries[1].label
			.. RESET
			.. string.format(" in %d...", math.max(secondsLeft, 0))
	)
end

function Firmware._drawMenu(self: Firmware)
	local width = 50
	local out = { CLEAR, "", BOLD .. "  BrickBIOS boot menu" .. RESET, "" }
	table.insert(out, "  ┌" .. string.rep("─", width) .. "┐")
	for i, entry in self.entries do
		local label = " " .. entry.label
		label ..= string.rep(" ", width - utf8.len(label) :: number)
		if i == self.selected then
			table.insert(out, "  │" .. INVERSE .. label .. RESET .. "│")
		else
			table.insert(out, "  │" .. label .. "│")
		end
	end
	table.insert(out, "  └" .. string.rep("─", width) .. "┘")
	table.insert(out, "")
	local hint = self.entries[self.selected].hint
	if hint then
		table.insert(out, "  " .. DIM .. hint .. RESET)
		table.insert(out, "")
	end
	table.insert(out, "  " .. YELLOW .. "↑/↓" .. RESET .. " choose   " .. YELLOW .. "Enter" .. RESET .. " boot")
	self.write(table.concat(out, "\r\n"))
end

function Firmware._boot(self: Firmware)
	if self.mode == "done" then
		return
	end
	self.mode = "done"
	local entry = self.entries[self.selected]
	self.write(CLEAR .. ESC .. "[?25h" .. "Loading " .. entry.label .. "...\r\n")
	self.onBoot(entry)
end

function Firmware.update(self: Firmware, now: number)
	if self.mode ~= "post" or not self.deadline then
		return
	end
	local left = self.deadline - now
	if left <= 0 then
		self:_boot()
	else
		local shown = math.ceil(left)
		if shown ~= self.lastShown then
			self:_drawCountdown(shown)
		end
	end
end

function Firmware.input(self: Firmware, data: string)
	if self.mode == "done" then
		return
	end
	self.pendingInput ..= data
	local buf = self.pendingInput
	while #buf > 0 do
		local consumed = 1
		local key: string? = nil
		if string.sub(buf, 1, 3) == "\27OQ" or string.sub(buf, 1, 5) == "\27[12~" then
			key = "menu"
			consumed = if string.sub(buf, 1, 3) == "\27OQ" then 3 else 5
		elseif string.match(buf, "^\27[%[O][AB]") then
			key = if string.sub(buf, 3, 3) == "A" then "up" else "down"
			consumed = 3
		elseif string.match(buf, "^\27[%[O]") and #buf < 3 then
			break -- incomplete escape sequence, wait for more
		elseif string.sub(buf, 1, 1) == "\27" then
			-- A lone Esc (or an unknown sequence): open the menu.
			key = "menu"
			local seq = string.match(buf, "^\27[%[O][%d;]*[%a~]")
			consumed = if seq then #seq else 1
		else
			local ch = string.sub(buf, 1, 1)
			if ch == "\r" or ch == "\n" then
				key = "enter"
			elseif ch == "k" or ch == "w" then
				key = "up"
			elseif ch == "j" or ch == "s" then
				key = "down"
			elseif tonumber(ch) then
				key = "number:" .. ch
			end
		end
		buf = string.sub(buf, consumed + 1)
		if key then
			self:_key(key)
			if self.mode == "done" then
				break
			end
		end
	end
	self.pendingInput = buf
end

function Firmware._key(self: Firmware, key: string)
	if self.mode == "post" then
		if key == "enter" then
			self:_boot()
		else
			self.mode = "menu"
			self:_drawMenu()
		end
		return
	end
	if key == "up" then
		self.selected = (self.selected - 2) % #self.entries + 1
		self:_drawMenu()
	elseif key == "down" then
		self.selected = self.selected % #self.entries + 1
		self:_drawMenu()
	elseif key == "enter" then
		self:_boot()
	elseif string.sub(key, 1, 7) == "number:" then
		local n = tonumber(string.sub(key, 8)) :: number
		if self.entries[n] then
			self.selected = n
			self:_boot()
		end
	end
end

return Firmware
