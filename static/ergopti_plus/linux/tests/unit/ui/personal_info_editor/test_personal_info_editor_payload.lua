--- tests/unit/ui/personal_info_editor/test_personal_info_editor_payload.lua

--- ==============================================================================
--- MODULE: Personal Info Editor Opening Payload And Refusal Paths
--- DESCRIPTION:
--- Pins what the page receives when it opens and what the bridge answers when a
--- save cannot complete, the Linux counterpart of the macOS personal-info
--- payload and save-transaction tests. The close ownership and the opening
--- source admission have their own files; this one covers the rest of the
--- handler contract.
---
--- FEATURES & RATIONALE:
--- 1. The field list is sorted by key, so the page order does not depend on
---    table iteration order.
--- 2. A field reachable through a letter alias shows its trigger hint; a field
---    with no alias shows none, so the page never invents a shortcut.
--- 3. A refused save leaves the editor open and tells the user once; a save the
---    catalogue could not reload is reported as saved but not reloaded.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the bridge over a stateless dynamic owner (no page epoch, so the
--- handler reads its dependencies from the state table only).
--- @param opts table|nil save, reload, letters, trigger and info overrides.
--- @return table fixture
local function fixture(opts)
	opts = opts or {}
	package.loaded["ui.personal_info_editor.bridge"] = nil
	local handler = require("ui.personal_info_editor.bridge")
	local seen = { pushed = {}, notices = {}, saves = {}, reloads = 0, closes = 0, changed = 0 }
	local dynamic = {
		get_info = function() return opts.info or { last_name = "Lovelace", first_name = "Ada", email = "" } end,
		get_letters = function() return opts.letters or { p = "first_name", n = "last_name" } end,
		get_trigger_char = function() return opts.trigger or "★" end,
		save_info = function(values)
			seen.saves[#seen.saves + 1] = values
			if opts.save_raises then error("disk full") end
			return opts.save_result ~= false
		end,
	}
	local state = {
		dyn_hotstrings = dynamic,
		webview_manager = {
			eval_js = function(_, code) seen.pushed[#seen.pushed + 1] = code; return opts.push_result ~= false end,
			hide = function() seen.closes = seen.closes + 1; return true end,
		},
		config = { reload = function() seen.reloads = seen.reloads + 1; return 0, opts.reload_result ~= false end },
		i18n = { get = function(key) return "T:" .. key end },
		notify_error = function(key) seen.notices[#seen.notices + 1] = key end,
		on_config_changed = function() seen.changed = seen.changed + 1 end,
	}
	return { handler = handler, state = state, seen = seen }
end

helpers.describe("personal info editor opening payload (linux-personal-payload)", function()
	helpers.it("lists the fields sorted by key with the trigger hint of aliased ones only", function()
		local f = fixture()
		local answer = f.handler.on_message({ action = "ready" }, f.state)
		helpers.assert_eq(answer.pushed, true)
		local keys, hints = {}, {}
		for _, field in ipairs(answer.data.fields) do
			keys[#keys + 1] = field.key
			hints[field.key] = field.hint
		end
		helpers.assert_eq(keys, { "email", "first_name", "last_name" })
		helpers.assert_eq(hints.first_name, "(@p★)")
		helpers.assert_eq(hints.last_name, "(@n★)")
		helpers.assert_eq(hints.email, "", "a field without an alias advertises no trigger")
		helpers.assert_eq(#f.seen.pushed, 1)
	end)

	helpers.it("translates the three window strings through the i18n owner", function()
		local f = fixture()
		local strings = f.handler.on_message({ action = "ready" }, f.state).data.strings
		helpers.assert_eq(strings["common.save"], "T:common.save")
		helpers.assert_eq(strings["common.cancel"], "T:common.cancel")
		helpers.assert_eq(strings["editor.personal_info.window_title"], "T:editor.personal_info.window_title")
	end)

	helpers.it("reports a page that could not receive the data", function()
		local f = fixture({ push_result = false })
		helpers.assert_eq(f.handler.on_message({ action = "ready" }, f.state).pushed, false)
	end)
end)

helpers.describe("personal info editor save outcomes (linux-personal-save)", function()
	helpers.it("a committed save reloads, announces the change and closes the page", function()
		local f = fixture()
		local answer = f.handler.on_message({ action = "save", values = { first_name = "Grace" } }, f.state)
		helpers.assert_eq(answer, { saved = true, reloaded = true, closed = true })
		helpers.assert_eq(f.seen.saves, { { first_name = "Grace" } })
		helpers.assert_eq(f.seen.reloads, 1)
		helpers.assert_eq(f.seen.changed, 1)
		helpers.assert_eq(f.seen.closes, 1)
	end)

	helpers.it("a refused save keeps the editor open and notifies once", function()
		local f = fixture({ save_result = false })
		local answer = f.handler.on_message({ action = "save", values = { first_name = "Grace" } }, f.state)
		helpers.assert_eq(answer, { saved = false, reloaded = false, closed = false })
		helpers.assert_eq(f.seen.notices, { "dialog.personal_info.save_failed" })
		helpers.assert_eq(f.seen.reloads, 0)
		helpers.assert_eq(f.seen.closes, 0)
	end)

	helpers.it("a raising persistence layer is a refused save, not a crash", function()
		local f = fixture({ save_raises = true })
		local answer = f.handler.on_message({ action = "save", values = { first_name = "Grace" } }, f.state)
		helpers.assert_eq(answer.saved, false)
		helpers.assert_eq(f.seen.notices, { "dialog.personal_info.save_failed" })
	end)

	helpers.it("a save without a values table never reaches persistence", function()
		local f = fixture()
		helpers.assert_eq(f.handler.on_message({ action = "save", values = "x" }, f.state).saved, false)
		helpers.assert_eq(#f.seen.saves, 0)
	end)

	helpers.it("a catalogue that does not reload leaves the page open and says so", function()
		local f = fixture({ reload_result = false })
		local answer = f.handler.on_message({ action = "save", values = { first_name = "Grace" } }, f.state)
		helpers.assert_eq(answer, { saved = true, reloaded = false, closed = false })
		helpers.assert_eq(f.seen.closes, 0)
		helpers.assert_eq(f.seen.changed, 0)
	end)

	helpers.it("ignores an unknown action and a payload that is not a table", function()
		local f = fixture()
		helpers.assert_eq(f.handler.on_message({ action = "bogus" }, f.state), nil)
		helpers.assert_eq(f.handler.on_message("save", f.state), nil)
	end)
end)
