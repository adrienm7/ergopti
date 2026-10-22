--- tests/unit/modules/shortcuts/actions/test_open_selection.lua

--- ==============================================================================
--- MODULE: copy_selected_path opens what the selection names (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/shortcuts/open_target_vectors.json, which the
--- macOS and Windows suites replay too, through _shared/lua/open_target with
--- the corpus's POSIX environment, then drives the real gesture dispatcher
--- with a recorded primary selection and a recording desktop opener.
---
--- ROOT CAUSE ENCODED:
--- The action did not exist on Linux, and the macOS and Windows versions sent
--- a selected IP address (192.168.1.1, 10.0.0.1:8080/admin) to a web search
--- instead of the browser (open-target-ip-address).
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local OpenTarget = require("open_target")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/shortcuts/open_target_vectors.json"

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the open-target corpus is not valid JSON")
end

--- Runs body with xclip answering `selection`.
local function with_selection(selection, body)
	local real_popen = io.popen
	io.popen = function()
		return { read = function() return selection end, close = function() return true end }
	end
	local ok, err = pcall(body)
	io.popen = real_popen
	if not ok then error(err, 0) end
end

--- Installs recording deps on the real open_selection module.
--- @param existing table|nil Paths that exist.
--- @return table world { opened, notices }
local function record(existing)
	local world = { opened = {}, notices = {} }
	local Subject = require("modules.shortcuts.open_selection")
	Subject._set_deps_for_test({
		open = function(target, on_done)
			world.opened[#world.opened + 1] = target
			on_done({ ok = true })
			return {}
		end,
		exists = function(path) return (existing or {})[path] == true end,
		notify = function(message) world.notices[#world.notices + 1] = message; return true end,
		getenv = function(name) return ({ HOME = "/home/ada" })[name] end,
	})
	return world, Subject
end

helpers.describe("copy_selected_path replays the shared open-target corpus", function()
	local corpus = read_corpus()
	local env = corpus.env.posix

	helpers.it("open-target: the corpus is loaded and exercises every kind", function()
		helpers.assert_true(#corpus.vectors >= 60, "the corpus must hold its vectors")
		local kinds = {}
		for _, vector in ipairs(corpus.vectors) do
			kinds[OpenTarget.classify(vector.text, function(name) return env[name] end).kind] = true
		end
		for _, kind in ipairs(OpenTarget.KINDS) do
			if kind ~= "registry" then
				helpers.assert_true(kinds[kind] == true, "the corpus must exercise the " .. kind .. " kind on Linux")
			end
		end
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("open-target vector '" .. vector.id .. "'", function()
			local want = vector.linux or vector.posix or vector.expect
			local got = OpenTarget.classify(vector.text, function(name) return env[name] end)
			helpers.assert_eq(got.kind, want.kind, vector.id .. ": kind")
			helpers.assert_eq(got.target, want.target, vector.id .. ": target")
			helpers.assert_eq(got.reason, want.reason, vector.id .. ": reason")
		end)
	end
end)

helpers.describe("copy_selected_path opens the primary selection (open-target-ip-address)", function()
	local G = helpers.load_module("modules.gestures.manager")
	G.init({ enabled = false })

	helpers.it("open-target: copy_selected_path is a Linux action now", function()
		local Catalogue = require("_generated.action_catalogue")
		local found = false
		for id in pairs(Catalogue.ACTIONS or Catalogue.actions or {}) do
			if id == "copy_selected_path" then found = true end
		end
		helpers.assert_true(found, "the Linux catalogue must offer copy_selected_path")
	end)

	for _, case in ipairs({
		{ "192.168.1.1", "http://192.168.1.1" },
		{ "10.0.0.1:8080/admin", "http://10.0.0.1:8080/admin" },
		{ "localhost:3000", "http://localhost:3000" },
		{ "example.com", "https://example.com" },
	}) do
		helpers.it("open-target: opens '" .. case[1] .. "' as " .. case[2] .. ", not a web search", function()
			local world, Subject = record()
			with_selection(case[1], function() G.execute_action("copy_selected_path", "tap_3") end)
			Subject._set_deps_for_test(nil)
			helpers.assert_eq(world.opened, { case[2] })
			helpers.assert_eq(#world.notices, 0)
		end)
	end

	helpers.it("open-target: opens an existing home-relative folder, reports a missing one (open-target-missing-path-reported)", function()
		local world, Subject = record({ ["/home/ada/Documents"] = true })
		Subject.open("~/Documents")
		Subject.open("/home/ada/nowhere")
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(world.opened, { "/home/ada/Documents" })
		helpers.assert_eq(#world.notices, 1, "the missing path must be reported, not searched")
		helpers.assert_true(world.notices[1]:find("/home/ada/nowhere", 1, true) ~= nil,
			"the notice names the path")
	end)

	helpers.it("open-target: reports a registry key and a bare file name instead of searching them", function()
		local world, Subject = record()
		Subject.open("HKLM\\SOFTWARE")
		Subject.open("notes.txt")
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(#world.opened, 0, "nothing must be opened, not even a search")
		helpers.assert_eq(#world.notices, 2)
	end)

	helpers.it("open-target: searches plain text with the shared default engine", function()
		local world, Subject = record()
		Subject.open("bonjour le monde")
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(world.opened, { OpenTarget.DEFAULT_SEARCH_URL .. "bonjour%20le%20monde" })
	end)
end)
