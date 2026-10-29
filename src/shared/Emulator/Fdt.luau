--!strict
--[[
	Minimal flattened device tree (DTB) writer.

	Lets the Machine describe its hardware (RAM size, UARTs, timer, syscon) to the
	Linux kernel at boot without shipping precompiled .dtb files.

	Usage:
		local fdt = Fdt.new()
		fdt:beginNode("")
		fdt:propU32("#address-cells", 2)
		fdt:propString("compatible", "riscv-minimal-nommu")
		fdt:beginNode("chosen")
		fdt:propString("bootargs", "console=ttyS0")
		fdt:endNode()
		fdt:endNode()
		local blob: buffer = fdt:finish()
]]

local FDT_MAGIC = 0xD00DFEED
local FDT_BEGIN_NODE = 1
local FDT_END_NODE = 2
local FDT_PROP = 3
local FDT_END = 9

local Fdt = {}
Fdt.__index = Fdt

export type Fdt = typeof(setmetatable(
	{} :: {
		_struct: { string },
		_strings: { string },
		_stringOffsets: { [string]: number },
		_stringsLen: number,
		_phandles: { [string]: number },
		_nextPhandle: number,
	},
	Fdt
))

local function be32(n: number): string
	return string.pack(">I4", n)
end

local function padTo4(s: string): string
	local rem = #s % 4
	if rem == 0 then
		return s
	end
	return s .. string.rep("\0", 4 - rem)
end

function Fdt.new(): Fdt
	return setmetatable({
		_struct = {},
		_strings = {},
		_stringOffsets = {},
		_stringsLen = 0,
		_phandles = {},
		_nextPhandle = 1,
	}, Fdt)
end

function Fdt._nameOffset(self: Fdt, name: string): number
	local existing = self._stringOffsets[name]
	if existing then
		return existing
	end
	local offset = self._stringsLen
	self._stringOffsets[name] = offset
	table.insert(self._strings, name .. "\0")
	self._stringsLen += #name + 1
	return offset
end

-- Returns a stable phandle number for a label, allocating one on first use.
function Fdt.phandle(self: Fdt, label: string): number
	local existing = self._phandles[label]
	if existing then
		return existing
	end
	local n = self._nextPhandle
	self._nextPhandle += 1
	self._phandles[label] = n
	return n
end

function Fdt.beginNode(self: Fdt, name: string)
	table.insert(self._struct, be32(FDT_BEGIN_NODE) .. padTo4(name .. "\0"))
end

function Fdt.endNode(self: Fdt)
	table.insert(self._struct, be32(FDT_END_NODE))
end

function Fdt.propRaw(self: Fdt, name: string, value: string)
	table.insert(self._struct, be32(FDT_PROP) .. be32(#value) .. be32(self:_nameOffset(name)) .. padTo4(value))
end

function Fdt.propEmpty(self: Fdt, name: string)
	self:propRaw(name, "")
end

function Fdt.propU32(self: Fdt, name: string, value: number)
	self:propRaw(name, be32(value))
end

function Fdt.propCells(self: Fdt, name: string, cells: { number })
	local parts = table.create(#cells)
	for i, c in cells do
		parts[i] = be32(c)
	end
	self:propRaw(name, table.concat(parts))
end

function Fdt.propString(self: Fdt, name: string, value: string)
	self:propRaw(name, value .. "\0")
end

function Fdt.propStrings(self: Fdt, name: string, values: { string })
	self:propRaw(name, table.concat(values, "\0") .. "\0")
end

function Fdt.finish(self: Fdt): buffer
	table.insert(self._struct, be32(FDT_END))
	local struct = table.concat(self._struct)
	local strings = table.concat(self._strings)

	local headerSize = 40
	local rsvOffset = headerSize -- already 8-byte aligned
	local rsvMap = string.rep("\0", 16) -- single terminating entry
	local structOffset = rsvOffset + #rsvMap
	local stringsOffset = structOffset + #struct
	local total = stringsOffset + #strings

	local header = be32(FDT_MAGIC)
		.. be32(total)
		.. be32(structOffset)
		.. be32(stringsOffset)
		.. be32(rsvOffset)
		.. be32(17) -- version
		.. be32(16) -- last compatible version
		.. be32(0) -- boot cpu id
		.. be32(#strings)
		.. be32(#struct)

	return buffer.fromstring(header .. rsvMap .. struct .. strings)
end

return Fdt
