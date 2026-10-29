--!strict
--[[
	The Community Workshop: packages players publish from inside their computers
	(`brick publish`) and everyone can browse in the Workshop GUI or install with
	`brick install`.

	Storage (one DataStore):
		index                     { v = 1, packages = { [name] = Summary } }
		pkg_<name>                Details (everything shown in the GUI)
		blob_<name>_<slot>_<i>    base64 of the LZ4-compressed tar, in chunks

	Official packages (OfficialPackages.luau) live in code, not the DataStore,
	and their names are reserved.

	Text players write (names, descriptions, READMEs) is passed through
	`filterText` before anyone else can see it.
]]

local LinuxVM = require(script.Parent.Deps) :: any
local Base64 = require(LinuxVM.Util.Base64)
local Config = require(LinuxVM.Config)
local Lz4 = require(LinuxVM.Util.Lz4)
local Tar = require(LinuxVM.Util.Tar)

local CHUNK_CHARS = 3_500_000
local INDEX_TTL = 30
local MAX_FILES_LISTED = 300
local MAX_README = 4000
local MAX_DESCRIPTION = 200

export type Summary = {
	v: string, -- version
	d: string, -- description
	a: number, -- author user id (0 = official)
	n: string, -- author name
	t: number, -- updated (unix time)
	dl: number, -- downloads
	s: number, -- size in bytes
}

export type Details = {
	name: string,
	version: string,
	description: string,
	readme: string,
	files: { string },
	depends: { string },
	author: number,
	authorName: string,
	created: number,
	updated: number,
	size: number,
	downloads: number,
	official: boolean,
	-- Storage bookkeeping (not shown to players)
	slot: string?,
	chunks: number?,
}

export type Store = {
	GetAsync: (self: any, key: string) -> any,
	SetAsync: (self: any, key: string, value: any) -> any,
	UpdateAsync: (self: any, key: string, transform: (any) -> any) -> any,
	RemoveAsync: (self: any, key: string) -> any,
}

export type Official = {
	name: string,
	version: string,
	description: string,
	readme: string?,
	tar: string,
	files: { string },
	depends: { string },
}

export type Options = {
	store: Store,
	-- Returns the filtered text, or errors if filtering is unavailable.
	filterText: ((text: string, authorId: number) -> string)?,
	official: { Official }?,
	now: (() -> number)?,
}

local WorkshopService = {}
WorkshopService.__index = WorkshopService

export type WorkshopService = typeof(setmetatable(
	{} :: {
		store: Store,
		filterText: ((text: string, authorId: number) -> string)?,
		official: { [string]: Official },
		now: () -> number,
		index: { [string]: Summary },
		indexFetchedAt: number,
		pendingDownloads: { [string]: number },
	},
	WorkshopService
))

function WorkshopService.new(options: Options): WorkshopService
	local official = {}
	for _, pkg in options.official or {} do
		official[pkg.name] = pkg
	end
	return setmetatable({
		store = options.store,
		filterText = options.filterText,
		official = official,
		now = options.now or os.time,
		index = {},
		indexFetchedAt = -math.huge,
		pendingDownloads = {},
	}, WorkshopService)
end

function WorkshopService.validName(name: string): boolean
	return #name >= 1 and #name <= 32 and string.match(name, "^[a-z0-9][a-z0-9._+-]*$") ~= nil
end

local function parseManifest(text: string): { [string]: string }
	local out = {}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local key, value = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
		if key then
			out[string.lower(key)] = value
		end
	end
	return out
end

local function splitWords(s: string?): { string }
	local out = {}
	for word in string.gmatch(s or "", "[^%s,]+") do
		table.insert(out, word)
	end
	return out
end

function WorkshopService._refreshIndex(self: WorkshopService, force: boolean?)
	if not force and self.now() - self.indexFetchedAt < INDEX_TTL then
		return
	end
	local ok, data = pcall(function()
		return self.store:GetAsync("index")
	end)
	if ok then
		self.index = if type(data) == "table" and type(data.packages) == "table" then data.packages else {}
		self.indexFetchedAt = self.now()
	end
end

