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
		document_owner_current = function(owner) return owner == seen.document end,
		document_owner_retained = function(owner) return owner == seen.document end,
		eval_owned_js = function(_, owner)
			if owner ~= seen.document then return false end
			seen.pushes = seen.pushes + 1; return seen.push_allowed ~= false
		end,
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
		seen.document = {}
		f.context = { app_name = "personal_info_editor", epoch = epoch, document_owner = seen.document,
			close_owned_window = function() seen.closes = seen.closes + 1; return true end }
		return handler.on_message({ action = "ready" }, state, f.context)
	end
	function f.ready() return handler.on_message("ready", state, f.context) end
	function f.save_from(context, name) return handler.on_message({ action = "save", values = { first_name = name } }, state, context) end
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

	helpers.it("duplicate ready preserves the original capture", function()
		local f = fixture()
		helpers.assert_eq(f.open(7).pushed, true)
		helpers.assert_eq(f.ready().pushed, true)
		helpers.assert_eq(f.seen.captures, 1)
		helpers.assert_eq(f.seen.pushes, 1)
		helpers.assert_eq(f.save("Grace").saved, true)
		helpers.assert_eq(f.seen.saves[1].receipt, { capture = 1 })
	end)

	helpers.it("a refused injection retries the same captured source", function()
		local f = fixture()
		f.seen.push_allowed = false
		helpers.assert_eq(f.open(7).pushed, false)
		helpers.assert_eq(f.save("early").saved, false)
		helpers.assert_eq(#f.seen.saves, 0)
		f.seen.push_allowed = true
		helpers.assert_eq(f.ready().pushed, true)
		helpers.assert_eq(f.seen.captures, 1)
		helpers.assert_eq(f.seen.pushes, 2)
		helpers.assert_eq(f.save("Grace").saved, true)
		helpers.assert_eq(f.seen.saves[1].receipt, { capture = 1 })
	end)

	helpers.it("a replacement document at the same epoch revokes the previous receipt", function()
		local f = fixture()
		helpers.assert_eq(f.open(7).pushed, true)
		local old = f.context
		helpers.assert_eq(f.open(7).pushed, true)
		helpers.assert_eq(f.save_from(old, "stale").saved, false)
		helpers.assert_eq(f.save("Grace").saved, true)
		helpers.assert_eq(#f.seen.saves, 1)
		helpers.assert_eq(f.seen.saves[1].receipt, { capture = 2 })
	end)

	helpers.it("cancel closes the exact page without persistence", function()
		local f = fixture()
		f.open(7)
		helpers.assert_eq(f.cancel(), { cancelled = true, closed = true })
		helpers.assert_eq(f.seen.closes, 1)
		helpers.assert_eq(#f.seen.saves, 0)
	end)
end)

helpers.describe("personal info actual document route", function()
	helpers.it("admits one source per confirmed document and rejects the previous document", function()
		local saved = package.loaded["ui.personal_info_editor.bridge"]
		package.loaded["ui.personal_info_editor.bridge"] = nil
		local handler = require("ui.personal_info_editor.bridge")
		local captures, saves = 0, {}
		local dynamic = {
			get_info = function() return {} end,
			capture_info_edit = function()
				captures = captures + 1
				return { capture = captures }, { name = "Ada" }, {}, "★"
			end,
			save_info = function(_, receipt) saves[#saves + 1] = receipt; return true, {} end,
		}
		local c = require("tests.support.document_fixture").new("personal_info_editor", handler, {
			dyn_hotstrings = dynamic, config = { reload = function() return 0, false end },
			i18n = { get = function(key) return key end },
		})
		local ok, err = pcall(function()
			c.handshake()
			local view = c.view()
			local old = view.confirmed
			helpers.assert_eq(captures, 1)
			helpers.assert_eq(#c.effects, 1)
			c.send({ action = "ready" }, view)
			helpers.assert_eq(captures, 1)
			helpers.assert_eq(#c.effects, 1)
			c.handshake()
			helpers.assert_eq(captures, 2)
			c.send({ action = "save", values = { name = "stale" } }, view, old)
			helpers.assert_eq(#saves, 0)
			c.send({ action = "save", values = { name = "Grace" } }, view)
			helpers.assert_eq(saves[1], { capture = 2 })
		end)
		c.close()
		package.loaded["ui.personal_info_editor.bridge"] = saved
		if not ok then error(err) end
	end)
end)
