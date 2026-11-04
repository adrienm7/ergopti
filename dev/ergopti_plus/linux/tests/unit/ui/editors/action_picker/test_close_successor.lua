--- tests/unit/ui/editors/action_picker/test_close_successor.lua

--- ==============================================================================
--- MODULE: Action Picker Close Successor Ownership (Linux)
--- DESCRIPTION:
--- Native close acknowledgement can run another opener before returning. Only
--- the retired session may be forgotten; a fresh binding must remain usable.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Keeps only the native window port and provider factory inert.
--- @param body function Real bridge scenario.
local function with_picker(body)
	local names = { "ui.action_picker.bridge", "ui.webview_manager", "adapters.program_providers" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local seen = { visible = false, shows = 0, closes = 0, pushes = {}, picks = {} }
	local host = {
		show = function() seen.visible = true; seen.shows = seen.shows + 1; return true end,
		hide = function()
			seen.visible = false; seen.closes = seen.closes + 1
			if seen.on_close then local callback = seen.on_close; seen.on_close = nil; callback() end
			return true
		end,
		is_visible = function() return seen.visible end,
		eval_js = function(app, script) seen.pushes[#seen.pushes + 1] = { app, script }; return true end,
	}
	package.loaded["ui.webview_manager"] = host
	package.loaded["adapters.program_providers"] = {}
	local bridge = helpers.load_module("ui.action_picker.bridge")
	local fixture = { bridge = bridge, seen = seen, host = host }
	fixture.open = function(title)
		local options = { title = title, current = "none", items = {} }
		assert(bridge.open(options, function(id)
			seen.picks[#seen.picks + 1] = { title, id }
			return true
		end))
		return options
	end
	fixture.message = function(action, id)
		return bridge.on_message({ action = action, id = id }, {}, { close_owned_window = host.hide })
	end
	local okay, detail = xpcall(function() body(fixture) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not okay then error(detail, 0) end
end

helpers.describe("Action picker exact close successor", function()
	for _, action in ipairs({ "confirm", "cancel" }) do
		helpers.it("(picker-close-successor) keeps the replacement opened during " .. action, function()
			with_picker(function(f)
				f.open("Original binding")
				local successor
				f.seen.on_close = function() successor = f.open("Successor binding") end
				f.message(action, "tab_new")
				helpers.assert_eq(f.bridge.is_open(), true, "old native completion cannot erase a new picker")
				helpers.assert_eq(f.bridge.pending_opts, successor, "the new binding keeps its own pending options")
				helpers.assert_eq({ f.seen.shows, f.seen.closes }, { 2, 1 })
				helpers.assert_eq(f.seen.visible, true)
				f.message("ready")
				helpers.assert_eq(#f.seen.pushes, 1)
				helpers.assert_eq(f.seen.pushes[1][1], "action_picker")
				helpers.assert_true(f.seen.pushes[1][2]:find("Successor binding", 1, true) ~= nil)
				f.message("confirm", "tab_close")
				local expected = action == "confirm"
					and { { "Original binding", "tab_new" }, { "Successor binding", "tab_close" } }
					or { { "Successor binding", "tab_close" } }
				helpers.assert_eq(f.seen.picks, expected)
				helpers.assert_eq(f.seen.closes, 2)
				helpers.assert_eq(f.bridge.is_open(), false)
				helpers.assert_nil(f.bridge.pending_opts)
			end)
		end)
	end

	helpers.it("(picker-close-successor) an older replacement opener yields to native close reentry", function()
		with_picker(function(f)
			f.open("Original binding")
			local successor
			f.seen.on_close = function() successor = f.open("Later native binding") end
			local accepted = f.bridge.open({ title = "Earlier request", items = {} }, function()
				error("superseded assignment must not run")
			end)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(f.bridge.pending_opts, successor)
			helpers.assert_eq({ f.seen.shows, f.seen.closes }, { 2, 1 })
			f.message("confirm", "tab_close")
			helpers.assert_eq(f.seen.picks, { { "Later native binding", "tab_close" } })
		end)
	end)

	helpers.it("(picker-close-successor) an older native show cannot claim a later picker", function()
		with_picker(function(f)
			local successor
			local show = f.host.show
			f.host.show = function(...)
				local shown = show(...)
				f.host.show = show
				successor = f.open("Later shown binding")
				return shown
			end
			local accepted = f.bridge.open({ title = "Earlier request", items = {} }, function()
				error("superseded assignment must not run")
			end)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(f.bridge.pending_opts, successor)
			helpers.assert_eq(f.bridge.is_open(), true)
			f.message("confirm", "tab_close")
			helpers.assert_eq(f.seen.picks, { { "Later shown binding", "tab_close" } })
		end)
	end)
end)
