--- tests/unit/modules/dynamic_hotstrings/test_personal_info_save_transaction.lua

--- ==============================================================================
--- MODULE: Personal Information Save Transaction Regression
--- DESCRIPTION:
--- Exercises the real personal-information save path across its preview fence,
--- staged file commit, live table publication, and editor callback. A rejected
--- transition must preserve the old in-memory and on-disk value, while the UI
--- remains open so the user can retry without losing the submitted form.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ Transaction Test Tools =======
-- =========================================
-- =========================================

--- Reads a complete test file.
--- @param path string File path.
--- @return string content File contents.
local function read_file(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

--- Replaces os.rename for one protected call and restores it before asserting.
--- @param replacement function Temporary rename implementation.
--- @param callback function Protected operation.
--- @return any result Callback result.
local function with_rename(replacement, callback)
	local original = os.rename
	os.rename = replacement
	local ok, result = pcall(callback)
	os.rename = original
	if not ok then error(result, 0) end
	return result
end

--- Runs cleanup even when the behavioral assertions fail.
--- @param callback function Test body.
--- @param cleanup function Cleanup body.
local function with_cleanup(callback, cleanup)
	local ok, err = xpcall(callback, debug.traceback)
	local cleanup_ok, cleanup_err = xpcall(cleanup, debug.traceback)
	if not ok then error(err, 0) end
	if not cleanup_ok then error(cleanup_err, 0) end
end

--- Emulates successful replacement on the Windows test host.
--- Production uses the native same-directory rename on macOS.
--- @param staged_path string Staged file path.
--- @param target_path string Destination file path.
--- @return boolean committed True after replacement.
local function replace_file_for_test(staged_path, target_path)
	local staged = assert(io.open(staged_path, "rb"))
	local content = assert(staged:read("*a"))
	assert(staged:close())
	local target = assert(io.open(target_path, "wb"))
	assert(target:write(content))
	assert(target:close())
	assert(os.remove(staged_path))
	return true
end

--- Loads a fresh PersonalInfo instance with a controlled preview fence.
--- @param config_path string Existing personal_info.toml path.
--- @return table personal_info Real module instance.
--- @return table fence Mutable fence state.
local function load_personal_info(config_path)
	package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
	local personal_info = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")
	local fence = { allow = false, calls = 0, raises = false }
	local keymap = {
		get_trigger_char = function() return "★" end,
		register_interceptor = function() end,
		register_preview_provider = function() end,
		invalidate_hotstring_preview = function()
			fence.calls = fence.calls + 1
			if fence.raises then error("simulated preview revocation crash") end
			return fence.allow
		end,
	}
	personal_info.start("", keymap, config_path)
	return personal_info, fence
end

--- Loads the real editor with observable native-window test doubles.
--- @return table editor Real editor module.
--- @return function dispatch Sends one usercontent message.
--- @return table state Observable window and log counters.
local function load_editor()
	local hs_stub = require("tests.stubs.hs")
	local dispatch
	local state = { deletes = 0, focuses = 0, errors = {} }

	hs_stub.webview.windowMasks = { titled = 1, closable = 2 }
	hs_stub.webview.usercontent.new = function()
		return {
			setCallback = function(_, callback)
				dispatch = callback
			end,
		}
	end
	hs_stub.screen = {
		mainScreen = function()
			return { frame = function() return { w = 1440, h = 900 } end }
		end,
	}
	_G.hs = hs_stub

	package.loaded["infra.logger"] = {
		debug = function() end,
		info = function() end,
		error = function(_, message)
			state.errors[#state.errors + 1] = tostring(message)
		end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.paths"] = { shared = function() return "/shared/personal_info_editor" end }
	package.loaded["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 800, height = 700 } end,
		get_centered_frame = function(width, height) return { w = width, h = height } end,
		force_focus = function() state.focuses = state.focuses + 1 end,
		show_webview = function()
			return {
				delete = function() state.deletes = state.deletes + 1 end,
			}
		end,
	}
	package.loaded["ui.personal_info_editor"] = nil
	local editor = require("ui.personal_info_editor")
	return editor, function(message)
		helpers.assert_type(dispatch, "function", "the editor must install its real usercontent callback")
		dispatch({ body = message })
	end, state, function()
		package.loaded["ui.personal_info_editor"] = nil
		package.loaded["ui.ui_builder"] = nil
		helpers.load_with_stubs("infra.logger")
	end
end





-- ===================================================
-- ===================================================
-- ======= 2/ Personal Information Save Commit =======
-- ===================================================
-- ===================================================

helpers.describe("PersonalInfo.save_info transaction (personal-info-save-commit-gate)", function()
	helpers.it("publishes neither memory nor disk until preview revocation and rename commit", function()
		local config_path = os.tmpname()
		local staged_path = config_path .. ".ergopti-save.tmp"
		with_cleanup(function()
			local initial = "[info]\nfirst_name = \"Alice\"\n\n[letters]\np = \"first_name\"\n"
			local file = assert(io.open(config_path, "wb"))
			assert(file:write(initial))
			assert(file:close())

			local personal_info, fence = load_personal_info(config_path)
			local live_info = personal_info.get_info()
			helpers.assert_eq(live_info.first_name, "Alice")

			local fence_result = personal_info.save_info({ first_name = "Bob" })
			helpers.assert_eq(fence_result, false,
				"a rejected preview revocation must reject the entire save")
			helpers.assert_true(personal_info.get_info() == live_info,
				"a rejected save must preserve the published table identity")
			helpers.assert_eq(live_info.first_name, "Alice",
				"a rejected save must preserve the old live expansion value")
			helpers.assert_eq(read_file(config_path), initial,
				"a rejected save must not touch the committed TOML")

			fence.allow = "truthy"
			helpers.assert_eq(personal_info.save_info({ first_name = "Bob" }), false,
				"a truthy non-boolean fence result must not authorize publication")
			helpers.assert_eq(read_file(config_path), initial,
				"a non-boolean fence result must preserve the committed TOML")

			fence.raises = true
			helpers.assert_eq(personal_info.save_info({ first_name = "Bob" }), false,
				"a throwing preview fence must become an exact rejected save")
			helpers.assert_eq(live_info.first_name, "Alice",
				"a throwing preview fence must preserve the old live expansion value")
			helpers.assert_eq(read_file(config_path), initial,
				"a throwing preview fence must preserve the committed TOML")
			fence.raises = false

			fence.allow = true
			local rename_result = with_rename(function() return nil, "simulated rename failure" end,
				function() return personal_info.save_info({ first_name = "Bob" }) end)
			helpers.assert_eq(rename_result, false,
				"a failed staged-file publication must reject the entire save")
			helpers.assert_eq(live_info.first_name, "Alice",
				"a rename failure must not publish the candidate in memory")
			helpers.assert_eq(read_file(config_path), initial,
				"a rename failure must preserve the previous committed TOML")

			local committed = with_rename(function(staged_path_arg, target_path_arg)
				helpers.assert_eq(target_path_arg, config_path,
					"the native publication must target the configured TOML")
				helpers.assert_true(read_file(staged_path_arg):find('first_name = "Bob"', 1, true) ~= nil,
					"the complete candidate must exist in the staging file before publication")
				helpers.assert_eq(read_file(target_path_arg), initial,
					"the old committed TOML must remain intact until the rename boundary")
				return replace_file_for_test(staged_path_arg, target_path_arg)
			end,
				function() return personal_info.save_info({ first_name = "Bob" }) end)
			helpers.assert_eq(committed, true, "a complete transaction must report an exact commit")
			helpers.assert_true(personal_info.get_info() == live_info,
				"a successful save must preserve the shared live-table identity")
			helpers.assert_eq(live_info.first_name, "Bob",
				"memory must publish the candidate only after the file commit")
			helpers.assert_true(read_file(config_path):find('first_name = "Bob"', 1, true) ~= nil,
				"the committed TOML must contain the accepted candidate")
			helpers.assert_eq(fence.calls, 5, "every valid save attempt must cross the preview fence")
		end, function()
			os.remove(staged_path)
			os.remove(config_path)
			package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 3/ Editor Save Commit Feedback =======
-- ==============================================
-- ==============================================

helpers.describe("Personal information editor save result (personal-info-editor-retry)", function()
	helpers.it("keeps the same editor open when the save callback refuses the commit", function()
		local editor, dispatch, state, cleanup = load_editor()
		with_cleanup(function()
			editor.open({}, function() return false end)
			dispatch({ action = "save", values = { first_name = "Bob" } })

			helpers.assert_eq(state.deletes, 0,
				"a rejected save must not delete the editor and discard the user's form")
			helpers.assert_true(#state.errors > 0,
				"a rejected save must leave a developer-visible diagnostic")

			editor.open({}, function() return "truthy" end)
			dispatch({ action = "save", values = { first_name = "Bob" } })
			helpers.assert_eq(state.deletes, 0,
				"a truthy non-boolean callback result must not close the editor")

			editor.open({}, function() error("simulated save callback crash") end)
			dispatch({ action = "save", values = { first_name = "Bob" } })
			helpers.assert_eq(state.deletes, 0,
				"a throwing save callback must not escape or close the editor")

			editor.open({}, function() return true end)
			helpers.assert_eq(state.focuses, 3,
				"reopening after rejected saves must focus the retained singleton")
			dispatch({ action = "save", values = { first_name = "Bob" } })
			helpers.assert_eq(state.deletes, 1,
				"the editor may close only after the callback reports an exact commit")
		end, cleanup)
	end)
end)

return true
