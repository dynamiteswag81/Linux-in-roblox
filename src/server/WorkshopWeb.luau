--!strict
--[[
	The Community Workshop as a website on the in-game network, served by the
	gateway at http://workshop/ (10.0.0.1). Simple HTML that reads well in the
	`browse` package or with `wget -O -`.

		/                     newest and most popular packages
		/search?q=words       search
		/pkg/<name>           package details
		/pkg/<name>.tar       download the package archive
]]

local WorkshopService = require(script.Parent.WorkshopService)

local WorkshopWeb = {}

local function escape(s: string): string
	return (string.gsub(s, "[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

local function urlDecode(s: string): string
	s = string.gsub(s, "+", " ")
	return (string.gsub(s, "%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16) :: number)
	end))
end

local function response(status: string, contentType: string, body: string): string
	return "HTTP/1.0 "
		.. status
		.. "\r\nServer: brick-workshop\r\nContent-Type: "
		.. contentType
		.. "\r\nContent-Length: "
		.. #body
		.. "\r\nConnection: close\r\n\r\n"
		.. body
end

local function page(title: string, body: string): string
	return "<html><head><title>"
		.. escape(title)
		.. "</title></head><body>\n<h1>"
		.. escape(title)
		.. "</h1>\n"
		.. body
		.. "\n<p>Install anything here with: brick install &lt;name&gt;</p></body></html>\n"
end

local function listing(results: { WorkshopService.SearchResult }): string
	if #results == 0 then
		return "<p>No packages found.</p>"
	end
	local out = { "<ul>" }
	for _, r in results do
		table.insert(
			out,
			string.format(
				'<li><a href="/pkg/%s">%s %s</a> - %s<br>by %s, %d downloads</li>',
				r.name,
				escape(r.name),
				escape(r.version),
				escape(r.description),
				escape(r.author),
				r.downloads
			)
		)
	end
	table.insert(out, "</ul>")
	return table.concat(out, "\n")
end

-- Turns an HTTP request into a full HTTP response. May yield (DataStore reads).
function WorkshopWeb.handle(workshop: WorkshopService.WorkshopService, request: string): string
	local method, target = string.match(request, "^(%u+) (%S+) HTTP/[%d.]+\r\n")
	if not method then
		return response("400 Bad Request", "text/plain", "Bad request\n")
	end
	if method ~= "GET" and method ~= "HEAD" then
		return response("405 Method Not Allowed", "text/plain", "Only GET is supported\n")
	end
	local path, query = string.match(target, "^([^?]*)%??(.*)$")
	path = path or "/"

	if path == "/" or path == "/index.html" then
		local popular = workshop:search("", "popular", 25)
		local newest = workshop:search("", "new", 10)
		local body = "<p>Programs made by players, for Brick Linux. Search: /search?q=words</p>\n"
			.. "<h2>Popular</h2>\n"
			.. listing(popular)
			.. "\n<h2>Newest</h2>\n"
			.. listing(newest)
		return response("200 OK", "text/html", page("Community Workshop", body))
	elseif path == "/search" then
		local q = urlDecode(string.match(query or "", "q=([^&]*)") or "")
		local results = workshop:search(q, "popular", 50)
		return response("200 OK", "text/html", page("Search: " .. q, listing(results)))
	end

	local name, ext = string.match(path, "^/pkg/([%w._+-]-)(%.tar)$")
	if not name then
		name = string.match(path, "^/pkg/([%w._+-]+)$")
	end
	if name and WorkshopService.validName(name) then
		if ext then
			local tar = workshop:download(name)
			if tar then
				return response("200 OK", "application/x-tar", tar)
			end
		else
			local d = workshop:getDetails(name)
			if d then
				local body = {
					"<p>" .. escape(d.description) .. "</p>",
					"<p>Version " .. escape(d.version) .. ", by " .. escape(d.authorName) .. ", " .. d.downloads .. " downloads</p>",
					'<p>Install: brick install ' .. escape(d.name) .. ' (or download <a href="/pkg/' .. d.name .. '.tar">' .. d.name .. ".tar</a>)</p>",
				}
				if d.readme ~= "" then
					table.insert(body, "<h2>README</h2><pre>" .. escape(d.readme) .. "</pre>")
				end
				if #d.files > 0 then
					table.insert(body, "<h2>Files</h2><pre>" .. escape(table.concat(d.files, "\n")) .. "</pre>")
				end
				return response("200 OK", "text/html", page(d.name, table.concat(body, "\n")))
			end
		end
	end
	return response("404 Not Found", "text/html", page("Not found", "<p>There's nothing at " .. escape(path) .. ".</p>"))
end

return WorkshopWeb
