--!strict
--[[
	Minimal ustar reader/writer.

	Workshop packages are tar archives made by `brick publish` inside the guest.
	The server reads them to find the BRICK manifest and list the files, and can
	build archives (e.g. for official packages defined in Luau).
]]

local Tar = {}

export type Entry = {
	name: string,
	mode: number,
	size: number,
	kind: "file" | "dir" | "symlink" | "other",
	data: string, -- file contents ("" for non-files)
	linkName: string,
}

local function cstring(s: string): string
	local nul = string.find(s, "\0", 1, true)
	return if nul then string.sub(s, 1, nul - 1) else s
end

local function octal(s: string): number
	local digits = string.match(cstring(s), "[0-7]+")
	return if digits then tonumber(digits, 8) or 0 else 0
end

-- Parses a tar archive. Errors on malformed input.
function Tar.parse(archive: string): { Entry }
	local entries: { Entry } = {}
	local pos = 1
	local longName: string? = nil
	while pos + 511 <= #archive do
		local header = string.sub(archive, pos, pos + 511)
		if header == string.rep("\0", 512) then
			break
		end
		local name = cstring(string.sub(header, 1, 100))
		local mode = octal(string.sub(header, 101, 108))
		local size = octal(string.sub(header, 125, 136))
		local typeflag = string.sub(header, 157, 157)
		local linkName = cstring(string.sub(header, 158, 257))
		if string.sub(header, 258, 262) == "ustar" then
			local prefix = cstring(string.sub(header, 346, 500))
			if prefix ~= "" then
				name = prefix .. "/" .. name
			end
		end
		local dataStart = pos + 512
		local data = string.sub(archive, dataStart, dataStart + size - 1)
		assert(#data == size, "tar: truncated archive")
		pos = dataStart + math.ceil(size / 512) * 512

		if typeflag == "L" then
			-- GNU long name for the next entry.
			longName = cstring(data)
		elseif typeflag == "x" or typeflag == "g" then
			-- pax headers: honour a "path" record if present.
			local path = string.match(data, "%d+ path=([^\n]*)\n")
			if typeflag == "x" and path then
				longName = path
			end
		else
			if longName then
				name = longName
				longName = nil
			end
			local kind: "file" | "dir" | "symlink" | "other" = "other"
			if typeflag == "0" or typeflag == "\0" or typeflag == "7" then
				kind = "file"
			elseif typeflag == "5" then
				kind = "dir"
			elseif typeflag == "2" then
				kind = "symlink"
			end
			name = string.gsub(name, "^%./", "")
			table.insert(entries, {
				name = name,
				mode = mode,
				size = size,
				kind = kind,
				data = if kind == "file" then data else "",
				linkName = linkName,
			})
		end
	end
	return entries
end

local function field(value: string, width: number): string
	return string.sub(value, 1, width) .. string.rep("\0", width - math.min(#value, width))
end

local function octalField(n: number, width: number): string
	return field(string.format("%0" .. (width - 1) .. "o", n), width)
end

export type NewEntry = {
	name: string,
	data: string?,
	mode: number?,
	kind: ("file" | "dir" | "symlink")?,
	linkName: string?,
}

-- Builds a ustar archive from a list of entries.
function Tar.build(entries: { NewEntry }, mtime: number?): string
	local parts = {}
	for _, e in entries do
		local kind = e.kind or "file"
		local data = if kind == "file" then (e.data or "") else ""
		local typeflag = if kind == "dir" then "5" elseif kind == "symlink" then "2" else "0"
		local name = e.name
		if kind == "dir" and string.sub(name, -1) ~= "/" then
			name ..= "/"
		end
		assert(#name <= 100, "tar: name too long: " .. name)
		local mode = e.mode or (if kind == "dir" then 493 else 420) -- 0755 / 0644
		local header = field(name, 100)
			.. octalField(mode, 8)
			.. octalField(0, 8)
			.. octalField(0, 8)
			.. octalField(#data, 12)
			.. octalField(mtime or 0, 12)
			.. "        " -- checksum placeholder
			.. typeflag
			.. field(e.linkName or "", 100)
			.. "ustar\0" .. "00"
			.. field("root", 32)
			.. field("root", 32)
			.. octalField(0, 8)
			.. octalField(0, 8)
			.. field("", 155)
			.. string.rep("\0", 12)
		local sum = 0
		for i = 1, 512 do
			sum += string.byte(header, i)
		end
		header = string.sub(header, 1, 148) .. string.format("%06o\0 ", sum) .. string.sub(header, 157)
		table.insert(parts, header)
		table.insert(parts, data)
		local pad = (512 - #data % 512) % 512
		table.insert(parts, string.rep("\0", pad))
	end
	table.insert(parts, string.rep("\0", 1024))
	return table.concat(parts)
end

return Tar
