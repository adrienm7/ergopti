--- tests/unit/ui/menu/scope/test_global_reset_transaction.lua

--- ==============================================================================
--- MODULE: Factory Reset Transaction Regression
--- DESCRIPTION:
--- Exercises the real global actions exported by ui.menu.start and proves every
--- runtime, preference, settings, file, Karabiner, and reload boundary of the
--- factory reset belongs to one exact transaction with reverse compensation and
--- retained retry debt. Enable All and Disable All, the other two kinds this
--- owner once had, are retired: the menu exports neither.
---
--- FEATURES & RATIONALE:
--- 1. Faithful Refusals: False, nil, throws, and synchronous callbacks followed
---    by request refusal remain distinct from exact terminal commitment.
--- 2. Observable Rollback: Mutable doubles expose every store so partial state
---    cannot hide behind a successful pcall or a permissive stub.
--- 3. Real Wiring: Both subjects are captured from ui.menu.start, not invoked
---    through a test-only transaction factory.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.scope.global_reset_transaction_fixture"] = nil
local Fixture = require("tests.support.ui.menu.scope.global_reset_transaction_fixture")
local assert_fully_restored = Fixture.assert_fully_restored
local fail = Fixture.fail
local with_menu_fixture = Fixture.with_menu_fixture





-- =============================================================
-- =============================================================
-- ======= 1/ Factory Reset Exact Transaction Boundaries =======
-- =============================================================
-- =============================================================

