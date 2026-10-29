--!strict
--[[
	SiFive-compatible PLIC (platform-level interrupt controller), one context
	(hart 0, machine mode). Devices drive level-triggered lines with setLevel();
	the PLIC raises the CPU's machine external interrupt (MEIP) when an enabled
	source with priority above the threshold is pending.

	Register map (offsets from the PLIC base):
		0x000000 + 4*src   priority
		0x001000           pending bits (read only)
		0x002000           enable bits for context 0
		0x200000           priority threshold for context 0
		0x200004           claim (read) / complete (write) for context 0
]]

local Plic = {}
Plic.__index = Plic

local NUM_SOURCES = 32

export type Plic = typeof(setmetatable(
	{} :: {
		priority: { number },
		level: { boolean },
		pending: { boolean },
		inService: { boolean },
		enable: number,
		threshold: number,
		-- Called whenever the external interrupt line to the CPU changes.
		onChange: (asserted: boolean) -> (),
		asserted: boolean,
	},
	Plic
))

function Plic.new(onChange: (asserted: boolean) -> ()): Plic
	local self = setmetatable({
		priority = table.create(NUM_SOURCES, 0),
		level = table.create(NUM_SOURCES, false),
		pending = table.create(NUM_SOURCES, false),
		inService = table.create(NUM_SOURCES, false),
		enable = 0,
		threshold = 0,
		onChange = onChange,
		asserted = false,
	}, Plic)
	return self
end

function Plic.reset(self: Plic)
	for i = 1, NUM_SOURCES do
		self.priority[i] = 0
		self.level[i] = false
		self.pending[i] = false
		self.inService[i] = false
	end
	self.enable = 0
	self.threshold = 0
	self:_update()
end

function Plic._best(self: Plic): number
	local best, bestPriority = 0, self.threshold
	for src = 1, NUM_SOURCES - 1 do
		if self.pending[src] and bit32.btest(self.enable, bit32.lshift(1, src)) then
			local p = self.priority[src]
			if p > bestPriority then
				best, bestPriority = src, p
			end
		end
	end
	return best
end

function Plic._update(self: Plic)
	local asserted = self:_best() ~= 0
	if asserted ~= self.asserted then
		self.asserted = asserted
		self.onChange(asserted)
	end
end

-- Drives interrupt line `src` (1..31) high or low.
function Plic.setLevel(self: Plic, src: number, high: boolean)
	self.level[src] = high
	if high and not self.inService[src] then
		self.pending[src] = true
	end
	self:_update()
end

function Plic.read(self: Plic, offset: number): number
	if offset < 0x1000 then
		return self.priority[offset // 4] or 0
	elseif offset == 0x1000 then
		local bits = 0
		for src = 1, NUM_SOURCES - 1 do
			if self.pending[src] then
				bits = bit32.bor(bits, bit32.lshift(1, src))
			end
		end
		return bits
	elseif offset == 0x2000 then
		return self.enable
	elseif offset == 0x200000 then
		return self.threshold
	elseif offset == 0x200004 then
		local src = self:_best()
		if src ~= 0 then
			self.pending[src] = false
			self.inService[src] = true
			self:_update()
		end
		return src
	end
	return 0
end

function Plic.write(self: Plic, offset: number, value: number)
	if offset < 0x1000 then
		local src = offset // 4
		if src >= 1 and src < NUM_SOURCES then
			self.priority[src] = bit32.band(value, 7)
		end
	elseif offset == 0x2000 then
		self.enable = value
	elseif offset == 0x200000 then
		self.threshold = bit32.band(value, 7)
	elseif offset == 0x200004 then
		local src = value
		if src >= 1 and src < NUM_SOURCES and self.inService[src] then
			self.inService[src] = false
			-- Level-triggered: still asserted means pending again.
			if self.level[src] then
				self.pending[src] = true
			end
		end
	else
		return
	end
	self:_update()
end

return Plic
