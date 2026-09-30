--- tests/unit/adapters/test_python_interpreter.lua

--- ==============================================================================
--- MODULE: Native Python Resolver Tests (hardening-h-python-resolver)
--- DESCRIPTION:
--- dev.155 started an x86_64-only Python on an Apple silicon Mac migrated from
--- Intel, and macOS announced an Intel app. The resolver must name an
--- interpreter from the slices of its Mach-O header, never by running it, and
--- skip every candidate macOS would run under Rosetta: an Intel /usr/local
--- (Homebrew) or developer-tools python3 first in line leaves the arm64 one
--- chosen, and with only Intel ones it returns nil and a named state.
--- ==============================================================================

local helpers = require("tests.helpers")

local CPU = { x86_64 = 0x01000007, arm64 = 0x0100000C }

--- Encodes one unsigned 32-bit integer.
local function u32(value, big_endian)
	local bytes = {}
	for index = 1, 4 do bytes[index] = math.floor(value / 256 ^ (index - 1)) % 256 end
	if big_endian then bytes = { bytes[4], bytes[3], bytes[2], bytes[1] } end
	return string.char(bytes[1], bytes[2], bytes[3], bytes[4])
end

--- The Mach-O header of an executable built for the given processors.
local function macho(archs)
	if #archs == 1 then
		return u32(0xFEEDFACF, false) .. u32(CPU[archs[1]], false) .. u32(0, false) .. u32(2, false)
			.. string.rep("\0", 16)
	end
	local parts = { u32(0xCAFEBABE, true), u32(#archs, true) }
	for index, arch in ipairs(archs) do
		parts[#parts + 1] = u32(CPU[arch], true) .. u32(0, true) .. u32(4096 * index, true)
			.. u32(4096, true) .. u32(12, true)
	end
	return table.concat(parts)
end

--- Loads the resolver over a modelled Mac.
--- @param files table path -> header bytes
--- @param options table|nil { arch, developer_dir, select_link, realpath }
--- @return table resolver, table reads
local function load(files, options)
	options = options or {}
	package.loaded["adapters.python_interpreter"] = nil
	local resolver = helpers.load_with_stubs("adapters.python_interpreter")
	local reads = {}
	resolver._set_deps({
		read_head = function(path)
			reads[#reads + 1] = path
			return files[path]
		end,
		realpath = function(path) return (options.realpath or {})[path] or path end,
		getenv = function(name)
			if name == "DEVELOPER_DIR" then return options.developer_dir end
			return nil
		end,
		select_link_target = function() return options.select_link end,
		process_arch = function() return options.arch or "arm64" end,
	})
	return resolver, reads
end

local CLT = "/Library/Developer/CommandLineTools/usr/bin/python3"

helpers.describe("hardening-h-python-resolver", function()
	helpers.it("reads thin, universal, script and foreign headers without running anything", function()
		local resolver = load({})
		helpers.assert_eq(table.concat(resolver.parse_header(macho({ "x86_64" })), ","), "x86_64")
		helpers.assert_eq(table.concat(resolver.parse_header(macho({ "x86_64", "arm64" })), ","), "x86_64,arm64")
		local archs, reason = resolver.parse_header("#!/usr/bin/env bash\nexec python3 \"$@\"\n")
		helpers.assert_nil(archs)
		helpers.assert_eq(reason, "script")
		helpers.assert_nil((resolver.parse_header("\202\202\202\202 not a binary")))
		-- A Java class file shares the fat magic; its version word is no slice count.
		helpers.assert_nil((resolver.parse_header(u32(0xCAFEBABE, true) .. u32(0x00000037, true) .. "xxxxxxxx")))
		resolver._set_deps(nil)
	end)

	helpers.it("skips the Intel developer tools and Intel /usr/local for the arm64 Homebrew", function()
		local resolver, reads = load({
			[CLT] = macho({ "x86_64" }),
			["/usr/local/bin/python3"] = macho({ "x86_64" }),
			["/opt/homebrew/bin/python3"] = macho({ "arm64" }),
		})
		local path, state = resolver.resolve()
		helpers.assert_eq(path, "/opt/homebrew/bin/python3")
		helpers.assert_eq(state.kind, "ready")
		for _, read in ipairs(reads) do
			helpers.assert_true(read ~= "/usr/local/bin/python3",
				"a native interpreter found earlier leaves /usr/local unread")
		end
		resolver._set_deps(nil)
	end)

	helpers.it("takes the universal developer tools first, the python3 /usr/bin/python3 runs", function()
		local resolver = load({
			[CLT] = macho({ "x86_64", "arm64" }),
			["/opt/homebrew/bin/python3"] = macho({ "arm64" }),
		})
		helpers.assert_eq((resolver.resolve()), CLT)
		resolver._set_deps(nil)
	end)

	helpers.it("follows DEVELOPER_DIR, then the xcode-select link, like the shim", function()
		local xcode = "/Applications/Xcode-old.app/Contents/Developer"
		local resolver = load({ [xcode .. "/usr/bin/python3"] = macho({ "x86_64" }),
			[CLT] = macho({ "x86_64", "arm64" }) }, { select_link = xcode })
		local path, state = resolver.resolve()
		helpers.assert_nil(path, "the linked Intel Xcode is what /usr/bin/python3 would run")
		helpers.assert_eq(state.kind, "python_not_native")
		helpers.assert_eq(state.found[1].path, xcode .. "/usr/bin/python3")
		resolver._set_deps(nil)

		resolver = load({ ["/opt/dev/usr/bin/python3"] = macho({ "arm64" }) },
			{ developer_dir = "/opt/dev", select_link = xcode })
		helpers.assert_eq((resolver.resolve()), "/opt/dev/usr/bin/python3")
		resolver._set_deps(nil)
	end)

	helpers.it("names the state and every Intel interpreter when none is native", function()
		local resolver = load({
			[CLT] = macho({ "x86_64" }),
			["/usr/local/bin/python3"] = macho({ "x86_64" }),
		})
		local path, state = resolver.resolve()
		helpers.assert_nil(path)
		helpers.assert_eq(state.kind, "python_not_native")
		helpers.assert_eq(state.native, "arm64")
		helpers.assert_eq(#state.found, 2)
		helpers.assert_eq(state.found[1].path, CLT)
		helpers.assert_eq(table.concat(state.found[1].archs, ","), "x86_64")
		helpers.assert_eq(state.found[2].path, "/usr/local/bin/python3")
		resolver._set_deps(nil)
	end)

	helpers.it("names a Mac without any Python", function()
		local resolver = load({})
		local path, state = resolver.resolve()
		helpers.assert_nil(path)
		helpers.assert_eq(state.kind, "python_missing")
		helpers.assert_eq(#state.found, 0)
		resolver._set_deps(nil)
	end)

	helpers.it("refuses a framework whose Python.app lacks the native slice", function()
		local framework = "/Library/Frameworks/Python.framework/Versions/3.8"
		local resolver = load({
			["/Library/Frameworks/Python.framework/Versions/Current/bin/python3"] = macho({ "x86_64", "arm64" }),
			[framework .. "/Resources/Python.app/Contents/MacOS/Python"] = macho({ "x86_64" }),
		}, { realpath = {
			["/Library/Frameworks/Python.framework/Versions/Current/bin/python3"] = framework .. "/bin/python3.8",
		} })
		local path, state = resolver.resolve()
		helpers.assert_nil(path)
		helpers.assert_eq(state.found[1].path, framework .. "/Resources/Python.app/Contents/MacOS/Python")
		resolver._set_deps(nil)
	end)

	helpers.it("accepts a universal python.org link in /usr/local, and Intel ones on an Intel Mac", function()
		local resolver = load({ ["/usr/local/bin/python3"] = macho({ "x86_64", "arm64" }) })
		helpers.assert_eq((resolver.resolve()), "/usr/local/bin/python3")
		resolver._set_deps(nil)

		resolver = load({ ["/usr/local/bin/python3"] = macho({ "x86_64" }) }, { arch = "x86_64" })
		helpers.assert_eq((resolver.resolve()), "/usr/local/bin/python3")
		resolver._set_deps(nil)
	end)

	helpers.it("inspects a venv interpreter through its link: an Intel base is not native", function()
		local venv_python = "/Users/u/Library/Application Support/Ergopti/mlx-venv/bin/python"
		local resolver = load({ [venv_python] = macho({ "x86_64" }) })
		local ok, detail = resolver.inspect(venv_python)
		helpers.assert_true(not ok)
		helpers.assert_eq(detail.reason, "no_arm64_slice")
		resolver._set_deps(nil)
	end)
end)