helpers.describe("HS-022 factory reset owns settings, files, deployment, and reload", function()
	helpers.it("refuses bulk mutation behind every live manual termination owner", function()
		for _, case in ipairs({
			{
				label = "menu reload",
				start = function(observations) return observations.actions.reload() end,
			},
			{
				label = "watcher reload",
				start = function(observations)
					helpers.assert_type(observations.config_watcher_callback, "function")
					return observations.config_watcher_callback()
				end,
			},
			{
				label = "quit",
				start = function(observations) return observations.actions.quit() end,
			},
		}) do
			with_menu_fixture({}, function(observations)
				helpers.assert_eq(case.start(observations), true, case.label .. " must be accepted")
				helpers.assert_true(observations.termination_pending)
				helpers.assert_eq(observations.actions.factory_reset(), false,
					case.label .. " must fence a later factory reset")
				helpers.assert_eq(observations.calls["karabiner-reset"] or 0, 0)
				helpers.assert_eq(observations.files, observations.initial_files)
			end)
		end
	end)

	helpers.it("refuses a reentrant action while synchronous rollback is on-stack", function()
		with_menu_fixture({ failures = { reload = fail("false") } }, function(observations)
			local nested_result = nil
			observations.hooks[
				"file-restore:/virtual/config_karabiner.toml:after"
			] = function()
				nested_result = observations.actions.factory_reset()
			end

			helpers.assert_eq(observations.actions.factory_reset(), false)
			helpers.assert_eq(nested_result, false,
				"rollback owns its inverse until the mutating boundary returns")
			assert_fully_restored(observations)
			helpers.assert_eq(
				observations.calls["file-restore:/virtual/config_karabiner.toml"],
				1,
				"the same inverse must not recurse while it is on-stack"
			)
		end)
	end)

	helpers.it("compensates settings and recoverable file move refusal shapes", function()
		for _, boundary in ipairs({
			"setting:llm_api_entries",
			"setting:llm_api_entry_id",
			"file-move:/virtual/config.toml",
			"file-move:/virtual/config_karabiner.toml",
		}) do
			local modes = boundary:sub(1, #"setting:") == "setting:"
				and { "false", "nil", "throw", "false-after", "throw-after" }
				or { "false", "nil", "throw", "false-after", "nil-after", "throw-after" }
			for _, mode in ipairs(modes) do
				with_menu_fixture({ failures = { [boundary] = fail(mode) } }, function(observations)
					helpers.assert_eq(observations.actions.factory_reset(), false)
					assert_fully_restored(observations)
					helpers.assert_eq(observations.reload_commits, 0)
				end)
			end
		end
	end)

	helpers.it("requires exact Karabiner deployment before requesting reload", function()
		for _, mode in ipairs({ "false", "nil", "throw", "sync-success-false", "sync-success-nil" }) do
			with_menu_fixture({ failures = { ["karabiner-reset"] = fail(mode) } }, function(observations)
				helpers.assert_eq(observations.actions.factory_reset(), false)
				assert_fully_restored(observations)
				helpers.assert_eq(observations.calls.reload or 0, 0)
			end)
		end
	end)

	helpers.it("compensates a negative reset deployment terminal before reload", function()
		with_menu_fixture({ failures = { ["karabiner-reset"] = fail("pending") } }, function(observations)
			helpers.assert_eq(observations.actions.factory_reset(), true)
			observations.terminals["karabiner-reset"](false, "regeneration-refused")
			assert_fully_restored(observations)
			helpers.assert_eq(observations.calls.reload or 0, 0)
		end)
	end)

	helpers.it("compensates every reload handoff refusal without a success claim", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_menu_fixture({ failures = { reload = fail(mode) } }, function(observations)
				helpers.assert_eq(observations.actions.factory_reset(), false)
				assert_fully_restored(observations)
				helpers.assert_eq(observations.reset_journal_phase, "cleared",
					"a refused reload must settle the restored journal")
				helpers.assert_eq(observations.calls["karabiner-restore"], 1)
				helpers.assert_eq(observations.reload_commits, 0)
			end)
		end
	end)

	helpers.it("rolls back every durable journal boundary refusal", function()
		for _, label in ipairs({ "reset-journal:prepared", "reset-journal:commit" }) do
			for _, mode in ipairs({ "false", "nil", "throw", "false-after", "throw-after" }) do
				with_menu_fixture({ failures = { [label] = fail(mode) } }, function(observations)
					helpers.assert_eq(observations.actions.factory_reset(), false,
						label .. " " .. mode .. " must refuse the reset")
					assert_fully_restored(observations)
					helpers.assert_eq(observations.reset_journal_phase, "cleared",
						"the restored transaction must durably settle its journal")
					helpers.assert_eq(observations.reload_commits, 0)
				end)
			end
		end
	end)

	helpers.it("retains compensation debt and lets one retry commit exactly once", function()
		with_menu_fixture({ failures = {
			reload = fail("false"),
			["file-restore:/virtual/config_karabiner.toml"] = fail("false"),
		} }, function(observations)
			helpers.assert_eq(observations.actions.factory_reset(), false)
			helpers.assert_nil(observations.files["/virtual/config_karabiner.toml"],
				"the refused inverse remains owned as cleanup debt")
			helpers.assert_eq(observations.actions.factory_reset(), true,
				"the retry must finish debt before starting one new candidate")
			helpers.assert_eq(observations.reload_commits, 1)
			helpers.assert_eq(#observations.notifications, 0,
				"reload handoff has no post-finalization notification tail")
			helpers.assert_eq(observations.post_reload_effects, 0)
			helpers.assert_eq(observations.calls.reload, 2,
				"one rejected handoff and one committed retry are expected")
		end)
	end)

	helpers.it("keeps reset fenced through a returning reload with no post-reload tail", function()
		with_menu_fixture({ failures = { ["karabiner-reset"] = fail("pending") } }, function(observations)
			helpers.assert_eq(observations.actions.factory_reset(), true)
			helpers.assert_eq(observations.actions.factory_reset(), false,
				"a second reset shares the one pending owner")
			helpers.assert_eq(observations.reload_commits, 0)
			local terminal = observations.terminals["karabiner-reset"]
			terminal(true, "ready")
			terminal(true, "duplicate")
			helpers.assert_eq(observations.reload_commits, 1)
			helpers.assert_eq(#observations.notifications, 0)
			helpers.assert_eq(observations.post_reload_effects, 0,
				"no UI or logger capability may run after the coordinator returned from hs.reload")
			helpers.assert_eq(observations.actions.factory_reset(), false,
				"the global mutation owner remains fenced until the Lua state is replaced")
			helpers.assert_nil(observations.files["/virtual/config.toml"])
			helpers.assert_not_nil(observations.files[
				"/virtual/config.toml.ergopti-reset-backup"])
			helpers.assert_eq(observations.reset_journal_phase, "commit",
				"the accepted reload must leave one durable commit decision")
			helpers.assert_eq(#observations.reset_journal_entries, 2,
				"the journal must own every reset pathname")
			for _, entry in ipairs(observations.reset_journal_entries) do
				helpers.assert_true(entry.existed == true and type(entry.identity) == "table",
					"each existing reset file must retain its inode identity")
			end
		end)
	end)

	helpers.it("rolls back an accepted reload whose exact lease later aborts", function()
		with_menu_fixture({ failures = { reload = fail("pending") } }, function(observations)
			helpers.assert_eq(observations.actions.factory_reset(), true)
			helpers.assert_type(observations.reload_abort, "function")
			helpers.assert_type(observations.builder_ctx, "table")
			helpers.assert_eq(observations.actions.factory_reset(), false,
				"an accepted reload handoff still owns every overlapping writer")
			helpers.assert_eq(observations.actions.reload(), false,
				"a manual reload cannot supersede the reset handoff")
			helpers.assert_eq(observations.builder_ctx.do_reload("menu"), false,
				"indirect menu callers must share the same reload capability")
			helpers.assert_eq(observations.actions.quit(), false,
				"a quit cannot upgrade the reset's exclusive reload owner")
			helpers.assert_eq(observations.calls.manual_reload or 0, 0)
			helpers.assert_eq(observations.calls.exit or 0, 0)
			-- The refused quit tells the user so; the reset itself notifies nothing.
			helpers.assert_eq(#observations.notifications, 1)
			helpers.assert_eq(observations.notifications[1].label, "notify.quit_refused")

			local abort = observations.reload_abort
			observations.reload_abort = nil
			abort("native fence refused")
			assert_fully_restored(observations)
			helpers.assert_eq(observations.reset_journal_phase, "cleared",
				"an aborted reload lease must settle the restored journal")
			helpers.assert_eq(observations.reload_commits, 0)
		end)
	end)
end)





-- ========================================================
-- ========================================================
-- ======= 2/ Recoverable File Move Native Contract =======
-- ========================================================
-- ========================================================

helpers.describe("HS-022 recoverable config moves retain exact inverse evidence", function()
	helpers.it("records a throw-after-move and restores the original bytes on retry", function()
		local files = { ["/config.toml"] = "old bytes" }
		local rename_calls = 0
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				if files[path] == nil then return nil, "absent" end
				return files[path], "ok"
			end,
			rename = function(source, destination)
				rename_calls = rename_calls + 1
				files[destination] = files[source]
				files[source] = nil
				if rename_calls == 1 then error("synthetic late rename throw") end
				return true
			end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		helpers.assert_type(entry, "table")
		helpers.assert_eq(mover.move(entry), false)
		helpers.assert_nil(files["/config.toml"])
		helpers.assert_eq(files["/config.toml.backup"], "old bytes")
		helpers.assert_eq(mover.restore(entry), true)
		helpers.assert_eq(files["/config.toml"], "old bytes")
		helpers.assert_nil(files["/config.toml.backup"])
	end)

	helpers.it("recognizes every pre-mutation move refusal as already restored", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			local files = { ["/config.toml"] = "old bytes" }
			local move_calls = 0
			local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
				read_with_status = function(path)
					if files[path] == nil then return nil, "absent" end
					return files[path], "ok"
				end,
				move_no_replace = function()
					move_calls = move_calls + 1
					if mode == "throw" then error("synthetic no-replace move throw") end
					if mode == "nil" then return nil end
					return false
				end,
				backup_path = function(path) return path .. ".backup" end,
			})
			local entry = mover.capture("/config.toml")
			helpers.assert_eq(mover.move(entry), false)
			helpers.assert_eq(mover.restore(entry), true,
				mode .. " before mutation is already the exact inverse posture")
			helpers.assert_eq(files["/config.toml"], "old bytes")
			helpers.assert_nil(files["/config.toml.backup"])
			helpers.assert_eq(move_calls, 1,
				"rollback must not invoke a second native move when nothing changed")
		end
	end)

	helpers.it("refuses an absent snapshot after a file appears", function()
		local files = {}
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				if files[path] == nil then return nil, "absent" end
				return files[path], "ok"
			end,
			move_no_replace = function() error("native move must stay unreachable") end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		files["/config.toml"] = "concurrent writer"
		helpers.assert_eq(mover.move(entry), false)
		helpers.assert_eq(mover.restore(entry), false)
		helpers.assert_eq(files["/config.toml"], "concurrent writer")
	end)

	helpers.it("never overwrites a destination created inside the forward move", function()
		local files = { ["/config.toml"] = "old bytes" }
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				if files[path] == nil then return nil, "absent" end
				return files[path], "ok"
			end,
			move_no_replace = function(_source, destination)
				files[destination] = "foreign backup"
				return true
			end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		helpers.assert_eq(mover.move(entry), false)
		helpers.assert_eq(files["/config.toml"], "old bytes")
		helpers.assert_eq(files["/config.toml.backup"], "foreign backup")
		helpers.assert_eq(mover.restore(entry), false,
			"a foreign destination remains retained evidence, never rollback fodder")
		helpers.assert_eq(files["/config.toml.backup"], "foreign backup")
	end)

	helpers.it("never overwrites a source recreated inside the inverse move", function()
		local files = { ["/config.toml"] = "old bytes" }
		local calls = 0
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				if files[path] == nil then return nil, "absent" end
				return files[path], "ok"
			end,
			move_no_replace = function(source, destination)
				calls = calls + 1
				if calls == 1 then
					files[destination] = files[source]
					files[source] = nil
				else
					files[destination] = "concurrent writer"
				end
				return true
			end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		helpers.assert_eq(mover.move(entry), true)
		helpers.assert_eq(mover.restore(entry), false)
		helpers.assert_eq(files["/config.toml"], "concurrent writer")
		helpers.assert_eq(files["/config.toml.backup"], "old bytes",
			"the exact inverse remains recoverable after a no-clobber refusal")
	end)

	helpers.it("rejects a split postcondition changed between its two reads", function()
		local files = { ["/config.toml"] = "old bytes" }
		local mutate_during_postcondition = false
		local mover = helpers.load_with_stubs("ui.menu.recoverable_file_moves").create({
			read_with_status = function(path)
				local content = files[path]
				if mutate_during_postcondition and path == "/config.toml.backup" then
					mutate_during_postcondition = false
					files["/config.toml"] = "concurrent writer"
				end
				if content == nil then return nil, "absent" end
				return content, "ok"
			end,
			move_no_replace = function(source, destination)
				files[destination] = files[source]
				files[source] = nil
				mutate_during_postcondition = true
				return true
			end,
			backup_path = function(path) return path .. ".backup" end,
		})
		local entry = mover.capture("/config.toml")
		helpers.assert_eq(mover.move(entry), false)
		helpers.assert_eq(files["/config.toml"], "concurrent writer")
		helpers.assert_eq(files["/config.toml.backup"], "old bytes")
	end)
end)


helpers.describe("gesture scope menu composition", function()
	helpers.it("wires exact scope modes and the shared fence, with no question for either mode", function()
		with_menu_fixture({}, function(observations)
			local received, selected, dialog_args
			package.loaded["infra.dialog_util"] = { block_alert = function(...)
				dialog_args = { ... }
				return selected
			end }
			package.loaded["ui.menu.gesture_scope"] = { new = function(options)
				received = options
				return { apply = function(mode)
					return options.admission("gesture scope fixture", function()
						helpers.assert_eq(observations.builder_ctx.save_prefs(), false,
							"ordinary save must not enter an owned scope")
						-- No owner asks (restore-recommended-no-confirm; the clear's
						-- question was retired on 2026-09-30).
						helpers.assert_nil(options.confirm, "no owner is handed a question port")
						return true
					end)
				end }
			end }
			selected = "onboarding.btn.no"
			helpers.assert_eq(observations.builder_ctx.apply_gesture_scope("clear"), true, "a clear applies at once")
			helpers.assert_nil(dialog_args, "a clear asks nothing")
			helpers.assert_type(received.checkpoint.capture, "function")
			helpers.assert_type(received.checkpoint.replace, "function")
			helpers.assert_eq(received.path, "/virtual/config.toml")
			dialog_args = nil
			helpers.assert_eq(observations.builder_ctx.apply_gesture_scope("recommended"), true)
			helpers.assert_nil(dialog_args, "restoring the recommended values asks nothing")
		end)
	end)
end)

helpers.describe("layout scope menu composition", function()
	helpers.it("wires exact scope modes and the shared fence, with no question for either mode", function()
		with_menu_fixture({}, function(observations)
			local received, selected, dialog_args
			package.loaded["infra.dialog_util"] = { block_alert = function(...)
				dialog_args = { ... }
				return selected
			end }
			package.loaded["ui.menu.scoped_preferences"] = { new = function(options)
				received = options
				return { apply = function(mode)
					return options.admission("layout scope fixture", function()
						helpers.assert_eq(observations.builder_ctx.save_prefs(), false,
							"ordinary save must not enter an owned scope")
						-- No owner asks (restore-recommended-no-confirm; the clear's
						-- question was retired on 2026-09-30).
						helpers.assert_nil(options.confirm, "no owner is handed a question port")
						return true
					end)
				end }
			end }
			selected = "onboarding.btn.no"
			helpers.assert_eq(observations.builder_ctx.apply_preference_scope("keyboard_layout", "clear"), true, "a clear applies at once")
			helpers.assert_nil(dialog_args, "a clear asks nothing")
			helpers.assert_eq(received.scope, "keyboard_layout")
			helpers.assert_type(received.runtime.capture, "function")
			helpers.assert_type(received.checkpoint.capture, "function")
			helpers.assert_type(received.checkpoint.replace, "function")
			helpers.assert_eq(received.path, "/virtual/config.toml")
			dialog_args = nil
			helpers.assert_eq(observations.builder_ctx.apply_preference_scope("keyboard_layout", "recommended"), true)
			helpers.assert_nil(dialog_args, "restoring the recommended values asks nothing")
		end)
	end)
end)

helpers.describe("metrics scope menu composition", function()
	helpers.it("wires exact scope modes and the shared fence, with no question for either mode", function()
		with_menu_fixture({}, function(observations)
			local received, selected, dialog_args
			package.loaded["infra.dialog_util"] = { block_alert = function(...)
				dialog_args = { ... }
				return selected
			end }
			package.loaded["ui.menu.metrics_scope"] = { new = function(options)
				received = options
				return { apply = function(mode)
					return options.admission("metrics scope fixture", function()
						helpers.assert_eq(observations.builder_ctx.save_prefs(), false,
							"ordinary save must not enter an owned scope")
						-- No owner asks (restore-recommended-no-confirm; the clear's
						-- question was retired on 2026-09-30).
						helpers.assert_nil(options.confirm, "no owner is handed a question port")
						return true
					end)
				end }
			end }
			selected = "onboarding.btn.no"
			helpers.assert_eq(observations.builder_ctx.apply_preference_scope("metrics", "clear"), true, "a clear applies at once")
			helpers.assert_nil(dialog_args, "a clear asks nothing")
			helpers.assert_type(received.activation_pending, "function")
			helpers.assert_nil(received.capture_shortcuts, "the Metrics scope owns no retired hotkey")
			helpers.assert_nil(received.apply_shortcut, "the scope cannot acquire a dedicated binding")
			helpers.assert_type(received.checkpoint.capture, "function")
			helpers.assert_type(received.checkpoint.replace, "function")
			helpers.assert_eq(received.path, "/virtual/config.toml")
			dialog_args = nil
			helpers.assert_eq(observations.builder_ctx.apply_preference_scope("metrics", "recommended"), true)
			helpers.assert_nil(dialog_args, "restoring the recommended values asks nothing")
		end)
	end)
end)

helpers.describe("hotstrings scope menu composition", function()
	helpers.it("wires the running keymap, both files and the shared fence, with no question for either mode", function()
		with_menu_fixture({}, function(observations)
			local received, selected, dialog_args
			package.loaded["infra.dialog_util"] = { block_alert = function(...)
				dialog_args = { ... }
				return selected
			end }
			local overrides = { get_override_path = function() return "/virtual/hotstrings_config.toml" end }
			package.loaded["modules.hotstrings.hotstrings_config"] = overrides
			local constructions = 0
			package.loaded["ui.menu.hotstrings_scope"] = { new = function(options)
				received, constructions = options, constructions + 1
				return { apply = function(mode)
					return options.admission("hotstrings scope fixture", function()
						helpers.assert_eq(observations.builder_ctx.save_prefs(), false,
							"ordinary save must not enter an owned scope")
						-- No owner asks (restore-recommended-no-confirm; the clear's
						-- question was retired on 2026-09-30).
						helpers.assert_nil(options.confirm, "no owner is handed a question port")
						return true
					end)
				end }
			end }
			selected = "onboarding.btn.no"
			helpers.assert_eq(observations.builder_ctx.apply_preference_scope("hotstrings", "clear"), true, "a clear applies at once")
			helpers.assert_nil(dialog_args, "a clear asks nothing")
			helpers.assert_eq(received.keymap, observations.keymap, "the scope drives the running typing engine")
			helpers.assert_eq(received.config, overrides, "the scope owns the loaded override file")
			helpers.assert_eq(received.path, "/virtual/config.toml")
			helpers.assert_eq(received.state, observations.state)
			helpers.assert_type(received.checkpoint.capture, "function")
			helpers.assert_type(received.checkpoint.replace, "function")
			helpers.assert_type(received.demotions.release_feature, "function")
			helpers.assert_eq(received.editor, package.loaded["ui.hotstring_editor"],
				"the editor follows the magic key, as from its own menu row")
			for _, name in ipairs({ "start_engine", "stop_engine", "is_personal", "remove", "capture_preferences" }) do
				helpers.assert_type(received[name], "function", name)
			end
			local config_backup, override_backup = received.backup_path(), received.override_backup_path()
			helpers.assert_eq(config_backup:find("/virtual/config.toml.hotstrings-", 1, true), 1)
			helpers.assert_eq(override_backup:find("/virtual/hotstrings_config.toml.hotstrings-", 1, true), 1)
			helpers.assert_true(received.backup_path() ~= config_backup, "every backup path is new")
			dialog_args = nil
			helpers.assert_eq(observations.builder_ctx.apply_preference_scope("hotstrings", "recommended"), true)
			helpers.assert_nil(dialog_args, "restoring the recommended values asks nothing")
			helpers.assert_eq(constructions, 1, "one owner per session keeps its retained inverse")
		end)
	end)

	helpers.it("skips the hotstrings category of the global restore when its owner cannot serve it", function()
		with_menu_fixture({}, function(observations)
			package.loaded["modules.hotstrings.hotstrings_config"] = {
				get_override_path = function() return "/virtual/hotstrings_config.toml" end,
			}
			local reason = "the hotstring override file was not read cleanly"
			local owner = { apply = function() return true end, unavailable = function() return reason end }
			package.loaded["ui.menu.hotstrings_scope"] = { new = function() return owner end }
			local composed
			package.loaded["ui.menu.global_scope"] = { new = function(options)
				composed = options
				return { apply = function() return true end }
			end }
			helpers.assert_eq(observations.actions.reset_defaults(), true)
			helpers.assert_nil(composed.owners.hotstrings(), "an owner that cannot serve its files is skipped")
			reason = nil
			helpers.assert_eq(composed.owners.hotstrings(), owner, "an available owner takes part")
		end)
	end)
end)

helpers.describe("private program admission uses the actual global writer fence", function()
	helpers.it("registers once and closes while another writer owns a mutation", function()
		with_menu_fixture({}, function(observations)
			helpers.assert_type(observations.program_admission, "function")
			helpers.assert_eq(observations.program_admission(), true)
			local reads = 0
			observations.hooks["gesture:swipe_left:before"] = function()
				reads = reads + 1
				helpers.assert_eq(observations.program_admission(), false)
			end
			observations.failures["setting:llm_api_entries"] = fail("false")
			helpers.assert_eq(observations.actions.factory_reset(), false)
			helpers.assert_eq(reads, 1)
			helpers.assert_eq(observations.program_admission(), true)
		end)
	end)
end)
