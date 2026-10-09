--- tests/unit/ui/menu/test_preview_mutation_transaction.lua

--- ==============================================================================
--- MODULE: Preview Mutation Admission and Publication
--- DESCRIPTION:
--- Exercises the actual menu callback, global writer fence and ordinary
--- preference transaction against independent physical configuration bytes.
--- Observations collected in caught callbacks are asserted afterward.
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")
local KEY = "preview_colored_tooltips"
local SOURCE = '# retained foreign header\n[hotstrings]\npreview_colored_tooltips = true\n[foreign]\nfuture = "kept" # retained\n'

local function read_bytes(path)
	local file = assert(io.open(path, "rb"))
	local bytes = file:read("*a")
	file:close()
	return bytes
end

local function find_row(rows, label)
	for _, row in ipairs(rows or {}) do
		if row.label == (label or "menu.hotstrings.tooltip_colored") then return row end
		local nested = find_row(row.items or row.submenu, label)
		if nested then return nested end
	end
end

local MAGIC_SOURCE = '# independent retained header\n[hotstrings]\npreview_star_enabled = true\npreview_colored_tooltips = true\n[foreign]\nfuture = "kept" # retained\n'

local PRESENCE_SOURCE = '# independent presence header\n[hotstrings]\npreview_autocorrect_enabled = true\npreview_ai_enabled = true\npreview_star_enabled = true\npreview_colored_tooltips = true\n[foreign]\nfuture = "kept" # retained\n'

