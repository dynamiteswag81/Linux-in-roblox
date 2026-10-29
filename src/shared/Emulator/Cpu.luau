--!native
--!optimize 2
--[[
	RV32IMA + Zicsr CPU core.

	Semantics follow cnlohr's mini-rv32ima (BSD/MIT/CC0), which is enough to boot
	a nommu Linux kernel: machine + user privilege levels, no MMU, a CLINT timer
	interrupt, and memory-mapped I/O handled by the owning Machine.

	Registers are stored as unsigned 32-bit integers (0 .. 2^32-1) held in Luau
	doubles. `regs[i + 1]` is register x<i>; regs[1] (x0) is always 0.

	Step return codes (same as mini-rv32ima):
		0       ran normally
		1       hart is waiting for an interrupt (WFI)
		0x5555  guest requested power off (syscon)
		0x7777  guest requested reboot (syscon)
]]

local band, bor, bxor = bit32.band, bit32.bor, bit32.bxor
local lshift, rshift, arshift, extract = bit32.lshift, bit32.rshift, bit32.arshift, bit32.extract
local readu32, readu16, readi16, readu8, readi8 = buffer.readu32, buffer.readu16, buffer.readi16, buffer.readu8, buffer.readi8
local writeu32, writeu16, writeu8 = buffer.writeu32, buffer.writeu16, buffer.writeu8
local fmod = math.fmod

local RAM_BASE = 0x80000000
local TWO32 = 4294967296

export type MmioHandler = {
	load: (addr: number) -> number,
	-- Returns a non-zero step code (e.g. 0x5555) to stop the CPU, otherwise 0/nil.
	store: (addr: number, value: number) -> number?,
	csrRead: (csr: number) -> number,
	csrWrite: (csr: number, value: number) -> (),
}

local Cpu = {}
Cpu.__index = Cpu

export type Cpu = typeof(setmetatable(
	{} :: {
		ram: buffer,
		ramSize: number,
		mmio: MmioHandler,
		regs: { number },
		pc: number,
		mstatus: number,
		cycle: number,
		timer: number,
		timermatch: number,
		mscratch: number,
		mtvec: number,
		mie: number,
		mip: number,
		mepc: number,
		mtval: number,
		mcause: number,
		priv: number,
		wfi: boolean,
		reservation: number,
		-- Machine external interrupt line, driven by the PLIC.
		meip: boolean,
	},
	Cpu
))

local function toSigned(x: number): number
	if x >= 0x80000000 then
		return x - TWO32
	end
	return x
end

-- High 32 bits of the unsigned 64-bit product a*b, using 16-bit limbs so every
-- intermediate stays exactly representable in a double.
local function mulhu(a: number, b: number): number
	local al, ah = band(a, 0xFFFF), rshift(a, 16)
	local bl, bh = band(b, 0xFFFF), rshift(b, 16)
	local mid = ah * bl + al * bh + rshift(al * bl, 16)
	return ah * bh + mid // 65536
end

-- Low 32 bits of a*b.
local function mullo(a: number, b: number): number
	local al, ah = band(a, 0xFFFF), rshift(a, 16)
	local bl, bh = band(b, 0xFFFF), rshift(b, 16)
	return band(al * bl + lshift(band(ah * bl + al * bh, 0xFFFF), 16), 0xFFFFFFFF)
end

local function mulh(a: number, b: number): number
	local r = mulhu(a, b)
	if a >= 0x80000000 then
		r -= b
	end
	if b >= 0x80000000 then
		r -= a
	end
	return band(r, 0xFFFFFFFF)
end

local function mulhsu(a: number, b: number): number
	local r = mulhu(a, b)
	if a >= 0x80000000 then
		r -= b
	end
	return band(r, 0xFFFFFFFF)
end

