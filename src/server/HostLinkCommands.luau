--!strict
--[[
	Commands guest programs can send to the game through the host link
	(`hostlink <command> [args]` inside Brick Linux; `brick` is built on these).

		pkg.search <words>     search the Community Workshop
		pkg.info <name>        package details
		pkg.get <name>         package archive (tar)
		pkg.version <name>     latest version string
		pkg.publish <name>     publish the tar archive sent as payload
		net.who                computers on the network: name, address, owner
		net.hosts              the same as /etc/hosts lines
		sys.whoami             the Roblox user who owns this computer
		sys.time               current Unix time
		help                   this list
]]

local NetworkService = require(script.Parent.NetworkService)
local Packet = require(script.Parent.Net.Packet)
local WorkshopService = require(script.Parent.WorkshopService)

local PUBLISH_COOLDOWN = 20

local HostLinkCommands = {}
HostLinkCommands.__index = HostLinkCommands

export type Owner = { userId: number, name: string }

export type HostLinkCommands = typeof(setmetatable(
	{} :: {
		workshop: WorkshopService.WorkshopService,
		network: NetworkService.NetworkService,
		lastPublish: { [number]: number },
		now: () -> number,
	},
	HostLinkCommands
))

function HostLinkCommands.new(
	workshop: WorkshopService.WorkshopService,
	network: NetworkService.NetworkService,
	now: (() -> number)?
): HostLinkCommands
	return setmetatable({
		workshop = workshop,
		network = network,
		lastPublish = {},
		now = now or os.time,
	}, HostLinkCommands)
end

local function formatSize(bytes: number): string
	if bytes >= 1024 * 1024 then
		return string.format("%.1f MiB", bytes / 1048576)
	elseif bytes >= 1024 then
		return string.format("%.1f KiB", bytes / 1024)
	end
	return bytes .. " B"
end

function HostLinkCommands._search(self: HostLinkCommands, query: string): string
	local results = self.workshop:search(query, "popular", 40)
	if #results == 0 then
		return "No packages match '" .. query .. "'. Try: brick search\n"
	end
	local out = {}
	for _, r in results do
		local tag = if r.official
			then "\27[1;36m[official]\27[0m"
			else string.format("(by %s, %d download%s)", r.author, r.downloads, if r.downloads == 1 then "" else "s")
		table.insert(out, string.format("\27[1;35mworkshop/\27[0;1m%s \27[1;32m%s\27[0m %s", r.name, r.version, tag))
		table.insert(out, "    " .. r.description)
	end
	return table.concat(out, "\n") .. "\n"
end

function HostLinkCommands._info(self: HostLinkCommands, name: string): (boolean, string)
	local d = self.workshop:getDetails(name)
	if not d then
		return false, "brick: package '" .. name .. "' was not found in the Community Workshop"
	end
	local lines = {
		"Name            : " .. d.name,
		"Version         : " .. d.version,
		"Description     : " .. d.description,
		"Author          : " .. d.authorName .. (if d.official then " (official)" else ""),
		"Depends On      : " .. (if #d.depends > 0 then table.concat(d.depends, " ") else "None"),
		"Download Size   : " .. formatSize(d.size),
		"Downloads       : " .. tostring(d.downloads),
	}
	if d.updated > 0 then
		table.insert(lines, "Last Updated    : " .. os.date("!%Y-%m-%d %H:%M UTC", d.updated))
	end
	if #d.files > 0 then
		local shown = {}
		for i = 1, math.min(#d.files, 10) do
			shown[i] = d.files[i]
		end
		local more = if #d.files > 10 then string.format(" (+%d more)", #d.files - 10) else ""
		table.insert(lines, "Files           : " .. table.concat(shown, "\n                  ") .. more)
	end
	if d.readme ~= "" then
		table.insert(lines, "")
		table.insert(lines, (string.gsub(d.readme, "\n+$", "")))
	end
	return true, table.concat(lines, "\n") .. "\n"
end

function HostLinkCommands._who(self: HostLinkCommands, hostsFormat: boolean): string
	local out = {}
	if hostsFormat then
		table.insert(out, "127.0.0.1\tlocalhost")
		table.insert(out, "10.0.0.1\tgateway workshop")
	end
	for _, e in self.network:list() do
		if hostsFormat then
			table.insert(out, Packet.ipToString(e.ip) .. "\t" .. e.hostname)
		else
			table.insert(out, string.format("%-20s %-12s %s", e.hostname, Packet.ipToString(e.ip), e.owner))
		end
	end
	return table.concat(out, "\n") .. "\n"
end

--[[
	Runs one command. `reply` may be called later (workshop calls yield), so
	callers should run this in its own thread.
]]
function HostLinkCommands.run(
	self: HostLinkCommands,
	owner: Owner,
	command: string,
	args: { string },
	payload: string,
	reply: (ok: boolean, data: string) -> ()
)
	local arg = args[1] or ""
	if command == "pkg.search" then
		reply(true, self:_search(table.concat(args, " ")))
	elseif command == "pkg.info" then
		reply(self:_info(arg))
	elseif command == "pkg.get" then
		local tar = self.workshop:download(arg)
		if tar then
			reply(true, tar)
		else
			reply(false, "brick: package '" .. arg .. "' was not found in the Community Workshop")
		end
	elseif command == "pkg.version" then
		local d = self.workshop:getDetails(arg)
		if d then
			reply(true, d.version)
		else
			reply(false, "not found")
		end
	elseif command == "pkg.publish" then
		local now = self.now()
		local last = self.lastPublish[owner.userId]
		if last and now - last < PUBLISH_COOLDOWN then
			reply(false, string.format("brick: please wait %d seconds before publishing again", PUBLISH_COOLDOWN - (now - last)))
			return
		end
		self.lastPublish[owner.userId] = now
		local ok, message = self.workshop:publish(owner.userId, owner.name, arg, payload)
		reply(ok, message .. "\n")
	elseif command == "net.who" then
		reply(true, self:_who(false))
	elseif command == "net.hosts" then
		reply(true, self:_who(true))
	elseif command == "sys.whoami" then
		reply(true, owner.name .. "\n")
	elseif command == "sys.time" then
		reply(true, tostring(os.time()) .. "\n")
	elseif command == "help" then
		reply(
			true,
			"pkg.search pkg.info pkg.get pkg.version pkg.publish net.who net.hosts sys.whoami sys.time\n"
		)
	else
		reply(false, "hostlink: unknown command '" .. command .. "' (try: hostlink help)")
	end
end

return HostLinkCommands