local function with_fixture(outcome, callback, translate, declaration_label, selected_key, reverse_presence)
	local owned_key = selected_key or KEY
	local presence = selected_key == "preview_autocorrect_enabled" or selected_key == "preview_ai_enabled"
	local owned_source = presence and PRESENCE_SOURCE or (selected_key and MAGIC_SOURCE or SOURCE)
	local label_key = presence and (selected_key == "preview_ai_enabled" and "menu.hotstrings.tooltip_ai" or "menu.hotstrings.tooltip_autocorrect")
		or (selected_key and "menu.hotstrings.tooltip_magic" or "menu.hotstrings.tooltip_colored")
	local section = presence and "preview_presence_controls" or (selected_key and "preview_magic_control" or "preview_colored_control")
	return helpers.with_stub_scope({
		"infra.preferences", "adapters.file_system", "infra.logger", "infra.dialog_util",
		"infra.i18n", "infra.manifest_menu", "infra.notifications", "ui.menu.menu_hotstrings_management",
		"modules.hotstrings.hotstrings_config",
		"ui.menu.preview_transaction", "ui.menu.preferences_transaction", "ui.menu.global_actions_transaction",
	}, function()
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local FileSystem = require("adapters.file_system")
		local Transaction = require("ui.menu.preferences_transaction")
		local Global = require("ui.menu.global_actions_transaction")
		local Preview = require("ui.menu.preview_transaction")
		translate = translate or function(key) return key end
		package.loaded["infra.i18n"] = { get = translate }
		local renderer = assert(require("menu.renderer").new({ platform = "hs",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = function(raw)
				local decoded = require("adapters.json_codec").decode(raw)
				if declaration_label and decoded[section] then
					for _, item in ipairs(decoded[section]) do
						if item.id == owned_key then item.i18n = declaration_label end
					end
				end
				if reverse_presence and decoded.preview_presence_controls then
					local rows = decoded.preview_presence_controls; rows[1], rows[2] = rows[2], rows[1]
				end
				return decoded
			end, i18n = { get = translate, section = function(key) return key end },
			logger = require("infra.logger"),
		}))
		package.loaded["modules.hotstrings.hotstrings_config"] = { resolve = function() return { delay = 0.1, has_override = false } end }
		package.loaded["infra.manifest_menu"] = { command_row = renderer.command_row, check_row = renderer.check_row, native_child_rows = renderer.native_child_rows, get_root = renderer.get_root, template_rows = renderer.template_rows, get_array = renderer.get_array, build = function(_, _, _, _, _, providers)
			if type(providers.preview_bubbles) == "function" then return providers.preview_bubbles() end
			return {}
		end }
		return OutputFixture.with_output(function(path)
			local file = assert(io.open(path, "wb")); assert(file:write(owned_source)); file:close()
			local loaded, status = Preferences.load(path)
			helpers.assert_eq(status, "ok")
			local state = { preview_colored_tooltips = loaded.preview_colored_tooltips,
				preview_star_enabled = true, preview_autocorrect_enabled = true, preview_ai_enabled = true,
				delays = {}, expansion_delay = 0.1, trigger_char = "★" }
			local calls = { native = 0, saves = 0, writes = 0, notices = 0, updates = 0, rollbacks = 0 }
			local runtime, paused, terminal, blocked_restore = true, false, false, false
			local keymap = { get_terminator_defs = function() return {} end }
			keymap["set_" .. owned_key] = function(value)
				calls.native = calls.native + 1
				if value == false and outcome == "native_false" then return false end
				if value == false and outcome == "native_nil" then return nil end
				if value == false and outcome == "native_throw" then error("injected preview refusal", 0) end
				if value == false and outcome == "native_debt" then runtime = false; blocked_restore = true; return false end
				if value == true and blocked_restore then return false end
				runtime = value
				return true
			end
			if outcome == "native_missing" then keymap["set_" .. owned_key] = nil end
			local native_write = FileSystem.write_if_unchanged
			FileSystem.write_if_unchanged = function(...)
				calls.writes = calls.writes + 1
				if outcome == "write_false" then return false, "injected writer refusal" end
				if outcome == "write_throw" then error("injected writer exception", 0) end
				return native_write(...)
			end
			local save = Transaction.bind(Preferences, {
				path = path, state = state, initial_state = Transaction.clone(state),
				initial_preferences = Transaction.clone(state), hotfiles = {}, core_modules = {},
				restore_runtime = function(snapshot)
					calls.rollbacks = calls.rollbacks + 1
					runtime = snapshot[owned_key]
					return true
				end,
			})
			local function accepted() return true end
			local global = assert(Global.create({
				state = state, capture_preferences = function() return Transaction.clone(state) end,
				sync_runtime = accepted, restore_state = accepted, settings = { get = function() return nil end, set = accepted, get_keys = function() return {} end },
				file_mover = { capture = accepted, move = accepted, restore = accepted },
				reset_journal = { prepare = accepted, mark_commit = accepted, mark_prepared = accepted, clear = accepted },
				gestures = { get_action = accepted, set_action = accepted, enable_all = accepted, disable_all = accepted },
				shortcuts = { set_shortcut_action = accepted, get_keyboard_action = accepted,
					set_keyboard_action = accepted, get_keyboard_assignments = accepted },
				karabiner = { snapshot_settings = accepted, reset_to_defaults = accepted, restore_settings = accepted },
				request_reload = accepted, terminal_pending = function() return terminal end,
			}))
			local function raw_save() calls.saves = calls.saves + 1; return save() end
			local owner = Preview.new({ state = state, keymap = keymap,
				admission = global.run_exclusive, paused = function() return paused end, save_prefs = raw_save })
			local context = { state = state, keymap = keymap, paused = false, delays = {},
				commit_preview = owner.toggle,
				save_prefs = function() return global.run_exclusive("Legacy save", raw_save) end,
				notify_feature = function() calls.notices = calls.notices + 1 end,
				updateMenu = function() calls.updates = calls.updates + 1 end,
			}
			local menus = require("ui.menu.menu_hotstrings_management").build_management(context).menu
			local row = assert(find_row(menus, translate(declaration_label or label_key)))
			callback({ action = row.action, row = row, menus = menus, state = state, calls = calls, owner = owner, global = global,
				path = path, runtime = function() return runtime end,
				set_paused = function(v) paused = v end, set_context_paused = function(v) context.paused = v end, set_terminal = function(v) terminal = v end,
				release_restore = function() blocked_restore = false end, read = function() return read_bytes(path) end,
				preferences = Preferences,
			})
		end)
	end)
