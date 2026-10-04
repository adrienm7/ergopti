--- tests/unit/modules/shortcuts/test_case_transforms.lua

--- ==============================================================================
--- MODULE: Shortcut Case Transforms
--- DESCRIPTION:
--- Proves the Linux handlers match the macOS/Windows toggle behavior and pass
--- Unicode results into the clipboard selection transaction.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_manager(selected, body)
	local names = {
		manager = "modules.shortcuts.manager",
		clipboard = "adapters.clipboard",
		event_loop = "adapters.event_loop",
		combo = "modules.gestures.combo_emitter",
		injector = "modules.hotstrings.injector",
		keylogger = "modules.keylogger.keylogger",
	}
	local previous = {}
	for key, name in pairs(names) do previous[key] = package.loaded[name] end

	local state = { selected = selected, replacement = nil }
	package.loaded[names.clipboard] = {
		transform_selection = function(transform)
			state.replacement = transform(state.selected)
			return true
		end,
		read_checked = function() return true, "clipboard", nil end,
	}
	package.loaded[names.event_loop] = { sleep_ms = function() return true end }
	package.loaded[names.combo] = { press = function() return true end }
	package.loaded[names.injector] = { inject = function() return { ok = true } end }
	package.loaded[names.keylogger] = { record_shortcut = function() return true end }
	package.loaded[names.manager] = nil

	local ok, err = pcall(function()
		body(require(names.manager), state)
	end)
	for key, name in pairs(names) do package.loaded[name] = previous[key] end
	helpers.assert_true(ok, "shortcut case probe must not throw: " .. tostring(err))
end

helpers.describe("shortcut case transforms", function()
	helpers.it("toggles an international selection between uppercase and lowercase", function()
		with_manager("été Straße Москва", function(manager, state)
			helpers.assert_true(manager.transform_uppercase())
			helpers.assert_eq(state.replacement, "ÉTÉ STRASSE МОСКВА")

			state.selected = state.replacement
			helpers.assert_true(manager.transform_uppercase())
			helpers.assert_eq(state.replacement, "été strasse москва")
		end)
	end)

	helpers.it("toggles title case like the macOS and Windows actions", function()
		with_manager("«ÉTÉ» STRAẞE МОСКВА", function(manager, state)
			helpers.assert_true(manager.transform_titlecase())
			helpers.assert_eq(state.replacement, "«Été» Straße Москва")

			state.selected = state.replacement
			helpers.assert_true(manager.transform_titlecase())
			helpers.assert_eq(state.replacement, "«été» straße москва")
		end)
	end)

	helpers.it("lowercases explicitly without applying toggle semantics", function()
		with_manager("ÉTÉ STRAẞE", function(manager, state)
			helpers.assert_true(manager.transform_lowercase())
			helpers.assert_eq(state.replacement, "été straße")
		end)
	end)

	helpers.it("capitalizes a non-ASCII CapsWord character after Unicode punctuation", function()
		with_manager("unused", function(manager)
			manager.toggle_caps_word()
			helpers.assert_eq(manager.process_caps_word("é"), "É")
			helpers.assert_eq(manager.process_caps_word("—"), nil)
			helpers.assert_eq(manager.process_caps_word("я"), "Я")
		end)
	end)
end)

--- Initializes the real configuration reservation and builds its actual tray row.
--- Native selection/clipboard ports remain the case fixture's boundaries.
--- @param body function
local function with_caps_word_menu(body)
	with_manager("unused", function(manager)
		require("test.config_unused_keys_contract").sandbox.with_config(
			'[shortcuts]\nenabled = false\n[foreign]\nvalue = "keep"\n', function(path)
				manager.init({ persist = true, config_path = path })
				local changed = { count = 0 }
				local builder = helpers.load_module("ui.menu.menu_builder")
				local function row()
					local rows = builder.build({ _version = "0.0.0-dev.12", shortcuts = manager,
						paused = false, is_paused = function() return true end,
						on_quit = function() end,
						on_menu_changed = function() changed.count = changed.count + 1 end,
					})
					local label = require("infra.i18n").get("sg_actions.caps_word")
					local function find(items)
						for _, item in ipairs(items or {}) do
							if item.title == label then return item end
							local nested = find(item.menu)
							if nested then return nested end
						end
					end
					return find(rows)
				end
				local original = require("test.config_unused_keys_contract").sandbox.read_bytes(path)
				body(manager, row, changed)
				helpers.assert_eq(require("test.config_unused_keys_contract").sandbox.read_bytes(path), original,
					"CapsWord is runtime state and must leave every configuration byte untouched")
			end)
	end)
end

