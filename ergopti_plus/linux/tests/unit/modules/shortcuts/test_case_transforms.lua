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

--- Records the existing native effect ports beneath an actual helper menu.
--- @param body function Receives manager, item finder, effects and menu reader.
local function with_helper_menu(body)
	with_case_menu(function(manager, item, _, rows)
		local effects = { chords = {}, reads = 0, injections = {} }
		package.loaded["modules.gestures.combo_emitter"].press = function(chord)
			effects.chords[#effects.chords + 1] = chord
			return effects.refuse_chord ~= #effects.chords
		end
		package.loaded["adapters.clipboard"].read_checked = function()
			effects.reads = effects.reads + 1
			return not effects.refuse_read, "été Straße Москва", "controlled read refusal"
		end
		package.loaded["modules.hotstrings.injector"].inject = function(count, text, consume)
			effects.injections[#effects.injections + 1] = { count, text, consume }
			return { ok = not effects.refuse_injection }
		end
		body(manager, item, effects, rows)
	end)
end

helpers.describe("shared selection helper command ownership", function()
	local path = require("infra.paths").shared("tests/corpus/menus/linux_selection_helpers.json")
	local file = assert(io.open(path, "rb"))
	local corpus = require("json").decode(file:read("*a"))
	file:close()

	for _, vector in ipairs(corpus.commands) do
		helpers.it("dispatches actual " .. vector.id .. " effects (selection-helper-command)", function()
			with_helper_menu(function(_, item, effects)
				local row = item(vector.label_key)
				helpers.assert_type(row, "table")
				helpers.assert_eq(row.disabled == true, false)
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(effects.chords, vector.chords)
				if vector.clipboard then
					helpers.assert_eq(effects.reads, 1)
					helpers.assert_eq(effects.injections, { { 0, vector.clipboard, false } })
				else
					helpers.assert_eq(effects.reads, 0)
					helpers.assert_eq(#effects.injections, 0)
				end
			end)
		end)

		helpers.it("fences retained " .. vector.id .. " during reservation (selection-helper-command)", function()
			with_helper_menu(function(manager, item, effects)
				local held, owner = item(vector.label_key).fn, {}
				helpers.assert_eq(manager.acquire_configuration(owner), true)
				helpers.assert_eq(item(vector.label_key).disabled, true)
				helpers.assert_eq(held(), false)
				helpers.assert_eq(#effects.chords + effects.reads + #effects.injections, 0)
				helpers.assert_eq(manager.release_configuration(owner), true)
				helpers.assert_eq(held(), true)
			end)
		end)

		helpers.it("requires current " .. vector.id .. " receipts (selection-helper-command)", function()
			with_helper_menu(function(manager, item, effects)
				local held = item(vector.label_key).fn
				local original, calls = manager[vector.method], 0
				for _, receipt in ipairs({ { value = false }, {}, { value = 0 }, { value = "ack" } }) do
					manager[vector.method] = function() calls = calls + 1; return receipt.value end
					helpers.assert_eq(held(), false)
				end
				helpers.assert_eq(calls, 4)
				helpers.assert_eq(#effects.chords + effects.reads + #effects.injections, 0)
				manager[vector.method] = original
				helpers.assert_eq(held(), true)
			end)
		end)

		helpers.it("refuses withdrawn " .. vector.id .. " capabilities (selection-helper-command)", function()
			with_helper_menu(function(manager, item, effects)
				local held = item(vector.label_key).fn
				local admitted, original = manager.configuration_admitted, manager[vector.method]
				for _, invalid in ipairs({ {}, { value = false }, { value = function() return 1 end } }) do
					manager.configuration_admitted = invalid.value
					helpers.assert_eq(item(vector.label_key).disabled, true)
					helpers.assert_eq(held(), false)
				end
				manager.configuration_admitted = admitted
				manager[vector.method] = nil
				helpers.assert_eq(item(vector.label_key).disabled, true)
				helpers.assert_eq(held(), false)
				helpers.assert_eq(#effects.chords + effects.reads + #effects.injections, 0)
				manager[vector.method] = original
				helpers.assert_eq(held(), true)
			end)
		end)
	end

	for _, method in ipairs({ "select_word", "select_line" }) do
		for _, failed_step in ipairs({ 1, 2 }) do
			helpers.it("retains native " .. method .. " step " .. failed_step .. " refusal (selection-helper-command)", function()
				with_helper_menu(function(_, item, effects)
					local vector = corpus.commands[method == "select_word" and 1 or 2]
					effects.refuse_chord = failed_step
					helpers.assert_eq(item(vector.label_key).fn(), false)
					helpers.assert_eq(#effects.chords, failed_step)
					effects.chords, effects.refuse_chord = {}, nil
					helpers.assert_eq(item(vector.label_key).fn(), true)
					helpers.assert_eq(effects.chords, vector.chords)
				end)
			end)
		end
	end

	for _, failure in ipairs({ "refuse_read", "refuse_injection" }) do
		helpers.it("retains actual paste " .. failure .. " and retry (selection-helper-command)", function()
			with_helper_menu(function(_, item, effects)
				local row = item("sg_actions.paste_plain")
				effects[failure] = true
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(#effects.injections, failure == "refuse_read" and 0 or 1)
				effects[failure] = nil
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(effects.reads, 2)
				helpers.assert_eq(#effects.injections, failure == "refuse_read" and 1 or 2)
				helpers.assert_eq(effects.injections[#effects.injections], { 0, "été Straße Москва", false })
			end)
		end)
	end

	for _, vector in ipairs(corpus.platforms) do
		helpers.it("preserves " .. vector.platform .. " placement (selection-helper-command)", function()
			local renderer = assert(require("menu.renderer").new({ platform = vector.platform,
				manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
				json_decode = require("json").decode, i18n = require("infra.i18n"), logger = require("logger.shim"),
			}))
			local commands, getters, calls = {}, {}, 0
			for _, command in ipairs(corpus.commands) do
				commands[command.id] = function() calls = calls + 1; return true end
				getters[command.id .. "_ready"] = function() return true end
			end
			local rows = renderer.build(corpus.section, "Selection", nil, nil,
				{ commands = commands, state_getters = getters })
			helpers.assert_eq(#rows, vector.rows)
			helpers.assert_eq(calls, 0)
			for index, row in ipairs(rows) do
				helpers.assert_eq(row.title, require("infra.i18n").get(corpus.commands[index].label_key))
				helpers.assert_eq(row.fn(), true)
			end
			helpers.assert_eq(calls, vector.rows)
		end)
	end

	--- Finds the selection block containing a helper inside the finished tray.
	--- @param rows table Native rendered menu entries.
	--- @param title string Expected first helper caption.
	--- @return table|nil, integer|nil Containing entries and position.
	local function containing(rows, title)
		for index, row in ipairs(rows or {}) do
			if row.title == title then return rows, index end
			local nested, position = containing(row.menu, title)
			if nested then return nested, position end
		end
	end

	helpers.it("preserves the composed helper order and separator (selection-helper-command)", function()
		with_helper_menu(function(_, _, _, rows)
			local i18n = require("infra.i18n")
			local entries, index = containing(rows(), i18n.get(corpus.commands[1].label_key))
			helpers.assert_type(entries, "table")
			helpers.assert_true(index > 2)
			helpers.assert_eq(entries[index - 1].title, "-")
			helpers.assert_eq(entries[index - 2].title, i18n.get("menu.shortcuts.to_titlecase"))
			for offset, command in ipairs(corpus.commands) do
				helpers.assert_eq(entries[index + offset - 1].title, i18n.get(command.label_key))
				local occurrences = 0
				for _, entry in ipairs(entries) do
					if entry.title == i18n.get(command.label_key) then occurrences = occurrences + 1 end
				end
				helpers.assert_eq(occurrences, 1)
			end
		end)
	end)

	helpers.it("follows changed shared helper order and caption (selection-helper-command)", function()
		with_helper_menu(function(_, _, _, rows)
			local root = require("infra.manifest_menu").get_root()
			local original = root[corpus.section]
			helpers.assert_type(original, "table")
			helpers.assert_eq(#original, 3)
			local replacement = {}
			for key, value in pairs(original[3]) do replacement[key] = value end
			replacement.i18n = "common.error_title"
			root[corpus.section] = { replacement, original[2], original[1] }
			local ok, err = pcall(function()
				local i18n = require("infra.i18n")
				local entries, index = containing(rows(), i18n.get("common.error_title"))
				helpers.assert_type(entries, "table")
				helpers.assert_eq(entries[index - 1].title, "-")
				helpers.assert_eq(entries[index + 1].title, i18n.get(corpus.commands[2].label_key))
				helpers.assert_eq(entries[index + 2].title, i18n.get(corpus.commands[1].label_key))
			end)
			root[corpus.section] = original
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("uses actual helper captions in all 21 locales (selection-helper-command)", function()
		-- Each binding captures its locale owner at load time. The full suite may
		-- have replaced that owner; reload the whole chain and restore it together.
		local names = { "locale.core", "infra.locale", "infra.i18n", "infra.manifest_menu", "ui.menu.menu_builder" }
		local previous_modules = {}
		for _, name in ipairs(names) do
			previous_modules[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		local isolated_ok, isolated_err = pcall(function()
			with_helper_menu(function(_, item)
				local paths, json = require("infra.paths"), require("json")
				local order_file = assert(io.open(paths.shared("data/locale_order.json"), "rb"))
				local order = json.decode(order_file:read("*a")).order
				order_file:close()
				helpers.assert_eq(#order, 21)
				local i18n, locale = require("infra.i18n"), require("infra.locale")
				i18n.init()
				local previous = i18n.get_locale()
				local ok, err = pcall(function()
					for _, code in ipairs(order) do
						local source = assert(io.open(paths.shared("data/locales/" .. code .. ".json"), "rb"))
						local labels = json.decode(source:read("*a"))
						source:close()
						locale.set_locale(code)
						for _, command in ipairs(corpus.commands) do
							helpers.assert_type(labels[command.label_key], "string")
							helpers.assert_eq(item(command.label_key).title, labels[command.label_key])
						end
					end
				end)
				locale.set_locale(previous)
				if not ok then error(err, 0) end
			end)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous_modules[name] end
		if not isolated_ok then error(isolated_err, 0) end
	end)
end)


--- Reads the independent physical selection order before testing native providers.
--- @return table Hand-authored boundary, caption and platform expectations.
local function selection_boundary_corpus()
	local path = require("infra.paths").shared("tests/corpus/menus/linux_selection_boundaries.json")
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return assert(require("json").decode(bytes))
end

--- Finds the existing CapsWord-led selection block inside the actual finished tray.
--- @param rows table Native rendered menu entries.
--- @param title string Genuine first selection caption.
--- @return table|nil, integer|nil Containing native entries and first position.
local function selection_boundary_block(rows, title)
	for index, row in ipairs(rows or {}) do
		if row.title == title then return rows, index end
		local nested, position = selection_boundary_block(row.menu, title)
		if nested then return nested, position end
	end
end

helpers.describe("shared selection presentation boundaries", function()
	local corpus = selection_boundary_corpus()
	local fragments = { "selection_case_boundary", "selection_helper_boundary" }

	helpers.it("keeps the complete physical order under an actual configured native owner", function()
		with_helper_menu(function(_, _, effects, rows)
			local native = require("infra.i18n")
			local entries, first = selection_boundary_block(rows(), native.get(corpus.selection_child_order[1].key))
			helpers.assert_type(entries, "table")
			helpers.assert_eq(#corpus.selection_child_order, 9)
			for offset, expected in ipairs(corpus.selection_child_order) do
				local row = entries[first + offset - 1]
				helpers.assert_type(row, "table")
				helpers.assert_eq(row.title, expected.separator and "-" or native.get(expected.key))
				if expected.separator then helpers.assert_nil(row.fn)
				else helpers.assert_type(row.fn, "function") end
			end
			helpers.assert_eq(#effects.chords + effects.reads + #effects.injections, 0,
				"boundary construction does not invoke a selection operation")
		end)
	end)

	helpers.it("keeps both boundaries and the retained action refusal under a real reservation", function()
		with_helper_menu(function(manager, item, effects, rows)
			local held = item("menu.shortcuts.select_word").fn
			local owner = {}
			helpers.assert_eq(manager.acquire_configuration(owner), true)
			local native = require("infra.i18n")
			local entries, first = selection_boundary_block(rows(), native.get(corpus.selection_child_order[1].key))
			helpers.assert_type(entries, "table")
			for offset, expected in ipairs(corpus.selection_child_order) do
				local row = entries[first + offset - 1]
				helpers.assert_eq(row.title, expected.separator and "-" or native.get(expected.key))
				if expected.separator then helpers.assert_nil(row.fn)
				else helpers.assert_eq(row.disabled, true) end
			end
			local refused = held()
			helpers.assert_eq(refused, false)
			helpers.assert_eq(#effects.chords + effects.reads + #effects.injections, 0)
			helpers.assert_eq(manager.release_configuration(owner), true)
			helpers.assert_eq(held(), true)
			helpers.assert_eq(effects.chords, { "ctrl+Right", "ctrl+shift+Left" })
		end)
	end)

	for _, fragment in ipairs(fragments) do
		local section = fragment
		helpers.it("consumes the genuine " .. section .. " and refuses missing or unbound replacements", function()
			with_helper_menu(function(_, _, effects, rows)
				local manifest = require("infra.manifest_menu")
				local root = manifest.get_root()
				local original = root[section]
				helpers.assert_type(original, "table")
				local native = require("infra.i18n")
				local offset = section == fragments[1] and 2 or 6
				local function block()
					return selection_boundary_block(rows(), native.get(corpus.selection_child_order[1].key))
				end
				local ok, detail = xpcall(function()
					root[section] = { { type = "label", id = "selection_boundary_marker",
						i18n = corpus.marker_key, platforms = { "linux" }, unavailable = "hide" } }
					local entries, first = block()
					helpers.assert_type(entries, "table")
					helpers.assert_eq(entries[first + offset - 1].title, native.get(corpus.marker_key))
					helpers.assert_eq(entries[first + offset - 1].disabled, true)
					helpers.assert_nil(entries[first + offset - 1].fn)
					root[section] = nil
					helpers.assert_nil(block(), "a withdrawn boundary refuses its actual selection provider")
					root[section] = { { type = "command", id = "selection_boundary_unbound", i18n = corpus.marker_key } }
					helpers.assert_nil(block(), "an unbound action cannot replace inert presentation")
				end, debug.traceback)
				root[section] = original
				helpers.assert_true(rawequal(root[section], original))
				if not ok then error(detail, 0) end
				local entries, first = block()
				helpers.assert_type(entries, "table")
				helpers.assert_eq(entries[first + offset - 1].title, "-", "repair restores the original boundary")
				helpers.assert_eq(#effects.chords + effects.reads + #effects.injections, 0)
			end)
		end)
	end

	for platform, expected_count in pairs(corpus.platform_rows) do
		local native_platform, count = platform, expected_count
		helpers.it("keeps the truthful " .. native_platform .. " boundary projection without an action", function()
			local renderer = assert(require("menu.renderer").new({ platform = native_platform,
				manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
				json_decode = require("json").decode, i18n = require("infra.i18n"), logger = require("logger.shim"),
			}))
			for _, section in ipairs(fragments) do
				local rows = assert(renderer.template_rows(section, {}, {}, {}))
				helpers.assert_eq(#rows, count)
				for _, row in ipairs(rows) do
					helpers.assert_eq(row.separator, true)
					helpers.assert_nil(row.action)
				end
			end
		end)
	end
end)