end

helpers.describe("preview menu mutation transaction", function()
	helpers.it("refuses a held global owner before changing RAM, native state or disk", function()
		with_fixture("ok", function(f)
			local observation
			local outer = f.global.run_exclusive("Held unrelated scope", function() observation = f.action(); return true end)
			helpers.assert_eq(outer, true)
			helpers.assert_eq(observation, false)
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.saves, 0)
			helpers.assert_eq(f.state[KEY], true)
			helpers.assert_eq(f.runtime(), true)
			helpers.assert_eq(f.read(), SOURCE)
		end)
	end)
	helpers.it("refuses terminal debt before entering the mutation", function()
		with_fixture("ok", function(f)
			f.set_terminal(true)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.saves, 0)
			helpers.assert_eq(f.state[KEY], true)
			helpers.assert_eq(f.read(), SOURCE)
		end)
	end)
	helpers.it("rechecks live pause after the menu was built", function()
		with_fixture("ok", function(f)
			f.set_paused(true)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.writes, 0)
			helpers.assert_eq(f.state[KEY], true)
		end)
	end)
	for _, outcome in ipairs({ "native_false", "native_nil", "native_throw", "native_missing" }) do
		helpers.it("keeps the owned state and source on " .. outcome, function()
			with_fixture(outcome, function(f)
				helpers.assert_eq(f.action(), false)
				helpers.assert_eq(f.calls.saves, 0)
				helpers.assert_eq(f.calls.writes, 0)
				helpers.assert_eq(f.calls.notices, 0)
				helpers.assert_eq(f.calls.updates, 0)
				helpers.assert_eq(f.state[KEY], true)
				helpers.assert_eq(f.runtime(), true)
				helpers.assert_eq(f.read(), SOURCE)
			end)
		end)
	end
	for _, outcome in ipairs({ "write_false", "write_throw" }) do
		helpers.it("uses the ordinary preference owner's rollback on " .. outcome, function()
			with_fixture(outcome, function(f)
				helpers.assert_eq(f.action(), false)
				helpers.assert_eq(f.calls.saves, 1)
				helpers.assert_eq(f.calls.rollbacks, 1)
				helpers.assert_eq(f.calls.notices, 0)
				helpers.assert_eq(f.calls.updates, 0)
				helpers.assert_eq(f.state[KEY], true)
				helpers.assert_eq(f.runtime(), true)
				helpers.assert_eq(f.read(), SOURCE)
				helpers.assert_eq(f.owner.pending(), false)
			end)
		end)
	end
	helpers.it("retains refused runtime compensation and prevents an unrelated successor", function()
		with_fixture("native_debt", function(f)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.owner.pending(), true)
			helpers.assert_eq(f.global.is_pending(), true)
			local called = 0
			helpers.assert_eq(f.global.run_exclusive("Foreign successor", function() called = called + 1; return true end), false)
			helpers.assert_eq(called, 0)
			helpers.assert_eq(f.calls.writes, 0)
			helpers.assert_eq(f.read(), SOURCE)
			f.release_restore()
			helpers.assert_eq(f.owner.retry_restore(), true)
			helpers.assert_eq(f.runtime(), true)
			helpers.assert_eq(f.owner.pending(), false)
			helpers.assert_eq(f.global.is_pending(), false)
		end)
	end)
	helpers.it("publishes only a native and durable ACK, retaining foreign data after reload", function()
		with_fixture("ok", function(f)
			helpers.assert_eq(f.action(), true)
			helpers.assert_eq(f.calls.saves, 1)
			helpers.assert_eq(f.calls.writes, 1)
			helpers.assert_eq(f.calls.notices, 1)
			helpers.assert_eq(f.calls.updates, 1)
			helpers.assert_eq(f.state[KEY], false)
			helpers.assert_eq(f.runtime(), false)
			helpers.assert_true(f.read():find('[foreign]\nfuture = "kept" # retained', 1, true) ~= nil)
			local loaded, status = f.preferences.load(f.path)
			helpers.assert_eq(status, "ok")
			helpers.assert_nil(loaded[KEY], "the existing sparse writer removes neutral false")
			local effective = loaded[KEY]
			if effective == nil then effective = require("infra.manifest_reader").default_for("hotstrings." .. KEY) end
			helpers.assert_eq(effective, false, "the acknowledged choice remains effective after reload")
		end)
	end)
