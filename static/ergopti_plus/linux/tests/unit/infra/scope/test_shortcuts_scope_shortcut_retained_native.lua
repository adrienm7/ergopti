--- tests/unit/infra/scope/test_shortcuts_scope_shortcut_retained_native.lua

--- Exercises the actual shortcut readers, dispatchers and parameter owner.

package.loaded["tests.support.infra.scope.shortcuts_scope_fixture"] = nil
local Fixture = require("tests.support.infra.scope.shortcuts_scope_fixture")
local helpers, Sandbox, Codec, Manifest, SOURCE, with_scope, with_collision_scope, COLLISION_BASE, NO_TAP_HOLDS, with_magic_collision_scope, with_magic_publication_scope, MAGIC_COLLISION_SOURCE =
	Fixture.helpers, Fixture.Sandbox, Fixture.Codec, Fixture.Manifest, Fixture.SOURCE, Fixture.with_scope, Fixture.with_collision_scope, Fixture.COLLISION_BASE, Fixture.NO_TAP_HOLDS, Fixture.with_magic_collision_scope, Fixture.with_magic_publication_scope, Fixture.MAGIC_COLLISION_SOURCE




helpers.describe("shortcut retained native release debt", function()
	local expected = {
		shortcuts = { enabled = true, wrap_text_if_selected = true, chatgpt_url = "https://old.example", unknown = "keep",
			keyboard = { ctrl_j = "open_url", ctrl_k = "enter", ctrl_p = "script_reload", foreign_slot = "keep" },
			tap_keys = { number_row_left = "send_text", unknown = "keep" } },
		gesture_parameters = { keyboard__ctrl_j__open_url = "https://old.example", tap_key__number_row_left__send_text = "typed",
			tap_3__open_url = "https://gesture.example", tap_hold__caps_lock__open_url = "https://hold.example", unknown = "keep" },
		linux = { action_parameters = { keyboard__ctrl_k__open_url = "https://legacy.example", unknown = "keep" } },
		gestures = { enabled = false, tap_3 = "enter" }, metrics = { enabled = true }, llm = { enabled = true }, other = { value = 42 },
	}
	local receipts = {
		{ name = "nil", reply = function() return nil end },
		{ name = "false", reply = function() return false end },
		{ name = "truthy string", reply = function() return "true" end },
		{ name = "wrong object", reply = function() return {} end },
		{ name = "exception", reply = function() error("native release refused") end },
	}
	--- Wraps real lease owners; an injected refusal never releases their token.
	local function controlled_scope(owners, controls, path, selected, refusal)
		local blocked, live, acknowledgements = true, {}, {}
		local faults = {}
		for _, entry in ipairs({ { "manager", "acquire_configuration", "release_configuration" },
			{ "gestures", "acquire_parameter_configuration", "release_parameter_configuration" },
			{ "url", "acquire_configuration", "release_configuration" },
			{ "keyboard", "acquire_configuration", "release_configuration" },
			{ "taps", "acquire_configuration", "release_configuration" },
			{ "chords", "acquire_configuration", "release_configuration" } }) do
			local name, native = entry[1], owners[entry[1]]
			local acquire, release = native[entry[2]], native[entry[3]]
			native[entry[2]] = function(token)
				if faults.reacquire == name and acknowledgements[name] then return false end
				local accepted = acquire(token)
				if accepted == true then
					helpers.assert_eq(live[name], nil, "a live acknowledged lease is never reacquired")
					live[name] = token
				end
				return accepted
			end
			native[entry[3]] = function(token)
				helpers.assert_eq(live[name], token, "a released lease is never released without a fresh acquisition")
				if name == selected and blocked then return refusal() end
				local accepted = release(token)
				if accepted == true then
					live[name] = nil
					acknowledgements[name] = (acknowledgements[name] or 0) + 1
				end
				return accepted
			end
		end
		local scope = require("infra.shortcuts_scope").new({ path = path, backup_path = path .. ".release-debt-backup",
			files = controls.files, is_paused = function() return controls.paused end })
		return scope, function(value) blocked = value == true end, live, acknowledgements, faults
	end

	for _, mode in ipairs({ "clear", "recommended" }) do
		for _, receipt in ipairs(receipts) do
			helpers.it("retains " .. mode .. " runtime/file compensation on " .. receipt.name .. " native release", function()
				with_scope(function(_, owners, controls, path)
					local scope, unblock, live = controlled_scope(owners, controls, path, "manager", receipt.reply)
					local called, committed = pcall(scope.apply, mode)
					helpers.assert_eq(called, true, "native refusal settles rather than escaping")
					helpers.assert_eq(committed, false)
					helpers.assert_eq(scope.pending(), true)
					helpers.assert_eq(scope.release(), false)
					helpers.assert_eq(scope.apply("clear"), false, "another request cannot replace release debt")
					unblock()
					helpers.assert_eq(scope.retry_restore(), true)
					helpers.assert_eq(scope.pending(), false)
					helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
					helpers.assert_eq(owners.manager.is_enabled(), true)
					helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "open_url")
					helpers.assert_eq(owners.taps.get_action("number_row_left"), "send_text")
					helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__ctrl_j", "open_url"), "https://old.example")
					helpers.assert_eq(next(live), nil)
				end)
			end)
		end
	end

	helpers.it("stops global progression and retries the exact shortcut inverse before earlier categories", function()
		with_scope(function(_, owners, controls, path)
			local scope, unblock = controlled_scope(owners, controls, path, "keyboard", function() return false end)
			local trace = {}
			local before = { apply = function(_, done) trace[#trace + 1] = "before.apply"; done(true) end,
				revert = function(done) trace[#trace + 1] = "before.revert"; done(true) end,
				release = function() trace[#trace + 1] = "before.release" end,
				pending = function() return false end, retry_restore = function(done) done(true) end }
			local after = { apply = function(_, done) trace[#trace + 1] = "after.apply"; done(true) end,
				revert = function(done) done(true) end, release = function() end,
				pending = function() return false end, retry_restore = function(done) done(true) end }
			local actual = require("config_scope_participant").synchronous({ apply = scope.apply, owner = function() return scope end })
			local logger = {}; for _, level in ipairs({ "start", "success", "warn", "info", "error" }) do logger[level] = function() end end
			local global = require("config_scope_composition").new({ manifest = Manifest, scope = "global", logger = logger,
				participants = function() return { tap_holds = before, shortcuts = actual, llm = after } end })
			local verdict, report
			global.apply("recommended", function(ok, detail) verdict, report = ok, detail end)
			helpers.assert_eq(verdict, false)
			helpers.assert_eq(report.failed, "shortcuts")
			helpers.assert_eq(report.reverted, false)
			helpers.assert_eq(global.pending(), true)
			helpers.assert_eq(trace, { "before.apply" }, "later scopes and earlier inverses wait for exact owned debt")
			unblock()
			local restored
			global.retry_restore(function(ok) restored = ok end)
			helpers.assert_eq(restored, true)
			helpers.assert_eq(trace, { "before.apply", "before.revert" })
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
			helpers.assert_eq(global.pending(), false)
		end)
	end)

	helpers.it("preserves a source successor while the exact inverse and all native claims remain pending", function()
		with_scope(function(_, owners, controls, path)
			local scope, unblock, live = controlled_scope(owners, controls, path, "keyboard", function() return false end)
			local publish, writes, candidate = controls.files.write_if_unchanged, 0, nil
			local foreign = '[foreign]\nowner = "external"\nvalue = 999\n'
			controls.files.write_if_unchanged = function(target, content, expected_source)
				if target == path then
					writes = writes + 1
					if writes == 2 then Sandbox.write_bytes(path, foreign) end
				end
				local ok, detail = publish(target, content, expected_source)
				if target == path and writes == 1 and ok == true then candidate = Sandbox.read_bytes(path) end
				return ok, detail
			end
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			helpers.assert_eq(scope.pending(), true)
			helpers.assert_eq(owners.keyboard.set_action("ctrl_j", "none"), false)
			unblock()
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			helpers.assert_true(next(live) ~= nil)
			local restored_runtime = controls.runtime_calls
			Sandbox.write_bytes(path, candidate) -- Explicit fixture repair under the retained source fence.
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(controls.runtime_calls, restored_runtime, "the acknowledged runtime inverse is not repeated")
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
			helpers.assert_eq(next(live), nil)
		end)
	end)

	helpers.it("retains a committed candidate until released dispatch claims can be reacquired for its inverse", function()
		with_scope(function(_, owners, controls, path)
			local scope, unblock, live, _, faults = controlled_scope(owners, controls, path, "keyboard", function() return false end)
			faults.reacquire = "taps"
			helpers.assert_eq(scope.apply("clear"), false)
			local candidate = Sandbox.read_bytes(path)
			helpers.assert_true(candidate ~= SOURCE)
			helpers.assert_eq(scope.pending(), true)
			unblock()
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), candidate)
			helpers.assert_true(next(live) ~= nil)
			faults.reacquire = nil
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
			helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "open_url")
			helpers.assert_eq(next(live), nil)
		end)
	end)

	helpers.it("settles release-only debt after an acknowledged explicit inverse without replaying it", function()
		with_scope(function(_, _, controls, path)
			local owners = { manager = require("modules.shortcuts.manager"), keyboard = require("modules.shortcuts.keyboard_shortcuts"),
				taps = require("modules.shortcuts.tap_keys"), chords = require("modules.shortcuts.script_chords"),
				url = require("modules.shortcuts.chatgpt"), gestures = require("modules.gestures.manager") }
			local scope, block, live = controlled_scope(owners, controls, path, "keyboard", function() return false end)
			block(false)
			helpers.assert_eq(scope.apply("recommended"), true)
			block(true)
			helpers.assert_eq(scope.revert(), false)
			helpers.assert_eq(scope.pending(), true)
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
			local runtime_calls = controls.runtime_calls
			block(false)
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(controls.runtime_calls, runtime_calls)
			helpers.assert_eq(next(live), nil)
		end)
	end)
end)




