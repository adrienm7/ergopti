--- tests/unit/modules/keymap/test_layout_registry.lua

--- ==============================================================================
--- MODULE: Layout Registry Conversion (Linux)
--- DESCRIPTION:
--- Linux prepares a registry layout by downloading its .keylayout and
--- converting it to XKB on the device with the converter the package ships
--- (layout-registry-convert). These tests replay the transaction through
--- injected collaborators with the real registry files: the download is
--- verified before anything is written, python3 is probed before the
--- conversion, a missing or too old python3 yields the translated explanation,
--- and the converter receives the verified file and the layout's convention.
--- The digest collaborator answers from a table of known contents: the real
--- SHA-256 is the file digest adapter's job, the refusal of a mismatch is this
--- module's.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local REGISTRY_DIR = helpers.driver_root() .. "/../../layouts/registry/"
local INDEX_URL = "https://raw.githubusercontent.com/adrienm7/ergopti/main/static/layouts/registry/index.json"
local ERGOL_URL = "https://raw.githubusercontent.com/adrienm7/ergopti/main/static/layouts/registry/ergol/ergol.keylayout"
local PYTHON_MESSAGE = "translated: layouts.linux_needs_python"

--- Reads a file of the repository registry byte for byte.
--- @param rel string
--- @return string
local function registry_file(rel)
	local handle = assert(io.open(REGISTRY_DIR .. rel, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Builds the collaborators of one preparation.
--- @param served table URL -> body; any other URL answers HTTP 404.
--- @param runs table Scripted process results, consumed in order.
--- @return table module, table deps, table state
local function fake_deps(served, runs)
	local Registry = require("layouts.registry")
	local LayoutRegistry = helpers.load_module("modules.keymap.layout_registry")
	local settings = assert(LayoutRegistry.settings())
	local ergol_sha = Registry.find_entry(Json.decode(registry_file("index.json")), "ergol").sha256
	local digests = { [registry_file("ergol/ergol.keylayout")] = ergol_sha }
	local state = { requests = {}, writes = {}, runs = {}, dirs = {} }
	local deps = {
		settings = settings,
		transport = {
			get = function(url, headers, timeout_ms, callback)
				state.requests[#state.requests + 1] = url
				if served[url] then callback(200, served[url], nil) else callback(404, "", "HTTP 404") end
			end,
			decode_json = Json.decode,
			sha256 = function(text, callback) callback(digests[text] or string.rep("0", 64), nil) end,
		},
		ensure_dir = function(dir)
			state.dirs[#state.dirs + 1] = dir
			return true
		end,
		write = function(path, content)
			state.writes[#state.writes + 1] = { path = path, content = content }
			return true
		end,
		run = function(program, args, options, callback)
			state.runs[#state.runs + 1] = { program = program, args = args, timeout_ms = options.timeout_ms }
			callback(assert(table.remove(runs, 1), "unexpected process run"))
			return true
		end,
		local_dir = "/cfg/layouts/",
		converter = "/pkg/linux/xkb_generation/keylayout_to_xkb.py",
		keycodes = "/pkg/_shared/modules/layouts/mac_keycodes.json",
		translate = function(key) return "translated: " .. key end,
	}
	return LayoutRegistry, deps, state
end

local OK_RUN = { exit_code = 0, stdout = "", stderr = "" }

--- Runs one preparation and returns its single terminal result.
local function prepare(id, served, runs, adjust)
	local LayoutRegistry, deps, state = fake_deps(served, runs)
	if adjust then adjust(deps) end
	local result = { calls = 0 }
	LayoutRegistry.install(id, function(ok, detail, user_message)
		result.calls = result.calls + 1
		result.ok, result.detail, result.user_message = ok, detail, user_message
	end, deps)
	helpers.assert_eq(result.calls, 1, "on_done must be called exactly once")
	return result, state
end

local function served_registry(layout_text)
	return { [INDEX_URL] = registry_file("index.json"), [ERGOL_URL] = layout_text }
end

--- Index of an argument's value in an argument vector.
local function arg_value(args, flag)
	for index, value in ipairs(args) do
		if value == flag then return args[index + 1] end
	end
	return nil
end

helpers.describe("layout registry (Linux): converting a registry layout on the device", function()
	helpers.it("names the shared defaults file it cannot decode (layout-registry-convert)", function()
		-- The shared json.lua answers nil to invalid JSON instead of raising, so a
		-- reader that only checks the pcall status loses the reason.
		local FileSystem = require("adapters.file_system")
		local LayoutRegistry = helpers.load_module("modules.keymap.layout_registry")
		local original_read = FileSystem.read
		local served = 0
		FileSystem.read = function(path)
			if type(path) == "string" and path:find("modules/layouts/defaults.json", 1, true) then
				served = served + 1
				return "{ not json"
			end
			return original_read(path)
		end
		local called, settings, err = pcall(LayoutRegistry.settings)
		FileSystem.read = original_read
		helpers.assert_true(called, "settings() must report, not raise: " .. tostring(settings))
		helpers.assert_eq(served, 1, "the malformed defaults file must be the one read")
		helpers.assert_nil(settings)
		helpers.assert_contains(tostring(err), "modules/layouts/defaults.json is not valid JSON")
	end)

	helpers.it("converts the verified layout with the shipped converter (layout-registry-convert)", function()
		local layout = registry_file("ergol/ergol.keylayout")
		local result, state = prepare("ergol", served_registry(layout), { OK_RUN, OK_RUN })
		helpers.assert_true(result.ok, "the preparation must succeed: " .. tostring(result.detail))
		helpers.assert_eq(result.detail.xkb_dir, "/cfg/layouts/ergol")
		helpers.assert_eq(#state.requests, 2)
		helpers.assert_eq(state.requests[1], INDEX_URL)
		helpers.assert_eq(state.requests[2], ERGOL_URL)
		helpers.assert_eq(state.dirs[1], "/cfg/layouts/", "the local folder is created first")
		helpers.assert_eq(state.writes[1].path, "/cfg/layouts/ergol.keylayout", "the layout first")
		helpers.assert_eq(state.writes[2].path, "/cfg/layouts/index.json", "then the index it matches")
		helpers.assert_true(state.writes[1].content == layout, "the verified bytes are what gets converted")
		helpers.assert_eq(#state.runs, 2, "a version probe, then the conversion")
		helpers.assert_eq(state.runs[1].program, "python3")
		helpers.assert_eq(state.runs[1].args[1], "-c")
		helpers.assert_contains(state.runs[1].args[2], "(3, 8)")
		local convert = state.runs[2]
		helpers.assert_eq(convert.program, "python3")
		helpers.assert_eq(convert.args[1], "/pkg/linux/xkb_generation/keylayout_to_xkb.py")
		helpers.assert_eq(arg_value(convert.args, "--keylayout"), "/cfg/layouts/ergol.keylayout")
		helpers.assert_eq(arg_value(convert.args, "--convention"), "ansi", "Ergo-L numbers its keys the ANSI way")
		helpers.assert_eq(arg_value(convert.args, "--layout-id"), "ergol")
		helpers.assert_eq(arg_value(convert.args, "--display-name"), "Ergo-L")
		helpers.assert_eq(arg_value(convert.args, "--index"), "/cfg/layouts/index.json")
		helpers.assert_eq(arg_value(convert.args, "--keycodes"), "/pkg/_shared/modules/layouts/mac_keycodes.json")
		helpers.assert_eq(arg_value(convert.args, "--out"), "/cfg/layouts/ergol")
		for index, value in ipairs(convert.args) do
			helpers.assert_type(value, "string", "argument " .. index .. " must be a string")
		end
	end)

	helpers.it("explains a missing or too old python3 in the user's language (layout-registry-convert)", function()
		local layout = registry_file("ergol/ergol.keylayout")
		local result, state = prepare("ergol", served_registry(layout),
			{ { exit_code = -1, stdout = "", stderr = "", error = "cannot start python3: ENOENT", not_found = true } })
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.user_message, PYTHON_MESSAGE)
		helpers.assert_eq(#state.runs, 1, "no conversion without an interpreter")

		result, state = prepare("ergol", served_registry(layout),
			{ { exit_code = 3, stdout = "", stderr = "", error = "python3 exited with code 3" } })
		helpers.assert_eq(result.user_message, PYTHON_MESSAGE, "Python 3.6 on RHEL 8 must get the same explanation")
		helpers.assert_contains(result.detail, "3.8 or newer", "the log names the version floor")
		helpers.assert_eq(#state.runs, 1)
	end)

	helpers.it("reports a failed conversion with the converter's own diagnostic (layout-registry-convert)", function()
		local result = prepare("ergol", served_registry(registry_file("ergol/ergol.keylayout")),
			{ OK_RUN, { exit_code = 3, stdout = "", stderr = "keylayout_to_xkb: bad layout", error = "exit 3" } })
		helpers.assert_true(result.ok == false)
		helpers.assert_contains(result.detail, "keylayout_to_xkb: bad layout")
		helpers.assert_nil(result.user_message)
	end)

	helpers.it("writes and runs nothing for an unverified or missing layout (layout-registry-convert)", function()
		local tampered = registry_file("ergol/ergol.keylayout"):gsub('output="q"', 'output="z"', 1)
		local result, state = prepare("ergol", served_registry(tampered), {})
		helpers.assert_contains(result.detail, "checksum")
		helpers.assert_eq(#state.writes, 0)
		helpers.assert_eq(#state.runs, 0)

		result, state = prepare("ergol", {}, {})
		helpers.assert_contains(result.detail, "HTTP 404")
		helpers.assert_eq(#state.writes + #state.runs, 0)

		result, state = prepare("ergol", served_registry(registry_file("ergol/ergol.keylayout")), {},
			function(deps) deps.converter = nil end)
		helpers.assert_contains(result.detail, "converter is not shipped")
		helpers.assert_eq(#state.runs, 0)
	end)

	helpers.it("finds the converter where the package and the source tree put it (layout-registry-convert)", function()
		local LayoutRegistry = helpers.load_module("modules.keymap.layout_registry")
		local packaged = LayoutRegistry.converter_path("/opt/ergopti/linux", function(path)
			return path == "/opt/ergopti/linux/xkb_generation/keylayout_to_xkb.py"
		end)
		helpers.assert_eq(packaged, "/opt/ergopti/linux/xkb_generation/keylayout_to_xkb.py")
		local source = LayoutRegistry.converter_path(helpers.driver_root(), function(path)
			local handle = io.open(path, "rb")
			if handle then handle:close() end
			return handle ~= nil
		end)
		helpers.assert_not_nil(source, "the source checkout must resolve the real converter")
		helpers.assert_contains(source, "ergopti/linux/xkb_generation/keylayout_to_xkb.py")
		helpers.assert_nil(LayoutRegistry.converter_path("/nowhere", function() return false end))
	end)
end)
