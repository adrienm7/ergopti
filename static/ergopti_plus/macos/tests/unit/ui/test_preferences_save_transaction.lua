--- tests/unit/ui/test_preferences_save_transaction.lua

--- ==============================================================================
--- MODULE: Preferences Save Transaction Regression
--- DESCRIPTION:
--- Proves that Preferences.save reports exact publication success and that the
--- menu invalidates caches only after that success. Returned/raised adapter
--- failures must remain false and preserve the caller's success-only effects.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_preferences(file_system)
	file_system.read_with_status = file_system.read_with_status or function()
		return "", "ok"
	end
	file_system.write_if_unchanged = file_system.write_if_unchanged or
		function(path, content, _expected_source)
			return file_system.write(path, content)
		end
	package.loaded["adapters.file_system"] = file_system
	package.loaded["infra.preferences"] = nil
	return require("infra.preferences")
end

local function minimal_save(preferences)
	preferences.load("/virtual/config.toml")
	return preferences.save("/virtual/config.toml", {}, {}, {})
end

helpers.describe("Preferences.save: exact atomic publication result", function()
	helpers.it("returns false when the atomic writer returns false", function()
		local calls = 0
		local preferences = load_preferences({
			write = function(path, content)
				calls = calls + 1
				helpers.assert_eq(path, "/virtual/config.toml")
				helpers.assert_type(content, "string")
				return false
			end,
		})
		helpers.assert_eq(minimal_save(preferences), false,
			"a returned write failure must never look like a successful preference save")
		helpers.assert_eq(calls, 1)
	end)

	helpers.it("contains a raised writer failure and returns false", function()
		local preferences = load_preferences({
			write = function() error("disk failure", 0) end,
		})
		local call_ok, committed = pcall(minimal_save, preferences)
		helpers.assert_true(call_ok, "an adapter error must not escape a user action callback")
		helpers.assert_eq(committed, false)
	end)

	helpers.it("returns true only after the writer confirms publication", function()
		local preferences = load_preferences({ write = function() return true end })
		helpers.assert_eq(minimal_save(preferences), true)
	end)

	helpers.it("preserves an external winner and lets the menu roll its live state back", function()
		local path = "/virtual/config.toml"
		local initial = "[features]\npreview_star_enabled = false\n"
		local external = "[features]\npreview_star_enabled = true\n"
		local disk = initial
		local publications = 0
		local preferences = load_preferences({
			read_with_status = function(read_path)
				helpers.assert_eq(read_path, path)
				return disk, "ok"
			end,
			-- Causal old-code seam: the unconditional writer loses B and reports a
			-- false success. The fixed code must never call it.
			write = function(_write_path, content)
				publications = publications + 1
				disk = external
				disk = content
				return true
			end,
			write_if_unchanged = function(write_path, _content, expected_source)
				publications = publications + 1
				helpers.assert_eq(write_path, path)
				helpers.assert_eq(expected_source,
					{ status = "ok", content = initial },
					"the exact boot bytes must cross the menu publication boundary")
				disk = external
				if expected_source.status ~= "ok" or disk ~= expected_source.content then
					return false, "source changed"
				end
				return true
			end,
		})
		local loaded, load_status = preferences.load(path)
		helpers.assert_eq(load_status, "ok")
		helpers.assert_type(loaded, "table")

		local transaction = require("ui.menu.preferences_transaction")
		local state = { preview_star_enabled = false }
		local restores = 0
		local save = transaction.bind(preferences, {
			path = path,
			state = state,
			hotfiles = {},
			core_modules = {},
			initial_state = state,
			initial_preferences = state,
			restore_runtime = function(snapshot)
				restores = restores + 1
				helpers.assert_eq(snapshot.preview_star_enabled, false)
				return true
			end,
		})
		state.preview_star_enabled = true

		helpers.assert_eq(save(), false,
			"a stale full-document menu save must be rejected")
		helpers.assert_eq(publications, 1)
		helpers.assert_eq(disk, external,
			"the external winner must survive byte-for-byte")
		helpers.assert_eq(state.preview_star_enabled, false,
			"the menu must roll the rejected runtime mutation back")
		helpers.assert_eq(restores, 1,
			"runtime restoration must run exactly once after the conflict")
	end)

	helpers.it("adopts a valid external winner so the next explicit save can commit", function()
		local path = "/virtual/config.toml"
		local initial = "[features]\npreview_star_enabled = false\n"
		local external = "[features]\npreview_star_enabled = true\n"
		local disk = initial
		local attempts = 0
		local expected_sources = {}
		local preferences = load_preferences({
			read_with_status = function(read_path)
				helpers.assert_eq(read_path, path)
				return disk, "ok"
			end,
			write_if_unchanged = function(write_path, content, expected_source)
				helpers.assert_eq(write_path, path)
				attempts = attempts + 1
				expected_sources[attempts] = expected_source
				if attempts == 1 then disk = external end
				if expected_source.status ~= "ok" or disk ~= expected_source.content then
					return false, "source changed"
				end
				disk = content
				return true
			end,
		})
		local loaded, load_status = preferences.load(path)
		helpers.assert_eq(load_status, "ok")
		helpers.assert_type(loaded, "table")
		local transaction = require("ui.menu.preferences_transaction")
		local state = { preview_star_enabled = false }
		local restores = 0
		local save = transaction.bind(preferences, {
			path = path,
			state = state,
			hotfiles = {},
			core_modules = {},
			initial_state = state,
			initial_preferences = state,
			restore_runtime = function(snapshot)
				restores = restores + 1
				helpers.assert_eq(snapshot.preview_star_enabled, false)
				return true
			end,
		})

		state.preview_star_enabled = true
		helpers.assert_eq(save(), false,
			"the stale first candidate must not overwrite an external winner")
		helpers.assert_eq(disk, external,
			"the first conflict must preserve the external bytes exactly")
		helpers.assert_eq(state.preview_star_enabled, false,
			"the rejected menu mutation must roll back before a retry")
		helpers.assert_eq(restores, 1)

		state.preview_star_enabled = true
		helpers.assert_eq(save(), true,
			"a second explicit save must use the adopted external source identity")
		helpers.assert_eq(attempts, 2)
		helpers.assert_eq(expected_sources[1], { status = "ok", content = initial })
		helpers.assert_eq(expected_sources[2], { status = "ok", content = external },
			"the retry must compare against the exact valid external winner")
		helpers.assert_true(disk ~= external,
			"the second explicit user intent must publish its encoded preferences")
	end)

	helpers.it("never adopts malformed external preferences as a writable baseline", function()
		local path = "/virtual/config.toml"
		local initial = "[features]\npreview_star_enabled = false\n"
		local malformed = "[features\npreview_star_enabled = true\n"
		local disk = initial
		local attempts = 0
		local expected_sources = {}
		local preferences = load_preferences({
			read_with_status = function() return disk, "ok" end,
			write_if_unchanged = function(_, _, expected_source)
				attempts = attempts + 1
				expected_sources[attempts] = expected_source
				if attempts == 1 then disk = malformed end
				return false, "source changed"
			end,
		})
		preferences.load(path)

		helpers.assert_eq(preferences.save(path, {}, {}, {}), false)
		helpers.assert_eq(preferences.save(path, {}, {}, {}), false)
		helpers.assert_eq(disk, malformed)
		helpers.assert_eq(expected_sources[1], { status = "ok", content = initial })
		helpers.assert_eq(attempts, 1, "a stale or malformed source must stop before publication")
		disk = initial
		helpers.assert_eq(preferences.save(path, {}, {}, {}), false)
		helpers.assert_eq(expected_sources[2], { status = "ok", content = initial },
			"invalid external bytes must never become an overwrite authorization")
	end)

end)

