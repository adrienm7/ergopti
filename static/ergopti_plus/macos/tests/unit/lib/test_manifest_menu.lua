--- tests/unit/lib/test_manifest_menu.lua

--- ==============================================================================
--- MODULE: Regression — ManifestMenu.build silently skips items with no handler (F-HIGH-25)
--- DESCRIPTION:
--- The "dynamic" and "action" dispatch branches in ManifestMenu.build fell
--- through silently when dynamic_handlers[id] was absent — unlike the sibling
--- "group" branch (which already warns on a missing id/i18n) and the unknown-type
--- else branch (which already warns on an unrecognised type). This let a
--- misclassified or drifted manifest entry vanish from the rendered menu with
--- zero diagnostic trail: personal_shortcuts was a live instance (declared with
--- no platforms restriction, so expected on macOS too, but menu_shortcuts.lua's
--- dyn_handlers had no matching key) before this same fix tagged it AHK-only.
---
--- Fix: log Logger.warn on a handler miss in both the "dynamic" and "action"
--- branches, matching the existing warn-on-drift convention already used by
--- the "group" and unknown-type branches.
---
--- This test exercises M.build with an EMPTY dynamic_handlers table against a
--- manifest entry of type "dynamic" (via a throwaway fixture manifest) and
--- asserts Logger.warn fires — it fails before the fix (zero warn calls,
--- silent skip) and passes after.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.manifest_menu_fixture")

local MANIFEST = [[
{
	"test_menu": [
		{ "type": "dynamic", "id": "no_such_dynamic_handler" },
		{ "type": "action", "id": "no_such_action_handler" }
	]
}
]]


