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

local function find_row(rows)
	for _, row in ipairs(rows or {}) do
		if row.label == "menu.hotstrings.tooltip_colored" then return row end
		local nested = find_row(row.items or row.submenu)
		if nested then return nested end
	end
end

local function with_fixture(outcome, callback)
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
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		local renderer = assert(require("menu.renderer").new({ platform = "hs",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = require("adapters.json_codec").decode, i18n = { get = function(key) return key end, section = function(key) return key end },
			logger = require("infra.logger"),
		}))
		package.loaded["modules.hotstrings.hotstrings_config"] = { resolve = function() return { delay = 0.1, has_override = false } end }
		package.loaded["infra.manifest_menu"] = { command_row = renderer.command_row, build = function(_, _, _, _, _, providers)
			if type(providers.preview_bubbles) == "function" then return providers.preview_bubbles() end
			return {}
		end }
		return OutputFixture.with_output(function(path)
			local file = assert(io.open(path, "wb")); assert(file:write(SOURCE)); file:close()
			local loaded, status = Preferences.load(path)
			helpers.assert_eq(status, "ok")
			local state = { preview_colored_tooltips = loaded.preview_colored_tooltips,
				preview_star_enabled = true, preview_autocorrect_enabled = true, preview_ai_enabled = true,
				delays = {}, expansion_delay = 0.1, trigger_char = "★" }
			local calls = { native = 0, saves = 0, writes = 0, notices = 0, updates = 0, rollbacks = 0 }
			local runtime, paused, terminal, blocked_restore = true, false, false, false
			local keymap = { get_terminator_defs = function() return {} end }
			keymap.set_preview_colored_tooltips = function(value)
				calls.native = calls.native + 1
				if value == false and outcome == "native_false" then return false end
				if value == false and outcome == "native_nil" then return nil end
				if value == false and outcome == "native_throw" then error("injected preview refusal", 0) end
				if value == false and outcome == "native_debt" then runtime = false; blocked_restore = true; return false end
				if value == true and blocked_restore then return false end
				runtime = value
				return true
			end
			if outcome == "native_missing" then keymap.set_preview_colored_tooltips = nil end
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
					runtime = snapshot.preview_colored_tooltips
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
			local row = assert(find_row(require("ui.menu.menu_hotstrings_management").build_management(context).menu))
			callback({ action = row.action, state = state, calls = calls, owner = owner, global = global,
				path = path, runtime = function() return runtime end,
				set_paused = function(v) paused = v end, set_terminal = function(v) terminal = v end,
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