end)


helpers.describe("declared coloured preview checkbox", function()
	helpers.it("rechecks declared readiness on a retained row before entering the native owner", function()
		with_fixture("ok", function(f)
			f.set_context_paused(true)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.writes, 0)
			helpers.assert_eq(f.read(), SOURCE)
		end)
	end)
	helpers.it("takes its provider label from the declaration rather than the native label literal", function()
		with_fixture("ok", function(f)
			helpers.assert_eq(f.row.label, "button.ok")
			helpers.assert_eq(f.row.checked, true)
			helpers.assert_eq(f.action(), true)
			helpers.assert_eq(f.calls.notices, 1)
		end, nil, "button.ok")
	end)
	helpers.it("keeps every existing locale, presence switch and separator in the real provider", function()
		local Paths = require("infra.paths")
		local Codec = require("adapters.json_codec")
		local function read_json(path)
			local file = assert(io.open(path, "rb")); local raw = file:read("*a"); file:close()
			return assert(Codec.decode(raw))
		end
		local corpus = read_json(Paths.shared("tests/corpus/menus/preview_colored_control.json"))
		local count = 0
		for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
			local catalog = read_json(Paths.shared("data/locales/" .. locale .. ".json"))
			local function translate(key) return catalog[key] or key end
			with_fixture("ok", function(f)
				local function group(rows)
					for _, row in ipairs(rows or {}) do
						if row.items and row.items[corpus.colored_position] == f.row then return row.items end
						local found = group(row.items or row.submenu); if found then return found end
					end
				end
				local rows = assert(group(f.menus))
				helpers.assert_eq(#rows, 5)
				for index, label in ipairs(corpus.siblings) do helpers.assert_eq(rows[index].label, translate(label)) end
				helpers.assert_eq(rows[corpus.separator_position].separator, true)
				helpers.assert_eq(f.row.label, translate(corpus.row.i18n))
				helpers.assert_true(f.row.label ~= corpus.row.i18n, "the actual locale supplies the label")
				helpers.assert_eq(f.row.checked, true)
				helpers.assert_eq(f.action(), true)
				helpers.assert_eq(f.calls.writes, 1)
			end, translate)
			count = count + 1
		end
		helpers.assert_eq(count, 21)
	end)
end)


helpers.describe("declared magic preview checkbox", function()
	helpers.it("refuses retained pause before entering the actual preview owner", function()
		with_fixture("ok", function(f)
			f.set_context_paused(true)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.writes, 0)
			helpers.assert_eq(f.state.preview_star_enabled, true)
			helpers.assert_eq(f.read(), MAGIC_SOURCE)
		end, nil, nil, "preview_star_enabled")
	end)
	helpers.it("keeps the real global admission fence for the magic flag", function()
		with_fixture("ok", function(f)
			local observed
			local accepted = f.global.run_exclusive("Held unrelated scope", function() observed = f.action(); return true end)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(observed, false)
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.writes, 0)
			helpers.assert_eq(f.read(), MAGIC_SOURCE)
		end, nil, nil, "preview_star_enabled")
	end)
	for _, mode in ipairs({ "native_false", "native_nil", "native_throw", "write_false", "write_throw" }) do
		helpers.it("keeps magic source and runtime after " .. mode, function()
			with_fixture(mode, function(f)
				helpers.assert_eq(f.action(), false)
				helpers.assert_eq(f.state.preview_star_enabled, true)
				helpers.assert_eq(f.runtime(), true)
				helpers.assert_eq(f.calls.notices, 0)
				helpers.assert_eq(f.calls.updates, 0)
				helpers.assert_eq(f.read(), MAGIC_SOURCE)
			end, nil, nil, "preview_star_enabled")
		end)
	end
	helpers.it("reloads the acknowledged neutral choice without losing independent foreign bytes", function()
		with_fixture("ok", function(f)
			helpers.assert_eq(f.action(), true)
			helpers.assert_eq(f.state.preview_star_enabled, false)
			helpers.assert_eq(f.calls.writes, 1)
			helpers.assert_eq(f.calls.updates, 1)
			local loaded, status = f.preferences.load(f.path)
			helpers.assert_eq(status, "ok")
			helpers.assert_nil(loaded.preview_star_enabled)
			helpers.assert_eq(require("infra.manifest_reader").default_for("hotstrings.preview_star_enabled"), false)
			helpers.assert_true(f.read():find('[foreign]\nfuture = "kept" # retained', 1, true) ~= nil)
		end, nil, nil, "preview_star_enabled")
	end)
