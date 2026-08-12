--- tests/unit/ui/test_metrics_apps_categories_transaction.lua

--- ==============================================================================
--- MODULE: Metrics Apps Category Persistence Transaction Tests
--- DESCRIPTION:
--- Drives the real category editor over a virtual filesystem. An unreadable or
--- corrupt existing file must never become an empty category map, and a save is
--- visible to the dashboard only after staged write, flush, close, and rename
--- all commit.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================
-- =====================================
-- ======= 1/ Virtual Filesystem =======
-- =====================================
-- =====================================

local CONFIG_DIR = "/virtual/ergopti"
local TARGET_PATH = CONFIG_DIR .. "/data/app_categories.json"
local STAGED_PATH = TARGET_PATH .. ".tmp"
local INITIAL_JSON = '{"Example":{"score":0,"type":"Old"}}'

--- Builds one file handle whose effects stay observable after the call.
--- @param state table Virtual filesystem state.
--- @param path string Opened path.
--- @param mode string Open mode.
--- @return table handle
local function make_handle(state, path, mode)
	local handle = {}
	if mode == "w" then
		-- io.open(..., "w") truncates immediately, before write() is attempted.
		if path == TARGET_PATH then state.target = "" else state.staged = "" end
	end

	function handle:read(_format)
		if state.failure == "read" then error("PRIVATE-CATEGORY-READ-FAILURE") end
		return path == TARGET_PATH and state.target or state.staged
	end

	function handle:write(payload)
		if state.failure == "write" then return nil, "PRIVATE-CATEGORY-WRITE-FAILURE" end
		if path == TARGET_PATH then state.target = state.target .. payload
		else state.staged = state.staged .. payload end
		return self
	end

	function handle:flush()
		if state.failure == "flush" then return nil, "PRIVATE-CATEGORY-FLUSH-FAILURE" end
		return true
	end

	function handle:close()
		if state.failure == "close" and mode == "w" then
			return nil, "PRIVATE-CATEGORY-CLOSE-FAILURE"
		end
		return true
	end

	return handle
end

--- Runs a callback with category-file primitives virtualized and restored.
--- @param spec table Failure mode and initial bytes.
--- @param callback function Receives module, state, chooser callbacks, logs.
local function with_category_store(spec, callback)
	local original_open = io.open
	local original_remove = os.remove
	local original_rename = os.rename
	local original_execute = os.execute
	local state = {
		target = spec.initial or INITIAL_JSON,
		staged = nil,
		failure = spec.failure,
		renames = 0,
		removes = 0,
		ui_pushes = 0,
	}
	local chooser_callbacks = {}
	local logs = {}

	io.open = function(path, mode)
		if path ~= TARGET_PATH and path ~= STAGED_PATH then return original_open(path, mode) end
		if path == TARGET_PATH and mode == "r" and state.failure == "eacces" then
			return nil, "PRIVATE-CATEGORY-OPEN-FAILURE", 13
		end
		return make_handle(state, path, mode)
	end
	os.remove = function(path)
		if path ~= STAGED_PATH then return original_remove(path) end
		state.removes = state.removes + 1
		state.staged = nil
		return true
	end
	os.rename = function(from, to)
		if from ~= STAGED_PATH or to ~= TARGET_PATH then return original_rename(from, to) end
		state.renames = state.renames + 1
		if state.failure == "rename" then return nil, "PRIVATE-CATEGORY-RENAME-FAILURE" end
		state.target = state.staged
		state.staged = nil
		return true
	end
	os.execute = function(_command) return true, "exit", 0 end

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
	os.remove = original_remove
	os.rename = original_rename
	os.execute = original_execute
	package.loaded["ui.metrics_apps"] = nil
	package.loaded["infra.dialog_util"] = nil
	package.loaded["ui.ui_builder"] = nil
	package.loaded["infra.logger"] = nil
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
-- ======= 2/ Read Ownership Is Fail-Closed =======
-- ================================================
-- ================================================

helpers.describe("metrics_apps categories: unreadable input is never treated as empty", function()
	for _, case in ipairs({
		{ label = "EACCES", failure = "eacces", initial = INITIAL_JSON },
		{ label = "corrupt JSON", failure = nil, initial = "{PRIVATE-CORRUPT-CATEGORY" },
	}) do
		helpers.it(case.label .. " preserves exact bytes and publishes no editor", function()
			with_category_store(case, function(metrics, state, callbacks, logs)
				local before = state.target
				attempt_edit(metrics, callbacks)
				helpers.assert_eq(#callbacks, 0,
					"a category editor must not open over state it failed to own")
				helpers.assert_eq(state.target, before,
					"read failure must preserve the user's exact committed category bytes")
				helpers.assert_eq(state.renames, 0,
					"read failure must never reach the publication boundary")
				helpers.assert_true(#logs > 0,
					"read refusal must be visible in the file logger")
			end)
		end)
	end
end)





-- ======================================================
-- ======================================================
-- ======= 3/ Save Publication Is One Transaction =======
-- ======================================================
-- ======================================================

helpers.describe("metrics_apps categories: staged save commits exactly once", function()
	for _, failure in ipairs({ "write", "close", "rename" }) do
		helpers.it(failure .. " failure preserves disk and suppresses UI success", function()
			with_category_store({ failure = failure }, function(metrics, state, callbacks, logs)
				local before = state.target
				attempt_edit(metrics, callbacks)
				helpers.assert_eq(#callbacks, 1, "a valid source must expose one picker")
				helpers.assert_eq(state.target, before,
					failure .. " failure must preserve the previous committed file")
				helpers.assert_eq(state.ui_pushes, 0,
					failure .. " failure must not publish a success refresh")
				helpers.assert_true(#logs > 0,
					failure .. " failure must be visible in the file logger")
			end)
		end)
	end

	helpers.it("success publishes staged bytes before one UI refresh", function()
		with_category_store({}, function(metrics, state, callbacks, _logs)
			attempt_edit(metrics, callbacks)
			helpers.assert_eq(state.renames, 1,
				"the target must be published through one same-directory rename")
			helpers.assert_true(state.target:find('"type":"New"', 1, true) ~= nil,
				"the committed file must contain the accepted category")
			helpers.assert_eq(state.ui_pushes, 1,
				"the dashboard may refresh exactly once after disk commit")
		end)
	end)
end)

return true
