--- tests/unit/ui/personal_info_editor/test_personal_info_editor_close.lua

--- ==============================================================================
--- MODULE: Personal Info Editor Close Ownership
--- DESCRIPTION:
--- Pins what closing a personal-info page revokes, the Linux counterpart of the
--- macOS close-transaction tests: only the exact closed epoch loses its
--- retained source, a save from a closed page never reaches persistence, and a
--- fresh opening of the same window is admitted again.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the bridge over a recording dynamic owner and a host whose page stays
--- current, so only the bridge's own close bookkeeping can refuse a save.
--- @return table fixture
local function fixture()
	package.loaded["ui.personal_info_editor.bridge"] = nil
	local handler = require("ui.personal_info_editor.bridge")
	local seen = { saves = {}, captures = 0, closes = 0, notices = 0, pushes = 0 }
	local dynamic = {
		get_info = function() return { first_name = "Ada" } end,
		capture_info_edit = function()
			seen.captures = seen.captures + 1
			return { capture = seen.captures }, { first_name = "Ada" }, { p = "first_name" }, "★"
		end,
		save_info = function(values, receipt)
			seen.saves[#seen.saves + 1] = { values = values, receipt = receipt }
			return true, { capture = "after-save" }
		end,
	}
	local host = {
		current_epoch = function() return seen.epoch end,
		page_current = function(_, expected) return expected == seen.epoch end,
		eval_js = function() seen.pushes = seen.pushes + 1; return true end,
	}
	local state = {
		dyn_hotstrings = dynamic, webview_manager = host,
		config = { reload = function() return 0, false end },
		i18n = { get = function(key) return key end },
		notify_error = function() seen.notices = seen.notices + 1 end,
	}
	local f = { handler = handler, seen = seen }
	function f.open(epoch)
		seen.epoch = epoch
		f.context = { app_name = "personal_info_editor", epoch = epoch,
			close_owned_window = function() seen.closes = seen.closes + 1; return true end }
		return handler.on_message({ action = "ready" }, state, f.context)
	end
	function f.save(name) return handler.on_message({ action = "save", values = { first_name = name } }, state, f.context) end
	function f.cancel() return handler.on_message({ action = "cancel" }, state, f.context) end
	return f
end

helpers.describe("personal info editor close ownership (linux-personal-close)", function()
	helpers.it("a foreign epoch close keeps the open page's retained source", function()
		local f = fixture()
		helpers.assert_eq(f.open(7).pushed, true)
		f.handler.on_window_closed(8)
		helpers.assert_eq(f.save("Grace"), { saved = true, reloaded = false, closed = false })
		helpers.assert_eq(#f.seen.saves, 1)
		helpers.assert_eq(f.seen.saves[1].receipt, { capture = 1 })
	end)

	helpers.it("the exact epoch close revokes the source before any persistence", function()
		local f = fixture()
		helpers.assert_eq(f.open(7).pushed, true)
		f.handler.on_window_closed(7)
		helpers.assert_eq(f.save("Grace"), { saved = false, reloaded = false, closed = false })
		helpers.assert_eq(#f.seen.saves, 0, "a closed page never reaches save_info")
		helpers.assert_eq(f.seen.notices, 0, "a page that is no longer ours gets no refusal notice")
	end)

	helpers.it("a fresh opening after close captures and saves with its own source", function()
		local f = fixture()
		f.open(7); f.handler.on_window_closed(7)
		helpers.assert_eq(f.open(7).pushed, true)
		helpers.assert_eq(f.save("Grace").saved, true)
		helpers.assert_eq(f.seen.saves[1].receipt, { capture = 2 }, "the new opening's capture, not the revoked one")
	end)

	helpers.it("cancel closes the exact page without persistence", function()
		local f = fixture()
		f.open(7)
		helpers.assert_eq(f.cancel(), { cancelled = true, closed = true })
		helpers.assert_eq(f.seen.closes, 1)
		helpers.assert_eq(#f.seen.saves, 0)
	end)
end)
