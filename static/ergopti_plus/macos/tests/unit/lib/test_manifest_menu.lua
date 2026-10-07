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


helpers.describe("inert existing-provider status data", function()
	local function status_definition(Menu)
		for _, item in ipairs(Menu.get_array("llm_menu")) do
			if item.id == "llm_backend" then return item.status_rows.unavailable end
		end
		error("Canonical backend status declaration is missing")
	end
	local document = [[
{
	"llm_menu": [{ "type": "dynamic", "id": "llm_backend", "status_rows": { "unavailable": [
		{ "type": "---" },
		{ "type": "label", "i18n": "menu.llm.local_servers.header" },
		{ "type": "label", "i18n": "menu.llm.unavailable" }
	] } }]
}
]]
	local function assert_inert_rows(Menu, Mutate)
		local definition = status_definition(Menu)
		helpers.assert_eq(#definition, 3)
		local header, unavailable = definition[2], definition[3]
		local old_caption = unavailable.i18n
		local outcome = table.pack(pcall(function()
			if Mutate then
				unavailable.i18n = "menu.llm.local_servers.rescan"
				definition[2], definition[3] = unavailable, header
			end
			local rows = Menu.status_rows("llm_menu", "llm_backend", "unavailable")
			helpers.assert_type(rows, "table")
			helpers.assert_eq(#rows, 3)
			helpers.assert_true(rows[1].separator)
			local tr = require("infra.i18n").get
			helpers.assert_eq(rows[2].label, tr(Mutate and "menu.llm.local_servers.rescan" or "menu.llm.local_servers.header"))
			helpers.assert_eq(rows[3].label, tr(Mutate and "menu.llm.local_servers.header" or "menu.llm.unavailable"))
			for index = 2, 3 do
				helpers.assert_eq(rows[index].disabled, true)
				helpers.assert_nil(rows[index].action)
				helpers.assert_nil(rows[index].items)
				helpers.assert_nil(rows[index].submenu)
			end
		end))
		definition[2], definition[3] = header, unavailable
		unavailable.i18n = old_caption
		if not outcome[1] then error(outcome[2], 0) end
	end

	helpers.it("returns only exact translated inactive data without command owners", function()
		fixture.with_manifest(document, nil, function(Menu) assert_inert_rows(Menu, false) end)
	end)
	helpers.it("reads caption and order from the current child declaration", function()
		fixture.with_manifest(document, nil, function(Menu) assert_inert_rows(Menu, true) end)
	end)
	helpers.it("refuses a malformed label without partial template data", function()
		fixture.with_manifest(document, nil, function(Menu)
			status_definition(Menu)[3].i18n = ""
			helpers.assert_nil(Menu.status_rows("llm_menu", "llm_backend", "unavailable"))
		end)
	end)
end)


helpers.describe("ordered child template native list and conditional include contract", function()
	local function with_frame(body)
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_template_api.json"
		local Menu = assert(require("menu.renderer").new({
			platform = "hs",
			manifest_path = function() return path end,
			json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end },
			logger = helpers.make_logger_stub(),
		}))
		local handle = assert(io.open(path, "rb"))
		local oracle = require("json").decode(handle:read("*a")); handle:close()
		local state = { ready = true, present = true, calls = 0, phases = {} }
		local function native_action() state.calls = state.calls + 1; return false end
		local builtin = { label = "Builtin native", checked = true, action = native_action }
		local custom = { label = "Custom native", items = { { label = "Native child", action = native_action } } }
		local getters = {
			ready = function() return state.ready end,
			custom_present = function() state.phases[#state.phases + 1] = "custom_present"; return state.present end,
		}
		local children = {
			builtins = function(...) helpers.assert_eq(select("#", ...), 0); state.phases[#state.phases + 1] = "builtins"; return { builtin } end,
			customs = function(...) helpers.assert_eq(select("#", ...), 0); state.phases[#state.phases + 1] = "customs"; return { custom } end,
		}
		body(Menu, { create = native_action, clone = native_action }, getters, children, state, oracle._expected, builtin, custom)
	end
	local function shape(rows)
		local labels = {}
		for _, row in ipairs(rows) do labels[#labels + 1] = row.separator and "---" or row.label end
		return table.concat(labels, "|")
	end
	helpers.it("splices real canonical data lazily at declaration positions and selects exact command order", function()
		with_frame(function(Menu, commands, getters, children, state, expected, builtin, custom)
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(shape(rows), table.concat(expected.present, "|"))
			helpers.assert_eq(table.concat(state.phases, "|"), table.concat(expected.phases, "|"))
			helpers.assert_true(rawequal(rows[2], builtin))
			helpers.assert_true(rawequal(rows[5], custom))
			helpers.assert_true(rawequal(rows[5].items, custom.items))
			local rendered = Menu.render_rows(rows, "frame")
			helpers.assert_eq(rendered[2].checked, true)
			helpers.assert_eq(rendered[5].menu[1].fn(), false)
			helpers.assert_eq(state.calls, 1)
			helpers.assert_eq(rows[6].action(), false)
			helpers.assert_eq(state.calls, 2)
			state.ready = false
			helpers.assert_eq(rows[6].action(), false)
			helpers.assert_eq(state.calls, 2, "existing command readiness remains live")
			state.ready = true
			Menu.get_array("commands")[2].id = "withdrawn"
			helpers.assert_eq(rows[6].action(), false)
			helpers.assert_eq(state.calls, 2, "selected command declaration withdrawal is effect free")
		end)
	end)
	helpers.it("a false presence getter skips the whole fragment without calling its native list", function()
		with_frame(function(Menu, commands, getters, children, state, expected)
			state.present = false
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(shape(rows), table.concat(expected.absent, "|"))
			helpers.assert_eq(table.concat(state.phases, "|"), "builtins|custom_present")
			helpers.assert_eq(state.calls, 0)
		end)
	end)
	helpers.it("empty native lists remain valid and legacy whole-section includes retain their order", function()
		with_frame(function(Menu, commands, getters, children)
			children.builtins, children.customs = function() return {} end, function() return {} end
			Menu.get_array("frame")[4].row_id = nil
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(shape(rows), "menu.profiles.header_default_profiles|---|menu.profiles.header_custom_profiles|menu.profiles.create_profile|menu.profiles.clone_builtin|---|menu.profiles.create_profile")
		end)
	end)
	helpers.it("platform filtering hides a selected original command without invoking another command", function()
		with_frame(function(Menu, commands, getters, children, state)
			Menu.get_array("commands")[2].platforms = { "linux" }
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(#rows, 7)
			helpers.assert_eq(rows[7].label, "menu.profiles.create_profile")
			helpers.assert_eq(state.calls, 0)
		end)
	end)
	helpers.it("lazy group children run after native lists and the actual check getter", function()
		with_frame(function(Menu, commands, getters, children, state)
			local declaration = Menu.get_array("frame")
			declaration[#declaration + 1] = { type = "check", id = "auto", i18n = "menu.profiles.auto_detect", checked_when = { "auto_checked" } }
			declaration[#declaration + 1] = { type = "group", id = "apps", i18n = "menu.profiles.per_app_overrides" }
			commands.auto = function() return false end
			getters.auto_checked = function() state.phases[#state.phases + 1] = "autodetect"; return true end
			local native = { label = "Native application", action = function() state.calls = state.calls + 1; return false end }
			children.apps = function(...)
				helpers.assert_eq(select("#", ...), 0)
				state.phases[#state.phases + 1] = "perapp"
				return { native }
			end
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(table.concat(state.phases, "|"), "builtins|custom_present|customs|autodetect|perapp")
			helpers.assert_eq(rows[9].checked, true)
			helpers.assert_true(rawequal(rows[10].items[1], native))
			local rendered = Menu.render_rows(rows, "native_phase_frame")
			helpers.assert_eq(rendered[10].menu[1].fn(), false)
			helpers.assert_eq(state.calls, 1)
		end)
	end)
	helpers.it("existing eager Array group identity and policy stay unchanged", function()
		with_frame(function(Menu, commands, getters, children)
			local declaration = Menu.get_array("frame")
			declaration[#declaration + 1] = { type = "group", id = "apps", i18n = "menu.profiles.per_app_overrides", disabled_when = { "group_ready" } }
			local native = { { label = "Existing application", action = function() return false end } }
			children.apps = native
			getters.group_ready = function() return false end
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_true(rawequal(rows[9].items, native))
			helpers.assert_eq(rows[9].disabled, true)
			helpers.assert_nil(rows[9].action)
		end)
	end)
	local group_refusals = {
		{ "missing", function() return nil end },
		{ "noncallable", function() return true end },
		{ "throw", function() return function() error("per-app native read refused") end end },
		{ "wrongtype", function() return function() return false end end },
		{ "sparse", function() return function() return { [2] = { label = "gap" } } end end },
		{ "scalar child", function() return function() return { false } end end },
		{ "driver dialect", function() return function() return { { title = "wrong", fn = function() end } } end end },
		{ "missing label", function() return function() return { { action = function() end } } end end },
		{ "empty label", function() return function() return { { label = "" } } end end },
		{ "wrong separator type", function() return function() return { { label = "Native", separator = "true" } } end end },
	}
	for _, refusal in ipairs(group_refusals) do
		helpers.it("refuses lazy group " .. refusal[1] .. " without returning a partial frame", function()
			with_frame(function(Menu, commands, getters, children, state)
				local declaration = Menu.get_array("frame")
				declaration[#declaration + 1] = { type = "group", id = "apps", i18n = "menu.profiles.per_app_overrides" }
				children.apps = refusal[2]()
				helpers.assert_nil(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(state.calls, 0)
			end)
		end)
	end
	local refusals = {
		{ "missing list provider", function(_, _, _, children) children.builtins = nil end },
		{ "noncallable list data", function(_, _, _, children) children.builtins = {} end },
		{ "throwing list provider", function(_, _, _, children) children.builtins = function() error("list refused") end end },
		{ "nil list result", function(_, _, _, children) children.builtins = function() end end },
		{ "nonarray list result", function(_, _, _, children) children.builtins = function() return false end end },
		{ "sparse list result", function(_, _, _, children) children.builtins = function() return { [2] = { label = "gap" } } end end },
		{ "metamethod forged dense array", function(_, _, _, children) children.builtins = function() return setmetatable({ [2] = { label = "gap" } }, { __len = function() return 1 end, __pairs = function() return ipairs({ { label = "forged" } }) end }) end end },
		{ "metamethod forged canonical label", function(_, _, _, children) children.builtins = function() return { setmetatable({}, { __index = { label = "forged" } }) } end end },
		{ "string keyed list result", function(_, _, _, children) children.builtins = function() return { bad = { label = "bad" } } end end },
		{ "scalar child", function(_, _, _, children) children.builtins = function() return { false } end end },
		{ "driver dialect child", function(_, _, _, children) children.builtins = function() return { { title = "wrong", fn = function() end } } end end },
		{ "missing canonical label", function(_, _, _, children) children.builtins = function() return { { action = function() end } } end end },
		{ "empty native label", function(_, _, _, children) children.builtins = function() return { { label = "" } } end end },
		{ "wrong native separator type", function(_, _, _, children) children.builtins = function() return { { label = "Native", separator = "true" } } end end },
		{ "missing presence getter", function(_, _, getters) getters.custom_present = nil end },
		{ "noncallable presence getter", function(_, _, getters) getters.custom_present = true end },
		{ "throwing presence getter", function(_, _, getters) getters.custom_present = function() error("presence refused") end end },
		{ "nil presence", function(_, _, getters) getters.custom_present = function() end end },
		{ "numeric presence", function(_, _, getters) getters.custom_present = function() return 1 end end },
		{ "string presence", function(_, _, getters) getters.custom_present = function() return "true" end end },
		{ "empty presence identity", function(Menu) Menu.get_array("frame")[3].present_when = "" end },
		{ "missing selected identity", function(Menu) Menu.get_array("frame")[4].row_id = "missing" end },
		{ "empty selected identity", function(Menu) Menu.get_array("frame")[4].row_id = "" end },
		{ "wrong type selected identity", function(Menu) Menu.get_array("frame")[4].row_id = false end },
		{ "duplicate selected identity", function(Menu) Menu.get_array("commands")[1].id = "clone" end },
		{ "missing include even when false", function(Menu, _, _, _, state) state.present = false; Menu.get_array("frame")[3].section = "missing" end },
		{ "unsupported include metadata", function(Menu) Menu.get_array("frame")[4].i18n = "native fallback" end },
		{ "fixed label disguised as list", function(Menu) Menu.get_array("frame")[2].i18n = "native fallback" end },
		{ "cyclic selected include", function(Menu) local row = Menu.get_array("commands")[2]; row.type, row.section = "include", "frame"; row.id = nil; Menu.get_array("frame")[4].row_id = nil end },
	}
	for _, refusal in ipairs(refusals) do
		helpers.it("refuses " .. refusal[1] .. " without a partial frame or a native command effect", function()
			with_frame(function(Menu, commands, getters, children, state)
				refusal[2](Menu, commands, getters, children, state)
				helpers.assert_nil(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(state.calls, 0)
			end)
		end)
	end
end)


helpers.describe("explicit inert presentation omission preserves actual native data", function()
	local function with_presentation(body)
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
		local state = { calls = 0, getters = 0, errors = {}, phases = {} }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) state.errors[#state.errors + 1] = string.format(fmt, ...) end
		local Menu = assert(require("menu.renderer").new({
			platform = "hs", manifest_path = function() return path end,
			json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger,
		}))
		local builtin = { label = "Builtin native", action = function() state.calls = state.calls + 1; return false end }
		local custom = { label = "Custom native", items = { { label = "Native child", action = function() state.calls = state.calls + 1 end } } }
		local children = {
			builtins = function() state.phases[#state.phases + 1] = "builtins"; return { builtin } end,
			customs = function() state.phases[#state.phases + 1] = "customs"; return { custom } end,
		}
		local getters = { forbidden = function() state.getters = state.getters + 1; return true end }
		body(Menu, { forbidden = builtin.action }, getters, children, state, builtin, custom)
	end
	local function labels(rows)
		local result = {}
		for _, row in ipairs(rows) do result[#result + 1] = row.separator and "---" or row.label end
		return table.concat(result, "|")
	end
	helpers.it("recursively composes valid inert presentation before unchanged native objects and callbacks", function()
		with_presentation(function(Menu, commands, getters, children, state, builtin, custom)
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(labels(rows), "menu.profiles.header_default_profiles|---|menu.profiles.header_custom_profiles|Builtin native|Custom native")
			helpers.assert_true(rawequal(rows[4], builtin))
			helpers.assert_true(rawequal(rows[5], custom))
			helpers.assert_eq(rows[4].action(), false)
			helpers.assert_eq(state.calls, 1)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	helpers.it("valid hidden presentation preserves native data without logging a refusal", function()
		with_presentation(function(Menu, commands, getters, children, state)
			local rows = Menu.get_array("presentation")
			for i = #rows, 2, -1 do rows[i] = nil end
			rows[1].platforms, rows[1].unavailable = { "ahk" }, "hide"
			local actual = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(labels(actual), "Builtin native|Custom native")
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	local omissions = {
		{ "missing", function(Menu) Menu.get_array("frame")[1].section = "missing" end },
		{ "empty", function(Menu) local rows = Menu.get_array("presentation"); for i = #rows, 1, -1 do rows[i] = nil end end },
		{ "malformed caption", function(Menu) Menu.get_array("presentation")[1].i18n = "" end },
		{ "unknown row", function(Menu) Menu.get_array("presentation")[3].type = "unknown" end },
		{ "clicked command", function(Menu) local row = Menu.get_array("presentation")[3]; row.type, row.section, row.id, row.i18n = "command", nil, "forbidden", "caption"; row.disabled_when = { "forbidden" } end },
		{ "clicked child", function(Menu) local row = Menu.get_array("presentation")[3]; row.type, row.section, row.id, row.i18n = "group", nil, "customs", "caption" end },
		{ "label getter", function(Menu) Menu.get_array("nested")[1].caption_getter = "forbidden" end },
		{ "header callback", function(Menu) Menu.get_array("presentation")[1].action = function() error("must not execute") end end },
		{ "conditional nested include", function(Menu) Menu.get_array("presentation")[3].present_when = "forbidden" end },
		{ "nested cycle", function(Menu) Menu.get_array("presentation")[3].section = "presentation" end },
		{ "nested missing", function(Menu) Menu.get_array("presentation")[3].section = "missing" end },
		{ "sparse presentation", function(Menu) Menu.get_array("presentation")[2] = nil end },
		{ "malformed platforms", function(Menu) Menu.get_array("presentation")[1].platforms = "hs" end },
		{ "inherited target getter", function(Menu) setmetatable(Menu.get_array("presentation")[1], { __index = { caption_getter = "forbidden" } }) end },
		{ "forged target membership", function(Menu) setmetatable(Menu.get_array("presentation"), { __len = function() return 1 end }) end },
		{ "selected inert row with clicked sibling", function(Menu)
			Menu.get_array("frame")[1].row_id = "safe"
			Menu.get_array("presentation")[1].id = "safe"
			Menu.get_array("presentation")[3] = { type = "command", id = "forbidden", i18n = "caption", disabled_when = { "forbidden" } }
		end },
	}
	for _, omission in ipairs(omissions) do
		helpers.it("logs and omits " .. omission[1] .. " before any clicked/getter work, preserving native data", function()
			with_presentation(function(Menu, commands, getters, children, state, builtin, custom)
				omission[2](Menu)
				local rows = assert(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(labels(rows), "Builtin native|Custom native")
				helpers.assert_true(rawequal(rows[1], builtin))
				helpers.assert_true(rawequal(rows[2], custom))
				helpers.assert_eq(state.getters, 0)
				helpers.assert_eq(state.calls, 0)
				helpers.assert_eq(table.concat(state.phases, "|"), "builtins|customs")
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_true(state.errors[1]:find("presentation omitted", 1, true) ~= nil)
				helpers.assert_eq(rows[1].action(), false)
				helpers.assert_eq(state.calls, 1)
			end)
		end)
	end
	local strict = {
		{ "unknown enum", function(Menu) Menu.get_array("frame")[1].on_refusal = "ignore" end },
		{ "empty enum", function(Menu) Menu.get_array("frame")[1].on_refusal = "" end },
		{ "false enum", function(Menu) Menu.get_array("frame")[1].on_refusal = false end },
		{ "missing include identity", function(Menu) Menu.get_array("frame")[1].section = "" end },
		{ "bad selector", function(Menu) Menu.get_array("frame")[1].row_id = "missing" end },
		{ "missing presence getter", function(Menu) Menu.get_array("frame")[1].present_when = "missing" end },
		{ "throwing presence getter", function(Menu, getters) Menu.get_array("frame")[1].present_when = "forbidden"; getters.forbidden = function() error("owner refused") end end },
		{ "wrong presence type", function(Menu, getters) Menu.get_array("frame")[1].present_when = "forbidden"; getters.forbidden = function() return 1 end end },
		{ "native provider failure", function(_, _, children) children.customs = function() error("real native read failed") end end },
		{ "policy on a native list", function(Menu) Menu.get_array("frame")[2].on_refusal = "omit_presentation" end },
		{ "strict ordinary include", function(Menu) local row = Menu.get_array("frame")[1]; row.on_refusal = nil; row.section = "missing" end },
	}
	for _, refusal in ipairs(strict) do
		helpers.it("keeps " .. refusal[1] .. " a refusal rather than a generic success fallback", function()
			with_presentation(function(Menu, commands, getters, children, state)
				refusal[2](Menu, getters, children)
				helpers.assert_nil(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(state.calls, 0)
			end)
		end)
	end
end)


helpers.describe("inert presentation platform membership cannot invoke implicit getters", function()
	helpers.it("omits a metatable-forged platform array before renderer iteration, retaining physical native data", function()
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
		local callbacks, errors = 0, {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		local Menu = assert(require("menu.renderer").new({ platform = "hs",
			manifest_path = function() return path end, json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger }))
		Menu.get_array("presentation")[1].platforms = setmetatable({ "ahk" }, {
			__index = function(_, index) callbacks = callbacks + 1; if index == 2 then return "hs" end end,
		})
		local builtin, custom = { label = "Builtin native" }, { label = "Custom native" }
		local rows = assert(Menu.template_rows("frame", {}, {}, {
			builtins = function() return { builtin } end, customs = function() return { custom } end,
		}))
		helpers.assert_eq(callbacks, 0, "raw platform proof cannot later execute an implicit callback")
		helpers.assert_eq(#rows, 2, "the malformed inert target is completely omitted on both Lua VMs")
		helpers.assert_true(rawequal(rows[1], builtin) and rawequal(rows[2], custom))
		helpers.assert_eq(#errors, 1)
		helpers.assert_true(errors[1]:find("presentation omitted", 1, true) ~= nil)
	end)
end)


helpers.describe("selected inert include inspects only physical identities before whole-target proof", function()
	for _, mode in ipairs({ "scalar sibling", "inherited sibling identity", "inherited target membership" }) do
		helpers.it("omits " .. mode .. " without implicit work, retaining the native data after a valid exact selector", function()
			local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
			local callbacks, errors = 0, {}
			local logger = helpers.make_logger_stub()
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			local Menu = assert(require("menu.renderer").new({ platform = "hs",
				manifest_path = function() return path end, json_decode = require("json").decode,
				i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger }))
			Menu.get_array("frame")[1].row_id = "safe"
			local target = Menu.get_array("presentation")
			target[1].id = "safe"
			if mode == "scalar sibling" then target[3] = false
			elseif mode == "inherited sibling identity" then
				target[3] = setmetatable({ type = "label", i18n = "caption" }, {
					__index = function() callbacks = callbacks + 1; return "inherited" end,
				})
			else
				setmetatable(target, { __index = function() callbacks = callbacks + 1 end })
			end
			local builtin, custom = { label = "Builtin native" }, { label = "Custom native" }
			local called, rows = pcall(Menu.template_rows, "frame", {}, {}, {
				builtins = function() return { builtin } end, customs = function() return { custom } end,
			})
			helpers.assert_true(called, "malformed presentation cannot throw before its opted-in preflight")
			helpers.assert_eq(callbacks, 0, "physical selector admission never invokes inherited identity/membership")
			helpers.assert_not_nil(rows)
			helpers.assert_eq(#rows, 2)
			helpers.assert_true(rawequal(rows[1], builtin) and rawequal(rows[2], custom))
			helpers.assert_eq(#errors, 1)
			helpers.assert_true(errors[1]:find("presentation omitted", 1, true) ~= nil)
		end)
	end
end)


helpers.describe("invalid inert selector refuses before identity comparison", function()
	helpers.it("does not invoke equality callbacks for a non-string selector", function()
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
		local callbacks, providers, errors = 0, 0, {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		local Menu = assert(require("menu.renderer").new({ platform = "hs",
			manifest_path = function() return path end, json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger }))
		local meta = { __eq = function() callbacks = callbacks + 1; return true end }
		Menu.get_array("frame")[1].row_id = setmetatable({}, meta)
		Menu.get_array("presentation")[1].id = setmetatable({}, meta)
		local function supplied() providers = providers + 1; return { { label = "Native" } } end
		local called, rows = pcall(Menu.template_rows, "frame", {}, {}, { builtins = supplied, customs = supplied })
		helpers.assert_true(called)
		helpers.assert_nil(rows, "bad selector is a strict identity refusal, not omitted presentation")
		helpers.assert_eq(callbacks, 0)
		helpers.assert_eq(providers, 0)
		helpers.assert_eq(#errors, 1)
		helpers.assert_nil(errors[1]:find("presentation omitted", 1, true))
	end)
end)


require("test.menu_native_child_rows").run(helpers, require("infra.manifest_menu"))

require("test.menu_dynamic_caption_contract").register(helpers, "macos")
