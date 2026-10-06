--- tests/unit/ui/menu/test_base_delay_mutation_transaction.lua

--- ==============================================================================
--- MODULE: Baseline Delay Admission and Publication
--- DESCRIPTION:
--- Exercises the actual baseline menu row, global admission and ordinary
--- preference transaction against private physical configuration bytes.
--- Protected callbacks collect observations; assertions run after they return.
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")
local SOURCE = '# retained baseline header\n[hotstrings]\nexpansion_delay = 0.1\n[hotstrings.delays]\nllm_prediction = 0.3 # independent delay\n[foreign]\nfuture = "kept" # retained\n'
local FOREIGN_SOURCE = SOURCE .. '# independently changed source\n'

local function read_bytes(path)
	local file = assert(io.open(path, "rb"))
	local bytes = file:read("*a")
	file:close()
	return bytes
end

local function find_baseline(rows)
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:find("menu.hotstrings.tooltip_default", 1, true) == 1 then
			return row
		end
		local nested = find_baseline(row.menu)
		if nested then return nested end
	end
end

local function with_fixture(outcome, callback)
	return helpers.with_stub_scope({
		"infra.preferences", "adapters.file_system", "infra.logger", "infra.dialog_util",
		"infra.i18n", "infra.manifest_menu", "infra.notifications", "ui.menu.menu_hotstrings_management",
		"modules.hotstrings.hotstrings_config", "ui.menu.base_delay_transaction",
		"ui.menu.preferences_transaction", "ui.menu.global_actions_transaction", "ui.menu.menu_state",
	}, function()
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local FileSystem = require("adapters.file_system")
		local Transaction = require("ui.menu.preferences_transaction")
		local Global = require("ui.menu.global_actions_transaction")
		local Baseline = require("ui.menu.base_delay_transaction")
		local MenuState = require("ui.menu.menu_state")
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		local renderer = assert(require("menu.renderer").new({ platform = "hs",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = require("adapters.json_codec").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end },
			logger = require("infra.logger"),
		}))
		package.loaded["infra.manifest_menu"] = {
			get_array = renderer.get_array, check_row = renderer.check_row,
			command_row = renderer.command_row, build = renderer.build,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = { resolve = function() return { delay = 0.1 } end }
		return OutputFixture.with_output(function(path)
			local file = assert(io.open(path, "wb")); assert(file:write(SOURCE)); file:close()
			local loaded, status = Preferences.load(path)
			helpers.assert_eq(status, "ok")
			local state = { expansion_delay = loaded.expansion_delay, delays = loaded.delays, trigger_char = "★" }
			local state_delays = state.delays
			local calls = { native = 0, saves = 0, writes = 0, notices = 0, updates = 0, rollbacks = 0, getters = 0 }
			local runtime, paused, terminal = 0.1, false, false
			local inverse_blocked, reentered = false, false
			local inverse_calls = 0
			local observed = {}
			local after_native = nil
			local owner = nil
			local keymap = { DEFAULT_STATE = { expansion_delay = require("infra.manifest_reader").default_for("hotstrings.expansion_delay") }, get_terminator_defs = function() return {} end, set_llm_model = function() return true end }
			function keymap.get_base_delay()
				calls.getters = calls.getters + 1
				if outcome == "getter_throw" then error("injected getter refusal", 0) end
				if outcome == "getter_malformed" then return "0.1" end
				if outcome == "getter_pause" then paused = true end
				return runtime
			end
			function keymap.set_base_delay(value)
				calls.native = calls.native + 1
				if value == 0.1 and inverse_blocked then
					if outcome == "inverse_throw" then error("injected inverse refusal", 0) end
					if outcome == "inverse_nil" then return nil end
					if outcome == "inverse_truthy" then return 2 end
					return false
				end
				if value ~= 0.1 then
					if outcome == "native_false" then return false end
					if outcome == "native_nil" then return nil end
					if outcome == "native_truthy" then return 2 end
					if outcome == "native_truthy_applied" then runtime = value; return 2 end
					if outcome == "native_throw" then error("injected native refusal", 0) end
					if outcome == "native_unapplied" then return true end
					if outcome:find("inverse_", 1, true) == 1 then inverse_blocked = true end
					if outcome == "source_changed" then
						local changed = assert(io.open(path, "wb")); changed:write(FOREIGN_SOURCE); changed:close()
					end
				end
				runtime = value
				if value == 0.1 then
					inverse_calls = inverse_calls + 1
					if outcome == "restore_foreign_after_ack" and inverse_calls == 2 then runtime = 0.9 end
				end
				if after_native and not reentered then reentered = true; after_native() end
				return true
			end
			if outcome == "getter_missing" then keymap.get_base_delay = nil end
			if outcome == "setter_missing" then keymap.set_base_delay = nil end
			local original_setter, original_getter = keymap.set_base_delay, keymap.get_base_delay
			local native_write = FileSystem.write_if_unchanged
			FileSystem.write_if_unchanged = function(...)
				calls.writes = calls.writes + 1
				if outcome == "write_foreign_runtime" then runtime = 0.9; return false end
				if outcome == "restore_foreign_after_ack" then return false end
				if outcome == "write_foreign_binding" then keymap.set_base_delay = function() return false end; return false end
				if outcome == "write_false" or outcome:find("inverse_", 1, true) == 1 then return false, "injected writer refusal" end
				if outcome == "write_nil" then return nil end
				if outcome == "write_truthy" then return 2 end
				if outcome == "write_throw" then error("injected writer exception", 0) end
				return native_write(...)
			end
			local save = Transaction.bind(Preferences, {
				path = path, state = state, initial_state = Transaction.clone(state),
				initial_preferences = Transaction.clone(state), hotfiles = {}, core_modules = {},
				restore_runtime = function(snapshot)
					calls.rollbacks = calls.rollbacks + 1
					if owner and owner.pending() and owner.restore_runtime() ~= true then return false end
					return MenuState.sync_state_to_modules(state, snapshot, false, { keymap = keymap, core_mods = {} }) == true
				end,
			})
			local function accepted() return true end
			local global = assert(Global.create({
				state = state, capture_preferences = function() return Transaction.clone(state) end,
				sync_runtime = accepted, restore_state = accepted,
				settings = { get = function() return nil end, set = accepted, get_keys = function() return {} end },
				file_mover = { capture = accepted, move = accepted, restore = accepted },
				reset_journal = { prepare = accepted, mark_commit = accepted, mark_prepared = accepted, clear = accepted },
				gestures = { get_action = accepted, set_action = accepted, enable_all = accepted, disable_all = accepted },
				shortcuts = { set_shortcut_action = accepted, get_keyboard_action = accepted,
					set_keyboard_action = accepted, get_keyboard_assignments = accepted },
				karabiner = { snapshot_settings = accepted, reset_to_defaults = accepted, restore_settings = accepted },
				request_reload = accepted, terminal_pending = function() return terminal end,
			}))
			local function raw_save() calls.saves = calls.saves + 1; return save() end
			owner = Baseline.new({ state = state, keymap = keymap, admission = global.run_exclusive,
				paused = function() return paused end, save_prefs = raw_save })
			local raw, button, prompt_raises = "750", "OK", false
			package.loaded["infra.dialog_util"] = { text_prompt = function(...)
				observed.prompt = table.pack(...)
				if prompt_raises then error("injected prompt refusal", 0) end
				return button, raw
			end }
			package.loaded["infra.notifications"] = { notify = function() calls.notices = calls.notices + 1 end }
			local context = { state = state, keymap = keymap, paused = false,
				commit_base_delay = owner.set,
				save_prefs = function() return global.run_exclusive("Legacy save", raw_save) end,
				updateMenu = function() calls.updates = calls.updates + 1 end }
			local menus = require("ui.menu.menu_hotstrings_management").build_management(context).menu
			local row = assert(find_baseline(menus))
			callback({ action = row.fn, row = row, state = state, state_delays = state_delays, calls = calls,
				owner = owner, global = global, runtime = function() return runtime end,
				set_paused = function(value) paused = value end, set_terminal = function(value) terminal = value end,
				set_runtime = function(value) runtime = value end,
				set_reentry = function(fn) after_native = fn end,
				release_restore = function() inverse_blocked = false end,
				restore_binding = function() keymap.set_base_delay = original_setter; keymap.get_base_delay = original_getter end,
				set_prompt = function(value, selected, raises) raw = value; button = selected or "OK"; prompt_raises = raises end,
				observed = observed, path = path, read = function() return read_bytes(path) end, preferences = Preferences,
			})
		end)
	end)
