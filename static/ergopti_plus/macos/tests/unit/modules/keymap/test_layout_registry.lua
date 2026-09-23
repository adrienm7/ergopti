--- tests/unit/modules/keymap/test_layout_registry.lua

--- ==============================================================================
--- MODULE: Layout Registry Installation (macOS)
--- DESCRIPTION:
--- macOS installs a registry layout by placing its .keylayout, unchanged, in
--- ~/Library/Keyboard Layouts (layout-registry-install). These tests replay the
--- download through injected collaborators with the real registry files and
--- pin the whole transaction: the URLs come from the shared defaults, a layout
--- is written only once it matches its index, the installed file is the
--- registry file byte for byte, and every failure leaves nothing behind.
--- The digest collaborator answers from a table of known contents: the real
--- SHA-256 is the crypto adapter's job, the refusal of a mismatch is this one.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local REGISTRY_DIR = helpers.driver_root() .. "/../../layouts/registry/"
local INDEX_URL = "https://raw.githubusercontent.com/adrienm7/ergopti/main/static/layouts/registry/index.json"
local ERGOL_URL = "https://raw.githubusercontent.com/adrienm7/ergopti/main/static/layouts/registry/ergol/ergol.keylayout"

--- Reads a file of the repository registry byte for byte.
--- @param rel string
--- @return string
local function registry_file(rel)
	local handle = assert(io.open(REGISTRY_DIR .. rel, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Replaces the first literal occurrence of old in text.
--- @param text string
--- @param old string
--- @param new string
--- @return string
local function tamper(text, old, new)
	local first, last = text:find(old, 1, true)
	assert(first, "tamper target not found: " .. old)
	return text:sub(1, first - 1) .. new .. text:sub(last + 1)
end

--- Builds the collaborators of one installation.
--- @param served table URL -> body; any other URL answers HTTP 404.
--- @return table deps
--- @return table state { requests, writes, prepared }
local function fake_deps(served)
	local Registry = require("layouts.registry")
	local LayoutRegistry = helpers.load_with_stubs("modules.keymap.layout_registry")
	local settings = assert(LayoutRegistry.settings())
	local index_text = registry_file("index.json")
	local ergol_sha = Registry.find_entry(Json.decode(index_text), "ergol").sha256
	local digests = { [registry_file("ergol/ergol.keylayout")] = ergol_sha }
	local state = { requests = {}, writes = {}, prepared = {} }
	local deps = {
		settings = settings,
		transport = {
			get = function(url, headers, timeout_ms, callback)
				state.requests[#state.requests + 1] = { url = url, timeout_ms = timeout_ms, headers = headers }
				if served[url] then callback(200, served[url], nil) else callback(404, "", "HTTP 404") end
			end,
			decode_json = Json.decode,
			sha256 = function(text, callback)
				callback(digests[text] or string.rep("0", 64), nil)
			end,
		},
		write = function(path, content)
			state.writes[#state.writes + 1] = { path = path, content = content }
			return true
		end,
		prepare_parent = function(path)
			state.prepared[#state.prepared + 1] = path
			return true
		end,
		local_dir = "/cfg/layouts/",
		layouts_dir = "/home/Library/Keyboard Layouts/",
	}
	return LayoutRegistry, deps, state
end

--- Runs one installation and returns its single terminal result.
--- @return table result { ok, detail, calls }
local function install(id, served, adjust)
	local LayoutRegistry, deps, state = fake_deps(served)
	if adjust then adjust(deps) end
	local result = { calls = 0 }
	LayoutRegistry.install(id, function(ok, detail)
		result.calls = result.calls + 1
		result.ok, result.detail = ok, detail
	end, deps)
	helpers.assert_eq(result.calls, 1, "on_done must be called exactly once")
	return result, state
end

local function served_registry(layout_text)
	return { [INDEX_URL] = registry_file("index.json"), [ERGOL_URL] = layout_text }
end

helpers.describe("layout registry (macOS): installing a registry layout", function()
	helpers.it("reads the registry location from the shared defaults (layout-registry-install)", function()
		local LayoutRegistry = helpers.load_with_stubs("modules.keymap.layout_registry")
		local Registry = require("layouts.registry")
		local settings = assert(LayoutRegistry.settings())
		helpers.assert_eq(Registry.raw_url(settings, settings.index_file), INDEX_URL)
		helpers.assert_eq(settings.local_folder, "layouts")
		helpers.assert_eq(settings.timeout_ms, 30000)
		helpers.assert_true(Registry.is_valid_id("ergopti_plus_ansi"))
		helpers.assert_true(not Registry.is_valid_id("../evil"), "an id is a file name and must not escape the folder")
		helpers.assert_true(not Registry.is_valid_id("Ergol"))
	end)

	helpers.it("installs the verified .keylayout unchanged (layout-registry-install)", function()
		local layout = registry_file("ergol/ergol.keylayout")
		local result, state = install("ergol", served_registry(layout))
		helpers.assert_true(result.ok, "the installation must succeed: " .. tostring(result.detail))
		helpers.assert_eq(result.detail.path, "/home/Library/Keyboard Layouts/ergol.keylayout")
		helpers.assert_eq(result.detail.entry.id, "ergol")
		helpers.assert_eq(#state.requests, 2, "the index then the layout")
		helpers.assert_eq(state.requests[1].url, INDEX_URL)
		helpers.assert_eq(state.requests[2].url, ERGOL_URL)
		helpers.assert_eq(state.requests[1].timeout_ms, 30000, "every request is bounded by the shared budget")
		helpers.assert_eq(#state.writes, 3)
		helpers.assert_eq(state.writes[1].path, "/cfg/layouts/ergol.keylayout", "the local copy first")
		helpers.assert_eq(state.writes[2].path, "/cfg/layouts/index.json", "then the index it matches")
		helpers.assert_eq(state.writes[3].path, "/home/Library/Keyboard Layouts/ergol.keylayout")
		helpers.assert_true(state.writes[1].content == layout and state.writes[3].content == layout,
			"the installed file is the registry file byte for byte")
		helpers.assert_eq(state.writes[2].content, registry_file("index.json"))
		helpers.assert_eq(#state.prepared, 3, "every folder is created before its file")
	end)

	helpers.it("refuses a layout that does not match its index and writes nothing (layout-registry-install)", function()
		local layout = tamper(registry_file("ergol/ergol.keylayout"), 'output="q"', 'output="z"')
		local result, state = install("ergol", served_registry(layout))
		helpers.assert_true(result.ok == false)
		helpers.assert_contains(result.detail, "checksum")
		helpers.assert_eq(#state.writes, 0, "an unverified layout must never reach the disk")

		local truncated = registry_file("ergol/ergol.keylayout"):sub(1, -2)
		result, state = install("ergol", served_registry(truncated))
		helpers.assert_contains(result.detail, "bytes instead of")
		helpers.assert_eq(#state.writes, 0)
	end)

	helpers.it("reports every other failure and writes nothing (layout-registry-install)", function()
		local result, state = install("ergol", {})
		helpers.assert_contains(result.detail, "HTTP 404")
		helpers.assert_eq(#state.requests, 1, "no layout request after a failed index")
		helpers.assert_eq(#state.writes, 0)

		result, state = install("optimot", served_registry(registry_file("ergol/ergol.keylayout")))
		helpers.assert_contains(result.detail, "not in the registry index")
		helpers.assert_eq(#state.writes, 0)

		result, state = install("../evil", served_registry(registry_file("ergol/ergol.keylayout")))
		helpers.assert_contains(result.detail, "not a registry layout id")
		helpers.assert_eq(#state.requests, 0, "an invalid id is refused before any request")

		result, state = install("ergol", { [INDEX_URL] = "<html>proxy</html>" })
		helpers.assert_contains(result.detail, "not valid JSON")
		helpers.assert_eq(#state.writes, 0)

		local oversized = registry_file("index.json"):gsub('"size": 66273', '"size": 99999999', 1)
		result, state = install("ergol", { [INDEX_URL] = oversized })
		helpers.assert_contains(result.detail, "no usable file, size or checksum")
		helpers.assert_eq(#state.requests, 1, "an entry over the download bound is not downloaded")
	end)

	helpers.it("stops at the first write that fails (layout-registry-install)", function()
		local attempts = {}
		local result = install("ergol", served_registry(registry_file("ergol/ergol.keylayout")),
			function(deps)
				deps.write = function(path, content)
					attempts[#attempts + 1] = path
					if #attempts == 2 then return false, "disk full" end
					return true
				end
			end)
		helpers.assert_true(result.ok == false)
		helpers.assert_contains(result.detail, "disk full")
		helpers.assert_eq(#attempts, 2, "the layout is not installed once the local index could not be written")
		helpers.assert_eq(attempts[2], "/cfg/layouts/index.json")
	end)
end)
