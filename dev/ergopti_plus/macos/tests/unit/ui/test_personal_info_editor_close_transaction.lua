--- tests/unit/ui/test_personal_info_editor_close_transaction.lua

--- ==============================================================================
--- MODULE: Personal Information Editor Close Transaction Regression
--- DESCRIPTION:
--- Drives the public editor lifecycle across a throwing native WebView delete.
--- The singleton owner and its bridge must remain reachable until an exact retry
--- succeeds, preventing a second editor from being created beside the first.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================
-- ======================================
-- ======= 1/ Stateful UI Fixture =======
-- ======================================
-- ======================================

--- Loads the real editor with a stateful WebView double.
--- @return table editor
--- @return table runtime
local function load_fixture()
	local runtime = { creates = 0, delete_throws = false, deletes = 0, focuses = 0 }
	local webview = {
		delete = function(self)
			runtime.deletes = runtime.deletes + 1
			if runtime.delete_throws then error("synthetic personal editor delete refusal") end
			return self
		end,
	}

	hs.webview = {
		windowMasks = { titled = 1, closable = 2 },
		usercontent = {
			new = function()
				return { setCallback = function(self, callback) self.callback = callback; return self end }
			end,
		},
	}
	hs.screen = {
		mainScreen = function()
			return { frame = function() return { w = 1440, h = 900 } end }
		end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.paths"] = { shared = function() return "/virtual/shared" end }
	package.loaded["infra.deferred_work"] = { after = function() return true end }
	package.loaded["ui.ui_builder"] = {
		force_focus = function(owner)
			helpers.assert_eq(owner, webview)
			runtime.focuses = runtime.focuses + 1
			return true
		end,
		get_app_geometry = function() return { width = 800, height = 600 } end,
		get_centered_frame = function(width, height) return { w = width, h = height } end,
		show_webview = function()
			runtime.creates = runtime.creates + 1
			return webview
		end,
	}
	package.loaded["ui.personal_info_editor"] = nil
	package.loaded["ui.personal_info_editor.init"] = nil
	return require("ui.personal_info_editor"), runtime
end





-- ==================================
-- ==================================
-- ======= 2/ Close Ownership =======
-- ==================================
-- ==================================

helpers.describe("personal information editor retains refused native closes", function()
	helpers.it("keeps the exact singleton until WebView delete succeeds", function()
		local Editor, runtime = load_fixture()
		Editor.open({}, function() return true end)
		helpers.assert_eq(runtime.creates, 1)

		runtime.delete_throws = true
		helpers.assert_eq(Editor.close(), false,
			"a throwing native delete must be an explicit close refusal")
		Editor.open({}, function() return true end)
		helpers.assert_eq(runtime.creates, 1,
			"the refused owner must be focused instead of replaced")
		helpers.assert_eq(runtime.focuses, 1)

		runtime.delete_throws = false
		helpers.assert_eq(Editor.close(), true,
			"retry must settle the exact retained WebView")
		Editor.open({}, function() return true end)
		helpers.assert_eq(runtime.creates, 2,
			"a successor is allowed only after native deletion commits")
	end)
end)