helpers.describe("menu preference side effects are success-gated", function()
	local transaction = require("ui.menu.preferences_transaction")

	helpers.it("leaves every cache untouched on false, nil, or raise", function()
		for _, save in ipairs({
			function() return false end,
			function() return nil end,
			function() error("save raised", 0) end,
		}) do
			local effects = 0
			local committed = transaction.commit(
				{ save = save },
				"/virtual/config.toml",
				{},
				{},
				{},
				{ invalidate_cache = function() effects = effects + 1 end },
				{ invalidate_cache = function() effects = effects + 1 end },
				function() effects = effects + 1 end
			)
			helpers.assert_eq(committed, false)
			helpers.assert_eq(effects, 0,
				"cache invalidation and dirty publication must require exact save success")
		end
	end)

	helpers.it("runs each success-only effect once after a confirmed save", function()
		local effects = 0
		local committed = transaction.commit(
			{ save = function() return true end },
			"/virtual/config.toml",
			{},
			{},
			{},
			{ invalidate_cache = function() effects = effects + 1 end },
			{ invalidate_cache = function() effects = effects + 1 end },
			function() effects = effects + 1 end
		)
		helpers.assert_eq(committed, true)
		helpers.assert_eq(effects, 3)
	end)
end)

helpers.describe("menu preferences: first-click rollback", function()
	helpers.it("returns false only when a synchronous runtime setter raises", function()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...)
			errors[#errors + 1] = string.format(fmt, ...)
		end
		package.loaded["infra.logger"] = logger
		local MenuState = helpers.load_with_stubs("ui.menu.menu_state")

		local function sync_with(setter)
			return MenuState.sync_state_to_modules({
				hotstrings = {},
				keymap = false,
				preview_star_enabled = false,
				keylogger_enabled = false,
			}, {}, false, {
				keymap = {
					set_llm_model = function() return true end,
					set_preview_star_enabled = setter,
				},
				hotstring_editor = {},
				core_mods = {},
				apply_metrics_shortcut = function() return true end,
				apply_apps_time_shortcut = function() return true end,
				save_prefs = function() return true end,
			})
		end

		local nil_result = sync_with(function() end)
		local throw_result = sync_with(function() error("runtime setter failure", 0) end)
		package.loaded["infra.logger"] = nil
		package.loaded["ui.menu.menu_state"] = nil

		helpers.assert_eq(nil_result, true,
			"a successful setter's nil return must not be confused with failure")
		helpers.assert_eq(throw_result, false,
			"a contained setter exception must make runtime synchronization fail")
		helpers.assert_eq(#errors, 1, "the raised setter must be reported once, as an ERROR")
		helpers.assert_contains(errors[1], "feature 'hotstrings'")
		helpers.assert_contains(errors[1], "keymap.set_preview_star_enabled")
		helpers.assert_contains(errors[1], "runtime setter failure")
	end)

	helpers.it("does not report rollback success when runtime restoration raises", function()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...)
			errors[#errors + 1] = string.format(fmt, ...)
		end
		package.loaded["infra.logger"] = logger
		local MenuState = helpers.load_with_stubs("ui.menu.menu_state")
		local transaction = require("ui.menu.preferences_transaction")
		local state = {
			hotstrings = {},
			keymap = false,
			preview_star_enabled = false,
			keylogger_enabled = false,
		}
		local rollback_successes = 0
		local save = transaction.bind({ save = function() return false end }, {
			path = "/virtual/config.toml",
			state = state,
			hotfiles = {},
			core_modules = {},
			initial_state = state,
			initial_preferences = {},
			restore_runtime = function(saved)
				return MenuState.sync_state_to_modules(state, saved, false, {
					keymap = {
						set_llm_model = function() return true end,
						set_preview_star_enabled = function()
							error("rollback setter failure", 0)
						end,
					},
					hotstring_editor = {},
					core_mods = {},
					apply_metrics_shortcut = function() return true end,
					apply_apps_time_shortcut = function() return true end,
					save_prefs = function() return true end,
				})
			end,
			on_rollback = function() rollback_successes = rollback_successes + 1 end,
		})

		state.preview_star_enabled = true
		local committed = save()
		package.loaded["infra.logger"] = nil
		package.loaded["ui.menu.menu_state"] = nil
		package.loaded["ui.menu.preferences_transaction"] = nil

		helpers.assert_eq(committed, false)
		helpers.assert_eq(state.preview_star_enabled, false)
		helpers.assert_eq(rollback_successes, 0,
			"on_rollback must run only after every runtime setter completes")
		helpers.assert_eq(#errors, 3)
		helpers.assert_contains(errors[2], "keymap.set_preview_star_enabled")
		helpers.assert_contains(errors[2], "rollback setter failure")
		helpers.assert_contains(errors[3], "Preference rollback did not commit: false.")
	end)

	helpers.it("preserves retained nested table identities during rollback", function()
		local transaction = require("ui.menu.preferences_transaction")
		local state = { nested = { enabled = true, values = { 1, 2 } } }
		local nested_ref = state.nested
		local values_ref = state.nested.values
		state.nested.enabled = false
		state.nested.values[1] = 99
		state.nested.values[3] = 3
		helpers.assert_eq(transaction.restore_table(state, {
			nested = { enabled = true, values = { 1, 2 } },
		}), true)
		helpers.assert_true(state.nested == nested_ref)
		helpers.assert_true(state.nested.values == values_ref)
		helpers.assert_eq(state.nested, { enabled = true, values = { 1, 2 } })
	end)

	helpers.it("restores the keylogger cipher posture without starting migration", function()
		helpers.load_with_stubs("infra.logger")
		local cipher_values = {}
		package.loaded["modules.keylogger.text_cipher"] = {
			set_enabled = function(value) cipher_values[#cipher_values + 1] = value end,
		}
		package.loaded["ui.menu.menu_state"] = nil
		local MenuState = require("ui.menu.menu_state")
		local result = MenuState.sync_state_to_modules({
			hotstrings = {},
			keylogger_encrypt = false,
			keylogger_enabled = false,
		}, {}, false, {
			keymap = { set_llm_model = function() return true end },
			hotstring_editor = {},
			core_mods = {},
			apply_metrics_shortcut = function() return true end,
			apply_apps_time_shortcut = function() return true end,
			save_prefs = function() return true end,
		})
		helpers.assert_eq(result, true)
		helpers.assert_eq(cipher_values, { false },
			"rollback must restore TextCipher's live posture from the acknowledged state")
	end)

	helpers.it("restores gesture registries owned outside the flat state", function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["ui.menu.menu_state"] = nil
		local MenuState = require("ui.menu.menu_state")
		local observed = {}
		local result = MenuState.sync_state_to_modules({ hotstrings = {}, gestures = true }, {
			gesture_modes = { swipe_left = "continuous" },
			gesture_sensitivities = { swipe_left = 1.25 },
		}, false, {
			keymap = { set_llm_model = function() return true end },
			gestures = {
				enable_all = function() return true end,
				is_enabled = function() return true end,
				set_mode = function(_, value) observed.mode = value end,
				set_sensitivity = function(_, value) observed.sensitivity = value end,
			},
			hotstring_editor = {},
			core_mods = {},
			apply_metrics_shortcut = function() return true end,
			apply_apps_time_shortcut = function() return true end,
			save_prefs = function() return true end,
		})
		helpers.assert_eq(result, true)
		helpers.assert_eq(observed, {
			mode = "continuous",
			sensitivity = 1.25,
		})
	end)
end)






-- ==========================================
-- ==========================================
-- ======= 2/ Current Preference View =======
-- ==========================================
-- ==========================================

helpers.describe("Preferences current canonical view", function()
	helpers.it("observes foreign master and display settings without adopting save authority (streaming-current-view)", function()
		local path = "/virtual/config.toml"
		local initial = "[llm]\nenabled = true\n[llm.models]\nselected = \"ollama\"\n"
		local external = "[llm]\nenabled = false\n[llm.models]\nselected = \"api\"\n[llm.display]\nstreaming = true\nstreaming_multi = false\n[future]\nvalue = 42\n"
		local disk, reads = initial, {}
		local preferences = load_preferences({
			read_with_status = function(read_path) reads[#reads + 1] = read_path; return disk, "ok" end,
			write = function() return false end,
		})
		preferences.load(path)
		local baseline = preferences.source_snapshot(path)
		disk = external
		local view, source = preferences.current_view(path)
		helpers.assert_eq(view.llm_enabled, false)
		helpers.assert_eq(view.llm_backend, "api")
		helpers.assert_eq(view.llm_streaming, true)
		helpers.assert_eq(view.llm_streaming_multi, false)
		helpers.assert_eq(source, {status = "ok", content = external})
		helpers.assert_true(preferences.source_matches(source, {status = "ok", content = external}))
		helpers.assert_eq(preferences.source_matches(baseline, source), false)
		helpers.assert_eq(preferences.source_matches(nil, source), false)
		helpers.assert_eq(preferences.source_matches({status = "unreadable"}, {status = "unreadable"}), false)
		helpers.assert_eq(preferences.source_matches({status = "ok"}, {status = "ok"}), false)
		helpers.assert_eq(preferences.source_matches({status = "absent"}, {status = "absent"}), true)
		helpers.assert_eq(preferences.source_matches({status = "absent"}, source), false)
		helpers.assert_eq(preferences.source_snapshot(path), baseline, "a current read is not overwrite authority")
		view.llm_enabled = true
		source.content = "replaced by caller"
		local again, second = preferences.current_view(path)
		helpers.assert_eq(again.llm_enabled, false, "successive current views are detached")
		helpers.assert_eq(second.content, external)
		helpers.assert_eq(preferences.source_snapshot(path), baseline)
		for _, read_path in ipairs(reads) do helpers.assert_eq(read_path, path) end
		helpers.assert_eq(disk, external)
	end)

	helpers.it("keeps the original compare-and-swap source after observing a foreign image (streaming-current-view)", function()
		local path = "/virtual/config.toml"
		local initial = "[llm]\nenabled = true\n"
		local external = "[llm]\nenabled = false\n[future]\nvalue = 42\n"
		local disk, observed, writes = initial, nil, 0
		local preferences = load_preferences({
			read_with_status = function() return disk, "ok" end,
			write = function() return false end,
			write_if_unchanged = function(_, content, expected)
				writes = writes + 1; observed = expected
				if expected.content ~= disk then return false, "source changed" end
				disk = content; return true
			end,
		})
		preferences.load(path)
		disk = external
		local view = preferences.current_view(path)
		helpers.assert_eq(view.llm_enabled, false)
		helpers.assert_eq(preferences.save(path, {llm_enabled = true}, {}, {}), false)
		helpers.assert_eq(observed, nil, "the real batch owner refuses changed bytes before reaching its adapter")
		helpers.assert_eq(writes, 0)
		helpers.assert_eq(disk, external, "the read-only view never bypasses the stale-save refusal")
		helpers.assert_eq(preferences.source_snapshot(path), {status = "ok", content = external}, "only the existing actual refusal may adopt its valid winner")
	end)

	helpers.it("distinguishes proven absence from unreadable malformed and raised reads (streaming-current-view)", function()
		for _, mode in ipairs({"absent", "unreadable", "malformed", "raise"}) do
			local status = "ok"
			local preferences = load_preferences({
				read_with_status = function()
					if mode == "raise" then error("read refused", 0) end
					if mode == "absent" then return nil, "absent" end
					if mode == "unreadable" then return nil, "unreadable" end
					return "[llm", status
				end,
				write = function() return false end,
			})
			local ok, view, source = pcall(preferences.current_view, "/virtual/config.toml")
			helpers.assert_true(ok, "a current-view read failure is a refused view, not a thrown UI action")
			if mode == "absent" then
				helpers.assert_eq(view, {})
				helpers.assert_eq(source, {status = "absent"})
			else
				helpers.assert_eq(view, nil)
				helpers.assert_eq(source, nil)
			end
			helpers.assert_eq(preferences.source_snapshot("/virtual/config.toml"), nil)
		end
	end)

	helpers.it("refuses invalid owned leaves without promoting them to absent defaults (streaming-current-view)", function()
		local path = "/virtual/config.toml"
		local initial = "[llm]\nenabled = true\n"
		local disk = initial
		local preferences = load_preferences({
			read_with_status = function() return disk, "ok" end,
			write = function() return false end,
		})
		preferences.load(path)
		local baseline = preferences.source_snapshot(path)
		for _, invalid in ipairs({"[llm]\nenabled = \"maybe\"\n", "[llm.display]\nstreaming = 1\n", "[llm]\nagent_mode = \"future-unknown\"\n", "[llm.models]\nselected = 123\n", "llm = 123\n", "[llm]\nmodels = false\n"}) do
			disk = invalid
			local view, source = preferences.current_view(path)
			helpers.assert_eq(view, nil)
			helpers.assert_eq(source, nil)
			helpers.assert_eq(preferences.source_snapshot(path), baseline)
			helpers.assert_eq(disk, invalid)
		end
	end)
	helpers.it("issues detached publication evidence only after exact owned save acknowledgements (streaming-current-view)", function()
		local path = "/virtual/config.toml"
		local disk = "[llm]\nenabled = true\n"
		local outcome = "ok"
		local preferences = load_preferences({
			read_with_status = function() return disk, "ok" end,
			write_if_unchanged = function(_, content)
				if outcome == "throw" then error("write refused", 0) end
				if outcome == "false" then return false end
				if outcome == "nil" then return nil end
				disk = content
				return true
			end,
		})
		helpers.assert_eq(preferences.publication_receipt(path), {id = 0})
		preferences.load(path)
		helpers.assert_eq(preferences.publication_receipt(path), {id = 0})
		helpers.assert_eq(preferences.save(path, {llm_enabled = true}, {}, {}), true)
		local first = preferences.publication_receipt(path)
		helpers.assert_eq(first, {id = 1, source = {status = "ok", content = disk}})
		first.id = 999
		first.source.content = "changed by caller"
		local acknowledged = preferences.publication_receipt(path)
		helpers.assert_eq(acknowledged.id, 1)
		helpers.assert_eq(acknowledged.source.content, disk)
		for _, refusal in ipairs({"false", "nil", "throw"}) do
			outcome = refusal
			helpers.assert_eq(preferences.save(path, {llm_enabled = true}, {}, {}), false)
			helpers.assert_eq(preferences.publication_receipt(path), acknowledged)
		end
		disk = "[llm]\nenabled = false\n[future]\nvalue = 42\n"
		helpers.assert_eq(preferences.save(path, {llm_enabled = true}, {}, {}), false)
		helpers.assert_eq(preferences.source_snapshot(path).content, disk)
		helpers.assert_eq(preferences.publication_receipt(path), acknowledged, "adopting a foreign winner is not an owned acknowledgement")
		preferences.load(path)
		helpers.assert_eq(preferences.publication_receipt(path), acknowledged)
		outcome = "ok"
		helpers.assert_eq(preferences.save(path, {llm_enabled = true}, {}, {}), true)
		helpers.assert_eq(preferences.publication_receipt(path), {id = 2, source = {status = "ok", content = disk}})
		helpers.assert_eq(preferences.publication_receipt("/virtual/other.toml"), {id = 0})
	end)
end)


helpers.describe("Number-row native-only preferences", function()
	helpers.it("keeps native absence sparse through the existing preference owner", function()
		local path, disk, written = "/virtual/number-row-native.toml", nil, 0
		local preferences = load_preferences({
			read_with_status = function() return disk, disk and "ok" or "absent" end,
			write_if_unchanged = function(_, content, expected)
				if expected.status ~= "absent" then return false end
				disk, written = content, written + 1
				return true
			end,
		})
		local saved, status = preferences.load(path)
		helpers.assert_eq(status, "absent")
		helpers.assert_eq(preferences.flat_key_for("layout.direct_access_digits"), "layout_number_row_mode")
		helpers.assert_eq(require("infra.manifest_reader").default_for("layout.direct_access_digits"), "native")
		helpers.assert_eq(saved.layout_number_row_mode, nil)
		helpers.assert_eq(preferences.save(path, { layout_number_row_mode = "native" }, {}, {}), true)
		helpers.assert_eq(written, 1)
		helpers.assert_eq(disk:find("direct_access_digits", 1, true), nil,
			"an unrelated ordinary save must not flush native absence")
	end)
	helpers.it("preserves malformed and future personal values through ordinary saves", function()
		for _, value in ipairs({ '"future-mode"', 'true', '1', '"true"', '{ future = 7 }' }) do
			local path = "/virtual/number-row-unknown.toml"
			local before = '[layout]\ndirect_access_digits = ' .. value .. ' # retained personal spelling\nfuture = { keep = 8 }\n'
			local disk = before
			local preferences = load_preferences({
				read_with_status = function() return disk, "ok" end,
				write_if_unchanged = function(_, content, expected)
					if expected.content ~= disk then return false end
					disk = content
					return true
				end,
			})
			local saved = preferences.load(path)
			helpers.assert_eq(saved.layout_number_row_mode, nil)
			helpers.assert_eq(preferences.save(path, { layout_number_row_mode = "native" }, {}, {}), true)
			helpers.assert_eq(disk:sub(1, #before), before, "native default never acquires outdated personal intent")
		end
	end)
end)

-- Do not leak the final FileSystem double into later test modules in the same
-- Lua process; those modules intentionally exercise the real atomic adapter.
package.loaded["adapters.file_system"] = nil
package.loaded["infra.preferences"] = nil

return true
