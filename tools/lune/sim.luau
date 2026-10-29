--[[
	Runs the actual Roblox server and client scripts against RobloxMock: one
	player walks up to a desk, powers on, boots Linux, types a command, opens
	the Workshop, and leaves. Catches Roblox API mistakes (bad property or enum
	names, nil indexing) that unit tests can't.

	lune run tools/lune/sim.luau
]]
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")
local Shim = require("./RobloxShim")
local Mock = require("./RobloxMock")

local world = Mock.createWorld()
local serverTree = Shim.mountMany(
	{ LinuxVM = "src/shared", LinuxServer = "src/server", LinuxImages = "src/images" },
	{ native = true, inject = world.globals("server") }
)
local clientTree = Shim.mountMany(
	{ LinuxVM = "src/shared", LinuxClient = "src/client" },
	{ native = true, inject = world.globals("client") }
)
world.mounts.server.ReplicatedStorage = { LinuxVM = serverTree.LinuxVM }
world.mounts.server.ServerStorage = { LinuxImages = serverTree.LinuxImages }
world.mounts.client.ReplicatedStorage = { LinuxVM = clientTree.LinuxVM }

local failures = 0
local function check(ok, what)
	if ok then
		print("ok   " .. what)
	else
		failures += 1
		print("FAIL " .. what)
	end
end

local function pump(seconds)
	local t = os.clock()
	while os.clock() - t < seconds do
		world.heartbeat:Fire(1 / 60)
		world.renderStepped:Fire(1 / 60)
		task.wait(0.004)
	end
end

-- Build a desk like the one the owner will make in Studio.
local desk = Mock.new("Model")
desk.Name = "Desk"
local screen = Mock.new("Part")
screen.Name = "Screen"
screen.Size = roblox.Vector3.new(4, 2.5, 0.2)
screen.CFrame = roblox.CFrame.new(0, 5, 0)
screen.Parent = desk
local seat = Mock.new("Seat")
seat.Parent = desk
local power = Mock.new("Part")
power.Name = "PowerButton"
power.Parent = desk
local escKey = Mock.new("Part")
escKey.Name = "Key_Escape"
escKey.Parent = desk
desk.Parent = world.Workspace
Mock.unwrap(desk):AddTag("LinuxComputer")
local kiosk = Mock.new("Part")
kiosk.Name = "Kiosk"
kiosk.Parent = world.Workspace
Mock.unwrap(kiosk):AddTag("WorkshopKiosk")

-- Server
local ComputerService = Shim.require(serverTree.LinuxServer.ComputerService)
ComputerService.start()
check(screen:FindFirstChild("UseComputerPrompt") ~= nil, "server added a ProximityPrompt to the screen")
check(escKey:FindFirstChildOfClass("ClickDetector") ~= nil, "server made Key_Escape clickable")

-- A player joins and their client starts.
local alice = world.addPlayer("Alice")
world.Players.LocalPlayer = alice
Mock.localPlayer = alice
local ComputerController = Shim.require(clientTree.LinuxClient.ComputerController)
local WorkshopGui = Shim.require(clientTree.LinuxClient.WorkshopGui)
ComputerController.openWorkshop = WorkshopGui.start()
ComputerController.start()
pump(0.5)

local playerGui = alice:FindFirstChild("PlayerGui")
check(playerGui:FindFirstChild("LinuxScreen") ~= nil, "client put a screen on the desk")

-- Use the desk.
screen:FindFirstChild("UseComputerPrompt").Triggered:Fire(alice)
pump(1)
check(desk:GetAttribute("InUseBy") == alice.UserId, "desk is marked in use by Alice")
local keyboard = playerGui:FindFirstChild("LinuxKeyboard")
check(keyboard ~= nil, "focus mode shows the on-screen keyboard")
check(world.boundActions.LinuxComputerKeyboard ~= nil, "keyboard input is captured")
check(world.camera.CameraType == roblox.Enum.CameraType.Scriptable, "camera moved to the screen")