local function divs(a: number, b: number): number
	if b == 0 then
		return 0xFFFFFFFF
	elseif a == 0x80000000 and b == 0xFFFFFFFF then
		return a
	end
	local q = toSigned(a) / toSigned(b)
	if q < 0 then
		q = -((-q) // 1)
	else
		q = q // 1
	end
	return band(q, 0xFFFFFFFF)
end

local function rems(a: number, b: number): number
	if b == 0 then
		return a
	elseif a == 0x80000000 and b == 0xFFFFFFFF then
		return 0
	end
	return band(fmod(toSigned(a), toSigned(b)), 0xFFFFFFFF)
end

function Cpu.new(ram: buffer, mmio: MmioHandler): Cpu
	local regs = table.create(32, 0)
	local self = setmetatable({
		ram = ram,
		ramSize = buffer.len(ram),
		mmio = mmio,
		regs = regs,
		pc = RAM_BASE,
		mstatus = 0,
		cycle = 0,
		timer = 0,
		timermatch = 0,
		mscratch = 0,
		mtvec = 0,
		mie = 0,
		mip = 0,
		mepc = 0,
		mtval = 0,
		mcause = 0,
		priv = 3,
		wfi = false,
		reservation = -1,
		meip = false,
	}, Cpu)
	return self
end

function Cpu.reset(self: Cpu, pc: number, a0: number, a1: number)
	table.clear(self.regs)
	for i = 1, 32 do
		self.regs[i] = 0
	end
	self.regs[11] = a0
	self.regs[12] = a1
	self.pc = pc
	self.mstatus = 0
	self.cycle = 0
	self.timer = 0
	self.timermatch = 0
	self.mscratch = 0
	self.mtvec = 0
	self.mie = 0
	self.mip = 0
	self.mepc = 0
	self.mtval = 0
	self.mcause = 0
	self.priv = 3
	self.wfi = false
	self.reservation = -1
	self.meip = false
end

local function readCsr(self: Cpu, csr: number, cycle: number): number
	if csr == 0x340 then
		return self.mscratch
	elseif csr == 0x305 then
		return self.mtvec
	elseif csr == 0x304 then
		return self.mie
	elseif csr == 0xC00 then
		return cycle % TWO32
	elseif csr == 0xC80 then
		return (cycle // TWO32) % TWO32
	elseif csr == 0x344 then
		return self.mip
	elseif csr == 0x341 then
		return self.mepc
	elseif csr == 0x300 then
		return self.mstatus
	elseif csr == 0x342 then
		return self.mcause
	elseif csr == 0x343 then
		return self.mtval
	elseif csr == 0xF11 then
		return 0xFF0FF0FF -- mvendorid
	elseif csr == 0x301 then
		return 0x40401101 -- misa: XLEN=32, I M A + X
	end
	return band(self.mmio.csrRead(csr), 0xFFFFFFFF)
end

local function writeCsr(self: Cpu, csr: number, value: number)
	if csr == 0x340 then
		self.mscratch = value
	elseif csr == 0x305 then
		self.mtvec = value
	elseif csr == 0x304 then
		self.mie = value
	elseif csr == 0x344 then
		self.mip = value
	elseif csr == 0x341 then
		self.mepc = value
	elseif csr == 0x300 then
		self.mstatus = value
	elseif csr == 0x342 then
		self.mcause = value
	elseif csr == 0x343 then
		self.mtval = value
	else
		self.mmio.csrWrite(csr, value)
	end
end

--[[
	Run up to `count` instructions. `elapsedUs` advances the machine timer
	(CLINT mtime, 1 MHz timebase) before executing.
]]
function Cpu.step(self: Cpu, count: number, elapsedUs: number): number
	local timer = self.timer + elapsedUs
	self.timer = timer
	local timermatch = self.timermatch
	local mip = self.mip
	if timermatch ~= 0 and timer > timermatch then
		self.wfi = false
		mip = bor(mip, 0x80)
	else
		mip = band(mip, 0xFFFFFF7F)
	end
	if self.meip then
		self.wfi = false
		mip = bor(mip, 0x800)
	else
		mip = band(mip, 0xFFFFF7FF)
	end
	self.mip = mip

	if self.wfi then
		return 1
	end

	local trap = 0
	local rval = 0
	local pc = self.pc
	local cycle = self.cycle
	local regs = self.regs
	local ram = self.ram
	local ramSize = self.ramSize
	local ramLimit = ramSize - 3
	local mmio = self.mmio

	local enabledPending = if band(self.mstatus, 0x8) ~= 0 then band(mip, self.mie) else 0
	if band(enabledPending, 0x800) ~= 0 then
		-- Machine external interrupt (PLIC).
		trap = 0x8000000B
	elseif band(enabledPending, 0x80) ~= 0 then
		-- Machine timer interrupt.
		trap = 0x80000007
	else
		for _ = 1, count do
			cycle += 1
			local ofs = pc - RAM_BASE
			if ofs < 0 or ofs >= ramSize then
				trap = 2 -- instruction access fault
				break
			elseif band(ofs, 3) ~= 0 then
				trap = 1 -- instruction address misaligned
				break
			end

			local ir = readu32(ram, ofs)
			local op = band(ir, 0x7F)
			local rd = extract(ir, 7, 5)
			local npc = pc + 4

			if op == 0x13 then -- OP-IMM
				local rs1 = regs[extract(ir, 15, 5) + 1]
				local imm = arshift(ir, 20)
				local f3 = extract(ir, 12, 3)
				if f3 == 0 then
					rval = band(rs1 + imm, 0xFFFFFFFF) -- ADDI
				elseif f3 == 1 then
					rval = lshift(rs1, band(imm, 0x1F)) -- SLLI
				elseif f3 == 2 then
					rval = if bxor(rs1, 0x80000000) < bxor(imm, 0x80000000) then 1 else 0 -- SLTI
				elseif f3 == 3 then
					rval = if rs1 < imm then 1 else 0 -- SLTIU
				elseif f3 == 4 then
					rval = bxor(rs1, imm)
				elseif f3 == 5 then
					if band(ir, 0x40000000) ~= 0 then
						rval = arshift(rs1, band(imm, 0x1F)) -- SRAI
					else
						rval = rshift(rs1, band(imm, 0x1F)) -- SRLI
					end
				elseif f3 == 6 then
					rval = bor(rs1, imm)
				else
					rval = band(rs1, imm)
				end
				if rd ~= 0 then
					regs[rd + 1] = rval
				end
			elseif op == 0x03 then -- LOAD
				local imm = rshift(ir, 20)
				if imm >= 0x800 then
					imm -= 0x1000
				end
				local addr = regs[extract(ir, 15, 5) + 1] + imm
				local a = addr - RAM_BASE
				local f3 = extract(ir, 12, 3)
				if a >= 0 and a < ramLimit then
					if f3 == 2 then
						rval = readu32(ram, a)
					elseif f3 == 4 then
						rval = readu8(ram, a)
					elseif f3 == 0 then
						rval = band(readi8(ram, a), 0xFFFFFFFF)
					elseif f3 == 5 then
						rval = readu16(ram, a)
					elseif f3 == 1 then
						rval = band(readi16(ram, a), 0xFFFFFFFF)
					else
						trap = 3
						break
					end
				else
					addr = band(addr, 0xFFFFFFFF)
					if addr >= 0x10000000 and addr < 0x12000000 then
						rval = mmio.load(addr)
						if f3 == 4 then
							rval = band(rval, 0xFF)
						elseif f3 == 5 then
							rval = band(rval, 0xFFFF)
						elseif f3 == 0 then
							rval = band(rval, 0xFF)
							if rval >= 0x80 then
								rval += 0xFFFFFF00
							end
						elseif f3 == 1 then
							rval = band(rval, 0xFFFF)
							if rval >= 0x8000 then
								rval += 0xFFFF0000
							end
						end
					else
						trap = 6 -- load access fault
						rval = addr
						break
					end
				end
				if rd ~= 0 then
					regs[rd + 1] = rval
				end
			elseif op == 0x63 then -- BRANCH
				local rs1 = regs[extract(ir, 15, 5) + 1]
				local rs2 = regs[extract(ir, 20, 5) + 1]
				local f3 = extract(ir, 12, 3)
				local taken
				if f3 == 0 then
					taken = rs1 == rs2
				elseif f3 == 1 then
					taken = rs1 ~= rs2
				elseif f3 == 4 then
					taken = bxor(rs1, 0x80000000) < bxor(rs2, 0x80000000)
				elseif f3 == 5 then
					taken = bxor(rs1, 0x80000000) >= bxor(rs2, 0x80000000)
				elseif f3 == 6 then
					taken = rs1 < rs2
				elseif f3 == 7 then
					taken = rs1 >= rs2
				else
					trap = 3
					break
				end
				if taken then
					local imm = bor(
						lshift(extract(ir, 8, 4), 1),
						lshift(extract(ir, 25, 6), 5),
						lshift(extract(ir, 7, 1), 11),
						lshift(extract(ir, 31, 1), 12)
					)
					if imm >= 0x1000 then
						imm -= 0x2000
					end
					npc = band(pc + imm, 0xFFFFFFFF)
				end
			elseif op == 0x23 then -- STORE
				local imm = bor(extract(ir, 7, 5), lshift(extract(ir, 25, 7), 5))
				if imm >= 0x800 then
					imm -= 0x1000
				end
				local addr = regs[extract(ir, 15, 5) + 1] + imm
				local rs2 = regs[extract(ir, 20, 5) + 1]
				local a = addr - RAM_BASE
				local f3 = extract(ir, 12, 3)
				if a >= 0 and a < ramLimit then
					if f3 == 2 then
						writeu32(ram, a, rs2)
					elseif f3 == 0 then
						writeu8(ram, a, band(rs2, 0xFF))
					elseif f3 == 1 then
						writeu16(ram, a, band(rs2, 0xFFFF))
					else
						trap = 3
						break
					end
				else
					addr = band(addr, 0xFFFFFFFF)
					if addr >= 0x10000000 and addr < 0x12000000 then
						if f3 == 0 then
							rs2 = band(rs2, 0xFF)
						elseif f3 == 1 then
							rs2 = band(rs2, 0xFFFF)
						end
						local code = mmio.store(addr, rs2)
						if code and code ~= 0 then
							-- syscon: stop the CPU and report the request.
							self.pc = npc
							self.cycle = cycle
							return code
						end
					else
						trap = 8 -- store/AMO access fault
						rval = addr
						break
					end
				end
			elseif op == 0x33 then -- OP
				local rs1 = regs[extract(ir, 15, 5) + 1]
				local rs2 = regs[extract(ir, 20, 5) + 1]
				local f3 = extract(ir, 12, 3)
				if band(ir, 0x02000000) ~= 0 then -- RV32M
					if f3 == 0 then
						rval = mullo(rs1, rs2)
					elseif f3 == 1 then
						rval = mulh(rs1, rs2)
					elseif f3 == 2 then
						rval = mulhsu(rs1, rs2)
					elseif f3 == 3 then
						rval = mulhu(rs1, rs2)
					elseif f3 == 4 then
						rval = divs(rs1, rs2)
					elseif f3 == 5 then
						rval = if rs2 == 0 then 0xFFFFFFFF else rs1 // rs2
					elseif f3 == 6 then
						rval = rems(rs1, rs2)
					else
						rval = if rs2 == 0 then rs1 else rs1 % rs2
					end
				else
					if f3 == 0 then
						if band(ir, 0x40000000) ~= 0 then
							rval = band(rs1 - rs2, 0xFFFFFFFF)
						else
							rval = band(rs1 + rs2, 0xFFFFFFFF)
						end
					elseif f3 == 1 then
						rval = lshift(rs1, band(rs2, 0x1F))
					elseif f3 == 2 then
						rval = if bxor(rs1, 0x80000000) < bxor(rs2, 0x80000000) then 1 else 0
					elseif f3 == 3 then
						rval = if rs1 < rs2 then 1 else 0
					elseif f3 == 4 then
						rval = bxor(rs1, rs2)
					elseif f3 == 5 then
						if band(ir, 0x40000000) ~= 0 then
							rval = arshift(rs1, band(rs2, 0x1F))
						else
							rval = rshift(rs1, band(rs2, 0x1F))
						end
					elseif f3 == 6 then
						rval = bor(rs1, rs2)
					else
						rval = band(rs1, rs2)
					end
				end
				if rd ~= 0 then
					regs[rd + 1] = rval
				end
			elseif op == 0x37 then -- LUI
				if rd ~= 0 then
					regs[rd + 1] = band(ir, 0xFFFFF000)
				end
			elseif op == 0x6F then -- JAL
				local imm = bor(
					lshift(extract(ir, 21, 10), 1),
					lshift(extract(ir, 20, 1), 11),
					lshift(extract(ir, 12, 8), 12),
					lshift(extract(ir, 31, 1), 20)
				)
				if imm >= 0x100000 then
					imm -= 0x200000
				end
				if rd ~= 0 then
					regs[rd + 1] = npc
				end
				npc = band(pc + imm, 0xFFFFFFFF)
			elseif op == 0x67 then -- JALR
				local target = band(regs[extract(ir, 15, 5) + 1] + arshift(ir, 20), 0xFFFFFFFE)
				if rd ~= 0 then
					regs[rd + 1] = npc
				end
				npc = target
			elseif op == 0x17 then -- AUIPC
				if rd ~= 0 then
					regs[rd + 1] = band(pc + band(ir, 0xFFFFF000), 0xFFFFFFFF)
				end
			elseif op == 0x73 then -- SYSTEM (Zicsr, ECALL, EBREAK, MRET, WFI)
				local csr = rshift(ir, 20)
				local micro = extract(ir, 12, 3)
				if band(micro, 3) ~= 0 then
					local rs1i = extract(ir, 15, 5)
					local rs1 = regs[rs1i + 1]
					rval = readCsr(self, csr, cycle)
					local doWrite = true
					local wv
					if micro == 1 then
						wv = rs1
					elseif micro == 2 then
						wv = bor(rval, rs1)
						doWrite = rs1i ~= 0
					elseif micro == 3 then
						wv = band(rval, bit32.bnot(rs1))
						doWrite = rs1i ~= 0
					elseif micro == 5 then
						wv = rs1i
					elseif micro == 6 then
						wv = bor(rval, rs1i)
						doWrite = rs1i ~= 0
					else
						wv = band(rval, bit32.bnot(rs1i))
						doWrite = rs1i ~= 0
					end
					if doWrite then
						writeCsr(self, csr, wv)
					end
					if rd ~= 0 then
						regs[rd + 1] = rval
					end
				elseif micro == 0 then
					if band(csr, 0xFF) == 0x02 then -- MRET
						local ms = self.mstatus
						local p = self.priv
						self.mstatus = bor(rshift(band(ms, 0x80), 4), lshift(p, 11), 0x80)
						self.priv = band(rshift(ms, 11), 3)
						npc = self.mepc
					elseif csr == 0 then -- ECALL
						trap = if self.priv ~= 0 then 12 else 9
						break
					elseif csr == 1 then -- EBREAK
						trap = 4
						break
					elseif csr == 0x105 then -- WFI
						self.mstatus = bor(self.mstatus, 8)
						self.wfi = true
						self.cycle = cycle
						self.pc = npc
						return 1
					elseif csr >= 0x120 and csr < 0x140 then
						-- SFENCE.VMA: no MMU, nothing to flush.
					else
						trap = 3
						break
					end
				else
					trap = 3
					break
				end
			elseif op == 0x2F then -- RV32A
				local addr = regs[extract(ir, 15, 5) + 1]
				local rs2 = regs[extract(ir, 20, 5) + 1]
				local a = addr - RAM_BASE
				if a < 0 or a >= ramLimit then
					trap = 8
					rval = addr
					break
				end
				rval = readu32(ram, a)
				local f5 = extract(ir, 27, 5)
				local doWrite = true
				if f5 == 2 then -- LR.W
					doWrite = false
					self.reservation = a
				elseif f5 == 3 then -- SC.W
					if self.reservation == a then
						rval = 0
					else
						rval = 1
						doWrite = false
					end
					self.reservation = -1
				elseif f5 == 1 then -- AMOSWAP.W
				elseif f5 == 0 then -- AMOADD.W
					rs2 = band(rs2 + rval, 0xFFFFFFFF)
				elseif f5 == 4 then
					rs2 = bxor(rs2, rval)
				elseif f5 == 12 then
					rs2 = band(rs2, rval)
				elseif f5 == 8 then
					rs2 = bor(rs2, rval)
				elseif f5 == 16 then -- AMOMIN.W
					if bxor(rval, 0x80000000) < bxor(rs2, 0x80000000) then
						rs2 = rval
					end
				elseif f5 == 20 then -- AMOMAX.W
					if bxor(rval, 0x80000000) > bxor(rs2, 0x80000000) then
						rs2 = rval
					end
				elseif f5 == 24 then -- AMOMINU.W
					if rval < rs2 then
						rs2 = rval
					end
				elseif f5 == 28 then -- AMOMAXU.W
					if rval > rs2 then
						rs2 = rval
					end
				else
					trap = 3
					break
				end
				if doWrite then
					writeu32(ram, a, rs2)
				end
				if rd ~= 0 then
					regs[rd + 1] = rval
				end
			elseif op == 0x0F then -- FENCE / FENCE.I
				-- No caches or reordering to model.
			else
				trap = 3 -- illegal instruction
				break
			end

			pc = npc
		end
	end

	if trap ~= 0 then
		if trap >= 0x80000000 then
			self.mcause = trap
			self.mtval = 0
		else
			self.mcause = trap - 1
			self.mtval = if trap > 5 and trap <= 8 then rval else pc
		end
		self.mepc = pc
		-- MPIE <- MIE, MIE <- 0, MPP <- current privilege.
		self.mstatus = bor(lshift(band(self.mstatus, 0x08), 4), lshift(self.priv, 11))
		pc = self.mtvec
		self.priv = 3
		self.reservation = -1
	end

	self.cycle = cycle
	self.pc = pc
	return 0
end

return Cpu