end)


helpers.describe("magic preview shared label contract", function()
	helpers.it("uses the edited declaration and preserves all other preview rows", function()
		with_fixture("ok", function(f)
			helpers.assert_eq(f.row.label, "button.ok")
			helpers.assert_eq(f.row.checked, true)
			helpers.assert_eq(f.action(), true)
			helpers.assert_eq(f.calls.writes, 1)
		end, nil, "button.ok", "preview_star_enabled")
	end)
	helpers.it("uses every actual locale without changing the two other presence flags", function()
		local Codec = require("adapters.json_codec")
		local Paths = require("infra.paths")
		local function read_json(path)
			local file = assert(io.open(path, "rb")); local raw = file:read("*a"); file:close()
			return assert(Codec.decode(raw))
		end
		local corpus = read_json(Paths.shared("tests/corpus/menus/preview_magic_control.json"))
		local observed = 0
		for _, code in ipairs(corpus.locales) do
			local catalog = read_json(Paths.shared("data/locales/" .. code .. ".json"))
			local function translate(key) return catalog[key] or key end
			with_fixture("ok", function(f)
				helpers.assert_eq(f.row.label, catalog[corpus.row.i18n])
				helpers.assert_true(f.row.label ~= corpus.row.i18n)
				helpers.assert_eq(f.action(), true)
				helpers.assert_eq(f.state.preview_autocorrect_enabled, true)
				helpers.assert_eq(f.state.preview_ai_enabled, true)
			end, translate, nil, "preview_star_enabled")
			observed = observed + 1
		end
		helpers.assert_eq(observed, 21)
	end)
end)


