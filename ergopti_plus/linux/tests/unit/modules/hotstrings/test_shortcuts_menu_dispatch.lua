--- tests/unit/modules/hotstrings/test_shortcuts_menu_dispatch.lua

--- ==============================================================================
--- MODULE: The Shortcuts Submenu Answers by Id
--- DESCRIPTION:
--- That the Linux shortcuts submenu is built from the manifest rather than by
--- hand, and that the rows it owns come out where and how the other two drivers
--- put them.
---
--- WHY BEING HAND-ROLLED WAS A REAL COST, NOT AN AESTHETIC ONE:
--- `extensions_shortcuts` sat at platforms = ["ahk"] with the reason "neither Lua
--- driver has that concept". That was false for both — macOS has walked the
--- extensions tree since its shortcuts menu was written, and Linux since
--- 2026-08-05. The restriction survived a correction attempt anyway, because a
--- menu that dispatches nothing BY ID cannot be promised a row by id: the
--- handler-bijection ratchet would have flagged it the moment the manifest
--- widened. So the manifest went on describing the product wrongly, and the only
--- way out was to make this menu answer by id. That is what is pinned here.
---
--- PARAMETERIZED ACTIONS:
--- Keyboard slots dispatch through the gestures action catalogue. An action such
--- as open_url is incomplete without its binding-scoped parameter, so the menu
--- must persist that parameter before publishing the visible key assignment.
---
--- WHAT IS NOT ASSERTED HERE:
--- That an extension's own rows do what they say. They come from the extension's
--- sandboxed shortcuts/menu.lua and are its author's to get right; what this
--- driver owes is that they appear at all.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A shortcuts module with the surface the menu reads.
--- @param log table|nil Records what the rows called.
--- @return table
local function fake_shortcuts(log)
	log = log or {}
	local enabled, caps = true, false
	return {
		is_enabled          = function() return enabled end,
		toggle              = function() enabled = not enabled ; log.toggled = true end,
		is_caps_word_active = function() return caps end,
		toggle_caps_word    = function() caps = not caps ; log.caps = true end,
		transform_uppercase = function() log.upper = true end,
		transform_lowercase = function() log.lower = true end,
		transform_titlecase = function() log.title = true end,
		select_word         = function() log.word = true end,
		select_line         = function() log.line = true end,
		paste_plain         = function() log.paste = true end,
		wrap_selection      = function(l, r) log.wrapped = l .. r end,
		get_wrap_pairs      = function()
			return {
				["("] = { left = "(", right = ")" },
				[")"] = { left = "(", right = ")" },
				["«"] = { left = "«", right = "»" },
				["»"] = { left = "«", right = "»" },
			}
		end,
	}
end

--- The shortcuts submenu, as the tray builder returns it.
--- @param ctx_extra table|nil
--- @return table|nil rows
local function shortcuts_menu(ctx_extra)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ctx = { _version = "9.9.9", shortcuts = fake_shortcuts() }
	for k, v in pairs(ctx_extra or {}) do ctx[k] = v end

	local wanted = require("infra.i18n").get("menu.shortcuts.select_word")
	for _, item in ipairs(mb.build(ctx)) do
		if type(item.menu) == "table" then
			for _, row in ipairs(item.menu) do
				if row.title == wanted then return item.menu end
			end
		end
	end
	return nil
end

