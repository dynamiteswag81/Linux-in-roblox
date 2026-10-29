--!strict
--[[
	Commands guest programs can send to the game through the host link
	(`hostlink <command> [args]` inside Brick Linux; `brick` is built on these).

		pkg.search <words>     search the Community Workshop
		pkg.info <name>        package details
		pkg.get <name>         package archive (tar)
		pkg.version <name>     latest version string
		pkg.publish <name>     publish the tar archive sent as payload
		pkg.unpublish <name>   remove one of your packages from the workshop
		msg.send <user> <text> send a message to another player's computer (filtered)
		msg.recv               take this computer's waiting messages
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
local MAX_MESSAGE = 200
local MAX_INBOX = 50
local MESSAGE_COOLDOWN = 1

local HostLinkCommands = {}
HostLinkCommands.__index = HostLinkCommands

export type Owner = { userId: number, name: string }

export type Options = {
	now: (() -> number)?,
	-- Filters a message from one player for another (TextService in the game).
	-- Errors if filtering isn't possible; the message is then not delivered.
	filterMessage: ((text: string, fromUserId: number, toUserId: number) -> string)?,
	-- Tells the recipient's game client about a new message (a toast).
	notifyMessage: ((toUserId: number, fromName: string, text: string) -> ())?,
}

type Message = { from: string, text: string, time: number }

export type HostLinkCommands = typeof(setmetatable(
	{} :: {
		workshop: WorkshopService.WorkshopService,
		network: NetworkService.NetworkService,
		lastPublish: { [number]: number },
		lastMessage: { [number]: number },
		inboxes: { [number]: { Message } },
		options: Options,
		now: () -> number,
	},
	HostLinkCommands
))

function HostLinkCommands.new(
	workshop: WorkshopService.WorkshopService,
	network: NetworkService.NetworkService,
	options: Options?
): HostLinkCommands
	local opts = options or {}
	return setmetatable({
		workshop = workshop,
		network = network,
		lastPublish = {},
		lastMessage = {},
		inboxes = {},
		options = opts,
		now = opts.now or os.time,
	}, HostLinkCommands)
end

-- Forgets a player's waiting messages (when they leave).
function HostLinkCommands.forget(self: HostLinkCommands, userId: number)
	self.inboxes[userId] = nil
	self.lastMessage[userId] = nil
	self.lastPublish[userId] = nil
end

function HostLinkCommands._send(self: HostLinkCommands, owner: Owner, args: { string }): (boolean, string)
	local to = args[1] or ""
	local text = table.concat(args, " ", 2)
	text = string.gsub(text, "[%c]", " ")
	if to == "" or text == "" then
		return false, "usage: msg <user> <message>"
	end
	if #text > MAX_MESSAGE then
		return false, string.format("msg: messages can be at most %d characters", MAX_MESSAGE)
	end
	local now = self.now()
	local last = self.lastMessage[owner.userId]
	if last and now - last < MESSAGE_COOLDOWN then
		return false, "msg: slow down a little"
	end
	local target = self.network:find(to)
	if not target or not target.userId then
		return false, "msg: " .. to .. " isn't online"
	end
	local toUserId = target.userId :: number
	local filter = self.options.filterMessage
	if filter then
		local ok, filtered = pcall(filter, text, owner.userId, toUserId)
		if not ok then
			return false, "msg: the message couldn't be delivered (filtering unavailable)"
		end
		text = filtered
	end
	self.lastMessage[owner.userId] = now
	local inbox = self.inboxes[toUserId] or {}
	self.inboxes[toUserId] = inbox
	table.insert(inbox, { from = owner.name, text = text, time = now })
	while #inbox > MAX_INBOX do
		table.remove(inbox, 1)
	end
	local notify = self.options.notifyMessage
	if notify then
		pcall(notify, toUserId, owner.name, text)
	end
	return true, "Sent to " .. target.owner .. ".\n"
end

function HostLinkCommands._receive(self: HostLinkCommands, owner: Owner): string
	local inbox = self.inboxes[owner.userId]
	if not inbox or #inbox == 0 then
		return ""
	end
	self.inboxes[owner.userId] = nil
	local lines = {}
	for _, m in inbox do
		table.insert(lines, string.format("[%s] %s: %s", os.date("!%H:%M", m.time), m.from, m.text))
	end
	return table.concat(lines, "\n") .. "\n"
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
	elseif command == "pkg.unpublish" then
		local ok, message = self.workshop:unpublish(owner.userId, arg)
		reply(ok, message .. "\n")
	elseif command == "msg.send" then
		reply(self:_send(owner, args))
	elseif command == "msg.recv" then
		reply(true, self:_receive(owner))
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
			"pkg.search pkg.info pkg.get pkg.version pkg.publish pkg.unpublish msg.send msg.recv net.who net.hosts sys.whoami sys.time\n"
		)
	else
		reply(false, "hostlink: unknown command '" .. command .. "' (try: hostlink help)")
	end
end

return HostLinkCommands