--- Builds a logger stub that records every Logger.warn call's format string.
--- @return table logger_stub Injectable package.loaded["infra.logger"] replacement.
--- @return table warn_messages Array of format strings passed to Logger.warn (grows live).
local function make_warn_capturing_logger()
	local warn_messages = {}
	local logger_stub = helpers.make_logger_stub()
	logger_stub.warn = function(_module, fmt, ...)
		-- Logger.warn(module, fmt, ...) formats internally, like the real logger —
		-- capture the FORMATTED message so id substitutions are actually visible.
		local ok, formatted = pcall(string.format, fmt, ...)
		warn_messages[#warn_messages + 1] = ok and formatted or tostring(fmt)
	end
	return logger_stub, warn_messages
end

helpers.describe("ManifestMenu.build: warns (does not silently skip) on a handler miss (F-HIGH-25)", function()
	helpers.it("logs Logger.warn when a type=dynamic entry has no matching dynamic_handlers key", function()
		local logger_stub, warn_messages = make_warn_capturing_logger()
		fixture.with_manifest(MANIFEST, logger_stub, function(ManifestMenu)

			-- Empty dynamic_handlers: neither fixture entry has a matching handler.
			local built = ManifestMenu.build("test_menu", "Test", {}, nil, {})

			helpers.assert_eq(#built, 0, "no item should be rendered when no handler matches")
			helpers.assert_true(#warn_messages > 0,
				"Logger.warn must fire when a type=dynamic/action entry has no matching handler — " ..
				"silently skipping it hides a permanently vanished menu item (F-HIGH-25)")

			local saw_dynamic_warn = false
			local saw_action_warn = false
			for _, msg in ipairs(warn_messages) do
				if msg:find("no_such_dynamic_handler", 1, true) then saw_dynamic_warn = true end
				if msg:find("no_such_action_handler", 1, true) then saw_action_warn = true end
			end
			helpers.assert_true(saw_dynamic_warn, "a missing 'dynamic' handler must be named in the warning")
			helpers.assert_true(saw_action_warn, "a missing 'action' handler must be named in the warning")
		end)
	end)
end)

helpers.describe("ManifestMenu decoding returns independent values (json-shared-tables)", function()
	helpers.it("equal menu arrays and nested objects can be edited independently (json-shared-tables)", function()
		local document = [[
{
	"first": [{ "type": "action", "id": "same", "options": { "label": "original" } }],
	"second": [{ "type": "action", "id": "same", "options": { "label": "original" } }]
}
]]
		local first, second = fixture.with_manifest(document, nil, function(ManifestMenu)
			local first = ManifestMenu.get_array("first")
			local second = ManifestMenu.get_array("second")
			first[1].options.label = "changed"
			first[#first + 1] = { type = "action", id = "added" }
			return first, second
		end)

		helpers.assert_true(not rawequal(first, second), "equal menu arrays must be distinct")
		helpers.assert_true(not rawequal(first[1], second[1]), "equal menu rows must be distinct")
		helpers.assert_true(not rawequal(first[1].options, second[1].options),
			"equal nested options must be distinct")
		helpers.assert_eq(first[1].options.label, "changed")
		helpers.assert_eq(#first, 2)
		helpers.assert_eq(second[1].options.label, "original", "editing one menu must leave its twin unchanged")
		helpers.assert_eq(#second, 1, "appending to one menu must leave its twin unchanged")
	end)
end)


helpers.describe("shared command provider policy", function()
	local document = [[
{
	"editor": [{ "type": "command", "id": "open", "i18n": "menu.hotstrings.open_editor", "disabled_when": ["ready"] }],
	"reason": [{ "type": "command", "id": "open", "i18n": "menu.hotstrings.open_editor", "disabled_when": ["ready"], "disabled_reason_key": "menu.about.source_run_reason" }],
	"check": [{ "type": "check", "id": "on", "i18n": "menu.hotstrings.open_editor", "checked_when": ["on"] }]
}
]]
	helpers.it("shared-personal-editor-policy: regular and provider commands retain their native shape", function()
		fixture.with_manifest(document, nil, function(Menu)
			local ready, calls = true, 0
			local action = function() calls = calls + 1 end
			local commands, getters = { open = action }, { ready = function() return ready end }
			local normal = Menu.build("editor", "Hotstrings", nil, nil, { commands = commands, state_getters = getters })
			local data = Menu.command_row("editor", "open", commands, getters)
			local rendered = Menu.render_rows({ data }, "test_editor")
			helpers.assert_eq(#normal, 1)
			helpers.assert_eq(#rendered, 1)
			helpers.assert_eq(normal[1].title, rendered[1].title)
			helpers.assert_eq(normal[1].disabled, rendered[1].disabled)
			helpers.assert_eq(normal[1].checked, nil)
			helpers.assert_eq(rendered[1].checked, nil)
			helpers.assert_eq(normal[1].fn, action, "existing build callback identity is unchanged")
			data.action()
			helpers.assert_eq(calls, 1)
			ready = false
			helpers.assert_eq(data.action(), false)
			helpers.assert_eq(calls, 1, "held provider delivery rereads the declaration")
			local grey = Menu.command_row("reason", "open", commands, getters)
			local normal_grey = Menu.build("reason", "Hotstrings", nil, nil, { commands = commands, state_getters = getters })
			helpers.assert_eq(grey.label, normal_grey[1].title)
			helpers.assert_eq(grey.action, nil)
			helpers.assert_eq(grey.disabled, normal_grey[1].disabled)
			local check = Menu.build("check", "Hotstrings", nil, nil,
				{ commands = { on = action }, state_getters = { on = function() return true end } })
			helpers.assert_eq(check[1].checked, true, "existing checkbox shape is retained")
		end)
	end)
	helpers.it("shared-personal-editor-policy: the canonical label can change without a native row", function()
		fixture.with_manifest(document, nil, function(Menu)
			local items = Menu.get_array("editor")
			items[1].i18n = "menu.hotstrings.open_file"
			local row = Menu.command_row("editor", "open", { open = function() end }, { ready = function() return true end })
			helpers.assert_eq(row.label, require("infra.i18n").get("menu.hotstrings.open_file"))
		end)
	end)
	helpers.it("shared-personal-editor-policy: absent declaration or owner refuses provider data", function()
		fixture.with_manifest(document, nil, function(Menu)
			helpers.assert_eq(Menu.command_row("editor", "missing", {}, {}), nil)
			helpers.assert_eq(Menu.command_row("editor", "open", {}, {}), nil)
			local data = Menu.command_row("editor", "open", { open = function() error("unowned readiness cannot open") end }, {})
			helpers.assert_eq(data.disabled, true)
			helpers.assert_eq(data.action(), false)
		end)
	end)
end)