--- Finds a row recursively in the tray adapter's rendered dialect.
--- @param rows table
--- @param title string
--- @return table|nil
local function find_row(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local nested = find_row(row.menu, title)
		if nested then return nested end
	end
	return nil
end

--- Finds the first row, at any depth, whose title starts with a prefix.
--- @param rows table|nil
--- @param prefix string
--- @return table|nil
local function find_row_prefix(rows, prefix)
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return row end
		local nested = find_row_prefix(row.menu, prefix)
		if nested then return nested end
	end
	return nil
end




-- =================================================================
-- =================================================================
-- ======= 1/ The rows this driver owns ============================
-- =================================================================
-- =================================================================

helpers.describe("shortcuts menu: this driver's own rows", function()

	helpers.it("draws the master toggle the renderer refuses to", function()
		local rows = shortcuts_menu()
		helpers.assert_not_nil(rows, "the shortcuts submenu must exist")
		helpers.assert_true(type(rows[1].fn) == "function",
			"row 1 of the manifest is a `toggle`, which the shared renderer skips by "
				.. "contract — so this caller has to build it, and a submenu whose "
				.. "first row is missing has no way to switch shortcuts off at all")
	end)

	helpers.it("labels every row from the catalogue, not from a French literal", function()
		for _, row in ipairs(shortcuts_menu() or {}) do
			if type(row.title) == "string" and row.title ~= "-" then
				helpers.assert_true(not row.title:find("texte", 1, true),
					"a translated label followed by an untranslated one is worse than "
						.. "either: it tells a Japanese user the row was localised and "
						.. "then hands them French")
			end
		end
	end)

	helpers.it("orders the wrapping pairs, so a rebuild does not shuffle them", function()
		local rows = shortcuts_menu()
		-- By its label, not by "the last submenu with more than one row". That
		-- shortcut passed here and failed in CI, where the bundled demo extension's
		-- shortcuts/menu.lua resolves and adds a second submenu after this one —
		-- so the test was asserting the ordering of an extension's rows, which are
		-- its author's to order.
		local wanted = require("infra.i18n").get("menu.shortcuts.wrap_symbols")
		local wrap = nil
		for _, row in ipairs(rows) do
			if row.title == wanted and type(row.menu) == "table" then wrap = row.menu end
		end
		helpers.assert_not_nil(wrap, "the wrapping-symbols submenu is present")

		local seen = {}
		for _, row in ipairs(wrap) do seen[#seen + 1] = row.title end
		local sorted = {}
		for index, title in ipairs(seen) do sorted[index] = title end
		table.sort(sorted)
		for index, title in ipairs(seen) do
			helpers.assert_eq(title, sorted[index],
				"get_wrap_pairs returns a map, and `pairs` would give the user a "
					.. "different order on every menu rebuild")
		end
		helpers.assert_eq(#wrap, 2,
			"one row per PAIR, not per character — each pair is stored under both "
				.. "of its ends and listing both would double the submenu")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The rows the manifest owns ===========================
-- =================================================================
-- =================================================================

--- Draws the shortcuts menu over a stubbed keyboard slot (ctrl_k), gestures
--- manager and picker bridge, then clicks the slot's picker row.
--- @param prompt function|nil The zenity prompt test boundary; nil draws the
---   menu without it, so the production choosers run.
--- @return table { picker, events, prompt_args, items, editor }
local function open_keyboard_slot_picker(prompt)
	local keyboard_binding = require("modules.shortcuts.keyboard_shortcuts").binding_id
	local prior_keyboard = package.loaded["modules.shortcuts.keyboard_shortcuts"]
	local prior_gestures = package.loaded["modules.gestures.manager"]
	local prior_picker = package.loaded["ui.action_picker.bridge"]
	local scene = { events = {} }
	local events = scene.events
	scene.items = { { type = "action", id = "open_url", label = "Open URL" } }
	scene.editor = { send_vocabulary = { keys = {} }, parameter_strings = { save = "Save" } }
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = {
		SLOT_GROUPS = { { prefix = "ctrl_", group_key = "menu.shortcuts.mod_ctrl" } },
		binding_id = keyboard_binding,
		available_slots = function() return { "ctrl_k" } end,
		get_action = function() return "none" end,
		get_slot_label = function() return "Ctrl+K" end,
		set_action = function(slot, action)
			events[#events + 1] = "assign:" .. slot .. ":" .. action
			return true
		end,
	}
	package.loaded["modules.gestures.manager"] = {
		get_action_names = function() return { "none", "open_url", "send_key" } end,
		get_action_label = function(action)
			return action == "open_url" and "Open URL" or "None"
		end,
		get_action_parameter_spec = function(action)
			return ({ open_url = "url", send_key = "key", open_app = "app" })[action]
		end,
		get_action_parameter_prompt = function(action) return "prompt:" .. action end,
		get_action_parameter = function(binding, action)
			events[#events + 1] = "prior:" .. binding .. ":" .. action
			return "https://old.example"
		end,
		validate_action_parameter = function(action, value)
			return (action == "open_url" and value == "https://new.example")
				or (action == "send_key" and value == "enter")
				or (action == "open_app" and value == "firefox")
		end,
		set_action_parameter = function(binding, action, value)
			events[#events + 1] = "parameter:" .. binding .. ":" .. action .. ":" .. value
			return true
		end,
		get_picker_items = function() return scene.items end,
		get_picker_parameter_fields = function(items, binding)
			helpers.assert_eq(items, scene.items, "the editor marks the items the picker shows")
			events[#events + 1] = "editor:" .. tostring(binding)
			return scene.editor
		end,
	}
	package.loaded["ui.action_picker.bridge"] = {
		open = function(opts, on_confirm)
			scene.picker = { opts = opts, on_confirm = on_confirm }
			return true
		end,
	}

	local ok, rows = pcall(function()
		local built = shortcuts_menu(prompt and {
			prompt_action_parameter = function(binding, action, spec, prior)
				scene.prompt_args = { binding, action, spec, prior }
				return prompt(binding, action, spec, prior)
			end,
		} or {})
		local picker_label = require("infra.i18n").get("dialog.action_picker.label") .. "…"
		-- Searched under the slot's own row: the number-row tap keys above it
		-- open the same picker.
		local slot_row = find_row_prefix(built, "Ctrl+K")
		helpers.assert_not_nil(slot_row, "the keyboard slot must be drawn")
		local picker_choice = find_row(slot_row.menu, picker_label)
		helpers.assert_not_nil(picker_choice,
			"the shared searchable picker must be reachable from a keyboard slot")
		helpers.assert_true(type(picker_choice.fn) == "function")
		-- Only what the click does: drawing the menu read the parameters of the
		-- rows' own bindings, the script chords' presets among them.
		for index = #events, 1, -1 do events[index] = nil end
		picker_choice.fn()
		return built
	end)
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = prior_keyboard
	package.loaded["modules.gestures.manager"] = prior_gestures
	package.loaded["ui.action_picker.bridge"] = prior_picker
	helpers.assert_true(ok, tostring(rows))
	helpers.assert_not_nil(scene.picker, "clicking the production row must open the picker host")
	return scene
end

helpers.describe("shortcuts menu: dispatched by id", function()

	helpers.it("stores a parameter under the exact keyboard dispatch binding before assignment", function()
		local scene = open_keyboard_slot_picker(function(binding, action, spec, prior)
			return "https://new.example"
		end)
		helpers.assert_eq(scene.picker.opts.current, "none")
		helpers.assert_true(scene.picker.on_confirm("open_url"))

		helpers.assert_eq(scene.prompt_args[1], "keyboard__ctrl_k")
		helpers.assert_eq(scene.prompt_args[2], "open_url")
		helpers.assert_eq(scene.prompt_args[3], "url")
		helpers.assert_eq(scene.prompt_args[4], "https://old.example")
		helpers.assert_eq(scene.events[#scene.events - 1],
			"parameter:keyboard__ctrl_k:open_url:https://new.example")
		helpers.assert_eq(scene.events[#scene.events], "assign:ctrl_k:open_url",
			"the visible key assignment must be published only after its parameter")
	end)

	helpers.it("hands the picker its editor for the slot's binding and stores what it collected", function()
		local scene = open_keyboard_slot_picker(function()
			error("the value the picker's editor collected must not be asked again")
		end)
		helpers.assert_eq(scene.events[1], "editor:keyboard__ctrl_k",
			"the editor starts from the values this slot's binding holds")
		helpers.assert_eq(scene.picker.opts.items, scene.items, "the marked items are the ones shown")
		helpers.assert_eq(scene.picker.opts.send_vocabulary, scene.editor.send_vocabulary)
		helpers.assert_eq(scene.picker.opts.parameter_strings, scene.editor.parameter_strings)

		helpers.assert_true(scene.picker.on_confirm("send_key", {}, "enter"))
		helpers.assert_eq(scene.prompt_args, nil, "no prompt for a value the page collected")
		helpers.assert_eq(scene.events[#scene.events - 1], "parameter:keyboard__ctrl_k:send_key:enter")
		helpers.assert_eq(scene.events[#scene.events], "assign:ctrl_k:send_key")
	end)

	helpers.it("picks an open_app application in the desktop-entry chooser, never a text prompt", function()
		local prior_chooser = package.loaded["ui.app_chooser"]
		local chooser_titles = {}
		package.loaded["ui.app_chooser"] = {
			pick = function(shell, title)
				helpers.assert_eq(type(shell.exec_line), "function", "the chooser runs through the shell runner")
				chooser_titles[#chooser_titles + 1] = title
				return "firefox"
			end,
		}
		local ok, err = pcall(function()
			local scene = open_keyboard_slot_picker(nil)
			helpers.assert_true(scene.picker.on_confirm("open_app"))
			helpers.assert_eq(chooser_titles, { "prompt:open_app" })
			helpers.assert_eq(scene.events[#scene.events - 1], "parameter:keyboard__ctrl_k:open_app:firefox")
			helpers.assert_eq(scene.events[#scene.events], "assign:ctrl_k:open_app")
		end)
		package.loaded["ui.app_chooser"] = prior_chooser
		if not ok then error(err, 0) end
	end)

	helpers.it("renders the Linux ChatGPT URL editor declared by the manifest", function()
		local rows = shortcuts_menu()
		local wanted = require("infra.i18n").get("menu.shortcuts.chatgpt_url_item")
		local editor = nil
		for _, row in ipairs(rows or {}) do
			if row.title == wanted then editor = row end
		end
		helpers.assert_not_nil(editor,
			"declaring shortcuts.chatgpt_url for Linux without a reachable editor would "
				.. "turn parity into a configuration value users cannot change")
		helpers.assert_true(type(editor.fn) == "function")
	end)

	helpers.it("renders an extension's rows through the manifest handler", function()
		-- The handler is reached only if the menu dispatches by id at all, which is
		-- the whole point: before this, the manifest could not promise Linux this
		-- row, and the restriction said no Lua driver had the concept while both
		-- did.
		local mb = helpers.load_module("ui.menu.menu_builder")
		helpers.assert_true(mb ~= nil)

		local source = nil
		for _, path in ipairs({ "ui/menu/menu_builder.lua" }) do
			local fh = io.open("./" .. path, "r")
			if fh then source = fh:read("*a") ; fh:close() end
		end
		helpers.assert_not_nil(source, "the builder's source must be readable")
		helpers.assert_contains(source, 'ManifestMenu.build("shortcuts_menu"',
			"the submenu must go through the shared renderer — a hand-rolled one "
				.. "cannot be handed a row by id, and that is exactly what kept "
				.. "extensions_shortcuts restricted to Windows in the manifest")
		helpers.assert_contains(source, '["extensions_shortcuts"]',
			"and it must register the handler the manifest names, or the renderer "
				.. "logs a warning and renders one row short, permanently")
	end)

	helpers.it("keeps the rest of the tray when the shortcuts module is absent", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local tree = mb.build({ _version = "9.9.9" })

		-- Not "it did not throw": that would pass just as well if build returned an
		-- empty list. What the user must still get is every OTHER submenu, and a
		-- shortcuts entry that says it is unavailable rather than vanishing.
		-- Compared against the resolved key, not against a substring of the French
		-- label: the label became a catalogue entry on 2026-08-05 and a test that
		-- pinned its spelling would have reported that improvement as a defect.
		local unavailable = require("infra.i18n").get("menu.shortcuts.unavailable")
		local top_level, placeholder = 0, false
		for _, item in ipairs(tree) do
			if type(item.menu) == "table" then
				top_level = top_level + 1
				for _, row in ipairs(item.menu) do
					if row.title == unavailable then placeholder = row.disabled == true end
				end
			end
		end
		helpers.assert_true(top_level >= 5,
			"a missing shortcuts module costs the user that submenu, never their menu")
		helpers.assert_true(placeholder,
			"and the entry stays, greyed: a row that disappears reads as a bug, and "
				.. "the user has no way to tell it apart from a feature they never had")
	end)

end)

helpers.describe("shortcuts menu: configured binding labels", function()
	for _, surface in ipairs({ "keyboard", "tap" }) do
		helpers.it("shows the saved value in the real " .. surface .. " provider", function()
			local owned = { "modules.shortcuts.keyboard_shortcuts", "modules.shortcuts.tap_keys", "modules.gestures.manager" }
			local saved = {}
			for _, name in ipairs(owned) do saved[name] = package.loaded[name] end
			local ok, failure = xpcall(function()
				local parameters = { ["owner_keyboard__ctrl_k"] = "https://keyboard.example/?q=[x]&p=50%",
					["owner_tap__number_row_left"] = "https://tap.example" }
				package.loaded[owned[1]] = {
					SLOT_GROUPS = { { prefix = "ctrl_", group_key = "menu.shortcuts.mod_ctrl" } },
					available_slots = function() return { "ctrl_k" } end,
					get_action = function() return "open_url" end,
					get_slot_label = function() return "Ctrl+K" end,
					binding_id = function(slot) return "owner_keyboard__" .. slot end,
				}
				package.loaded[owned[2]] = {
					keys = function() return { { id = "number_row_left" } } end,
					get_action = function() return "open_url" end,
					display_name = function() return "Left" end,
					binding_id = function(id) return "owner_tap__" .. id end,
				}
				package.loaded[owned[3]] = {
					get_action_label = function() return "Open [configurable]" end,
					get_action_parameter = function(binding, action)
						helpers.assert_eq(action, "open_url")
						return parameters[binding] or ""
					end,
				}
				local rows = shortcuts_menu()
				local row = find_row_prefix(rows, surface == "keyboard" and "Ctrl+K" or "Left")
				helpers.assert_not_nil(row, "the real provider must render its assigned row")
				local value = parameters[surface == "keyboard" and "owner_keyboard__ctrl_k" or "owner_tap__number_row_left"]
				helpers.assert_true(row.title:find("Open [" .. value .. "]", 1, true) ~= nil, row.title)
				helpers.assert_true(row.title:find("[configurable]", 1, true) == nil)
			end, debug.traceback)
			for _, name in ipairs(owned) do package.loaded[name] = saved[name] end
			assert(ok, failure)
		end)
	end
end)

helpers.describe("shortcuts menu: master publication receipt", function()
	--- Records visible refusals while preserving the real menu callback boundary.
	--- @param action function Native rendered callback.
	--- @return boolean called
	--- @return any receipt
	--- @return table notices
	--- @return integer releases
	local function observe(action)
		local execute, modal = os.execute, require("ui.modal")
		local run, notices, releases = modal.run, {}, 0
		modal.run = function(callback) releases = releases + 1; return callback() end
		os.execute = function(command)
			if command:find("zenity", 1, true) then notices[#notices + 1] = command; return 0 end
			return execute(command)
		end
		local called, receipt = pcall(action)
		os.execute, modal.run = execute, run
		return called, receipt, notices, releases
	end
	--- Selects the exact declared master rather than a coincidental native index.
	--- @param sc table Native shortcuts owner.
	--- @param changed function Menu publication observer.
	--- @return table row
	local function master_row(sc, changed)
		local key, declarations = nil, 0
		for _, declaration in ipairs(require("infra.manifest_menu").get_array("shortcuts_menu")) do
			if declaration.id == "shortcuts_toggle" then key = declaration.i18n; declarations = declarations + 1 end
		end
		helpers.assert_eq(declarations, 1)
		local row = find_row(shortcuts_menu({ shortcuts = sc, on_menu_changed = changed }), require("infra.i18n").get(key))
		helpers.assert_not_nil(row)
		helpers.assert_eq(type(row.fn), "function")
		return row
	end
	for _, initial in ipairs({ true, false }) do
		for _, outcome in ipairs({ "true", "false", "nil", "number", "text", "throw", "missing" }) do
			helpers.it("requires the native master receipt " .. outcome .. " from " .. tostring(initial), function()
				local state, asked, legacy, redraws = initial, {}, 0, 0
				local sc = fake_shortcuts()
				sc.is_enabled = function() return state end
				sc.toggle = function() legacy = legacy + 1; return state end
				sc.set_enabled = function(value)
					asked[#asked + 1] = value
					if outcome == "throw" then error("controlled master refusal") end
					if outcome == "nil" then return nil end
					if outcome == "number" then return 2 end
					if outcome == "text" then return "true" end
					if outcome == "true" then state = value end
					return outcome == "true"
				end
				if outcome == "missing" then sc.set_enabled = nil end
				local row = master_row(sc, function() redraws = redraws + 1 end)
				local called, receipt, notices, releases = observe(row.fn)
				helpers.assert_true(called)
				helpers.assert_eq(legacy, 0, "posture is not a durable acknowledgement")
				helpers.assert_eq(asked, outcome == "missing" and {} or { not initial })
				helpers.assert_eq(receipt, outcome == "true")
				helpers.assert_eq(redraws, outcome == "true" and 1 or 0)
				helpers.assert_eq(#notices, outcome == "true" and 0 or 1)
				helpers.assert_eq(releases, #notices)
				if #notices > 0 then
					helpers.assert_true(notices[1]:find(require("adapters.shell_runner").quote(
						require("infra.i18n").get("dialog.bulk_toggle.save_failed")), 1, true) ~= nil)
				end
			end)
		end
		helpers.it("uses the current master instead of the held checked state " .. tostring(initial), function()
			local state, asked, redraws = initial, {}, 0
			local sc = fake_shortcuts()
			sc.is_enabled = function() return state end
			sc.set_enabled = function(value) asked[#asked + 1] = value; state = value; return true end
			local row = master_row(sc, function() redraws = redraws + 1 end)
			state = not initial
			local called, receipt, notices = observe(row.fn)
			helpers.assert_true(called)
			helpers.assert_eq(receipt, true)
			helpers.assert_eq(asked, { initial })
			helpers.assert_eq(state, initial)
			helpers.assert_eq(redraws, 1)
			helpers.assert_eq(#notices, 0)
		end)
	end
	for _, invalid in ipairs({ "nil", "number", "text", "throw", "missing" }) do
		helpers.it("refuses malformed current master " .. invalid .. " before writing", function()
			local sc, writes, redraws = fake_shortcuts(), 0, 0
			sc.set_enabled = function() writes = writes + 1; return true end
			local row = master_row(sc, function() redraws = redraws + 1 end)
			sc.is_enabled = function()
				if invalid == "throw" then error("controlled read refusal") end
				if invalid == "number" then return 2 end
				if invalid == "text" then return "true" end
				return nil
			end
			if invalid == "missing" then sc.is_enabled = nil end
			local called, receipt, notices, releases = observe(row.fn)
			helpers.assert_true(called)
			helpers.assert_eq(receipt, false)
			helpers.assert_eq(writes, 0)
			helpers.assert_eq(redraws, 0)
			helpers.assert_eq(#notices, 1)
			helpers.assert_eq(releases, 1)
		end)
	end
end)

helpers.describe("shortcuts menu: current script chord publication", function()
	--- Observes the existing localized modal boundary outside caught callbacks.
	--- @param action function Rendered native command.
	--- @return boolean called
	--- @return any receipt
	--- @return table notices
	--- @return integer releases
	local function observe(action)
		local execute, modal = os.execute, require("ui.modal")
		local run, notices, releases = modal.run, {}, 0
		modal.run = function(callback) releases = releases + 1; return callback() end
		os.execute = function(command)
			if command:find("zenity", 1, true) then notices[#notices + 1] = command; return 0 end
			return execute(command)
		end
		local called, receipt = pcall(action)
		os.execute, modal.run = execute, run
		return called, receipt, notices, releases
	end
	--- Borrows the exact shared command and the supplied native chord owner.
	--- @param chords table Script chord owner.
	--- @param changed function Publication observer.
	--- @return function action
	local function command(chords, changed)
		local key, declared = nil, 0
		for _, row in ipairs(require("infra.manifest_menu").get_array("script_control_group")) do
			if row.id == "script_control_toggle" then key = row.i18n; declared = declared + 1 end
		end
		helpers.assert_eq(declared, 1)
		local prior = package.loaded["modules.shortcuts.script_chords"]
		package.loaded["modules.shortcuts.script_chords"] = chords
		local called, row = pcall(function()
			return find_row(shortcuts_menu({ on_menu_changed = changed }), require("infra.i18n").get(key))
		end)
		package.loaded["modules.shortcuts.script_chords"] = prior
		helpers.assert_true(called, tostring(row))
		helpers.assert_not_nil(row)
		helpers.assert_eq(type(row.fn), "function")
		return row.fn
	end
	--- Supplies only the native fields the actual group renderer consumes.
	--- @param current boolean Initial runtime posture.
	--- @return table owner
	local function inert_owner(current)
		return { chords_enabled = function() return current end, slots = function() return {} end }
	end
	for _, initial in ipairs({ true, false }) do
		for _, outcome in ipairs({ "true", "false", "nil", "number", "text", "throw", "missing" }) do
			helpers.it("requires the script chord setter receipt " .. outcome .. " from " .. tostring(initial), function()
				local owner, asked, redraws = inert_owner(initial), {}, 0
				owner.set_chords_enabled = function(value)
					asked[#asked + 1] = value
					if outcome == "throw" then error("controlled native chord refusal") end
					if outcome == "nil" then return nil end
					if outcome == "number" then return 2 end
					if outcome == "text" then return "true" end
					return outcome == "true"
				end
				if outcome == "missing" then owner.set_chords_enabled = nil end
				local called, receipt, notices, releases = observe(command(owner, function() redraws = redraws + 1 end))
				helpers.assert_true(called, "a native setter refusal remains a contained menu result")
				helpers.assert_eq(asked, outcome == "missing" and {} or { not initial })
				helpers.assert_eq(redraws, outcome == "true" and 1 or 0)
				helpers.assert_eq(receipt, outcome == "true")
				helpers.assert_eq(#notices, outcome == "true" and 0 or 1)
				helpers.assert_eq(releases, #notices)
				if #notices > 0 then
					helpers.assert_true(notices[1]:find(require("adapters.shell_runner").quote(
						require("infra.i18n").get("dialog.bulk_toggle.save_failed")), 1, true) ~= nil)
				end
			end)
		end
		helpers.it("retires the held script chord target from " .. tostring(initial), function()
			local current, asked, redraws = initial, {}, 0
			local owner = inert_owner(initial)
			owner.chords_enabled = function() return current end
			owner.set_chords_enabled = function(value) asked[#asked + 1] = value; current = value; return true end
			local action = command(owner, function() redraws = redraws + 1 end)
			current = not initial
			local called, receipt, notices = observe(action)
			helpers.assert_true(called)
			helpers.assert_eq(asked, { initial }, "the current posture decides the requested opposite")
			helpers.assert_eq(current, initial)
			helpers.assert_eq(receipt, true)
			helpers.assert_eq(redraws, 1)
			helpers.assert_eq(#notices, 0)
		end)
	end
	for _, invalid in ipairs({ "nil", "number", "text", "throw", "missing" }) do
		helpers.it("rejects the current script chord read " .. invalid .. " before writes", function()
			local owner, writes, redraws = inert_owner(true), 0, 0
			owner.set_chords_enabled = function() writes = writes + 1; return true end
			local action = command(owner, function() redraws = redraws + 1 end)
			owner.chords_enabled = function()
				if invalid == "throw" then error("controlled chord read refusal") end
				if invalid == "number" then return 2 end
				if invalid == "text" then return "true" end
				return nil
			end
			if invalid == "missing" then owner.chords_enabled = nil end
			local called, receipt, notices, releases = observe(action)
			helpers.assert_true(called)
			helpers.assert_eq(writes, 0)
			helpers.assert_eq(redraws, 0)
			helpers.assert_eq(receipt, false)
			helpers.assert_eq(#notices, 1)
			helpers.assert_eq(releases, 1)
		end)
	end
	--- Uses the real chord loader, sparse native writer and private canonical file.
	--- @param initial boolean Durable/runtime posture.
	--- @param body function Test over the actual initialized owner.
	local function with_real_owner(initial, body)
		local path = os.tmpname()
		local source = '# independently owned future configuration\n[shortcuts.script_control]\nchords_enabled = '
			.. tostring(initial) .. '\nscript_altgr_enter = "script_reload"\nfuture_mode = "kept" # independent comment\n[future]\nvalues = ["a", "b"]\n'
		local file = assert(io.open(path, "wb"));assert(file:write(source));assert(file:close())
		local paths, loaded = require("infra.config_paths"), {}
		for _, name in ipairs({ "infra.config_paths", "modules.shortcuts.script_chords" }) do
			loaded[#loaded + 1] = { name = name, value = package.loaded[name] }
		end
		local port = {}
		for key, value in pairs(paths) do port[key] = value end
		port.config = function(name) if name == "config.toml" then return path end return paths.config(name) end
		local rename = os.rename
		local called, failure = pcall(function()
			package.loaded["infra.config_paths"] = port
			package.loaded["modules.shortcuts.script_chords"] = nil
			local chords = require("modules.shortcuts.script_chords")
			chords.init({ is_paused = function() return false end, defer = function() return true end })
			helpers.assert_eq(chords.chords_enabled(), initial)
			body(chords, path, source)
		end)
		os.rename = rename
		for _, row in ipairs(loaded) do package.loaded[row.name] = row.value end
		os.remove(path .. ".tmp")
		assert(os.remove(path), "the actual private chord config is retired")
		if not called then error(failure, 0) end
	end
	--- Reads the complete owned canonical byte image.
	--- @param path string Private config path.
	--- @return string source
	local function read(path)
		local file = assert(io.open(path, "rb"));local source = file:read("*a");assert(file:close());return source
	end
	for _, initial in ipairs({ true, false }) do
		for _, outcome in ipairs({ "true", "false", "nil", "number", "throw" }) do
			helpers.it("acknowledges the actual chord publication " .. outcome .. " from " .. tostring(initial), function()
				with_real_owner(initial, function(chords, path, source)
					local redraws, writes, rename = 0, 0, os.rename
					local action = command(chords, function() redraws = redraws + 1 end)
					os.rename = function(from, to)
						if from == path .. ".tmp" and to == path then
							writes = writes + 1
							if outcome == "throw" then error("controlled native publication refusal") end
							if outcome == "false" then return false end
							if outcome == "nil" then return nil end
							if outcome == "number" then return 2 end
						end
						return rename(from, to)
					end
					local called, receipt, notices, releases = observe(action)
					os.rename = rename
					helpers.assert_true(called)
					helpers.assert_eq(writes, 1)
					helpers.assert_eq(receipt, outcome == "true")
					helpers.assert_eq(redraws, outcome == "true" and 1 or 0)
					helpers.assert_eq(#notices, outcome == "true" and 0 or 1)
					helpers.assert_eq(releases, #notices)
					if outcome == "true" then
						helpers.assert_eq(chords.chords_enabled(), not initial)
						local expected = source:gsub("chords_enabled = " .. tostring(initial), "chords_enabled = " .. tostring(not initial), 1)
						if not initial then expected = source:gsub("chords_enabled = false\n", "", 1) end
						helpers.assert_eq(read(path), expected, "only the owned sparse switch leaf changes")
						local decoded = require("toml_codec").decode(read(path))
						if not initial then helpers.assert_nil(decoded.shortcuts.script_control.chords_enabled, "the true default is a deletion") end
						package.loaded["modules.shortcuts.script_chords"] = nil
						local reloaded = require("modules.shortcuts.script_chords")
						helpers.assert_eq(reloaded.chords_enabled(), not initial, "a native reload reads the acknowledged target")
					else
						helpers.assert_eq(read(path), source, "all slot assignments/comments/future fields survive refusal")
						helpers.assert_eq(chords.chords_enabled(), initial)
					end
					helpers.assert_eq(chords.get_action("script_altgr_enter"), "script_reload")
				end)
			end)
		end
		helpers.it("uses the real owner after independent chord publication from " .. tostring(initial), function()
			with_real_owner(initial, function(chords, path, source)
				local redraws, writes, rename = 0, 0, os.rename
				local action = command(chords, function() redraws = redraws + 1 end)
				helpers.assert_true(chords.set_chords_enabled(not initial), "the actual independent writer changes the live posture")
				helpers.assert_eq(chords.chords_enabled(), not initial)
				os.rename = function(from, to)
					if from == path .. ".tmp" and to == path then writes = writes + 1 end
					return rename(from, to)
				end
				local called, receipt, notices = observe(action)
				os.rename = rename
				helpers.assert_true(called)
				helpers.assert_eq(chords.chords_enabled(), initial, "the real held callback toggles the current durable state")
				helpers.assert_eq(receipt, true)
				helpers.assert_eq(writes, 1)
				helpers.assert_eq(redraws, 1)
				helpers.assert_eq(#notices, 0)
				local observed = read(path):gsub("\nchords_enabled = %a+\n", "\n")
				local retained = source:gsub("\nchords_enabled = %a+\n", "\n")
				helpers.assert_eq(observed, retained, "all independent slot/comment/future bytes remain exact")
				package.loaded["modules.shortcuts.script_chords"] = nil
				helpers.assert_eq(require("modules.shortcuts.script_chords").chords_enabled(), initial)
			end)
		end)
		helpers.it("respects the native chord configuration reservation from " .. tostring(initial), function()
			with_real_owner(initial, function(chords, path, source)
				local action, redraws = nil, 0
				action = command(chords, function() redraws = redraws + 1 end)
				local owner = {}
				helpers.assert_true(chords.acquire_configuration(owner))
				local called, receipt, notices = observe(action)
				local released = chords.release_configuration(owner)
				helpers.assert_true(released)
				helpers.assert_true(called)
				helpers.assert_eq(receipt, false)
				helpers.assert_eq(redraws, 0)
				helpers.assert_eq(#notices, 1)
				helpers.assert_eq(read(path), source)
				helpers.assert_eq(chords.chords_enabled(), initial)
			end)
		end)
	end
end)

helpers.describe("declared Shortcut wrap presentation source", function()
	helpers.it("withdraws and repairs the actual wrap-parent source without a fixed fallback", function()
		local renderer = require("infra.manifest_menu")
		local root = renderer.get_root()
		local original = root.shortcut_wrap_frame
		local label = require("infra.i18n").get("menu.shortcuts.wrap_symbols")
		local log = {}
		local ok, detail = xpcall(function()
			local current = assert(find_row(shortcuts_menu({ shortcuts = fake_shortcuts(log) }), label))
			helpers.assert_eq(#current.menu, 2, "the actual source returns sorted unique pairs")
			root.shortcut_wrap_frame = nil
			helpers.assert_nil(find_row(shortcuts_menu({ shortcuts = fake_shortcuts(log) }), label), "no undeclared parent is fabricated")
			helpers.assert_nil(log.wrapped, "presentation withdrawal never invokes a native selection action")
			root.shortcut_wrap_frame = original
			local repaired = assert(find_row(shortcuts_menu({ shortcuts = fake_shortcuts(log) }), label))
			repaired.menu[1].fn()
			helpers.assert_eq(log.wrapped, "()")
		end, debug.traceback)
		root.shortcut_wrap_frame = original
		if not ok then error(detail, 0) end
	end)

	helpers.it("uses the declared live-wrap label and late source readiness before its unchanged native setter", function()
		local renderer = require("infra.manifest_menu")
		local root = renderer.get_root()
		local original = root.shortcut_wrap_live_control
		local i18n = require("infra.i18n")
		local state, admitted, writes, redraws = false, true, 0, 0
		local shortcuts = fake_shortcuts()
		shortcuts.configuration_admitted = function() return admitted end
		shortcuts.is_wrap_on_type_enabled = function() return state end
		shortcuts.set_wrap_on_type_enabled = function(value) writes = writes + 1; state = value; return true end
		local function rows() return shortcuts_menu({ shortcuts = shortcuts, on_menu_changed = function() redraws = redraws + 1 end }) end
		local ok, detail = xpcall(function()
			local row = assert(find_row(rows(), i18n.get("shortcuts.label_wrap_text")))
			helpers.assert_eq(row.checked, false)
			helpers.assert_nil(row.disabled)
			helpers.assert_eq(writes + redraws, 0)
			root.shortcut_wrap_live_control = nil
			helpers.assert_eq(row.fn(), false, "retained callback cannot bypass actual declaration withdrawal")
			helpers.assert_nil(find_row(rows(), i18n.get("shortcuts.label_wrap_text")))
			helpers.assert_eq(writes + redraws, 0)
			root.shortcut_wrap_live_control = original
			admitted = false
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(writes + redraws, 0)
			admitted = true
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(writes, 1)
			helpers.assert_eq(redraws, 1)
			helpers.assert_eq(assert(find_row(rows(), i18n.get("shortcuts.label_wrap_text"))).checked, true)
		end, debug.traceback)
		root.shortcut_wrap_live_control = original
		if not ok then error(detail, 0) end
	end)
end)

-- Own the genuine native translation cohort while exercising cold and warm trays.
local function with_shortcut_locale(code, scenario)
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu", "ui.menu.menu_builder" }
	local prior = {}; for _, name in ipairs(names) do prior[name] = rawget(package.loaded, name) end
	local native, owner, receipt, acquired
	local ok, detail = xpcall(function()
		for _, name in ipairs(names) do rawset(package.loaded, name, nil) end
		native = require("infra.i18n")
		native.init()
		owner = { pending = function() return false end }
		assert(native.scope_acquire(owner))
		acquired = true
		receipt = assert(native.scope_capture(owner))
		assert(native.scope_apply(owner, receipt, code))
		return scenario()
	end, debug.traceback)
	local restored = not receipt or native.scope_restore(owner, receipt)
	local released = not acquired or native.scope_release(owner)
	local forgotten = not receipt or (released and native.scope_forget(owner, receipt))
	for _, name in ipairs(names) do rawset(package.loaded, name, prior[name]) end
	assert(restored and released and forgotten, "genuine locale inverse or lease finalization refused")
	for _, name in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, name), prior[name]), name) end
	if not ok then error(detail, 0) end
end

helpers.describe("Shortcut frame genuine translated hierarchy", function()
	for _, code in ipairs({ "en", "fr" }) do
		local language = code
		helpers.it("retains the handwritten cold and warm " .. language .. " wrap hierarchy and callbacks", function()
			with_shortcut_locale(language, function()
				local path = require("infra.paths").shared("tests/corpus/menus/shortcut_presentation_frames.json")
				local file = assert(io.open(path, "rb"))
				local bytes = assert(file:read("*a")); assert(file:close())
				local expected = assert(require("json").decode(bytes))[language]
				local state, writes, redraws = false, 0, 0
				local log, shortcuts = {}, fake_shortcuts()
				shortcuts.wrap_selection = function(left, right) log.wrapped = left .. right end
				shortcuts.configuration_admitted = function() return true end
				shortcuts.is_wrap_on_type_enabled = function() return state end
				shortcuts.set_wrap_on_type_enabled = function(value) state = value; writes = writes + 1; return true end
				local function build()
					return shortcuts_menu({ shortcuts = shortcuts, on_menu_changed = function() redraws = redraws + 1 end })
				end
				local cold = assert(build())
				local parent = assert(find_row(cold, expected.lua_wrap))
				local live = assert(find_row(cold, expected.linux_wrap_feature))
				helpers.assert_eq(#parent.menu, 2)
				helpers.assert_eq(parent.menu[1].title, "( … )")
				helpers.assert_eq(parent.menu[2].title, "« … »")
				helpers.assert_eq(live.checked, false)
				helpers.assert_eq(writes + redraws, 0, "building the complete hierarchy cannot apply native state")
				parent.menu[1].fn()
				helpers.assert_eq(log.wrapped, "()")
				helpers.assert_eq(live.fn(), true)
				helpers.assert_eq(writes, 1)
				helpers.assert_eq(redraws, 1)
				local warm = assert(build())
				helpers.assert_eq(assert(find_row(warm, expected.linux_wrap_feature)).checked, true)
				helpers.assert_eq(#assert(find_row(warm, expected.lua_wrap)).menu, 2)
				helpers.assert_eq(writes + redraws, 2, "a warm rebuild retains state without repeating the setter")
			end)
		end)
	end
end)

helpers.describe("Shortcut extension genuine physical failure marker", function()
	for _, code in ipairs({ "en", "fr" }) do
		local language = code
		helpers.it("uses and withdraws the whole declared " .. language .. " marker after the real extension chunk fails", function()
			with_shortcut_locale(language, function()
				local lfs, Paths = require("lfs"), require("infra.paths")
				local directory = os.tmpname(); assert(os.remove(directory)); assert(lfs.mkdir(directory))
				local pack = directory .. "/g1-marker"
				assert(lfs.mkdir(pack)); assert(lfs.mkdir(pack .. "/shortcuts")); assert(lfs.mkdir(pack .. "/hotstrings"))
				local function write(path, bytes)
					local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
				end
				write(pack .. "/manifest.toml", '[extension]\nname = "Native %s $1 50%"\n')
				write(pack .. "/shortcuts/menu.lua", 'error("Actual compiled physical extension failure", 0)\n')
				local original_roots = Paths.extension_roots
				local root = require("infra.manifest_menu").get_root()
				local original_frame = root.shortcut_extension_error_frame
				local expected = language == "fr" and "Native %s $1 50% — Erreur" or "Native %s $1 50% — Error"
				local ok, detail = xpcall(function()
					Paths.extension_roots = function() return { directory } end
					local current = assert(find_row(shortcuts_menu(), expected))
					helpers.assert_eq(current.disabled, true)
					helpers.assert_nil(current.fn, "a real failed extension marker is inert")
					helpers.assert_nil(current.menu)
					root.shortcut_extension_error_frame = nil
					helpers.assert_nil(find_row(shortcuts_menu(), expected), "no raw-label fallback bypasses missing declaration")
					root.shortcut_extension_error_frame = { { type = "command", id = "foreign_marker", i18n = "common.error_title" } }
					helpers.assert_nil(find_row(shortcuts_menu(), expected), "a malformed whole frame cannot borrow an unrelated callback")
					root.shortcut_extension_error_frame = original_frame
					helpers.assert_eq(assert(find_row(shortcuts_menu(), expected)).disabled, true)
					local file = assert(io.open(pack .. "/shortcuts/menu.lua", "rb"))
					helpers.assert_eq(assert(file:read("*a")), 'error("Actual compiled physical extension failure", 0)\n')
					assert(file:close())
				end, debug.traceback)
				Paths.extension_roots = original_roots
				root.shortcut_extension_error_frame = original_frame
				assert(os.remove(pack .. "/manifest.toml")); assert(os.remove(pack .. "/shortcuts/menu.lua"))
				assert(lfs.rmdir(pack .. "/shortcuts")); assert(lfs.rmdir(pack .. "/hotstrings")); assert(lfs.rmdir(pack)); assert(lfs.rmdir(directory))
				if not ok then error(detail, 0) end
			end)
		end)
	end
end)
