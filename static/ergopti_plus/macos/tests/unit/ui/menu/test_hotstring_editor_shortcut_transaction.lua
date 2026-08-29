--- tests/unit/ui/menu/test_hotstring_editor_shortcut_transaction.lua

--- ==============================================================================
--- MODULE: Personal Hotstring Editor Shortcut Transaction
--- DESCRIPTION:
--- Drives the real personal-hotstring menu callback and the real editor shortcut
--- owner. A rejected replacement must preserve the acknowledged menu state,
--- preferences, rendered label, and previous live binding.
--- ==============================================================================

local helpers = require("tests.helpers")

local FAILURE_OUTCOMES = { "false", "nil", "throw" }


--- Returns a strict result double for a requested failure mode.
--- @param outcome string true|false|nil|throw.
--- @param calls table Mutable counters.
--- @param field string Counter field to increment.
--- @return function mutation
local function result_for(outcome, calls, field)
	return function()
		calls[field] = calls[field] + 1
		if outcome == "throw" then error("injected shortcut mutation failure", 0) end
		if outcome == "false" then return false end
		if outcome == "nil" then return nil end
		return true
	end
end


--- Finds the reachable shortcut row returned by the real custom-menu builder.
--- @param rows table|nil Provider rows.
--- @param prefix string Localized shortcut prefix.
--- @return table|nil row
local function find_shortcut_row(rows, prefix)
	for _, row in ipairs(type(rows) == "table" and rows or {}) do
		if type(row.label) == "string"
			and row.label:sub(1, #prefix) == prefix then
			return row
		end
		local nested = find_shortcut_row(row.items, prefix)
		if nested then return nested end
	end
	return nil
end


--- Runs one prompt result through the real menu callback.
--- @param raw string Prompt text.
--- @param outcome string Runtime setter outcome.
--- @return table fixture Observed state, calls, and callback result.
local function run_menu_action(raw, outcome)
	local saved_dialog = package.loaded["infra.dialog_util"]
	local saved_notifications = package.loaded["infra.notifications"]
	local saved_lifecycle = package.loaded["ui.menu.keymap_lifecycle"]
	local saved_custom = package.loaded["ui.menu.menu_hotstrings_custom"]
	local calls = { sets = 0, clears = 0, saves = 0, updates = 0, notices = 0 }
	local state = {
		keymap = true,
		hotstrings = { personal = true, custom = true },
		trigger_char = "★",
		custom_editor_shortcut = { mods = { "ctrl" }, key = "A" },
		custom_default_section = false,
		custom_close_on_add = false,
	}

	package.loaded["infra.dialog_util"] = {
		text_prompt = function() return "OK", raw end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(_title, _body, kind)
			helpers.assert_eq(kind, "error")
			calls.notices = calls.notices + 1
		end,
	}
	package.loaded["ui.menu.keymap_lifecycle"] = nil
	package.loaded["ui.menu.menu_hotstrings_custom"] = nil

	local ok, fixture_or_err = xpcall(function()
		local Custom = require("ui.menu.menu_hotstrings_custom")
		local shortcut_prefix = require("infra.i18n").get("menu.hotstrings.shortcut_prefix")
		helpers.assert_true(type(shortcut_prefix) == "string" and shortcut_prefix ~= "",
			"the localized shortcut prefix must be available")
		local ctx = {
			paused = false,
			state = state,
			hotfiles = { "personal.toml" },
			get_group_name = function() return "personal" end,
			applyTriggerChar = function(value) return value end,
			keymap = {
				is_group_enabled = function() return true end,
				get_sections = function() return nil end,
			},
			hotstring_editor = {
				open = function() end,
				set_shortcut = result_for(outcome, calls, "sets"),
				clear_shortcut = result_for(outcome, calls, "clears"),
			},
			save_prefs = function()
				calls.saves = calls.saves + 1
				return true
			end,
			updateMenu = function() calls.updates = calls.updates + 1 end,
		}
		local built = Custom.build_custom(ctx, { group_counts = {} })
		local row = find_shortcut_row(built and built.items, shortcut_prefix)
		helpers.assert_type(row, "table", "the rendered shortcut row must be reachable")
		helpers.assert_type(row.action, "function", "the rendered shortcut row must be clickable")
		return { result = row.action(), state = state, calls = calls }
	end, debug.traceback)

	package.loaded["infra.dialog_util"] = saved_dialog
	package.loaded["infra.notifications"] = saved_notifications
	package.loaded["ui.menu.keymap_lifecycle"] = saved_lifecycle
	package.loaded["ui.menu.menu_hotstrings_custom"] = saved_custom
	if not ok then error(fixture_or_err, 0) end
	return fixture_or_err
end


--- Loads the real editor against an inspectable registrar boundary.
--- The double mirrors the production bind/unbind/setEnabled surface and lets the
--- editor transaction, rather than the fixture, decide which handle is current.
--- @param body function Callback receiving editor and registrar fixture.
local function with_editor_registrar(body)
	local saved_registrar = package.loaded["adapters.hotkey_registrar"]
	local saved_editor = package.loaded["ui.hotstring_editor"]
	local calls = { bind = 0, unbind = 0, enable = 0, order = {} }
	local handles = {}
	local refuse_chord = nil
	local refuse_unbind = {}
	local next_handle = 0
	local registrar = {}

	function registrar.bind(chord, callback)
		calls.bind = calls.bind + 1
		calls.order[#calls.order + 1] = "bind:" .. chord
		if chord == refuse_chord then return nil end
		next_handle = next_handle + 1
		local handle = "handle#" .. tostring(next_handle)
		handles[handle] = { chord = chord, callback = callback, live = true, enabled = true }
		return handle
	end

	function registrar.unbind(handle)
		calls.unbind = calls.unbind + 1
		calls.order[#calls.order + 1] = "unbind:" .. tostring(handle)
		local entry = handles[handle]
		if not entry then return false end
		entry.enabled = false
		if refuse_unbind[handle] then return false end
		entry.live = false
		handles[handle] = nil
		return true
	end

	function registrar.setEnabled(handle, enabled)
		calls.enable = calls.enable + 1
		calls.order[#calls.order + 1] = "enable:" .. tostring(handle) .. ":" .. tostring(enabled)
		local entry = handles[handle]
		if not entry or not entry.live then return false end
		entry.enabled = enabled == true
		return true
	end

	package.loaded["adapters.hotkey_registrar"] = registrar
	package.loaded["ui.hotstring_editor"] = nil
	local ok, err = xpcall(function()
		local Editor = helpers.load_with_stubs("ui.hotstring_editor")
		body(Editor, {
			calls = calls,
			handles = handles,
			refuse = function(chord) refuse_chord = chord end,
			refuse_unbind = function(handle) refuse_unbind[handle] = true end,
		})
	end, debug.traceback)
	package.loaded["adapters.hotkey_registrar"] = saved_registrar
	package.loaded["ui.hotstring_editor"] = saved_editor
	if not ok then error(err, 0) end
end


helpers.describe("personal hotstring editor shortcut is transactional", function()
	helpers.it("rejects invalid prompt syntax before runtime or persistence", function()
		local fixture = run_menu_action("foo+bar", "true")
		helpers.assert_eq(fixture.result, false)
		helpers.assert_eq(fixture.calls.sets, 0)
		helpers.assert_eq(fixture.calls.saves, 0)
		helpers.assert_eq(fixture.calls.updates, 0)
		helpers.assert_eq(fixture.calls.notices, 1)
		helpers.assert_eq(fixture.state.custom_editor_shortcut,
			{ mods = { "ctrl" }, key = "A" })
	end)

	helpers.it("does not publish false, nil, or throwing runtime replacements", function()
		for _, outcome in ipairs(FAILURE_OUTCOMES) do
			local fixture = run_menu_action("cmd+v", outcome)
			helpers.assert_eq(fixture.result, false, outcome)
			helpers.assert_eq(fixture.calls.sets, 1, outcome)
			helpers.assert_eq(fixture.calls.saves, 0, outcome)
			helpers.assert_eq(fixture.calls.updates, 0, outcome)
			helpers.assert_eq(fixture.calls.notices, 1, outcome)
			helpers.assert_eq(fixture.state.custom_editor_shortcut,
				{ mods = { "ctrl" }, key = "A" }, outcome)
		end
	end)

	helpers.it("does not publish false, nil, or throwing runtime clears", function()
		for _, outcome in ipairs(FAILURE_OUTCOMES) do
			local fixture = run_menu_action("", outcome)
			helpers.assert_eq(fixture.result, false, outcome)
			helpers.assert_eq(fixture.calls.clears, 1, outcome)
			helpers.assert_eq(fixture.calls.saves, 0, outcome)
			helpers.assert_eq(fixture.calls.updates, 0, outcome)
			helpers.assert_eq(fixture.calls.notices, 1, outcome)
			helpers.assert_eq(fixture.state.custom_editor_shortcut,
				{ mods = { "ctrl" }, key = "A" }, outcome)
		end
	end)

	helpers.it("publishes one canonical shortcut only after exact true", function()
		local fixture = run_menu_action("option+k", "true")
		helpers.assert_eq(fixture.result, true)
		helpers.assert_eq(fixture.calls.sets, 1)
		helpers.assert_eq(fixture.calls.saves, 1)
		helpers.assert_eq(fixture.calls.updates, 1)
		helpers.assert_eq(fixture.calls.notices, 0)
		helpers.assert_eq(fixture.state.custom_editor_shortcut,
			{ mods = { "alt" }, key = "K" })
	end)

	helpers.it("rejects persisted shortcuts whose boot binding does not commit", function()
		for _, outcome in ipairs(FAILURE_OUTCOMES) do
			local calls = { sets = 0 }
			local MenuState = helpers.load_with_stubs("ui.menu.menu_state")
			local committed = MenuState.sync_state_to_modules({
				hotstrings = {},
				keymap = false,
				keylogger_enabled = false,
				custom_editor_shortcut = { mods = { "cmd" }, key = "V" },
			}, {}, false, {
				keymap = { set_llm_model = function() return true end },
				hotstring_editor = {
					set_shortcut = result_for(outcome, calls, "sets"),
				},
				core_mods = {},
				apply_metrics_shortcut = function() return true end,
				apply_apps_time_shortcut = function() return true end,
				save_prefs = function() return true end,
			})
			helpers.assert_eq(committed, false, outcome)
			helpers.assert_eq(calls.sets, 1, outcome)
		end
	end)

	helpers.it("keeps the prior live binding when validation or binding is refused", function()
		with_editor_registrar(function(Editor, fixture)
			helpers.assert_eq(Editor.set_shortcut({ "ctrl" }, "A"), true)
			local old = fixture.handles["handle#1"]
			helpers.assert_type(old, "table")

			helpers.assert_eq(Editor.set_shortcut({ "bogus" }, "B"), false)
			helpers.assert_eq(fixture.calls.bind, 1,
				"invalid syntax must not reach the registrar")
			helpers.assert_true(old.live and old.enabled,
				"validation refusal must preserve the prior binding")

			fixture.refuse("Cmd+B")
			helpers.assert_eq(Editor.set_shortcut({ "cmd" }, "B"), false)
			helpers.assert_eq(fixture.calls.bind, 2)
			helpers.assert_eq(fixture.calls.unbind, 0,
				"bind refusal must happen before releasing the prior handle")
			helpers.assert_true(old.live and old.enabled,
				"OS bind refusal must preserve the prior binding")
		end)
	end)

	helpers.it("rolls back a replacement when the prior handle cannot be released", function()
		with_editor_registrar(function(Editor, fixture)
			helpers.assert_eq(Editor.set_shortcut({ "ctrl" }, "A"), true)
			fixture.refuse_unbind("handle#1")
			helpers.assert_eq(Editor.set_shortcut({ "cmd" }, "B"), false)
			helpers.assert_nil(fixture.handles["handle#2"],
				"the candidate binding must be released during rollback")
			helpers.assert_true(fixture.handles["handle#1"].enabled,
				"the prior binding must be re-enabled after release refusal")
			helpers.assert_eq(fixture.calls.enable, 1)
		end)
	end)
end)
