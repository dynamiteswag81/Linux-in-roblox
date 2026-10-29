--[[
	Tiny emulation of Roblox's `script` / `require(instance)` model for Lune.

	Lets the game's ModuleScripts (which use `require(script.Parent.Foo)`) run
	unchanged in the Lune test harness. Directory layout follows Rojo:
		Foo.luau          -> ModuleScript "Foo"
		Foo/init.luau     -> ModuleScript "Foo" with children
		Foo.server.luau   -> Script, Foo.client.luau -> LocalScript (not loadable here)

	Usage:
		local Shim = require("./RobloxShim")
		local root = Shim.mount("src/shared", "LinuxVM", { native = true })
		local Machine = Shim.require(root.Emulator.Machine)
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Shim = {}

type Node = {
	Name: string,
	Parent: Node?,
	ClassName: string,
	_path: string?, -- source file, if this is a script
	_dir: string?, -- directory, if it has children
	_children: { [string]: Node }?,
	_options: { native: boolean, inject: { [string]: any }? },
}

local nodeMeta = {}
local moduleCache: { [Node]: any } = {}

local sources: { [string]: string } = {}

-- Directory scanning and file reads can yield in Lune, which isn't allowed inside
-- metamethods, so the whole tree is built (and sources read) when mounted.
local function listChildren(node: Node): { [string]: Node }
	local cached = rawget(node :: any, "_children")
	if cached then
		return cached
	end
	local children: { [string]: Node } = {}
	local dir = rawget(node :: any, "_dir")
	if dir and fs.isDir(dir) then
		for _, entry in fs.readDir(dir) do
			local full = dir .. "/" .. entry
			local name, class, path, subdir
			if fs.isDir(full) then
				name = entry
				subdir = full
				if fs.isFile(full .. "/init.luau") then
					class, path = "ModuleScript", full .. "/init.luau"
				elseif fs.isFile(full .. "/init.server.luau") then
					class, path = "Script", full .. "/init.server.luau"
				elseif fs.isFile(full .. "/init.client.luau") then
					class, path = "LocalScript", full .. "/init.client.luau"
				else
					class = "Folder"
				end
			elseif string.match(entry, "%.server%.luau$") then
				name, class, path = string.gsub(entry, "%.server%.luau$", ""), "Script", full
			elseif string.match(entry, "%.client%.luau$") then
				name, class, path = string.gsub(entry, "%.client%.luau$", ""), "LocalScript", full
			elseif string.match(entry, "%.luau$") and not string.match(entry, "^init%.") then
				name, class, path = string.gsub(entry, "%.luau$", ""), "ModuleScript", full
			end
			if path then
				sources[path] = fs.readFile(path)
			end
			if name then
				children[name] = setmetatable({
					Name = name,
					Parent = node,
					ClassName = class,
					_path = path,
					_dir = subdir,
					_options = rawget(node :: any, "_options"),
				}, nodeMeta) :: any
			end
		end
	end
	rawset(node :: any, "_children", children)
	for _, child in children do
		listChildren(child)
	end
	return children
end

nodeMeta.__index = function(node: Node, key: string)
	local child = listChildren(node)[key]
	if child then
		return child
	end
	if key == "FindFirstChild" then
		return function(self: Node, name: string)
			return listChildren(self)[name]
		end
	elseif key == "WaitForChild" then
		return function(self: Node, name: string)
			local c = listChildren(self)[name]
			assert(c, "WaitForChild: no child " .. name)
			return c
		end
	elseif key == "GetChildren" then
		return function(self: Node)
			local list = {}
			for _, c in listChildren(self) do
				table.insert(list, c)
			end
			table.sort(list, function(a, b)
				return a.Name < b.Name
			end)
			return list
		end
	elseif key == "IsA" then
		return function(self: Node, class: string)
			return self.ClassName == class
		end
	end
	error(string.format("%s is not a valid member of %s", tostring(key), node.Name), 2)
end
nodeMeta.__tostring = function(node: Node)
	return node.Name
end

local function requireNode(node: Node): any
	local cached = moduleCache[node]
	if cached ~= nil then
		return cached
	end
	assert(node.ClassName == "ModuleScript", "Attempted to require a non-ModuleScript: " .. node.Name)
	local source = sources[node._path :: string]
	-- A custom environment table would disable Luau's builtin fastcalls (16x
	-- slower), so `script` and `require` are passed in as chunk arguments,
	-- declared on the first line after the `--!` directives to keep line numbers.
	-- Extra locals (Roblox globals like game, Enum, Instance) when a mount asks for them.
	local inject = node._options.inject
	local names, values = {}, {}
	if inject then
		for name, value in inject do
			table.insert(names, name)
			table.insert(values, value)
		end
	end
	local header = "local script, require" .. (if #names > 0 then ", " .. table.concat(names, ", ") else "") .. " = ...; "
	local lines = string.split(source, "\n")
	for i, line in lines do
		if string.sub(line, 1, 3) ~= "--!" then
			lines[i] = header .. line
			break
		end
	end
	local bytecode = luau.compile(table.concat(lines, "\n"), { optimizationLevel = 2, debugLevel = 1 })
	local chunk = luau.load(bytecode, {
		debugName = node._path,
		codegenEnabled = node._options.native,
	})
	local result = chunk(node, Shim.require, table.unpack(values))
	moduleCache[node] = result
	return result
end

function Shim.require(target: any): any
	if type(target) == "table" and getmetatable(target) == nodeMeta then
		return requireNode(target)
	end
	error("Shim.require expects a shimmed Instance, got " .. typeof(target))
end

-- Mounts a directory as a fake Instance tree and returns the root node.
function Shim.mount(dir: string, name: string, options: { native: boolean, inject: { [string]: any }? }?): any
	local root = setmetatable({
		Name = name,
		Parent = nil,
		ClassName = "Folder",
		_dir = dir,
		_options = options or { native = true },
	}, nodeMeta)
	listChildren(root)
	return root
end

-- Mounts several directories as siblings under one root folder, like the
-- game's tree (e.g. { LinuxVM = "src/shared", LinuxServer = "src/server" }).
function Shim.mountMany(dirs: { [string]: string }, options: { native: boolean, inject: { [string]: any }? }?): any
	local opts = options or { native = true }
	local root = setmetatable({
		Name = "game",
		Parent = nil,
		ClassName = "Folder",
		_children = {},
		_options = opts,
	}, nodeMeta)
	for name, dir in dirs do
		local child = Shim.mount(dir, name, opts)
		rawset(child, "Parent", root)
		rawget(root, "_children")[name] = child
	end
	return root
end

return Shim
