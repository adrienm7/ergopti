--- tests/unit/ui/test_metrics_apps_categories_transaction.lua

--- ==============================================================================
--- MODULE: Metrics Apps Category Persistence Transaction Tests
--- DESCRIPTION:
--- Drives the real category editor over the classified FileSystem contract.
--- Unsafe source identities must never become an empty map, and no dashboard
--- state may publish before the symlink-revalidating atomic writer commits.
--- ==============================================================================

local helpers = require("tests.helpers")

local CONFIG_DIR = "/virtual/ergopti"
local TARGET_PATH = CONFIG_DIR .. "/data/app_categories.json"
local INITIAL_JSON = '{"Example":{"score":0,"type":"Old"}}'

--- Runs a callback with category-file adapter calls virtualized and observed.
--- Direct access to the category pathname throws so an io.open regression is
--- causal and cannot silently bypass the status stub.
--- @param spec table Read sequence, initial bytes, and write result.
--- @param callback function Receives module, state, chooser callbacks, logs.
local function with_category_store(spec, callback)
	local original_open = io.open
	local state = {
		target = spec.initial or INITIAL_JSON,
		exists = spec.initial_status ~= "absent",
		read_calls = 0,
		writes = 0,
		ui_pushes = 0,
	}
	local chooser_callbacks = {}
	local logs = {}

	io.open = function(path, mode)
		if path == TARGET_PATH then
			error("category persistence bypassed adapters.file_system in mode " .. tostring(mode))
		end
		return original_open(path, mode)
	end

	package.loaded["adapters.file_system"] = {
		read_with_status = function(path)
			helpers.assert_eq(path, TARGET_PATH)
			state.read_calls = state.read_calls + 1
			local observation = spec.read_sequence and spec.read_sequence[state.read_calls] or nil
			local status = observation and observation.status
				or (state.exists and (spec.read_status or "ok") or "absent")
			local detail = observation and observation.detail or spec.read_detail
			if status == "ok" then return state.target, "ok" end
			return nil, status, detail or status
		end,
		write = function(path, payload)
			helpers.assert_eq(path, TARGET_PATH)
			state.writes = state.writes + 1
			if spec.write_result == false then return false end
			state.target = payload
			state.exists = true
			return true
		end,
	}

	local noop = function() end
	package.loaded["infra.logger"] = {
		debug = noop, trace = noop, done = noop, info = noop, start = noop, success = noop,
		warn = function(_log, format_string, ...)
			logs[#logs + 1] = string.format(format_string, ...)
		end,
		error = function(_log, format_string, ...)
			logs[#logs + 1] = string.format(format_string, ...)
		end,
	}
	package.loaded["infra.dialog_util"] = {
		text_prompt = function(_title, _prompt, _prior, confirm, _cancel)
			return confirm, "1"
		end,
		alert = noop,
	}
	package.loaded["ui.ui_builder"] = {}

	local chooser = {
		new = function(on_choice)
			chooser_callbacks[#chooser_callbacks + 1] = on_choice
			local object = {}
			function object:placeholderText(_value) return self end
			function object:choices(_values) return self end
			function object:searchSubText(_enabled) return self end
			function object:show() return self end
			return object
		end,
	}
	local metrics = helpers.load_with_stubs("ui.metrics_apps", {
		configdir = CONFIG_DIR,
		chooser = chooser,
		application = { find = function() return nil end },
		image = {},
	})
	metrics._wv = {
		evaluateJavaScript = function(_self, _script)
			state.ui_pushes = state.ui_pushes + 1
		end,
	}

	local ok, result = xpcall(function()
		return callback(metrics, state, chooser_callbacks, logs)
	end, debug.traceback)

	io.open = original_open
	package.loaded["ui.metrics_apps"] = nil
	package.loaded["ui.ui_builder"] = nil
	package.loaded["infra.dialog_util"] = nil
	package.loaded["infra.logger"] = nil
	package.loaded["adapters.file_system"] = nil
	if not ok then error(result, 0) end
	return result
end

--- Opens the real category picker and selects a replacement category when the
--- production loader allowed the chooser to exist.
--- @param metrics table Real metrics_apps module.
--- @param callbacks function[] Captured chooser callbacks.
local function attempt_edit(metrics, callbacks)
	metrics.prompt_category("Example", "Old", 0)
	if callbacks[1] then callbacks[1]({ _kind = "pick", _value = "New" }) end
end





-- ================================================
-- ================================================
-- ======= 1/ Read Ownership Is Fail-Closed =======
-- ================================================
-- ================================================

helpers.describe("metrics_apps categories: unsafe input is never treated as empty", function()
	for _, case in ipairs({
		{ label = "EACCES", read_status = "error", read_detail = "permission denied" },
		{ label = "dangling symlink", read_status = "error", read_detail = "dangling target" },
		{ label = "directory", read_status = "error", read_detail = "not a regular file" },
		{ label = "corrupt JSON", read_status = "ok", initial = "{PRIVATE-CORRUPT-CATEGORY" },
	}) do
		helpers.it(case.label .. " preserves exact bytes and publishes no editor", function()
			with_category_store(case, function(metrics, state, callbacks, logs)
				local before = state.target
				attempt_edit(metrics, callbacks)
				helpers.assert_eq(#callbacks, 0,
					"a category editor must not open over state it failed to own")
				helpers.assert_eq(state.target, before,
					"read failure must preserve the user's exact committed category bytes")
				helpers.assert_eq(state.read_calls, 1,
					"the editor must consume one classified adapter snapshot")
				helpers.assert_eq(state.writes, 0,
					"unsafe input must never reach the publication boundary")
				helpers.assert_true(#logs > 0,
					"read refusal must be visible in the file logger")
			end)
		end)
	end

	helpers.it("a proven absence can create the first category file", function()
		with_category_store({ initial_status = "absent" }, function(metrics, state, callbacks, _logs)
			attempt_edit(metrics, callbacks)
			helpers.assert_eq(#callbacks, 1)
			helpers.assert_eq(state.writes, 1)
			helpers.assert_true(state.target:find('"type":"New"', 1, true) ~= nil)
			helpers.assert_eq(state.ui_pushes, 1)
		end)
	end)
end)





-- ======================================================
-- ======================================================
-- ======= 2/ Save Publication Is One Transaction =======
-- ======================================================
-- ======================================================

helpers.describe("metrics_apps categories: failed publication exposes no candidate", function()
	for _, failure in ipairs({ "write", "close", "rename" }) do
		helpers.it(failure .. " failure preserves disk and suppresses UI success", function()
			with_category_store({ write_result = false }, function(metrics, state, callbacks, logs)
				local before = state.target
				attempt_edit(metrics, callbacks)
				helpers.assert_eq(#callbacks, 1, "a valid source must expose one picker")
				helpers.assert_eq(state.target, before,
					failure .. " failure must preserve the previous committed file")
				helpers.assert_eq(state.writes, 1,
					failure .. " failure must reach the atomic adapter exactly once")
				helpers.assert_eq(state.ui_pushes, 0,
					failure .. " failure must not publish a success refresh")
				helpers.assert_true(#logs > 0,
					failure .. " failure must be visible in the file logger")
			end)
		end)
	end

	helpers.it("a retarget between source snapshots refuses the mutation before write", function()
		with_category_store({ read_sequence = {
			{ status = "ok" },
			{ status = "error", detail = "symlink identity changed" },
		} }, function(metrics, state, callbacks, logs)
			local before = state.target
			attempt_edit(metrics, callbacks)
			helpers.assert_eq(#callbacks, 1,
				"the first committed snapshot may expose the picker")
			helpers.assert_eq(state.read_calls, 2,
				"the accepted choice must re-read before building its mutation")
			helpers.assert_eq(state.writes, 0,
				"a changed source identity must never reach publication")
			helpers.assert_eq(state.target, before)
			helpers.assert_eq(state.ui_pushes, 0)
			helpers.assert_true(#logs > 0)
		end)
	end)

	helpers.it("a retarget refused by the writer preserves disk and UI state", function()
		with_category_store({ write_result = false }, function(metrics, state, callbacks, _logs)
			local before = state.target
			attempt_edit(metrics, callbacks)
			helpers.assert_eq(state.read_calls, 2)
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(state.target, before)
			helpers.assert_eq(state.ui_pushes, 0)
		end)
	end)

	helpers.it("success commits bytes before one UI refresh", function()
		with_category_store({}, function(metrics, state, callbacks, _logs)
			attempt_edit(metrics, callbacks)
			helpers.assert_eq(state.writes, 1,
				"the target must be published through one atomic adapter call")
			helpers.assert_true(state.target:find('"type":"New"', 1, true) ~= nil,
				"the committed file must contain the accepted category")
			helpers.assert_eq(state.ui_pushes, 1,
				"the dashboard may refresh exactly once after disk commit")
		end)
	end)
end)

return true
