--[[
	A headless "server" with real services and several computers, for
	end-to-end tests of the workshop, package manager and network.

	lune run tools/lune/world.luau <script.txt>
	lune run tools/lune/world.luau -e "alice: uname -a" -e "bob: ping -c 1 alice"

	Script lines:
		<computer>: <shell input>     type a line (Enter added) and wait until idle
		<computer>: !keys <text>      type raw text (\r \n \e escapes, no Enter)
		@wait <seconds>               run all computers
		@screen <computer>            print that computer's screen
		@expect <computer> <text>     fail unless the screen contains text
		@reboot <computer>            power cycle (disk is kept)
	Computers are created on first mention and booted automatically.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local Shim = require("./RobloxShim")

local root = Shim.mountMany({ LinuxVM = "src/shared", LinuxServer = "src/server", LinuxImages = "src/images" })
local Computer = Shim.require(root.LinuxServer.Computer)
local Disk = Shim.require(root.LinuxVM.Emulator.Disk)
local ImageLoader = Shim.require(root.LinuxVM.Emulator.ImageLoader)
local HostLinkCommands = Shim.require(root.LinuxServer.HostLinkCommands)
local NetworkService = Shim.require(root.LinuxServer.NetworkService)
local OfficialPackages = Shim.require(root.LinuxServer.OfficialPackages)
local WorkshopService = Shim.require(root.LinuxServer.WorkshopService)

local imageCache = {}
local function loadImage(name)
	if imageCache[name] == nil then
		local mod = root.LinuxImages:FindFirstChild(name)
		if mod then
			local info = Shim.require(mod)
			local chunks = {}
			for n = 1, info.chunks do
				chunks[n] = Shim.require(mod[string.format("Chunk%03d", n)])
			end
			imageCache[name] = ImageLoader.fromChunks(info, chunks)
		else
			imageCache[name] = false
		end
	end
	return imageCache[name] or nil
end

local function memoryStore()
	local data = {}
	return {
		GetAsync = function(_, key) return data[key] end,
		SetAsync = function(_, key, value) data[key] = value end,
		RemoveAsync = function(_, key) data[key] = nil end,
		UpdateAsync = function(_, key, fn) data[key] = fn(data[key]); return data[key] end,
	}
end

local workshop = WorkshopService.new({ store = memoryStore(), official = OfficialPackages.build() })
local network = NetworkService.new()
local commands = HostLinkCommands.new(workshop, network)
local WorkshopWeb = Shim.require(root.LinuxServer.WorkshopWeb)
network:serveHttp(function(request, respond)
	respond(WorkshopWeb.handle(workshop, request))
end)

local computers = {}
local order = {}
local nextUserId = 1

local function getComputer(name)
	local c = computers[name]
	if c then
		return c
	end
	local userId = nextUserId
	nextUserId += 1
	local hostname = NetworkService.hostnameFor(name)
	local ipText, ipBytes, mac = network:allocateAddress()
	local computer = Computer.new({
		id = tostring(userId),
		ownerName = name,
		hostname = hostname,
		ip = ipText,
		mac = mac,
		disk = Disk.new(32 * 1024 * 1024),
		loadImage = loadImage,
	})
	local owner = { userId = userId, name = name }
	computer.hostLinkHandler = function(command, args, payload, reply)
		local ok, err = pcall(commands.run, commands, owner, command, args, payload, reply)
		if not ok then
			reply(false, "hostlink: " .. tostring(err))
		end
	end
	local endpoint = {
		hostname = hostname,
		ip = ipBytes,
		mac = mac,
		owner = name,
		userId = userId,
		deliver = function(frame)
			computer:receiveFrame(frame)
		end,
	}
	computer.onFrame = function(frame)
		network:transmit(endpoint, frame)
	end
	network:attach(endpoint)
	c = { computer = computer, name = name }
	computers[name] = c
	table.insert(order, name)
	computer:pressPower(os.clock())
	return c
end

local settle

local function runAll(seconds)
	local t = os.clock()
	while os.clock() - t < seconds do
		local now = os.clock()
		for _, name in order do
			local computer = computers[name].computer
			computer:update(now, 0.01)
			computer:takeStream(now)
		end
		network:tick()
	end
end

local function atPrompt(computer)
	local term = computer.terminal
	local line = string.sub(term:getLineText(term.cursorRow), 1, term.cursorCol - 1)
	return string.match(line, "[#$] $") ~= nil
end

-- Runs until every computer is idle at a prompt (or timeout).
function settle(timeout)
	local t = os.clock()
	local lastVersions = {}
	local still = 0
	while os.clock() - t < timeout do
		runAll(0.2)
		local changed = false
		local allPrompt = true
		for _, name in order do
			local computer = computers[name].computer
			if lastVersions[name] ~= computer.terminal.version then
				changed = true
				lastVersions[name] = computer.terminal.version
			end
			if not atPrompt(computer) then
				allPrompt = false
			end
		end
		if changed then
			still = 0
		else
			still += 1
		end
		if allPrompt and still >= 3 then
			return true
		end
	end
	return false
end

local function screen(name)
	return computers[name].computer.terminal:toText()
end

local lines = {}
local args = process.args
local i = 1
while i <= #args do
	if args[i] == "-e" then
		table.insert(lines, args[i + 1])
		i += 2
	else
		for line in string.gmatch(fs.readFile(args[i]) .. "\n", "([^\n]*)\n") do
			table.insert(lines, line)
		end
		i += 1
	end
end

local failures = 0
for _, line in lines do
	if line == "" or string.sub(line, 1, 1) == "#" then
		continue
	end
	local cmd, rest = string.match(line, "^@(%a+)%s*(.*)$")
	if cmd == "wait" then
		runAll(tonumber(rest) or 1)
	elseif cmd == "peek" then
		local who, label = string.match(rest, "^(%S+)%s*(.*)$")
		local term = getComputer(who).computer.terminal
		print(string.format("----- %s %s (cursor %d,%d) -----", who, label, term.cursorRow, term.cursorCol))
		local text = string.gsub(term:toText(), "\n~", "")
		print(text)
	elseif cmd == "screen" then
		getComputer(rest)
		settle(60)
		print(string.format("===== %s =====", rest))
		print(screen(rest))
	elseif cmd == "expect" then
		local who, text = string.match(rest, "^(%S+)%s+(.+)$")
		getComputer(who)
		settle(60)
		if string.find(screen(who), text, 1, true) then
			print(string.format("ok   %s shows %q", who, text))
		else
			failures += 1
			print(string.format("FAIL %s does not show %q", who, text))
			print(screen(who))
		end
	elseif cmd == "disk" then
		local disk = getComputer(rest).computer.disk
		local mbr = buffer.create(512)
		disk:readInto(0, 512, mbr, 0)
		print(string.format("[disk %s] %d blocks used, generation %d, MBR signature %02x%02x",
			rest, disk:usedBlocks(), disk.generation, buffer.readu8(mbr, 510), buffer.readu8(mbr, 511)))
	elseif cmd == "reboot" then
		local c = getComputer(rest)
		c.computer:pressPower(os.clock())
		c.computer:pressPower(os.clock())
	else
		local who, input = string.match(line, "^(%S+):%s?(.*)$")
		if who then
			local isNew = computers[who] == nil
			local c = getComputer(who)
			if isNew then
				settle(120) -- let it boot before typing anything
			end
			local raw = string.match(input, "^!keys (.*)$")
			-- Raw keys go to interactive programs (fdisk, vi...), so don't wait for a shell prompt.
			if not raw and not settle(120) then
				print("(warning: not every computer reached a prompt before typing)")
			end
			if raw then
				raw = string.gsub(raw, "\\r", "\r")
				raw = string.gsub(raw, "\\n", "\n")
				raw = string.gsub(raw, "\\e", "\27")
				raw = string.gsub(raw, "\\x(%x%x)", function(hex)
					return string.char(tonumber(hex, 16) :: number)
				end)
				c.computer:input(raw)
				runAll(1.5)
			else
				c.computer:input(input .. "\r")
				settle(120)
			end
		else
			print("? " .. line)
		end
	end
end
print(string.format("%d expectation(s) failed", failures))
process.exit(if failures == 0 then 0 else 1)