helpers.describe("CapsWord selection checkbox ownership", function()
	local path = require("infra.paths").shared("tests/corpus/menus/linux_caps_word.json")
	local file = assert(io.open(path, "rb"))
	local corpus = require("json").decode(file:read("*a"))
	file:close()

	for _, vector in ipairs(corpus.states) do
		helpers.it("renders the shared state " .. vector.name .. " (selection-caps-word)", function()
			with_caps_word_menu(function(manager, row)
				if vector.active then manager.toggle_caps_word() end
				local owner = {}
				if vector.reserved then helpers.assert_eq(manager.acquire_configuration(owner), true) end
				local item = row()
				helpers.assert_type(item, "table", "the declared CapsWord checkbox must remain present")
				helpers.assert_eq(item.title, require("infra.i18n").get(corpus.label_key))
				helpers.assert_eq(item.checked, vector.checked)
				helpers.assert_eq(item.disabled == true, vector.disabled)
				if vector.reserved then helpers.assert_eq(manager.release_configuration(owner), true) end
			end)
		end)
	end

	helpers.it("returns an exact publication receipt from the actual native owner (selection-caps-word)", function()
		with_caps_word_menu(function(manager)
			helpers.assert_eq(manager.toggle_caps_word(), true)
			helpers.assert_eq(manager.is_caps_word_active(), true)
			local owner = {}
			helpers.assert_eq(manager.acquire_configuration(owner), true)
			helpers.assert_eq(manager.toggle_caps_word(), false)
			helpers.assert_eq(manager.configuration_snapshot(owner).caps_word_active, true)
			helpers.assert_eq(manager.release_configuration(owner), true)
			helpers.assert_eq(manager.toggle_caps_word(), true)
			helpers.assert_eq(manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("acknowledges the published state before menu refresh after live pause while shortcuts are off (selection-caps-word)", function()
		with_caps_word_menu(function(manager, row, changed)
			local item = row()
			helpers.assert_eq(item.disabled == true, false)
			helpers.assert_eq(item.fn(), true)
			helpers.assert_eq(manager.is_caps_word_active(), true)
			helpers.assert_eq(changed.count, 1)
			helpers.assert_eq(row().checked, true)
			helpers.assert_eq(row().fn(), true)
			helpers.assert_eq(manager.is_caps_word_active(), false)
			helpers.assert_eq(changed.count, 2)
		end)
	end)

	helpers.it("toggles the latest published state rather than the retained checkmark (selection-caps-word)", function()
		with_caps_word_menu(function(manager, row, changed)
			local held = row().fn
			helpers.assert_eq(manager.toggle_caps_word(), true)
			helpers.assert_eq(manager.is_caps_word_active(), true)
			helpers.assert_eq(held(), true)
			helpers.assert_eq(manager.is_caps_word_active(), false)
			helpers.assert_eq(changed.count, 1)
		end)
	end)

	helpers.it("refuses a retained callback while the actual configuration owner holds it (selection-caps-word)", function()
		with_caps_word_menu(function(manager, row, changed)
			local held = row().fn
			local owner = {}
			helpers.assert_eq(manager.acquire_configuration(owner), true)
			helpers.assert_eq(held(), false)
			helpers.assert_eq(manager.is_caps_word_active(), false)
			helpers.assert_eq(changed.count, 0)
			helpers.assert_eq(manager.release_configuration(owner), true)
			helpers.assert_eq(row().fn(), true)
			helpers.assert_eq(manager.is_caps_word_active(), true)
			helpers.assert_eq(changed.count, 1)
		end)
	end)

	for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" },
		{ name = "zero", value = 0 }, { name = "truthy-string", value = "ack" } }) do
		helpers.it("does not refresh after the native owner's " .. receipt.name .. " receipt (selection-caps-word)", function()
			with_caps_word_menu(function(manager, row, changed)
				local calls = 0
				manager.toggle_caps_word = function() calls = calls + 1; return receipt.value end
				local returned = row().fn()
				helpers.assert_eq(returned, false)
				helpers.assert_eq(calls, 1)
				helpers.assert_eq(changed.count, 0)
				helpers.assert_eq(manager.is_caps_word_active(), false)
			end)
		end)
	end

	helpers.it("rechecks a real reservation acquired inside protected metric delivery (selection-caps-word)", function()
		with_caps_word_menu(function(manager, row, changed)
			local owner, observed = {}, {}
			package.loaded["modules.keylogger.keylogger"].record_shortcut = function(_, key)
				observed.key = key
				observed.acquired = manager.acquire_configuration(owner)
			end
			local returned = row().fn()
			helpers.assert_eq(observed.key, "caps_word")
			helpers.assert_eq(observed.acquired, true)
			helpers.assert_eq(manager.is_caps_word_active(), false)
			helpers.assert_eq(returned, false)
			helpers.assert_eq(manager.configuration_snapshot(owner).caps_word_triggered, false)
			helpers.assert_eq(changed.count, 0)
			helpers.assert_eq(manager.release_configuration(owner), true)
			package.loaded["modules.keylogger.keylogger"].record_shortcut = function() end
			helpers.assert_eq(row().fn(), true)
			helpers.assert_eq(manager.is_caps_word_active(), true)
		end)
	end)

	helpers.it("keeps a metric callback's acknowledged reservation even when it throws (selection-caps-word)", function()
		with_caps_word_menu(function(manager, row, changed)
			local owner, observed = {}, {}
			package.loaded["modules.keylogger.keylogger"].record_shortcut = function()
				observed.acquired = manager.acquire_configuration(owner)
				error("controlled metric failure after reservation")
			end
			local returned = row().fn()
			helpers.assert_eq(observed.acquired, true)
			helpers.assert_eq(manager.is_caps_word_active(), false)
			helpers.assert_eq(returned, false)
			helpers.assert_eq(changed.count, 0)
			helpers.assert_eq(manager.release_configuration(owner), true)
		end)
	end)

	helpers.it("refuses missing or malformed native readiness instead of borrowing a default (selection-caps-word)", function()
		with_caps_word_menu(function(manager, row, changed)
			local calls = 0
			manager.toggle_caps_word = function() calls = calls + 1; return true end
			for _, invalid in ipairs({ { value = nil }, { value = false }, { value = function() return 1 end } }) do
				manager.configuration_admitted = invalid.value
				local item = row()
				helpers.assert_eq(item.disabled, true)
				helpers.assert_type(item.fn, "function", "retained native callbacks remain guarded even when disabled")
				helpers.assert_eq(item.fn(), false)
			end
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(changed.count, 0)
		end)
	end)

	for _, vector in ipairs(corpus.platforms) do
		helpers.it("keeps the existing " .. vector.platform .. " platform boundary (selection-caps-word)", function()
			local renderer = assert(require("menu.renderer").new({ platform = vector.platform,
				manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
				json_decode = require("json").decode, i18n = require("infra.i18n"),
				logger = require("logger.shim"),
			}))
			local rows = renderer.build(corpus.section, "CapsWord", nil, nil, {
				commands = { [corpus.id] = function() return true end },
				state_getters = { selection_caps_word_active = function() return false end,
					selection_caps_word_ready = function() return true end },
			})
			helpers.assert_eq(#rows, vector.rows)
			if vector.rows > 0 then
				helpers.assert_eq(rows[1].title, require("infra.i18n").get(corpus.label_key))
				helpers.assert_eq(rows[1].checked, false)
				helpers.assert_type(rows[1].fn, "function")
			end
		end)
	end
end)

--- Builds the case trio through the actual manager, configuration, and renderer.
--- @param body function Receives the manager, menu finder, and clipboard observations.
local function with_case_menu(body)
	with_caps_word_menu(function(manager)
		local observed = { clipboard_calls = 0 }
		package.loaded["adapters.clipboard"].transform_selection = function(transform)
			observed.clipboard_calls = observed.clipboard_calls + 1
			observed.replacement = transform(observed.selected or "été")
			return true
		end
		local builder = helpers.load_module("ui.menu.menu_builder")
		local function rows()
			return builder.build({ _version = "0.0.0-dev.12", shortcuts = manager,
				paused = false, is_paused = function() return true end,
				on_quit = function() end,
			})
		end
		local function item(label_key)
			local label = require("infra.i18n").get(label_key)
			local function find(items)
				for _, row in ipairs(items or {}) do
					if row.title == label then return row end
					local nested = find(row.menu)
					if nested then return nested end
				end
			end
			return find(rows())
		end
		body(manager, item, observed, rows)
	end)
end

helpers.describe("shared selection case command ownership", function()
	local path = require("infra.paths").shared("tests/corpus/menus/linux_selection_case.json")
	local file = assert(io.open(path, "rb"))
	local corpus = require("json").decode(file:read("*a"))
	file:close()

	for _, vector in ipairs(corpus.commands) do
		helpers.it("publishes the declared " .. vector.id .. " Unicode action (selection-case-command)", function()
			with_case_menu(function(_, item, observed)
				observed.selected = vector.selected
				local row = item(vector.label_key)
				helpers.assert_type(row, "table")
				helpers.assert_eq(row.disabled == true, false)
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(observed.clipboard_calls, 1)
				helpers.assert_eq(observed.replacement, vector.expected)
			end)
		end)

		helpers.it("retires held " .. vector.id .. " while configuration is reserved (selection-case-command)", function()
			with_case_menu(function(manager, item, observed)
				local held, owner = item(vector.label_key).fn, {}
				helpers.assert_eq(manager.acquire_configuration(owner), true)
				helpers.assert_eq(item(vector.label_key).disabled, true)
				helpers.assert_eq(held(), false)
				helpers.assert_eq(observed.clipboard_calls, 0)
				helpers.assert_eq(manager.release_configuration(owner), true)
				helpers.assert_eq(held(), true)
				helpers.assert_eq(observed.clipboard_calls, 1)
			end)
		end)

		helpers.it("rechecks " .. vector.id .. " reservation after protected metrics (selection-case-command)", function()
			with_case_menu(function(manager, item, observed)
				local owner = {}
				package.loaded["modules.keylogger.keylogger"].record_shortcut = function(_, key)
					observed.metric_key = key
					observed.acquired = manager.acquire_configuration(owner)
					error("controlled metric refusal after reservation")
				end
				local returned = item(vector.label_key).fn()
				helpers.assert_eq(observed.acquired, true)
				helpers.assert_type(observed.metric_key, "string")
				helpers.assert_eq(returned, false)
				helpers.assert_eq(observed.clipboard_calls, 0)
				helpers.assert_eq(observed.replacement, nil)
				helpers.assert_eq(manager.release_configuration(owner), true)
				package.loaded["modules.keylogger.keylogger"].record_shortcut = function() end
				helpers.assert_eq(item(vector.label_key).fn(), true)
				helpers.assert_eq(observed.clipboard_calls, 1)
			end)
		end)

		helpers.it("requires strict " .. vector.id .. " acknowledgement (selection-case-command)", function()
			with_case_menu(function(manager, item, observed)
				local calls = 0
				for _, receipt in ipairs({ { value = false }, {}, { value = 0 }, { value = "ack" } }) do
					manager[vector.method] = function() calls = calls + 1; return receipt.value end
					helpers.assert_eq(item(vector.label_key).fn(), false)
				end
				helpers.assert_eq(calls, 4)
				helpers.assert_eq(observed.clipboard_calls, 0)
			end)
		end)

		helpers.it("refuses malformed " .. vector.id .. " capabilities (selection-case-command)", function()
			with_case_menu(function(manager, item, observed)
				local admitted = manager.configuration_admitted
				for _, invalid in ipairs({ {}, { value = false }, { value = function() return 1 end } }) do
					manager.configuration_admitted = invalid.value
					local row = item(vector.label_key)
					helpers.assert_eq(row.disabled, true)
					helpers.assert_eq(row.fn(), false)
				end
				manager.configuration_admitted = admitted
				manager[vector.method] = nil
				local row = item(vector.label_key)
				helpers.assert_eq(row.disabled, true)
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(observed.clipboard_calls, 0)
			end)
		end)
	end

	for _, vector in ipairs(corpus.platforms) do
		helpers.it("keeps " .. vector.platform .. " selection command placement (selection-case-command)", function()
			local renderer = assert(require("menu.renderer").new({ platform = vector.platform,
				manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
				json_decode = require("json").decode, i18n = require("infra.i18n"), logger = require("logger.shim"),
			}))
			local commands, getters = {}, {}
			for _, command in ipairs(corpus.commands) do
				commands[command.id] = function() return true end
				getters[command.id .. "_ready"] = function() return true end
			end
			local rows = renderer.build(corpus.section, "Selection", nil, nil,
				{ commands = commands, state_getters = getters })
			helpers.assert_eq(#rows, vector.rows)
			for index, row in ipairs(rows) do
				helpers.assert_eq(row.title, require("infra.i18n").get(corpus.commands[index].label_key))
				helpers.assert_eq(row.fn(), true)
			end
		end)
	end

	helpers.it("keeps direct catalogue case semantics and refuses reserved aliases (selection-case-command)", function()
		with_case_menu(function(manager, _, observed)
			observed.selected = "«été» Straße Москва"
			helpers.assert_eq(manager.transform_to_uppercase(), true)
			helpers.assert_eq(observed.replacement, "«ÉTÉ» STRASSE МОСКВА")
			observed.selected = "«ÉTÉ» STRAẞE МОСКВА"
			helpers.assert_eq(manager.transform_to_titlecase(), true)
			helpers.assert_eq(observed.replacement, "«Été» Straße Москва")
			local owner = {}
			package.loaded["modules.keylogger.keylogger"].record_shortcut = function()
				observed.acquired = manager.acquire_configuration(owner)
			end
			local before = observed.clipboard_calls
			local result = manager.action_handlers().wrap_selection(nil, "(|)")
			helpers.assert_eq(observed.acquired, true)
			helpers.assert_eq(result, false)
			helpers.assert_eq(observed.clipboard_calls, before)
			helpers.assert_eq(manager.transform_to_uppercase(), false)
			helpers.assert_eq(manager.transform_to_titlecase(), false)
			helpers.assert_eq(manager.release_configuration(owner), true)
		end)
	end)
end)