helpers.describe("Linux ordinary obsolete shortcut parent policy", function()
	for _, literal in ipairs({ '"legacy"', '["legacy"]', "[]" }) do
		helpers.it("clears neutral tap intent while retaining exact obsolete source " .. literal, function()
			local source = '[shortcuts]\nenabled = true\ntap_keys = ' .. literal .. ' # taps retained\n'
				.. '[shortcuts.keyboard]\nfuture = "keep" # keyboard retained\n[future]\nkeep = 7\n'
			local expected = '[shortcuts]\ntap_keys = ' .. literal .. ' # taps retained\n[shortcuts.keyboard]\n'
				.. 'magic_editor = "none"\nfuture = "keep" # keyboard retained\n[future]\nkeep = 7\n\n[shortcuts.script_control]\n'
				.. 'script_altgr_backspace = "none"\nscript_altgr_delete = "none"\nscript_altgr_enter = "none"\nscript_altgr_escape = "none"\n'
			with_scope(function(scope, owners, controls, path, backup)
				local committed, detail = scope.apply("clear")
				helpers.assert_eq(committed, true, detail)
				helpers.assert_eq(Sandbox.read_bytes(path), expected, "hand-authored full image preserves obsolete token and comments")
				helpers.assert_eq(Sandbox.read_bytes(backup), source)
				helpers.assert_eq(#controls.backups, 1)
				helpers.assert_eq(controls.runtime_calls, 1)
				helpers.assert_eq(controls.device_calls, 0)
				helpers.assert_eq(owners.manager.is_enabled(), false)
				helpers.assert_eq(owners.keyboard.get_action("magic_editor"), "none")
				for _, id in ipairs({ "number_row_left", "number_row_right_1", "number_row_right_2" }) do
					helpers.assert_eq(owners.taps.get_action(id), "none")
				end
				owners.keyboard._reset()
				owners.taps._reset()
				helpers.assert_eq(owners.keyboard.get_action("magic_editor"), "none", "fresh actual keyboard reader agrees with ACK")
				helpers.assert_eq(owners.taps.get_action("number_row_left"), "none", "fresh actual tap reader agrees with ACK")
				helpers.assert_eq(scope.pending(), false)
			end, source)
		end)
	end

	helpers.it("compensates refused neutral source publication without erasing obsolete tap intent", function()
		local source = '[shortcuts]\nenabled = true\ntap_keys = ["legacy"]\n[shortcuts.keyboard]\nfuture = "keep"\n[future]\nkeep = 7\n'
		with_scope(function(scope, owners, controls, path)
			local actions = owners.keyboard.get_assignments()
			controls.refuse = path
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			helpers.assert_eq(#controls.backups, 1)
			helpers.assert_eq(controls.runtime_calls, 2, "actual candidate and compensation both pass the native owner")
			helpers.assert_eq(controls.device_calls, 0)
			helpers.assert_eq(owners.manager.is_enabled(), true)
			helpers.assert_eq(owners.keyboard.get_assignments(), actions)
			helpers.assert_eq(owners.taps.get_action("number_row_left"), "none")
			helpers.assert_eq(scope.pending(), false)
			helpers.assert_eq(scope.retry_restore(), true, "the actual compensation journal is settled")
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			owners.keyboard._reset()
			owners.taps._reset()
			helpers.assert_eq(owners.keyboard.get_assignments(), actions)
			helpers.assert_eq(owners.taps.get_action("number_row_left"), "none")
		end, source)
	end)

	for _, owner in ipairs({ "keyboard", "tap" }) do
		helpers.it("keeps existing ordinary " .. owner .. " collision refusal source and native state", function()
			local source = '[shortcuts]\nenabled = true\nkeyboard = "legacy"\ntap_keys = ["legacy"]\n[future]\nkeep = 7\n'
			with_scope(function(_, owners, controls, path)
				local accepted
				if owner == "keyboard" then accepted = owners.keyboard.set_action("ctrl_j", "send_text")
				else accepted = owners.taps.set_action("number_row_left", "send_text") end
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(Sandbox.read_bytes(path), source)
				helpers.assert_eq(#controls.backups, 0)
				helpers.assert_eq(controls.runtime_calls, 0)
				helpers.assert_eq(controls.device_calls, 0)
				helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "none")
				helpers.assert_eq(owners.taps.get_action("number_row_left"), "none")
			end, source)
		end)
	end
end)




require("test.config_obsolete_parents_contract").register(helpers)




helpers.describe("Linux shortcut scope pair initialization", function()
	helpers.it("refuses an uninitialized actual pair owner before backup or other runtime mutation", function()
		with_scope(function(scope, owners, controls, path)
			local before = Sandbox.read_bytes(path)
			local committed, detail = scope.apply("clear")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(detail, "shortcut configuration acquisition refused")
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(#controls.backups, 0)
			helpers.assert_eq(controls.runtime_calls, 0)
			helpers.assert_eq(controls.pair_changes, 0)
			helpers.assert_eq(controls.device_calls, 0)
			helpers.assert_eq(owners.combinations.configuration_pending(), nil)
			helpers.assert_true(owners.manager.configuration_admitted())
		end, nil, { initialize_pairs = false })
	end)
end)




helpers.describe("Linux paused shortcut compensation source custody", function()
	helpers.it("settles a pause refusal through its exact fence while ordinary source admission stays closed", function()
		with_scope(function(_, owners, controls)
			local pairs, token = owners.combinations, {}
			helpers.assert_true(pairs.acquire_configuration(token))
			helpers.assert_true(pairs.acquire_delivery_fence(token))
			controls.paused = true
			helpers.assert_eq(pairs.configuration_source(token), nil)
			local source = pairs.configuration_source(token, true)
			helpers.assert_type(source, "table")
			helpers.assert_eq(pairs.configuration_source_matches(token, source), false)
			helpers.assert_true(pairs.configuration_source_matches(token, source, true))
			helpers.assert_eq(pairs.configuration_source_matches({}, source, true), false)
			helpers.assert_eq(pairs.capture_runtime(), nil)
			helpers.assert_true(pairs.release_configuration(token))
			local restored = pairs.capture_edit_source(token, true)
			helpers.assert_type(restored, "table")
			helpers.assert_true(restored.guard())
			helpers.assert_eq(pairs.capture_edit_source(token), nil)
			helpers.assert_eq(pairs.capture_edit_source(nil, true), nil)
			helpers.assert_eq(pairs.capture_edit_source({}, true), nil)
			local alias = setmetatable({}, { __eq = function() return true end })
			helpers.assert_eq(pairs.capture_edit_source(alias, true), nil)
			controls.paused = "unknown"
			helpers.assert_eq(restored.guard(), false)
			helpers.assert_eq(pairs.capture_edit_source(token, true), nil)
			controls.paused = true
			helpers.assert_true(pairs.release_delivery_fence(token))
			helpers.assert_eq(restored.guard(), false, "settled fence cannot grant later paused source currency")
			helpers.assert_eq(pairs.capture_runtime(), nil)
		end)
	end)

	helpers.it("retains a foreign pair edit during paused rollback until the original frame is restored", function()
		with_scope(function(scope, owners, controls, path)
			local foreign = SOURCE .. '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n'
			controls.before_publish = function(target)
				if target ~= path then
					controls.paused = true
					Sandbox.write_bytes(path, foreign)
				end
			end
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_true(scope.pending())
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			helpers.assert_eq(owners.manager.configuration_admitted(), false)
			helpers.assert_true(owners.combinations.configuration_pending())
			helpers.assert_eq(owners.combinations.capture_runtime(), nil)
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			controls.before_publish = nil
			Sandbox.write_bytes(path, SOURCE)
			helpers.assert_true(scope.retry_restore())
			helpers.assert_eq(scope.pending(), false)
			helpers.assert_true(owners.manager.configuration_admitted())
			helpers.assert_eq(owners.combinations.configuration_pending(), false)
			helpers.assert_eq(owners.combinations.capture_runtime(), nil, "paused recovery does not enable native delivery")
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
		end)
	end)
end)




helpers.describe("Linux shortcut scope canonical parameter admission", function()
	helpers.it("refuses a live canonical parameter replacement without inventing a runtime reload", function()
		with_scope(function(scope, owners, controls, path)
			local foreign = SOURCE:gsub('keyboard__ctrl_j__open_url = "https://old.example"',
				'keyboard__ctrl_j__open_url = "https://foreign.example"')
			Sandbox.write_bytes(path, foreign)
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			helpers.assert_eq(#controls.backups, 0)
			helpers.assert_eq(controls.runtime_calls, 0)
			helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__ctrl_j", "open_url"), "https://old.example")
		end)
	end)
end)




helpers.describe("Linux merged shortcut acquisition custody", function()
	helpers.it("reclaims only previously held ports after a partial acquisition and refused release", function()
		with_scope(function(_, owners, controls, path)
			local attempts, blocked = { keyboard = 0, taps = 0, chords = 0 }, true
			owners.keyboard.acquire_configuration = function()
				attempts.keyboard = attempts.keyboard + 1
				return false
			end
			for _, name in ipairs({ "taps", "chords" }) do
				local native, acquire = owners[name], owners[name].acquire_configuration
				native.acquire_configuration = function(token)
					attempts[name] = attempts[name] + 1
					return acquire(token)
				end
			end
			local release = owners.manager.release_configuration
			owners.manager.release_configuration = function(token)
				if blocked then return false end
				return release(token)
			end
			local scope = require("infra.shortcuts_scope").new({ path = path, backup_path = path .. ".acquisition-backup",
				files = controls.files, is_paused = function() return controls.paused end })
			local original = Sandbox.read_bytes(path)
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(scope.pending(), true)
			helpers.assert_eq(attempts, { keyboard = 1, taps = 0, chords = 0 }, "a release debt never acquires a never-held sibling")
			helpers.assert_eq(Sandbox.read_bytes(path), original)
			helpers.assert_eq(#controls.backups, 0)
			helpers.assert_eq(controls.runtime_calls, 0)
			blocked = false
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(scope.pending(), false)
			helpers.assert_eq(attempts, { keyboard = 1, taps = 0, chords = 0 })
			helpers.assert_eq(Sandbox.read_bytes(path), original)
		end)
	end)
end)




helpers.describe("Linux physical edit four-owner collision preflight", function()
	for _, case in ipairs({
		{ name = "ordinary logical binding", source = COLLISION_BASE .. 'ctrl_j = "copy"\n', key = "physical_ctrl_KeyJ", tap = NO_TAP_HOLDS },
		{ name = "ordinary native None reservation", source = COLLISION_BASE .. 'ctrl_j = "none"\n', key = "physical_ctrl_KeyJ", tap = NO_TAP_HOLDS },
		{ name = "plain tap key", source = COLLISION_BASE .. '[shortcuts.tap_keys]\nnumber_row_left = "copy"\n', key = "physical_none_Backquote", tap = NO_TAP_HOLDS },
		{ name = "ordered combination", source = COLLISION_BASE .. '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n', key = "physical_none_Tab", tap = NO_TAP_HOLDS },
		{ name = "simultaneous combination", source = COLLISION_BASE .. '[mod_combos]\nenabled = true\nsimultaneous_threshold_ms = 50\nsymmetric = true\n[mod_combos.config.tab_then_caps_lock]\ncombo = "copy"\n', key = "physical_none_Tab", chord = "tab_then_caps_lock", tap = NO_TAP_HOLDS },
		{ name = "native tap-hold prefix", source = COLLISION_BASE, key = "physical_none_Tab", tap = '[tap_hold]\nenabled = true\ninherit_defaults = true\n' },
	}) do
		helpers.it("refuses " .. case.name .. " before any write or native ownership change", function()
			with_collision_scope(case.source, case.tap, function(scope, owners, controls, path)
				local before = Sandbox.read_bytes(path)
				if case.chord then helpers.assert_eq(owners.combinations.get_chord(case.chord), "copy", "actual canonical simultaneous owner must claim this fixture") end
				local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = case.key, value = "copy", intent = "keyboard_assignment" } })
				helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "collision")
				helpers.assert_eq(Sandbox.read_bytes(path), before); helpers.assert_eq(#controls.backups, 0)
				helpers.assert_eq(controls.runtime_calls, 0); helpers.assert_eq(controls.device_calls, 0)
				helpers.assert_eq(#controls.executed, 0); helpers.assert_eq(controls.pair_changes, 0)
				helpers.assert_eq(owners.keyboard.physical_delivery_available(), false)
			end)
		end)
	end
	helpers.it("four-family preflight with no known collision does not grant native delivery", function()
		with_collision_scope(COLLISION_BASE .. 'ctrl_j = "copy"\n', NO_TAP_HOLDS, function(scope, _, controls, path)
			local before = Sandbox.read_bytes(path)
			-- The partial native model withdraws readiness at the source observation.
			controls.on_source = function() controls.delivery_available = false end
			local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_ctrl_KeyK", value = "copy", intent = "keyboard_assignment" } })
			helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "unavailable")
			helpers.assert_eq(controls.source_reads, 1); helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(#controls.backups, 0); helpers.assert_eq(controls.runtime_calls, 0)
		end)
	end)
	for _, boundary in ipairs({ "source", "tap owner", "paused Manager", "held owner" }) do
		helpers.it("refuses " .. boundary .. " revocation during the original map observation", function()
			with_collision_scope(COLLISION_BASE .. 'ctrl_j = "copy"\n', NO_TAP_HOLDS, function(scope, owners, controls, path, Manager)
				local once, token, original = false, {}, owners.taps.capture_collision_inventory
				controls.on_source = function()
					if once then return end; once = true
					if boundary == "source" then Sandbox.write_bytes(path, COLLISION_BASE)
					elseif boundary == "tap owner" then owners.taps.capture_collision_inventory = function() return nil end
					elseif boundary == "paused Manager" then
						Manager.set_paused(true); controls.intentional_hook_changes = controls.intentional_hook_changes + 1
					else owners.keyboard.acquire_configuration(token) end
				end
				local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_ctrl_KeyJ", value = "copy", intent = "keyboard_assignment" } })
				helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "source_changed")
				helpers.assert_eq(#controls.backups, 0); helpers.assert_eq(controls.runtime_calls, 0)
				owners.taps.capture_collision_inventory = original
				if boundary == "held owner" then helpers.assert_true(owners.keyboard.release_configuration(token)) end
				if boundary == "paused Manager" then Manager.set_paused(false); controls.intentional_hook_changes = controls.intentional_hook_changes + 1 end
			end)
		end)
	end
	helpers.it("the shared policy preserves None and ordered claim identity without granting readiness", function()
		local policy = require("shortcuts.physical_conflicts")
		local request = { slot = "physical_none_CapsLock", code = 58, action = "none", mods = {}, aliases = {} }
		local claims = { { kind = "prefix", binding = "combination__caps_lock_then_tab", codes = { 58, 15 } } }
		helpers.assert_eq(policy.conflicts(request, claims), false)
		request.action = "copy"
		local conflict, binding = policy.conflicts(request, claims)
		helpers.assert_true(conflict); helpers.assert_eq(binding, "combination__caps_lock_then_tab")
		request.code = 36; helpers.assert_eq(policy.conflicts(request, claims), false)
	end)
end)




helpers.describe("partial collision domains remain unavailable", function()
	helpers.it("modified native-prefix overlap remains unknown instead of a guessed collision", function()
		with_collision_scope(COLLISION_BASE, '[tap_hold]\nenabled = true\ninherit_defaults = true\n', function(scope, _, controls, path)
			local before = Sandbox.read_bytes(path)
			local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_ctrl_CapsLock", value = "copy", intent = "keyboard_assignment" } })
			helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "unavailable")
			helpers.assert_eq(Sandbox.read_bytes(path), before); helpers.assert_eq(#controls.backups, 0)
			helpers.assert_eq(controls.runtime_calls, 0)
		end)
	end)
end)




helpers.describe("conditional Magic Editor yields during collision preflight", function()
	for _, case in ipairs({
		{ name = "default active Magic Editor yields to a new explicit physical source without granting delivery", stored = nil },
		{ name = "custom Magic Editor action also yields to a new explicit physical source", stored = "copy" },
	}) do
		helpers.it(case.name, function()
			local source = '[shortcuts]\nenabled = true\n[shortcuts.keyboard]\n'
				.. (case.stored and 'magic_editor = "copy"\n' or '')
			with_collision_scope(source, NO_TAP_HOLDS, function(scope, owners, controls, path)
				local names = { "modules.hotstrings.magic_key_source", "modules.hotstrings.magic_key" }
				local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
				local ok, why = pcall(function()
					local facts = { generation = 7, status = "ready", candidates = {
						{ code = "KeyJ", native_code = 36, identity = "evdev:36", text = "★", native_text = "j", direct = true, dead = false },
					} }
					-- Native facts are modeled; both the actual keyboard consumer and
					-- shared conditional priority policy execute without replacement.
					package.loaded[names[1]] = { editor_source = function() return facts end,
						known_codes = function() return { KeyJ = true } end }
					package.loaded[names[2]] = { get = function() return "★" end }
					local before = Sandbox.read_bytes(path)
					local decision = owners.keyboard.magic_editor_decision({ master = true, paused = false, inhibited = false })
					helpers.assert_true(decision.active); helpers.assert_eq(decision.source.native_code, 36)
					helpers.assert_eq(decision.action, case.stored or Manifest.default_for("shortcuts.keyboard.magic_editor"))
					local policy = require("shortcuts.magic_editor")
					local projected = policy.resolve({ default_action = Manifest.default_for(policy.PATH), stored_action = case.stored,
						is_action = owners.gestures.is_assignable, trigger = "★", source = facts, known_codes = { KeyJ = true },
						explicit_claims = { ["evdev:36"] = { action = "copy", binding_id = "keyboard__physical_super_KeyJ" } },
						configuration_generation = 1, admission = { master = true, paused = false, inhibited = false } })
					helpers.assert_eq(projected.active, false); helpers.assert_eq(projected.reason, "explicit_assignment")
					-- The conditional recommendation yields; only the independent
					-- modeled capability revocation prevents a new publication.
					controls.on_source = function() controls.delivery_available = false end
					local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_super_KeyJ", value = "copy", intent = "keyboard_assignment" } })
					helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "unavailable", "yielding conditional recommendation is not a personal collision")
					helpers.assert_eq(Sandbox.read_bytes(path), before); helpers.assert_eq(#controls.backups, 0)
					helpers.assert_eq(controls.runtime_calls, 0); helpers.assert_eq(controls.device_calls, 0)
					helpers.assert_eq(#controls.executed, 0); helpers.assert_eq(controls.pair_changes, 0)
					helpers.assert_eq(owners.keyboard.physical_delivery_available(), false)
				end)
				for _, name in ipairs(names) do package.loaded[name] = saved[name] end
				if not ok then error(why, 0) end
			end)
		end)
	end
end)




helpers.describe("physical preflight joins the original Magic Key replacement", function()
	for _, case in ipairs({
		{ name = "plain chosen source", key = "physical_none_KeyJ", reason = "collision" },
		{ name = "Shift source is not replaced", key = "physical_shift_KeyJ", reason = "unavailable" },
		{ name = "Super editor chord is not the plain replacement", key = "physical_super_KeyJ", reason = "unavailable" },
	}) do
		helpers.it("(magic-collision-scope) " .. case.name, function()
			with_magic_collision_scope(MAGIC_COLLISION_SOURCE, {}, function(scope, owners, controls, path)
				local before = Sandbox.read_bytes(path)
					-- V5 requires initial readiness before observing a collision-free input.
					if case.reason == "unavailable" then
						controls.on_source = function() controls.delivery_available = false end
					end
				local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = case.key, value = "copy", intent = "keyboard_assignment" } })
				helpers.assert_eq(accepted, false); helpers.assert_eq(reason, case.reason)
				helpers.assert_eq(Sandbox.read_bytes(path), before); helpers.assert_eq(#controls.backups, 0)
				helpers.assert_eq(controls.runtime_calls, 0); helpers.assert_eq(controls.device_calls, 0)
				helpers.assert_eq(controls.pair_changes, 0); helpers.assert_eq(#controls.executed, 0)
				helpers.assert_eq(owners.keyboard.physical_delivery_available(), false)
			end)
		end)
	end
	for _, case in ipairs({
		{ name = "automatic", source = COLLISION_BASE .. '[hotstrings]\nmagic_key_source = "auto"\n', state = {} },
		{ name = "replacement off", source = MAGIC_COLLISION_SOURCE, state = { replace = false } },
		{ name = "untypable", source = MAGIC_COLLISION_SOURCE, state = { typable = false } },
	}) do
		helpers.it("(magic-collision-scope) " .. case.name .. " adds no replacement collision or readiness", function()
			with_magic_collision_scope(case.source, case.state, function(scope, owners, controls, path)
				local before = Sandbox.read_bytes(path)
					-- The original V5 final readiness fence remains decisive after observation.
					controls.on_source = function() controls.delivery_available = false end
				local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_none_KeyJ", value = "copy", intent = "keyboard_assignment" } })
				helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "unavailable")
				helpers.assert_eq(Sandbox.read_bytes(path), before); helpers.assert_eq(#controls.backups, 0)
				helpers.assert_eq(controls.runtime_calls, 0); helpers.assert_eq(controls.device_calls, 0)
				helpers.assert_eq(owners.keyboard.physical_delivery_available(), false)
			end)
		end)
	end
	helpers.it("(magic-collision-scope) accepted queued capture refuses configuration before acquisition", function()
		with_magic_collision_scope(MAGIC_COLLISION_SOURCE, {}, function(scope, _, controls, path, Source)
			local chosen, before = {}, Sandbox.read_bytes(path)
			helpers.assert_true(Source.capture({ on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() error("no capture result before settlement") end }))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_none_KeyJ", value = "copy", intent = "keyboard_assignment" } })
			helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "source_changed")
			helpers.assert_eq(chosen, {}); helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(#controls.backups, 0); helpers.assert_eq(controls.runtime_calls, 0); helpers.assert_eq(controls.device_calls, 0)
		end)
	end)
	for _, removing in ipairs({ false, true }) do
		helpers.it("(magic-collision-scope) preserves native " .. (removing and "removal" or "None") .. " without invoking replacement admission", function()
			local source = removing and MAGIC_COLLISION_SOURCE:gsub('magic_editor = "none"\n', 'magic_editor = "none"\nphysical_none_KeyJ = "copy"\n', 1) or MAGIC_COLLISION_SOURCE
			with_magic_publication_scope(source, function(scope, owners, controls, path, Source)
				-- Both legitimate native-intent writes must publish while actual readiness is false.
				helpers.assert_eq(scope.physical_delivery_available(), false)
				local observations = 0
				Source.capture_collision_inventory = function() observations = observations + 1; error("native intent must not acquire an output collision frame") end
				local update = { section = "shortcuts.keyboard", key = "physical_none_KeyJ" }
				if removing then update.delete = true
				else update.value, update.intent = "none", "keyboard_assignment" end
				local accepted, detail = scope.edit({ update })
				helpers.assert_eq(accepted, true, detail); helpers.assert_eq(observations, 0)
				helpers.assert_eq(scope.physical_delivery_available(), false)
				local document = Codec.decode(Sandbox.read_bytes(path))
				local expected
				if not removing then expected = "none" end
				helpers.assert_eq(document.shortcuts.keyboard.physical_none_KeyJ, expected)
				helpers.assert_eq(document.hotstrings.magic_key_source, "KeyJ")
				helpers.assert_eq(controls.device_calls, 0); helpers.assert_eq(#controls.executed, 0)
				helpers.assert_eq(owners.keyboard.physical_delivery_available(), false)
			end)
		end)
	end
end)




helpers.describe("Linux configured Navigation physical collision preflight", function()
	local NAV_NONE = '[_meta]\nschema_version = 1\n[layers.nav.all]\nKeyJ = "none"\n'
	local TAP_NAV = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.left_alt]\n'
		.. 'tap_action = "enter"\nhold_modifier = ""\nhold_layer = "nav"\ntime_activation_seconds = 0.2\n'

	local function unchanged(owners, controls, path, before)
		helpers.assert_eq(Sandbox.read_bytes(path), before)
		helpers.assert_eq(#controls.backups, 0); helpers.assert_eq(controls.runtime_calls, 0)
		helpers.assert_eq(controls.device_calls, 0); helpers.assert_eq(#controls.executed, 0)
		helpers.assert_eq(controls.pair_changes, 0); helpers.assert_eq(owners.keyboard.physical_delivery_available(), false)
	end

	helpers.it("(nav-configured-reservation) actual preflight refuses reachable Navigation None before configuration acquisition", function()
		with_collision_scope(COLLISION_BASE, TAP_NAV, function(scope, owners, controls, path)
			local before = Sandbox.read_bytes(path)
			local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_none_KeyJ",
				value = "copy", intent = "keyboard_assignment" } })
			helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "collision")
			unchanged(owners, controls, path, before)
		end, NAV_NONE)
	end)

	helpers.it("(nav-configured-reservation) unknown modified Navigation overlap remains unavailable before any write", function()
		with_collision_scope(COLLISION_BASE, TAP_NAV, function(scope, owners, controls, path)
			local before = Sandbox.read_bytes(path)
			local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_shift_KeyJ",
				value = "copy", intent = "keyboard_assignment" } })
			helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "unavailable")
			unchanged(owners, controls, path, before)
		end, NAV_NONE)
	end)

	helpers.it("(nav-configured-reservation) real changed layer bytes cannot borrow the installed Manager baseline at preflight", function()
		with_collision_scope(COLLISION_BASE, TAP_NAV, function(scope, owners, controls, path)
			local before = Sandbox.read_bytes(path)
			local handle = assert(io.open(controls.navigation_path, "wb"))
			local wrote, result = pcall(handle.write, handle, "[broken")
			local closed, acknowledged = pcall(handle.close, handle)
			helpers.assert_true(wrote and result ~= nil and result ~= false); helpers.assert_true(closed and acknowledged == true)
			local verification = assert(io.open(controls.navigation_path, "rb"))
			local read_ok, bytes = pcall(verification.read, verification, "*a")
			local close_ok, verified_closed = pcall(verification.close, verification)
			helpers.assert_true(read_ok and bytes == "[broken"); helpers.assert_true(close_ok and verified_closed == true)
			local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_none_KeyJ",
				value = "copy", intent = "keyboard_assignment" } })
			helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "source_changed")
			unchanged(owners, controls, path, before)
		end, NAV_NONE)
	end)
end)

