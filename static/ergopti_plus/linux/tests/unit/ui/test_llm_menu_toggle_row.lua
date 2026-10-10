--- tests/unit/ui/test_llm_menu_toggle_row.lua

--- ==============================================================================
--- MODULE: The AI Master Toggle Row And The Keyboard Slot Groups (Linux tray)
--- DESCRIPTION:
--- The AI submenu's first row is the manifest's `llm_toggle`: this driver
--- registers the command, and the shared renderer draws it as a checkbox with
--- one translated label, ticked from the live state; the parent row carries the
--- same tick. Nothing pinned that the row exists, reads the live state and
--- reaches the engine, so a rename on either side would have left the AI with no
--- switch in the tray.
---
--- The Shortcuts submenu drew one submenu per keyboard slot group even when the
--- shared key catalogue could not be read, so the tray showed three groups that
--- opened onto nothing; they are now left out and the failure is logged.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The submenu of the top-level row whose title contains the translation of `key`.
--- @param items table
--- @param key string
--- @return table|nil
local function submenu_of(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if type(item.title) == "string" and item.title:find(label, 1, true) then return item.menu end
	end
	return nil
end

--- The top-level row whose title contains the translation of `key`.
--- @param items table
--- @param key string
--- @return table|nil
local function parent_of(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if type(item.title) == "string" and item.title:find(label, 1, true) then return item end
	end
	return nil
end

--- An LLM engine double.
--- @param enabled boolean
--- @return table engine, table calls
local function fake_llm(enabled)
	local calls = { toggle = 0 }
	local engine = {
		is_enabled = function() return enabled end,
		toggle = function() calls.toggle = calls.toggle + 1 enabled = not enabled return true end,
	}
	return engine, calls
end

--- Builds the tray around one LLM double.
--- @param llm table
--- @param changed table|nil Receives a `count` of on_menu_changed calls.
--- @return table items
local function build(llm, changed)
	local mb = helpers.load_module("ui.menu.menu_builder")
	return mb.build({
		_version = "0.0.0-dev.12",
		llm = llm,
		on_quit = function() end,
		on_menu_changed = function() if changed then changed.count = changed.count + 1 end end,
	})
end

helpers.describe("tray (linux): the AI master toggle row", function()
	helpers.it("draws an unticked switch first while the AI is off", function()
		local llm = fake_llm(false)
		local items = build(llm)
		local rows = submenu_of(items, "menu.llm.title")
		helpers.assert_true(rows ~= nil and rows[1] ~= nil, "the AI submenu must be drawn")
		helpers.assert_eq(rows[1].title, require("infra.i18n").get("menu.llm.enable"))
		helpers.assert_eq(rows[1].checked, false, "the switch is a checkbox, unticked while off")
		helpers.assert_eq(type(rows[1].fn), "function", "the toggle row must act")
		helpers.assert_eq(parent_of(items, "menu.llm.title").checked, false, "the parent is unticked too")
	end)

	helpers.it("ticks the same switch, and its parent, while the AI is on", function()
		local llm = fake_llm(true)
		local items = build(llm)
		local rows = submenu_of(items, "menu.llm.title")
		helpers.assert_eq(rows[1].title, require("infra.i18n").get("menu.llm.enable"))
		helpers.assert_eq(rows[1].checked, true, "the switch is ticked while on")
		helpers.assert_eq(parent_of(items, "menu.llm.title").checked, true, "the parent row is ticked too")
	end)

	helpers.it("clicking it toggles the engine and redraws the tray", function()
		local llm, calls = fake_llm(false)
		local changed = { count = 0 }
		local rows = submenu_of(build(llm, changed), "menu.llm.title")
		rows[1].fn()
		helpers.assert_eq(calls.toggle, 1, "the row must reach llm.toggle")
		helpers.assert_eq(changed.count, 1, "the tray must be rebuilt so the label follows the state")
	end)

	-- ai-menu-no-clear: « Tout effacer (comportement du système) » sat under the
	-- switch and cleared a section with nothing for the system to do in its
	-- place; the maintainer retired it. « Restaurer les valeurs conseillées »
	-- stays the one row between the switch and the separator.
	helpers.it("draws the restore row under the switch and no clear row", function()
		local i18n = require("infra.i18n")
		local rows = submenu_of(build(fake_llm(true)), "menu.llm.title")
		helpers.assert_true(rows ~= nil and #rows > 3, "the AI submenu must be drawn")
		helpers.assert_eq(rows[2].title, i18n.get("common.restore_recommended"), "the restore row follows the switch")
		helpers.assert_eq(type(rows[2].fn), "function", "the restore row must act")
		helpers.assert_eq(rows[3].title, "-", "a separator closes the switch's group")
		local clear = i18n.get("common.clear_to_system")
		helpers.assert_true(clear ~= "common.clear_to_system", "the clear label must be translated to be looked for")
		for index, row in ipairs(rows) do
			helpers.assert_true(row.title ~= clear, "row " .. index .. " of the AI submenu is a clear row")
		end
	end)
end)

helpers.describe("tray (linux): keyboard slot groups need a key catalogue", function()
	--- Menu inventory stays editable when its native source is unavailable.
	--- This fixture owns that dependency rather than inheriting another test's
	--- initialized physical-source owner or its expired private config path.
	local function with_unavailable_source(body)
		local saved_source = package.loaded["modules.hotstrings.magic_key_source"]
		local saved_magic = package.loaded["modules.hotstrings.magic_key"]
		package.loaded["modules.hotstrings.magic_key_source"] = {
			editor_source = function() return { generation = 1, status = "unavailable", candidates = {} } end,
			known_codes = function() return {} end,
		}
		package.loaded["modules.hotstrings.magic_key"] = { get = function() return "★" end, is_customised = function() return false end }
		local ok, err = pcall(body)
		package.loaded["modules.hotstrings.magic_key_source"] = saved_source
		package.loaded["modules.hotstrings.magic_key"] = saved_magic
		if not ok then error(err, 0) end
	end

	-- The positive case, so the absence assertion below cannot pass by looking
	-- in the wrong submenu.
	helpers.it("draws every slot group when the catalogue is readable", function()
		with_unavailable_source(function()
			local kbd = helpers.load_module("modules.shortcuts.keyboard_shortcuts")
			kbd._reset()
			local mb = helpers.load_module("ui.menu.menu_builder")
			local rows = submenu_of(mb.build({
				_version = "0.0.0-dev.12",
				shortcuts = require("modules.shortcuts.manager"),
				on_quit = function() end,
			}), "menu.shortcuts.title")
			local i18n = require("infra.i18n")
			for _, group in ipairs(kbd.SLOT_GROUPS) do
				local label, found = i18n.get(group.group_key), nil
				for _, row in ipairs(rows or {}) do
					if row.title == label then found = row end
				end
				helpers.assert_true(found ~= nil and type(found.menu) == "table" and #found.menu > 0,
					"slot group '" .. label .. "' must be drawn with its slots")
			end
		end)
	end)

	helpers.it("draws no empty slot group when the catalogue cannot be read", function()
		with_unavailable_source(function()
			local saved_paths = package.loaded["infra.paths"]
			local saved_kbd = package.loaded["modules.shortcuts.keyboard_shortcuts"]
			local real_paths = require("infra.paths")
			local blind = setmetatable({ shared = function() return nil end }, { __index = real_paths })
			package.loaded["infra.paths"] = blind
			package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
			local ok_kbd, kbd = pcall(require, "modules.shortcuts.keyboard_shortcuts")
			package.loaded["infra.paths"] = saved_paths
			local ok, err = pcall(function()
				helpers.assert_true(ok_kbd, tostring(kbd))
				kbd._reset()
				helpers.assert_eq(#kbd.available_slots("ctrl_"), 0, "the blind catalogue offers no slot")
				local mb = helpers.load_module("ui.menu.menu_builder")
				local items = mb.build({
					_version = "0.0.0-dev.12",
					shortcuts = require("modules.shortcuts.manager"),
					on_quit = function() end,
				})
				local rows = submenu_of(items, "menu.shortcuts.title")
				helpers.assert_true(rows ~= nil, "the shortcuts submenu must be drawn")
				local i18n = require("infra.i18n")
				for _, group in ipairs(kbd.SLOT_GROUPS) do
					local label, found = i18n.get(group.group_key), nil
					for _, row in ipairs(rows) do
						if group.prefix == "contextual" and row.title == label then found = row
						else helpers.assert_true(row.title ~= label,
							"slot group '" .. label .. "' was drawn with no slot in it") end
					end
					if group.prefix == "contextual" then
						helpers.assert_type(found, "table", "the logical contextual slot does not depend on the modifier key catalogue")
						helpers.assert_eq(#found.menu, 1, "its one stable editable slot must remain visible")
						helpers.assert_type(found.menu[1].menu[1].fn, "function", "unavailable native evidence never removes the ordinary action picker")
					end
				end
		end)
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = saved_kbd
		if not ok then error(err, 0) end
		end)
	end)
end)

--- Retrieves the actual local slot builder retained by the public tray builder.
--- The test executes native closures; it does not copy their implementation or
--- publish a test-only API in the driver.
local function slot_builder_from(module)
	local gestures
	for index = 1, math.huge do
		local name, value = debug.getupvalue(module.build, index)
		if name == nil then break end
		if name == "_build_gestures" then gestures = value break end
	end
	helpers.assert_type(gestures, "function", "the real gestures tray builder is retained")
	for index = 1, math.huge do
		local name, value = debug.getupvalue(gestures, index)
		if name == nil then break end
		if name == "slot_binding_rows" then
			helpers.assert_type(value, "function", "the real slot menu closure is retained")
			return value
		end
	end
	error("The gestures tray builder lost its actual slot menu closure")
end

--- Uses the real shared renderer and generated declarations. Only the native
--- picker and action-registry boundary are controlled; no GUI is exercised.
local function with_slot_frame(locale, mutation, body)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	local saved_i18n_safe = rawget(_G, "i18n_safe")
	local ok, raised = pcall(function()
		local Paths = require("infra.paths")
		local json = require("json")
		local file = assert(io.open(Paths.shared("data/locales/" .. locale .. ".json"), "rb"))
		local catalogue = json.decode(file:read("*a"))
		assert(file:close())
		local state = { opened = {}, assigned = {}, accepts = true, catalogue = catalogue }
		local function translate(key) return catalogue[key] or key end
		-- Both the old native path and shared rendering receive the same real
		-- catalogue, so predecessor comparisons do not invent a locale failure.
		package.loaded["infra.i18n"] = { get = translate, section = translate,
			get_locale = function() return locale end }
		local renderer = assert(require("menu.renderer").new({
			platform = "linux",
			manifest_path = function() return Paths.shared("modules/menu/menu_manifest.json") end,
			json_decode = json.decode,
			i18n = { get = translate, section = translate },
			logger = helpers.make_logger_stub(),
		}))
		local declarations = renderer.get_root()
		if mutation then mutation(declarations) end
		state.items = { { id = "open_url", label = "Controlled native picker choice" } }
		package.loaded["modules.gestures.manager"] = {
			get_picker_items = function() return state.items end,
			get_picker_parameter_fields = function(items, binding)
				state.editor_items, state.editor_binding = items, binding
				return { send_vocabulary = {}, parameter_strings = {}, prompt_choices = {},
					vision_choices = {}, language_choices = {}, default_count = 1,
					edit_current_label = "Controlled native editor label" }
			end,
		}
		package.loaded["ui.action_picker.bridge"] = {
			open = function(options, confirm)
				state.opened[#state.opened + 1] = options
				state.confirm = confirm
				return true
			end,
		}
		local module = helpers.load_module_with_dependency("ui.menu.menu_builder", "infra.manifest_menu", renderer)
		local build_rows = slot_builder_from(module)
		function state.assign(option, picked)
			state.assigned[#state.assigned + 1] = { option = option, picked = picked }
			return state.accepts
		end
		function state.rows(bound) return build_rows("Actual caller slot", bound, "ctrl_a", state.assign) end
		body(state)
	end)
	for name in pairs(package.loaded) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.i18n_safe = saved_i18n_safe
	if not ok then error(raised, 0) end
end

helpers.describe("Linux shared slot picker and conditional clear frame", function()
	-- Independent expectations preserve the original bound ~= "none" policy,
	-- including the legacy empty-string case rather than deriving expectations
	-- from the new declaration or implementation.
	for _, vector in ipairs({
		{ bound = "none", count = 1 },
		{ bound = "open_url", count = 2 },
		{ bound = "send_shortcut", count = 2 },
		{ bound = "", count = 2 },
	}) do
		helpers.it("retains picker then optional clear for '" .. vector.bound .. "'", function()
			with_slot_frame("en", nil, function(state)
				local rows = state.rows(vector.bound)
				helpers.assert_eq(#rows, vector.count)
				helpers.assert_eq(rows[1].label, state.catalogue["dialog.action_picker.label"] .. "…")
				helpers.assert_type(rows[1].action, "function")
				if vector.count == 2 then
					helpers.assert_eq(rows[2].label, state.catalogue["dialog.action_picker.disabled"])
					helpers.assert_type(rows[2].action, "function")
				end
				helpers.assert_eq(#state.opened, 0, "building a row never opens the picker")
				helpers.assert_eq(#state.assigned, 0, "building a row never publishes an assignment")
			end)
		end)
	end
	for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
		"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("retains the genuine " .. locale .. " picker caption and ellipsis", function()
			with_slot_frame(locale, nil, function(state)
				helpers.assert_eq(state.rows("none")[1].label, state.catalogue["dialog.action_picker.label"] .. "…")
			end)
		end)
	end
	for _, accepts in ipairs({ true, false }) do
		helpers.it("retains native picker confirmation result " .. tostring(accepts), function()
			with_slot_frame("en", nil, function(state)
				state.accepts = accepts
				local rows = state.rows("open_url")
				rows[1].action()
				helpers.assert_eq(#state.opened, 1)
				helpers.assert_eq(state.opened[1].title, "Actual caller slot")
				helpers.assert_eq(state.opened[1].current, "open_url")
				helpers.assert_true(state.opened[1].items == state.items, "the native catalogue identity is forwarded")
				helpers.assert_true(state.editor_items == state.items, "the native editor receives that same catalogue")
				helpers.assert_eq(state.editor_binding, "ctrl_a")
				local picked = { shortcut = "Ctrl+Shift+Q" }
				helpers.assert_eq(state.confirm("send_shortcut", {}, picked), accepts)
				helpers.assert_eq(#state.assigned, 1)
				helpers.assert_eq(state.assigned[1].option, "send_shortcut")
				helpers.assert_true(state.assigned[1].picked == picked, "the original native picker value identity is forwarded")
				rows[2].action()
				helpers.assert_eq(#state.assigned, 2)
				helpers.assert_eq(state.assigned[2].option, "none")
				helpers.assert_nil(state.assigned[2].picked)
				helpers.assert_eq(#state.opened, 1, "clearing never opens a picker")
			end)
		end)
	end
	local refusals = {
		{ name = "withdrawn complete frame", mutate = function(root) root.slot_binding_frame = nil end },
		{ name = "withdrawn late clear frame", mutate = function(root) root.slot_binding_clear_frame = nil end },
		{ name = "empty late clear frame", mutate = function(root) root.slot_binding_clear_frame = {} end },
		{ name = "unknown late clear callback", mutate = function(root) root.slot_binding_clear_frame[1].id = "unowned_clear" end },
		{ name = "wrong-platform late clear", mutate = function(root) root.slot_binding_clear_frame[1].platforms = { "hs" } end },
		{ name = "unknown presence getter", mutate = function(root) root.slot_binding_frame[2].present_when = "unowned_presence" end },
		{ name = "non-string presence getter", mutate = function(root) root.slot_binding_frame[2].present_when = 1 end },
		{ name = "additional declared picker", mutate = function(root) root.slot_binding_frame[3] = root.slot_binding_frame[1] end },
	}
	for _, refusal in ipairs(refusals) do
		helpers.it("refuses " .. refusal.name .. " without opening or assigning", function()
			with_slot_frame("en", refusal.mutate, function(state)
				helpers.assert_eq(#state.rows("open_url"), 0, "a failed frame cannot leave a partial picker submenu")
				helpers.assert_eq(#state.opened, 0)
				helpers.assert_eq(#state.assigned, 0)
			end)
		end)
	end
	helpers.it("refuses a withdrawn clear declaration even while the slot is unbound", function()
		with_slot_frame("en", function(root) root.slot_binding_clear_frame = nil end, function(state)
			helpers.assert_eq(#state.rows("none"), 0)
			helpers.assert_eq(#state.opened, 0)
			helpers.assert_eq(#state.assigned, 0)
		end)
	end)
end)


helpers.describe("Linux rendered AI source refusal", function()
	helpers.it("disables the genuine toggle row and refuses a retained click after newer-schema boot (ai-readonly-admission)", function()
		local Sandbox = require("test.config_unused_keys_contract").sandbox
		local Migration = require("config_migrate")
		local registry = assert(Migration.load_registry(require("infra.paths").shared(Migration.REGISTRY_PATH)))
		local source = '[_meta]\nschema_version = ' .. (registry.current + 1)
			.. '\n[llm]\nenabled = false\n[private]\nkeep = "exact"\n'
		Sandbox.with_config(source, function(path)
			local saved = {}
			for name, value in pairs(package.loaded) do saved[name] = value end
			local ok, raised = pcall(function()
				package.loaded["infra.config_paths"] = {
					config = function() return path end,
					config_home = function() return assert(path:match("^(.*)/[^/]+$")) end,
				}
				package.loaded["infra.llm_preferences"] = nil
				local llm, calls = fake_llm(false)
				local changed = { count = 0 }
				local before = submenu_of(build(llm, changed), "menu.llm.title")
				helpers.assert_true(not before[1].disabled, "an unrefused owner initially admits this explicit action")
				local retained = before[1].fn
				helpers.assert_eq(type(retained), "function")
				local boot = Migration.boot({ path = path, driver = "linux", registry = registry })
				helpers.assert_eq(boot.status, "newer")
				helpers.assert_eq(boot.read_only, true)
				local rows = submenu_of(build(llm, changed), "menu.llm.title")
				helpers.assert_eq(rows[1].disabled, true, "the shared renderer consumes actual source admission")
				helpers.assert_eq(rows[1].checked, false, "refusal cannot invent consent")
				helpers.assert_eq(retained(), false, "a previously captured click must recheck source permission")
				helpers.assert_eq(calls.toggle, 0, "no engine mutation occurs after the writer refusal")
				helpers.assert_eq(changed.count, 0, "no successful-state repaint is emitted")
				helpers.assert_eq(Sandbox.read_bytes(path), source)
			end)
			for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
			for name, value in pairs(saved) do package.loaded[name] = value end
			if not ok then error(raised, 0) end
		end)
	end)
end)
