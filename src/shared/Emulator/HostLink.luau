--!strict
--[[
	Host link: an MMIO mailbox the guest's `hostlink` tool uses to reach the game
	(package manager, Community Workshop, player directory...). See
	linux/src/hostlink.c for the guest side and register layout.

	Requests arrive as `handler(command, args, payload, reply)`. The handler may
	answer immediately or later (e.g. after a DataStore call) by calling
	`reply(ok, data)` exactly once.
]]

local RAM_BASE = 0x80000000
local MAGIC = 0x4B435242 -- "BRCK"

local ST_IDLE = 0
local ST_BUSY = 1
local ST_OK = 2
local ST_ERR = 3
local ST_TOO_LARGE = 4

-- Guards against a guest asking for absurd allocations.
local MAX_REQUEST = 4 * 1024 * 1024

local HostLink = {}
HostLink.__index = HostLink

export type Handler = (command: string, args: { string }, payload: string, reply: (ok: boolean, data: string) -> ()) -> ()

export type HostLink = typeof(setmetatable(
	{} :: {
		ram: buffer,
		regs: { number },
		status: number,
		respLen: number,
		pending: string?,
		pendingOk: boolean,
		requestId: number,
		handler: Handler?,
	},
	HostLink
))

function HostLink.new(ram: buffer): HostLink
	return setmetatable({
		ram = ram,
		regs = { 0, 0, 0, 0 }, -- REQ_ADDR, REQ_LEN, RESP_ADDR, RESP_CAP
		status = ST_IDLE,
		respLen = 0,
		pending = nil,
		pendingOk = false,
		requestId = 0,
		handler = nil,
	}, HostLink)
end

function HostLink.reset(self: HostLink)
	self.regs = { 0, 0, 0, 0 }
	self.status = ST_IDLE
	self.respLen = 0
	self.pending = nil
	-- Invalidates replies to requests made before the reset.
	self.requestId += 1
end

function HostLink.read(self: HostLink, offset: number): number
	if offset < 0x10 then
		return self.regs[offset // 4 + 1]
	elseif offset == 0x14 then
		return self.status
	elseif offset == 0x18 then
		return self.respLen
	elseif offset == 0x1C then
		return MAGIC
	end
	return 0
end

function HostLink._copyOut(self: HostLink)
	local data = self.pending :: string
	local cap = self.regs[4]
	local addr = self.regs[3] - RAM_BASE
	self.respLen = #data
	if #data > cap then
		self.status = ST_TOO_LARGE
		return
	end
	if addr < 0 or addr + #data > buffer.len(self.ram) then
		self.status = ST_ERR
		self.respLen = 0
		self.pending = nil
		return
	end
	buffer.writestring(self.ram, addr, data)
	self.status = if self.pendingOk then ST_OK else ST_ERR
	self.pending = nil
end

function HostLink._submit(self: HostLink)
	if self.status == ST_BUSY then
		return
	end
	local addr = self.regs[1] - RAM_BASE
	local len = self.regs[2]
	if addr < 0 or len > MAX_REQUEST or addr + len > buffer.len(self.ram) then
		self.pending, self.pendingOk = "hostlink: bad request buffer", false
		self:_copyOut()
		return
	end
	local raw = buffer.readstring(self.ram, addr, len)
	local newline = string.find(raw, "\n", 1, true) or (#raw + 1)
	local args = string.split(string.sub(raw, 1, newline - 1), "\t")
	local command = table.remove(args, 1) or ""
	local payload = string.sub(raw, newline + 1)

	self.status = ST_BUSY
	self.requestId += 1
	local id = self.requestId
	local answered = false
	local function reply(ok: boolean, data: string)
		if answered or id ~= self.requestId then
			return
		end
		answered = true
		self.pending, self.pendingOk = data, ok
		self:_copyOut()
	end

	local handler = self.handler
	if not handler then
		reply(false, "hostlink: nothing is listening on the host")
		return
	end
	local ok, err = pcall(handler, command, args, payload, reply)
	if not ok then
		reply(false, "hostlink: host error: " .. tostring(err))
	end
end

function HostLink.write(self: HostLink, offset: number, value: number)
	if offset < 0x10 then
		self.regs[offset // 4 + 1] = value
	elseif offset == 0x10 then
		if value == 1 then
			self:_submit()
		elseif value == 2 and self.status == ST_TOO_LARGE and self.pending then
			self:_copyOut()
		end
	end
end

return HostLink