local function screenText(): string
	local gui = playerGui:FindFirstChild("LinuxScreen")
	local rows = gui and gui:FindFirstChild("Rows", true)
	if not rows then
		return ""
	end
	local lines = {}
	for i = 1, 25 do
		local label = rows:FindFirstChild("Row" .. i)
		local text = if label then label.Text else ""
		text = string.gsub(text, "<[^>]*>", "")
		text = string.gsub(text, "&lt;", "<")
		text = string.gsub(text, "&gt;", ">")
		text = string.gsub(text, "&amp;", "&")
		text = string.gsub(text, "&quot;", '"')
		text = string.gsub(text, "&apos;", "'")
		lines[i] = text
	end
	return table.concat(lines, "\n")
end

-- Power on with the on-screen button.
local powerButton = keyboard:FindFirstChild("⏻ Power", true)
check(powerButton ~= nil, "on-screen Power button exists")
powerButton.Activated:Fire()
pump(1.5)
check(string.find(screenText(), "BrickBIOS", 1, true) ~= nil or string.find(screenText(), "Memory", 1, true) ~= nil, "firmware screen shows on the desk")
check(desk:GetAttribute("FlashDrive") == false, "desk has a FlashDrive attribute (no drive yet)")
check(string.find(screenText(), "No bootable device", 1, true) ~= nil, "empty disk and no flash drive: nothing to boot")

-- The game's flash drive mechanic plugs the installer in; the firmware notices.
desk:SetAttribute("FlashDrive", true)
pump(1.5)
check(string.find(screenText(), "installer flash drive", 1, true) ~= nil, "firmware sees the flash drive")

local deadline = os.clock() + 60
while os.clock() < deadline and not string.find(screenText(), "root@alice", 1, true) do
	pump(0.5)
end
check(string.find(screenText(), "root@alice", 1, true) ~= nil, "Linux booted to a shell prompt on the desk screen")

-- Type with the real keyboard path (ContextActionService callback).
local function typeKey(name: string, shift: boolean?)
	local action = world.boundActions.LinuxComputerKeyboard
	world.keysDown.LeftShift = shift or nil
	local input = { UserInputType = roblox.Enum.UserInputType.Keyboard, KeyCode = (roblox.Enum.KeyCode :: any)[name] }
	action("LinuxComputerKeyboard", roblox.Enum.UserInputState.Begin, input)
	action("LinuxComputerKeyboard", roblox.Enum.UserInputState.End, input)
	world.keysDown.LeftShift = nil
end
local names = { e = "E", c = "C", h = "H", o = "O", i = "I", [" "] = "Space", r = "R", k = "K", b = "B" }
for ch in string.gmatch("echo hi brick", ".") do
	typeKey(names[ch])
end
typeKey("Return")
pump(3)
check(string.find(screenText(), "hi brick", 1, true) ~= nil, "typing reaches the computer and output comes back")

-- Esc via the physical key part.
escKey:FindFirstChildOfClass("ClickDetector").MouseClick:Fire(alice)
pump(0.2)

-- Workshop GUI
local workshopGui = playerGui:FindFirstChild("Workshop")
workshopGui:FindFirstChild("WorkshopButton").Activated:Fire()
pump(1)
local results = workshopGui:FindFirstChild("Results", true)
local cards = 0
for _, child in results:GetChildren() do
	if child:IsA("TextButton") then
		cards += 1
	end
end
check(cards >= 5, "workshop lists packages (" .. cards .. ")")
local cowsay = results:FindFirstChild("cowsay")
if cowsay then
	cowsay.Activated:Fire()
	pump(0.5)
end
local details = workshopGui:FindFirstChild("Details", true)
local install
for _, d in details:GetDescendants() do
	if d:IsA("TextButton") and d.Text == "Install on my computer" then
		install = d
	end
end
check(install ~= nil, "package details show an install button")
if install then
	install.Activated:Fire()
	pump(2)
	check(string.find(screenText(), "brick install cowsay", 1, true) ~= nil, "install button typed the command on the computer")
end

-- Leave
keyboard:FindFirstChild("⏏ Leave", true).Activated:Fire()
pump(0.5)
check(playerGui:FindFirstChild("LinuxKeyboard") == nil, "leaving closes the keyboard")
check(desk:GetAttribute("InUseBy") == 0, "desk is free again")

-- Leaving the game saves the disk.
world.Players.PlayerRemoving:Fire(alice)
pump(1)

print(string.format("%d signal errors", #Mock.errors))
for _, e in Mock.errors do
	print("  " .. e)
end
print(string.format("%d check(s) failed", failures))
process.exit(if failures == 0 and #Mock.errors == 0 then 0 else 1)
