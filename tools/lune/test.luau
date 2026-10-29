--[[
	Runs every tests/*.spec.luau file. Each spec returns a function that receives
	`test(name, fn)` plus the mounted LinuxVM tree, and uses assert/error.

	lune run tools/lune/test.luau
]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local Shim = require("./RobloxShim")

local root = Shim.mountMany({ LinuxVM = "src/shared", LinuxServer = "src/server", LinuxImages = "src/images" })
local passed, failed = 0, 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print(string.format("FAIL %s\n     %s", name, tostring(err)))
	end
end

local files = fs.readDir("tests")
table.sort(files)
for _, file in files do
	if string.match(file, "%.spec%.luau$") then
		local chunk = luau.load(fs.readFile("tests/" .. file), { debugName = "tests/" .. file })
		local spec = chunk()
		spec(test, root, Shim.require)
	end
end

print(string.format("%d passed, %d failed", passed, failed))
process.exit(if failed == 0 then 0 else 1)
