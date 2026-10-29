--!strict
--[[
	8250/16550-compatible UART (the subset Linux's 8250 driver needs in polling mode).

	There is no interrupt controller, so the guest polls the line status register.
	Bytes the guest transmits are collected for the host; bytes the host queues are
	handed to the guest one at a time through the receive buffer.
]]

local Uart = {}
Uart.__index = Uart

local CHARS = table.create(256)
for i = 0, 255 do
	CHARS[i + 1] = string.char(i)
end

export type Uart = typeof(setmetatable(
	{} :: {
		_input: string,
		_inputPos: number,
		_output: { string },
		_outputCount: number,
		lcr: number,
		ier: number,
		mcr: number,
		scr: number,
		dll: number,
		dlm: number,
		-- Called for every byte the guest transmits (optional).
		onByte: ((byte: number) -> ())?,
	},
	Uart
))

function Uart.new(): Uart
	return setmetatable({
		_input = "",
		_inputPos = 1,
		_output = {},
		_outputCount = 0,
		lcr = 0,
		ier = 0,
		mcr = 0,
		scr = 0,
		dll = 0,
		dlm = 0,
		onByte = nil,
	}, Uart)
end

function Uart.reset(self: Uart)
	self._input = ""
	self._inputPos = 1
	self._output = {}
	self._outputCount = 0
	self.lcr = 0
	self.ier = 0
	self.mcr = 0
	self.scr = 0
end

function Uart.hasInput(self: Uart): boolean
	return self._inputPos <= #self._input
end

function Uart.pushInput(self: Uart, data: string)
	if self._inputPos > #self._input then
		self._input = data
	else
		self._input = string.sub(self._input, self._inputPos) .. data
	end
	self._inputPos = 1
end

function Uart.popInput(self: Uart): number?
	local pos = self._inputPos
	if pos > #self._input then
		return nil
	end
	self._inputPos = pos + 1
	return string.byte(self._input, pos)
end

function Uart.emit(self: Uart, byte: number)
	local n = self._outputCount + 1
	self._outputCount = n
	self._output[n] = CHARS[byte + 1]
	local onByte = self.onByte
	if onByte then
		onByte(byte)
	end
end

function Uart.takeOutput(self: Uart): string
	if self._outputCount == 0 then
		return ""
	end
	local s = table.concat(self._output, "", 1, self._outputCount)
	table.clear(self._output)
	self._outputCount = 0
	return s
end

function Uart.read(self: Uart, offset: number): number
	local dlab = bit32.band(self.lcr, 0x80) ~= 0
	if offset == 0 then
		if dlab then
			return self.dll
		end
		return self:popInput() or 0
	elseif offset == 1 then
		return if dlab then self.dlm else self.ier
	elseif offset == 2 then
		-- IIR. Without an interrupt controller Linux polls this from a timer and
		-- only services the port when an interrupt is reported "pending".
		if self._inputPos <= #self._input then
			return 0xC4 -- received data available
		elseif bit32.band(self.ier, 0x02) ~= 0 then
			return 0xC2 -- transmit holding register empty
		end
		return 0xC1 -- nothing pending
	elseif offset == 3 then
		return self.lcr
	elseif offset == 4 then
		return self.mcr
	elseif offset == 5 then
		-- LSR: transmitter empty + holding register empty, plus data ready.
		return if self._inputPos <= #self._input then 0x61 else 0x60
	elseif offset == 6 then
		-- MSR: CTS, DSR, DCD asserted.
		return 0xB0
	elseif offset == 7 then
		return self.scr
	end
	return 0
end

function Uart.write(self: Uart, offset: number, value: number)
	value = bit32.band(value, 0xFF)
	local dlab = bit32.band(self.lcr, 0x80) ~= 0
	if offset == 0 then
		if dlab then
			self.dll = value
		else
			self:emit(value)
		end
	elseif offset == 1 then
		if dlab then
			self.dlm = value
		else
			self.ier = value
		end
	elseif offset == 3 then
		self.lcr = value
	elseif offset == 4 then
		self.mcr = value
	elseif offset == 7 then
		self.scr = value
	end
end

return Uart
