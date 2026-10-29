return function(test, root, require)
	local Lz4 = require(root.Util.Lz4)
	local Base64 = require(root.Util.Base64)
	local Tar = require(root.Util.Tar)

	test("base64 round trips all lengths", function()
		for len = 0, 40 do
			local b = buffer.create(len)
			for i = 0, len - 1 do
				buffer.writeu8(b, i, (i * 37 + len) % 256)
			end
			local text = Base64.encode(b)
			assert(#text % 4 == 0)
			local back = Base64.decode(text)
			assert(buffer.tostring(back) == buffer.tostring(b), "length " .. len)
		end
		assert(Base64.encode(buffer.fromstring("Man")) == "TWFu")
		assert(Base64.encode(buffer.fromstring("Ma")) == "TWE=")
		assert(Base64.encode(buffer.fromstring("M")) == "TQ==")
	end)

	local function roundTrip(s)
		local packed = Lz4.compress(buffer.fromstring(s))
		local out = Lz4.decompress(packed, #s)
		assert(buffer.tostring(out) == s, "lz4 round trip failed for length " .. #s)
		return buffer.len(packed)
	end

	test("lz4 round trips small and patterned inputs", function()
		roundTrip("")
		roundTrip("a")
		roundTrip("hello hello hello hello hello hello")
		roundTrip(string.rep("\0", 100000))
		local parts = {}
		for i = 1, 5000 do
			parts[i] = tostring(i * 7919 % 1000)
		end
		roundTrip(table.concat(parts, ","))
	end)

	test("lz4 compresses zeros well", function()
		local size = roundTrip(string.rep("\0", 65536))
		assert(size < 400, "zeros compressed to " .. size)
	end)

	test("tar build/parse round trip", function()
		local archive = Tar.build({
			{ name = "BRICK", data = "name=hello\nversion=1.0\n" },
			{ name = "files", kind = "dir" },
			{ name = "files/usr/bin/hello", data = "#!/bin/sh\necho hi\n", mode = 493 },
			{ name = "files/usr/bin/hi", kind = "symlink", linkName = "hello" },
		})
		assert(#archive % 512 == 0)
		local entries = Tar.parse(archive)
		assert(#entries == 4, #entries)
		assert(entries[1].name == "BRICK" and entries[1].data == "name=hello\nversion=1.0\n")
		assert(entries[2].kind == "dir")
		assert(entries[3].mode == 493 and entries[3].data == "#!/bin/sh\necho hi\n")
		assert(entries[4].kind == "symlink" and entries[4].linkName == "hello")
	end)
end
