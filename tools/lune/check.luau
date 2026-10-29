--[[
	Compiles every .luau file in the repository to catch syntax errors
	(useful for Roblox-only code the tests can't run).

	lune run tools/lune/check.luau
]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local failures = 0
local count = 0
local function walk(dir: string)
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			walk(path)
		elseif string.match(entry, "%.luau$") and not string.match(path, "src/images/") then
			count += 1
			local ok, err = pcall(luau.compile, fs.readFile(path))
			if not ok then
				failures += 1
				print(path .. ": " .. tostring(err))
			end
		end
	end
end
for _, dir in { "src", "tests", "tools" } do
	walk(dir)
end
print(string.format("%d files checked, %d with syntax errors", count, failures))
process.exit(if failures == 0 then 0 else 1)