local function officialSummary(pkg: Official): Summary
	return { v = pkg.version, d = pkg.description, a = 0, n = Config.OS_NAME, t = 0, dl = 0, s = #pkg.tar }
end

export type SearchResult = {
	name: string,
	version: string,
	description: string,
	author: string,
	downloads: number,
	updated: number,
	size: number,
	official: boolean,
}

-- Searches names and descriptions. sort: "popular" (default) | "new" | "name".
function WorkshopService.search(self: WorkshopService, query: string?, sort: string?, limit: number?): { SearchResult }
	self:_refreshIndex()
	local q = string.lower(query or "")
	local results: { SearchResult } = {}
	local seen = {}
	local function consider(name: string, s: Summary, official: boolean)
		if seen[name] then
			return
		end
		local nameHit = q == "" or string.find(name, q, 1, true) ~= nil
		local descHit = q ~= "" and string.find(string.lower(s.d), q, 1, true) ~= nil
		if nameHit or descHit then
			seen[name] = true
			table.insert(results, {
				name = name,
				version = s.v,
				description = s.d,
				author = s.n,
				downloads = s.dl + (self.pendingDownloads[name] or 0),
				updated = s.t,
				size = s.s,
				official = official,
			})
		end
	end
	for name, pkg in self.official do
		consider(name, officialSummary(pkg), true)
	end
	for name, s in self.index do
		consider(name, s, false)
	end
	local mode = sort or "popular"
	table.sort(results, function(a, b)
		if q ~= "" then
			-- Exact and name matches first.
			local aExact, bExact = a.name == q, b.name == q
			if aExact ~= bExact then
				return aExact
			end
		end
		if mode == "new" then
			if a.updated ~= b.updated then
				return a.updated > b.updated
			end
		elseif mode == "popular" then
			if a.official ~= b.official then
				return a.official
			end
			if a.downloads ~= b.downloads then
				return a.downloads > b.downloads
			end
		end
		return a.name < b.name
	end)
	local max = limit or 50
	while #results > max do
		table.remove(results)
	end
	return results
end

-- Full details for one package, or nil.
function WorkshopService.getDetails(self: WorkshopService, name: string): Details?
	local official = self.official[name]
	if official then
		return {
			name = official.name,
			version = official.version,
			description = official.description,
			readme = official.readme or "",
			files = official.files,
			depends = official.depends,
			author = 0,
			authorName = Config.OS_NAME,
			created = 0,
			updated = 0,
			size = #official.tar,
			downloads = 0,
			official = true,
		}
	end
	if not WorkshopService.validName(name) then
		return nil
	end
	local data = self.store:GetAsync("pkg_" .. name)
	if type(data) ~= "table" then
		return nil
	end
	self:_refreshIndex()
	local summary = self.index[name]
	data.downloads = (if summary then summary.dl else 0) + (self.pendingDownloads[name] or 0)
	data.official = false
	return data :: Details
end

-- Returns the package's tar archive (and counts a download), or nil.
function WorkshopService.download(self: WorkshopService, name: string): string?
	local official = self.official[name]
	if official then
		return official.tar
	end
	local details = self:getDetails(name)
	if not details or not details.slot or not details.chunks then
		return nil
	end
	local parts = table.create(details.chunks)
	for i = 1, details.chunks do
		local part = self.store:GetAsync(string.format("blob_%s_%s_%d", name, details.slot, i))
		if type(part) ~= "string" then
			return nil
		end
		parts[i] = part
	end
	local blob = Base64.decode(table.concat(parts))
	local size = buffer.readu32(blob, 0)
	local packed = buffer.create(buffer.len(blob) - 4)
	buffer.copy(packed, 0, blob, 4, buffer.len(packed))
	local tar = buffer.tostring(Lz4.decompress(packed, size))
	self.pendingDownloads[name] = (self.pendingDownloads[name] or 0) + 1
	return tar
end

-- Writes accumulated download counts into the index (call every minute or so).
function WorkshopService.flushDownloads(self: WorkshopService)
	if next(self.pendingDownloads) == nil then
		return
	end
	local pending = self.pendingDownloads
	self.pendingDownloads = {}
	local ok = pcall(function()
		self.store:UpdateAsync("index", function(data)
			data = if type(data) == "table" then data else { v = 1, packages = {} }
			for name, count in pending do
				local s = data.packages[name]
				if s then
					s.dl += count
				end
			end
			return data
		end)
	end)
	if not ok then
		-- Try again next time.
		for name, count in pending do
			self.pendingDownloads[name] = (self.pendingDownloads[name] or 0) + count
		end
	end
end

function WorkshopService._filter(self: WorkshopService, text: string, authorId: number): string
	local filter = self.filterText
	if not filter or not Config.FILTER_WORKSHOP_TEXT or text == "" then
		return text
	end
	return filter(text, authorId)
end

--[[
	Publishes (or updates) a package from a tar archive made by `brick publish`.
	Returns ok, message. Yields (DataStore and text filtering calls).
]]
function WorkshopService.publish(
	self: WorkshopService,
	authorId: number,
	authorName: string,
	name: string,
	tar: string
): (boolean, string)
	if not WorkshopService.validName(name) then
		return false, "Package names are 1-32 characters: a-z, 0-9, and . _ + -"
	end
	if self.official[name] then
		return false, "'" .. name .. "' is an official package name. Pick another name."
	end
	if #tar > Config.MAX_PACKAGE_BYTES then
		return false, string.format("Package is too big (%d KB, max %d KB).", #tar // 1024, Config.MAX_PACKAGE_BYTES // 1024)
	end

	local ok, entries = pcall(Tar.parse, tar)
	if not ok then
		return false, "The package archive is damaged: " .. tostring(entries)
	end
	local manifestText: string? = nil
	local readme = ""
	local files = {}
	for _, e in entries do
		if e.name == "BRICK" and e.kind == "file" then
			manifestText = e.data
		elseif (e.name == "README" or e.name == "README.md" or e.name == "README.txt") and e.kind == "file" then
			readme = e.data
		elseif string.sub(e.name, 1, 6) == "files/" and e.kind ~= "dir" and #files < MAX_FILES_LISTED then
			table.insert(files, "/" .. string.sub(e.name, 7))
		end
	end
	if not manifestText then
		return false, "The package has no BRICK manifest."
	end
	local manifest = parseManifest(manifestText)
	if manifest.name ~= name then
		return false, string.format("BRICK says name=%s but you published '%s'.", tostring(manifest.name), name)
	end
	local version = manifest.version or ""
	if not string.match(version, "^[%w._+~-]+$") or #version > 32 then
		return false, "BRICK needs a version= line (like version=1.0)."
	end
	local depends = splitWords(manifest.depends)
	for _, dep in depends do
		if not WorkshopService.validName(dep) then
			return false, "Bad dependency name: " .. dep
		end
	end
	local description = string.sub(manifest.description or "", 1, MAX_DESCRIPTION)
	readme = string.sub(readme, 1, MAX_README)

	-- Ownership and quota.
	local existing = self.store:GetAsync("pkg_" .. name)
	if type(existing) == "table" and existing.author ~= authorId then
		return false, string.format("'%s' belongs to %s. Pick another name.", name, tostring(existing.authorName))
	end
	if type(existing) ~= "table" then
		self:_refreshIndex(true)
		local count = 0
		for _, s in self.index do
			if s.a == authorId then
				count += 1
			end
		end
		if count >= Config.MAX_PACKAGES_PER_PLAYER then
			return false, string.format("You can publish at most %d packages.", Config.MAX_PACKAGES_PER_PLAYER)
		end
	end

	-- Moderation: names must pass unchanged; other text is published filtered.
	local filterOk, filtered = pcall(function()
		local filteredName = self:_filter(name, authorId)
		if filteredName ~= name then
			error("name", 0)
		end
		return {
			description = self:_filter(description, authorId),
			readme = self:_filter(readme, authorId),
		}
	end)
	if not filterOk then
		if filtered == "name" then
			return false, "That package name isn't allowed."
		end
		return false, "Text filtering is unavailable right now. Try again in a minute."
	end

	-- Store the archive in the slot not used by the current version.
	local slot = if type(existing) == "table" and existing.slot == "a" then "b" else "a"
	local raw = buffer.fromstring(tar)
	local packed = Lz4.compress(raw)
	local blob = buffer.create(4 + buffer.len(packed))
	buffer.writeu32(blob, 0, buffer.len(raw))
	buffer.copy(blob, 4, packed, 0, buffer.len(packed))
	local text = Base64.encode(blob)
	local chunks = math.max(1, math.ceil(#text / CHUNK_CHARS))
	for i = 1, chunks do
		self.store:SetAsync(
			string.format("blob_%s_%s_%d", name, slot, i),
			string.sub(text, (i - 1) * CHUNK_CHARS + 1, i * CHUNK_CHARS)
		)
	end

	local now = self.now()
	local details: Details = {
		name = name,
		version = version,
		description = filtered.description,
		readme = filtered.readme,
		files = files,
		depends = depends,
		author = authorId,
		authorName = authorName,
		created = if type(existing) == "table" then existing.created else now,
		updated = now,
		size = #tar,
		downloads = 0,
		official = false,
		slot = slot,
		chunks = chunks,
	}
	self.store:SetAsync("pkg_" .. name, details)
	self.store:UpdateAsync("index", function(data)
		data = if type(data) == "table" and type(data.packages) == "table" then data else { v = 1, packages = {} }
		local previous = data.packages[name]
		data.packages[name] = {
			v = version,
			d = filtered.description,
			a = authorId,
			n = authorName,
			t = now,
			dl = if previous then previous.dl else 0,
			s = #tar,
		}
		return data
	end)
	self.indexFetchedAt = -math.huge
	local verb = if type(existing) == "table" then "Updated" else "Published"
	return true, string.format("%s %s %s in the Community Workshop.", verb, name, version)
end

-- Removes a package (author or game owner only; checked by the caller).
function WorkshopService.unpublish(self: WorkshopService, authorId: number, name: string): (boolean, string)
	local existing = self.store:GetAsync("pkg_" .. name)
	if type(existing) ~= "table" then
		return false, "No such package."
	end
	if existing.author ~= authorId then
		return false, "Only the author can remove a package."
	end
	self.store:RemoveAsync("pkg_" .. name)
	self.store:UpdateAsync("index", function(data)
		if type(data) == "table" and type(data.packages) == "table" then
			data.packages[name] = nil
		end
		return data
	end)
	self.indexFetchedAt = -math.huge
	return true, "Removed " .. name .. "."
end

return WorkshopService