helpers.describe("declared autocorrection and AI preview presence", function()
	for _, key in ipairs({ "preview_autocorrect_enabled", "preview_ai_enabled" }) do
		helpers.it("fences retained pause for " .. key .. " before native mutation", function()
			with_fixture("ok", function(f)
				f.set_context_paused(true)
				helpers.assert_eq(f.action(), false)
				helpers.assert_eq(f.calls.native, 0)
				helpers.assert_eq(f.calls.writes, 0)
				helpers.assert_eq(f.calls.notices, 0)
				helpers.assert_eq(f.calls.updates, 0)
				helpers.assert_eq(f.state[key], true)
				helpers.assert_eq(f.read(), PRESENCE_SOURCE)
			end, nil, nil, key)
		end)
		for _, outcome in ipairs({ "native_false", "native_nil", "native_throw", "native_missing", "write_false", "write_throw" }) do
			helpers.it("retains native and physical " .. key .. " after " .. outcome, function()
				with_fixture(outcome, function(f)
					helpers.assert_eq(f.action(), false)
					helpers.assert_eq(f.state[key], true)
					helpers.assert_eq(f.runtime(), true)
					helpers.assert_eq(f.read(), PRESENCE_SOURCE)
					helpers.assert_eq(f.calls.notices, 0)
					helpers.assert_eq(f.calls.updates, 0)
				end, nil, nil, key)
			end)
		end
		helpers.it("keeps the actual global scope owner for " .. key, function()
			with_fixture("ok", function(f)
				local observed
				local accepted = f.global.run_exclusive("Held independent owner", function() observed = f.action(); return true end)
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(observed, false)
				helpers.assert_eq(f.calls.native, 0)
				helpers.assert_eq(f.calls.writes, 0)
				helpers.assert_eq(f.read(), PRESENCE_SOURCE)
			end, nil, nil, key)
		end)
		helpers.it("persists and reloads the acknowledged " .. key .. " without changing its neighbour", function()
			with_fixture("ok", function(f)
				helpers.assert_eq(f.action(), true)
				helpers.assert_eq(f.calls.writes, 1)
				helpers.assert_eq(f.calls.notices, 1)
				helpers.assert_eq(f.calls.updates, 1)
				helpers.assert_eq(f.runtime(), false)
				local loaded, status = f.preferences.load(f.path)
				helpers.assert_eq(status, "ok")
				helpers.assert_nil(loaded[key], "the existing sparse writer removes the neutral false leaf")
				helpers.assert_eq(require("infra.manifest_reader").default_for("hotstrings." .. key), false)
				local neighbour = key == "preview_ai_enabled" and "preview_autocorrect_enabled" or "preview_ai_enabled"
				helpers.assert_eq(loaded[neighbour], true)
				helpers.assert_true(f.read():find('future = "kept" # retained', 1, true) ~= nil)
			end, nil, nil, key)
		end)
	end
end)


helpers.describe("ordered presence checkbox locale contract", function()
	local function read_json(path)
		local file = assert(io.open(path, "rb")); local text = file:read("*a"); file:close()
		return assert(require("adapters.json_codec").decode(text))
	end
	helpers.it("uses both real labels and the actual declaration order in all twenty-one locales", function()
		local Paths = require("infra.paths")
		local corpus = read_json(Paths.shared("tests/corpus/menus/preview_presence_controls.json"))
		local observed = 0
		for _, locale in ipairs(corpus.locales) do
			local catalog = read_json(Paths.shared("data/locales/" .. locale .. ".json"))
			local function translate(key) return catalog[key] or key end
			for _, reverse in ipairs({ false, true }) do
				with_fixture("ok", function(f)
					local function preview(rows)
						for _, row in ipairs(rows or {}) do
							if row.items and row.items[2] and (row.items[2] == f.row or row.items[3] == f.row) then return row.items end
							local child = preview(row.items or row.submenu); if child then return child end
						end
					end
					local rows = assert(preview(f.menus))
					helpers.assert_eq(#rows, 5)
					helpers.assert_eq(rows[1].label, translate("menu.hotstrings.tooltip_magic"))
					for index, expected in ipairs(corpus.rows) do
						local position = reverse and (4 - index) or (index + 1)
						helpers.assert_eq(rows[position].label, translate(expected.i18n))
						helpers.assert_true(rows[position].label ~= expected.i18n)
						helpers.assert_eq(rows[position].checked, true)
					end
					helpers.assert_eq(rows[4].separator, true)
					helpers.assert_eq(rows[5].label, translate("menu.hotstrings.tooltip_colored"))
				end, translate, nil, "preview_autocorrect_enabled", reverse)
			end
			observed = observed + 1
		end
		helpers.assert_eq(observed, 21)
	end)
	for _, key in ipairs({ "preview_autocorrect_enabled", "preview_ai_enabled" }) do
		helpers.it("consumes the admitted declaration label for " .. key, function()
			with_fixture("ok", function(f)
				helpers.assert_eq(f.row.label, "button.ok")
				helpers.assert_eq(f.action(), true)
				helpers.assert_eq(f.calls.writes, 1)
			end, nil, "button.ok", key)
		end)
	end
end)
