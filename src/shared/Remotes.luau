--!strict
--[[
	The RemoteEvents/RemoteFunctions the game uses. The server creates them on
	first use; clients wait for them.

		TerminalOutput  server -> client  (computerId, kind, payload)
		                kind "data": raw console bytes
		                kind "snapshot": full Terminal snapshot
		                kind "state": computer state ("off" | "firmware" | "running")
		TerminalInput   client -> server  (bytes) keyboard input for the computer you're using
		ComputerAction  client -> server  (action, ...) "leave" | "power" | "reset"
		Workshop        client -> server  RemoteFunction (action, ...) browse the Community Workshop
		Notify          server -> client  (message) short toast for the player
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

local EVENTS = { "TerminalOutput", "TerminalInput", "ComputerAction", "Notify" }
local FUNCTIONS = { "Workshop" }
local FOLDER_NAME = "LinuxRemotes"

local function getFolder(): Folder
	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			for _, name in EVENTS do
				local e = Instance.new("RemoteEvent")
				e.Name = name
				e.Parent = folder
			end
			for _, name in FUNCTIONS do
				local f = Instance.new("RemoteFunction")
				f.Name = name
				f.Parent = folder
			end
			folder.Parent = ReplicatedStorage
		end
		return folder :: Folder
	end
	return ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
end

function Remotes.event(name: string): RemoteEvent
	return getFolder():WaitForChild(name) :: RemoteEvent
end

function Remotes.func(name: string): RemoteFunction
	return getFolder():WaitForChild(name) :: RemoteFunction
end

return Remotes
