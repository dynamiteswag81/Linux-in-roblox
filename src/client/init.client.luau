--[[
	Linux in Roblox: client entry point.
]]
local ComputerController = require(script.ComputerController)
local WorkshopGui = require(script.WorkshopGui)

ComputerController.openWorkshop = WorkshopGui.start()
ComputerController.start()
