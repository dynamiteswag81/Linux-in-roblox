--!strict
--[[
	Where server modules find the shared LinuxVM modules: ReplicatedStorage in
	Roblox, or the sibling folder the Lune test harness mounts.
]]
if game then
	return game:GetService("ReplicatedStorage"):WaitForChild("LinuxVM")
end
return (script :: any).Parent.Parent.LinuxVM