end

local function assert_retained(f, expected_source)
	helpers.assert_eq(f.state.expansion_delay, 0.1)
	helpers.assert_eq(f.runtime(), 0.1)
	helpers.assert_eq(f.read(), expected_source or SOURCE)
	helpers.assert_true(rawequal(f.state.delays, f.state_delays))
	helpers.assert_eq(f.state.delays.llm_prediction, 0.3)
	helpers.assert_eq(f.calls.updates, 0)
end

helpers.describe("baseline delay mutation transaction", function()
	helpers.it("refuses a held global owner before changing RAM, runtime or disk", function()
		with_fixture("ok", function(f)
			local observed = nil
			local outer = f.global.run_exclusive("Held independent owner", function() observed = f.action(); return true end)
			helpers.assert_eq(outer, true)
			helpers.assert_eq(observed, false)
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.saves, 0)
			assert_retained(f)
		end)
	end)
	helpers.it("refuses terminal debt before native admission", function()
		with_fixture("ok", function(f)
			f.set_terminal(true)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.writes, 0)
			assert_retained(f)
		end)
	end)
	for _, outcome in ipairs({ "native_false", "native_nil", "native_truthy", "native_truthy_applied", "native_throw", "native_unapplied" }) do
		helpers.it("requires actual baseline commitment on " .. outcome, function()
			with_fixture(outcome, function(f)
				local result = f.action()
				helpers.assert_eq(f.calls.saves, 0, "a refused native value must never reach the real writer")
				helpers.assert_eq(f.calls.writes, 0)
				helpers.assert_eq(f.owner.pending(), false)
				assert_retained(f)
				helpers.assert_eq(result, false)
			end)
		end)
	end
	for _, outcome in ipairs({ "getter_missing", "setter_missing", "getter_malformed", "getter_throw", "getter_pause" }) do
		helpers.it("refuses unproved baseline admission on " .. outcome, function()
			with_fixture(outcome, function(f)
				helpers.assert_eq(f.action(), false)
				helpers.assert_eq(f.calls.native, 0)
				helpers.assert_eq(f.calls.writes, 0)
				assert_retained(f)
			end)
		end)
	end
	helpers.it("rechecks current pause on a retained row", function()
		with_fixture("ok", function(f)
			f.set_paused(true)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.calls.native, 0)
			assert_retained(f)
		end)
	end)
	for _, outcome in ipairs({ "write_false", "write_nil", "write_truthy", "write_throw", "source_changed" }) do
		helpers.it("restores the baseline through ordinary rollback on " .. outcome, function()
			with_fixture(outcome, function(f)
				helpers.assert_eq(f.action(), false)
				helpers.assert_eq(f.calls.rollbacks, 1)
				helpers.assert_eq(f.owner.pending(), false)
				helpers.assert_eq(f.global.is_pending(), false)
				assert_retained(f, outcome == "source_changed" and FOREIGN_SOURCE or SOURCE)
			end)
		end)
	end
	for _, outcome in ipairs({ "inverse_false", "inverse_nil", "inverse_truthy", "inverse_throw" }) do
		helpers.it("retains the exact native inverse until recovery on " .. outcome, function()
			with_fixture(outcome, function(f)
				helpers.assert_eq(f.action(), false)
				helpers.assert_eq(f.state.expansion_delay, 0.1)
				helpers.assert_eq(f.runtime(), 0.75)
				helpers.assert_eq(f.owner.pending(), true)
				helpers.assert_eq(f.global.is_pending(), true)
				local successors = 0
				helpers.assert_eq(f.global.run_exclusive("Foreign successor", function() successors = successors + 1; return true end), false)
				helpers.assert_eq(successors, 0)
				f.release_restore()
				helpers.assert_eq(f.owner.retry_restore(), true)
				helpers.assert_eq(f.owner.pending(), false)
				helpers.assert_eq(f.global.is_pending(), false)
				helpers.assert_eq(f.global.run_exclusive("Foreign successor", function() successors = successors + 1; return true end), true)
				helpers.assert_eq(successors, 1)
				assert_retained(f)
			end)
		end)
	end
	helpers.it("keeps a newly foreign native value while its inverse token is retained", function()
		with_fixture("inverse_false", function(f)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.owner.pending(), true)
			f.set_runtime(0.9)
			local before_retry = f.calls.native
			helpers.assert_eq(f.owner.retry_restore(), false)
			helpers.assert_eq(f.calls.native, before_retry)
			helpers.assert_eq(f.runtime(), 0.9)
			helpers.assert_eq(f.global.is_pending(), true)
			f.release_restore()
			f.set_runtime(0.75)
			helpers.assert_eq(f.owner.retry_restore(), true)
			assert_retained(f)
		end)
	end)
	helpers.it("retries a held source only through the acknowledged canonical source owner", function()
		with_fixture("source_changed", function(f)
			helpers.assert_eq(f.action(), false)
			assert_retained(f, FOREIGN_SOURCE)
			helpers.assert_eq(f.action(), true)
			helpers.assert_eq(f.calls.saves, 2)
			helpers.assert_eq(f.calls.writes, 1, "the first source mismatch must refuse before the atomic writer")
			helpers.assert_eq(f.calls.updates, 1)
			helpers.assert_eq(f.state.expansion_delay, 0.75)
			helpers.assert_eq(f.runtime(), 0.75)
			helpers.assert_true(f.read():find("# independently changed source", 1, true) ~= nil)
			helpers.assert_true(f.read():find('[foreign]\nfuture = "kept" # retained', 1, true) ~= nil)
		end)
	end)
	helpers.it("keeps the inverse retained until the entire ordinary rollback returns", function()
		with_fixture("restore_foreign_after_ack", function(f)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.runtime(), 0.9)
			helpers.assert_eq(f.state.expansion_delay, 0.1)
			helpers.assert_eq(f.owner.pending(), true)
			helpers.assert_eq(f.global.is_pending(), true)
			local before_retry = f.calls.native
			helpers.assert_eq(f.owner.retry_restore(), false)
			helpers.assert_eq(f.calls.native, before_retry)
			helpers.assert_eq(f.read(), SOURCE)
			f.set_runtime(0.75)
			helpers.assert_eq(f.owner.retry_restore(), true)
			assert_retained(f)
		end)
	end)
	for _, outcome in ipairs({ "write_foreign_runtime", "write_foreign_binding" }) do
		helpers.it("preserves a foreign native owner through ordinary rollback on " .. outcome, function()
			with_fixture(outcome, function(f)
				helpers.assert_eq(f.action(), false)
				helpers.assert_eq(f.state.expansion_delay, 0.1)
				helpers.assert_eq(f.runtime(), outcome == "write_foreign_runtime" and 0.9 or 0.75)
				helpers.assert_eq(f.calls.native, 1, "ordinary rollback must not enter the unguarded legacy delay sync")
				helpers.assert_eq(f.owner.pending(), true)
				helpers.assert_eq(f.global.is_pending(), true)
				local before_retry = f.calls.native
				helpers.assert_eq(f.owner.retry_restore(), false)
				helpers.assert_eq(f.calls.native, before_retry)
				helpers.assert_eq(f.read(), SOURCE)
				f.restore_binding()
				f.set_runtime(0.75)
				helpers.assert_eq(f.owner.retry_restore(), true)
				helpers.assert_eq(f.global.is_pending(), false)
				assert_retained(f)
			end)
		end)
	end
	helpers.it("refuses native reentry without publishing a second change", function()
		with_fixture("ok", function(f)
			local nested = nil
			f.set_reentry(function() nested = f.action() end)
			helpers.assert_eq(f.action(), true)
			helpers.assert_eq(nested, false)
			helpers.assert_eq(f.calls.saves, 1)
			helpers.assert_eq(f.calls.writes, 1)
			helpers.assert_eq(f.calls.updates, 1)
			helpers.assert_eq(f.state.expansion_delay, 0.75)
			helpers.assert_eq(f.runtime(), 0.75)
		end)
	end)
	for _, milliseconds in ipairs({ "0", "650", "750" }) do
		helpers.it("publishes and reloads acknowledged " .. milliseconds .. " ms with foreign neighbours intact", function()
			with_fixture("ok", function(f)
				f.set_prompt(milliseconds)
				helpers.assert_eq(f.action(), true)
				local expected = tonumber(milliseconds) / 1000
				helpers.assert_eq(f.state.expansion_delay, expected)
				helpers.assert_eq(f.runtime(), expected)
				helpers.assert_eq(f.calls.saves, 1)
				helpers.assert_eq(f.calls.writes, 1)
				helpers.assert_eq(f.calls.updates, 1)
				helpers.assert_true(f.read():find('[foreign]\nfuture = "kept" # retained', 1, true) ~= nil)
				helpers.assert_true(f.read():find("# retained baseline header", 1, true) ~= nil)
				local loaded, status = f.preferences.load(f.path)
				helpers.assert_eq(status, "ok")
				local reloaded = { expansion_delay = require("infra.manifest_reader").default_for("hotstrings.expansion_delay") }
				f.preferences.merge_saved_data(reloaded, loaded)
				helpers.assert_eq(reloaded.expansion_delay, expected)
				helpers.assert_eq(reloaded.delays.llm_prediction, 0.3)
				if milliseconds == "750" then helpers.assert_nil(loaded.expansion_delay, "the actual canonical default must remain sparse") end
				helpers.assert_eq(f.state.delays.llm_prediction, 0.3)
				helpers.assert_eq(f.observed.prompt[1], "menu.hotstrings.tooltip_default")
				helpers.assert_eq(f.observed.prompt[2], "menu.hotstrings.delay_prompt")
				helpers.assert_eq(f.observed.prompt[3], "100")
				helpers.assert_eq(f.observed.prompt[4], "OK")
				helpers.assert_eq(f.observed.prompt[5], "common.cancel")
			end)
		end)
	end
	for _, raw in ipairs({ "-1", "1.5", "invalid" }) do
		helpers.it("preserves validation without native or disk mutation for " .. raw, function()
			with_fixture("ok", function(f)
				f.set_prompt(raw)
				f.action()
				helpers.assert_eq(f.calls.notices, 1)
				helpers.assert_eq(f.calls.native, 0)
				helpers.assert_eq(f.calls.writes, 0)
				assert_retained(f)
			end)
		end)
	end
	helpers.it("keeps cancellation and prompt errors free of mutations", function()
		with_fixture("ok", function(f)
			f.set_prompt("750", "common.cancel")
			f.action()
			f.set_prompt("750", "OK", true)
			f.action()
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.writes, 0)
			assert_retained(f)
		end)
	end)
end)
