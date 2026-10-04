--- tests/unit/ui/menu/test_layout_scope.lua

local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local FileSystem = require("adapters.file_system")

local function fixture(number_row_source, complete_source)
	package.loaded["adapters.file_system"] = FileSystem
	local Layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
	local state = { layout_pause_switch_enabled = true, layout_on_pause = "French", layout_on_resume = "Ergopti+" }
	local original = '[layout]\npause_switch_enabled = true\non_pause = "French"\non_resume = "Ergopti+"\nfuture = { preserve = 7 }\n[llm]\nenabled = true\n[metrics]\nenabled = true\n'
	if complete_source ~= nil then original = complete_source end
	if number_row_source then
		original = original:gsub("%[layout%]\n", "[layout]\ndirect_access_digits = " .. number_row_source .. " # retained personal intent\n", 1)
	end
	local files, controls, writes = { config = original }, {}, 0
	local adapter = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("conditional publication is required") end,
		write_if_unchanged = function(path, content, expected)
			if controls.refuse and path == "config" then return false end
			if expected.status == "ok" and expected.content ~= files[path] then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			files[path], writes = content, writes + 1
			return true
		end,
	}
	package.loaded["adapters.file_system"] = adapter
	local prefs = helpers.load_with_stubs("infra.preferences")
	prefs.load("config")
	local PT = require("ui.menu.preferences_transaction")
	local save, checkpoint = PT.bind(prefs, { path = "config", state = state, hotfiles = {}, core_modules = {},
		initial_state = state, initial_preferences = prefs.snapshot(state, {}, {}), restore_runtime = function() return true end })
	--- A layout owner over this fixture's file, preferences and checkpoint.
	--- @param backup string|nil Its backup path; the first owner uses "backup".
	--- @return table owner
	local function new_owner(backup)
		return require("ui.menu.scoped_preferences").new({
			scope = "keyboard_layout", path = "config", state = state, files = adapter, preferences = prefs,
			checkpoint = checkpoint, demotions = require("ui.menu.session_demotions").new(),
			capture_preferences = function() return prefs.snapshot(state, {}, {}) end,
			backup_path = function() return backup or "backup" end,
			admission = function(_, callback) return callback() end,
			paused = function() return false end,
			runtime = {
				capture = function(_, source) return Layout.capture_scope(state, source) end,
				apply = function(_, rows) return Layout.apply_scope(state, rows) end,
				restore = function(snapshot) return Layout.restore_scope(state, snapshot) end,
			},
		})
	end
	return new_owner(), Layout, state, files, controls, prefs, save, function() return writes end, original, new_owner
end

helpers.describe("macOS keyboard-layout scope", function()
	helpers.it("restores and clears the exact switching policy without touching other consent or unknown data", function()
		for _, mode in ipairs({ "clear", "recommended" }) do
			local owner, Layout, state, files, _, prefs, save, _, original = fixture()
			helpers.assert_eq(owner.apply(mode), true)
			local decoded = Codec.decode(files.config)
			helpers.assert_eq(state.layout_pause_switch_enabled, false)
			helpers.assert_eq(state.layout_on_pause, false)
			helpers.assert_eq(state.layout_on_resume, false)
			helpers.assert_eq(decoded.layout.pause_switch_enabled, nil)
			helpers.assert_eq(decoded.layout.on_pause, nil)
			helpers.assert_eq(decoded.layout.on_resume, nil)
			helpers.assert_eq(decoded.layout.future.preserve, 7)
			helpers.assert_eq(decoded.llm.enabled, true)
			helpers.assert_eq(decoded.metrics.enabled, true)
			helpers.assert_eq(files.backup, original)
			helpers.assert_eq(prefs.source_snapshot("config").content, files.config)
			helpers.assert_eq(save(), true)
			helpers.assert_eq(Layout.schedule_pause_layout_switch(false, state, function() error("no native switch") end), nil)
		end
	end)
	helpers.it("refuses while an earlier deferred switch can still mutate the native input source", function()
		local owner, Layout, state, files, _, _, _, writes, original = fixture()
		local deferred, done
		Layout.set_layout_by_kl_name_async = function(_, callback) done = callback; return true end
		Layout.schedule_pause_layout_switch(false, state, function(callback) deferred = callback; return true end)
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(writes(), 0)
		deferred()
		helpers.assert_eq(owner.apply("clear"), false, "dispatch acceptance is not terminal completion")
		helpers.assert_eq(files.config, original)
		done(true)
		helpers.assert_eq(owner.apply("clear"), true)
	end)
	helpers.it("invalidates a refused scheduler callback and awaits a failed native terminal result", function()
		local owner, Layout, state = fixture()
		local deferred, done, calls = nil, nil, 0
		Layout.set_layout_by_kl_name_async = function(_, callback) calls = calls + 1; done = callback; return true end
		Layout.schedule_pause_layout_switch(false, state, function(callback) deferred = callback; return false end)
		deferred()
		helpers.assert_eq(calls, 0)
		helpers.assert_eq(Layout.scope_pending(), false)
		Layout.schedule_pause_layout_switch(false, state, function(callback) deferred = callback; return true end)
		deferred()
		helpers.assert_eq(Layout.scope_pending(), true)
		done(false)
		helpers.assert_eq(Layout.scope_pending(), false)
		helpers.assert_eq(owner.apply("clear"), true)
	end)
	helpers.it("requires a boolean native terminal and ignores a synchronous refused schedule", function()
		local owner, Layout, state, _, _, _, _, writes = fixture()
		local calls, done = 0
		Layout.set_layout_by_kl_name_async = function(_, callback) calls = calls + 1; done = callback; return true end
		Layout.schedule_pause_layout_switch(false, state, function(callback) callback(); return false end)
		helpers.assert_eq(calls, 0)
		Layout.schedule_pause_layout_switch(false, state, function(callback) callback(); return true end)
		helpers.assert_eq(calls, 1)
		done("accepted")
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(writes(), 0)
		done(true)
		helpers.assert_eq(owner.apply("clear"), true)
	end)
	helpers.it("validates every planned field before changing policy and restores absent state exactly", function()
		local _, Layout, state = fixture()
		local saved = Layout.capture_scope({})
		local ok = pcall(Layout.apply_scope, state, {
			{ section = "layout", key = "on_resume", delete = true },
			{ section = "metrics", key = "enabled", delete = true },
		})
		helpers.assert_eq(ok, false)
		helpers.assert_eq(state.layout_on_resume, "Ergopti+")
		helpers.assert_eq(Layout.restore_scope(state, saved), true)
		helpers.assert_eq(state.layout_on_resume, nil)
		helpers.assert_eq(state.layout_pause_switch_enabled, nil)
	end)
	helpers.it("restores policy and save baselines on publication refusal or a nonterminal runtime result", function()
		for _, failure in ipairs({ "write", "native" }) do
			local owner, Layout, state, files, controls, prefs, save, _, original = fixture()
			if failure == "write" then controls.refuse = true
			else
				local apply = Layout.apply_scope
				Layout.apply_scope = function(...) apply(...); return "accepted" end
			end
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(files.config, original)
			helpers.assert_eq(state.layout_pause_switch_enabled, true)
			helpers.assert_eq(state.layout_on_pause, "French")
			helpers.assert_eq(state.layout_on_resume, "Ergopti+")
			helpers.assert_eq(prefs.source_snapshot("config").content, original)
			controls.refuse = false
			helpers.assert_eq(save(), true)
		end
	end)
	helpers.it("a stale source refuses before backup and state mutation", function()
		for _, failure in ipairs({ "stale" }) do
			local owner, _, state, files, _, _, _, writes = fixture()
			if failure == "stale" then files.config = '[future]\nexternal = true\n' end
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(writes(), 0)
			helpers.assert_eq(state.layout_on_resume, "Ergopti+")
		end
	end)
end)

package.loaded["adapters.file_system"] = FileSystem
package.loaded["infra.preferences"] = nil

helpers.describe("layout scope provider", function()
	helpers.it("dispatches the common commands through the exact scope owner", function()
		local renderer = require("infra.manifest_menu")
		local original, captured = renderer.build
		renderer.build = function(_, _, _, _, ctx) captured = ctx; return {} end
		local ok, err = xpcall(function()
			local Layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
			local selected, mode
			local ctx = { state = {}, base_dir = helpers.driver_root(), updateMenu = function() end,
				save_prefs = function() error("scope provider must not publish an ordinary save") end,
				apply_preference_scope = function(scope, value) selected, mode = scope, value; return true end }
			Layout.build(ctx)
			helpers.assert_eq(captured.commands.scope_clear(), true)
			helpers.assert_eq(selected, "keyboard_layout")
			helpers.assert_eq(mode, "clear")
			helpers.assert_eq(captured.commands.scope_restore(), true)
			helpers.assert_eq(mode, "recommended")
			ctx.paused = true
			helpers.assert_eq(captured.commands.scope_clear(), false)
			ctx.paused, ctx.apply_preference_scope = false, nil
			helpers.assert_eq(captured.commands.scope_restore(), false)
		end, debug.traceback)
		renderer.build = original
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("macOS scoped preferences under a composition", function()
	helpers.it("reverts a commit: runtime, staged source, checkpoint and the exact bytes", function()
		local owner, _, state, files, _, prefs, save, _, original = fixture()
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_eq(state.layout_on_pause, false)
		helpers.assert_eq(owner.revert(), true)
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(state.layout_pause_switch_enabled, true)
		helpers.assert_eq(state.layout_on_pause, "French")
		helpers.assert_eq(state.layout_on_resume, "Ergopti+")
		helpers.assert_eq(prefs.source_snapshot("config").content, original)
		helpers.assert_eq(owner.pending(), false)
		helpers.assert_eq(save(), true, "the ordinary writer continues from the restored checkpoint")
		helpers.assert_eq(owner.revert(), false, "one commit reverts once")
	end)

	helpers.it("release forgets the inverse once the composition commits", function()
		local owner, _, _, files = fixture()
		helpers.assert_eq(owner.apply("clear"), true)
		local committed = files.config
		owner.release()
		helpers.assert_eq(owner.revert(), false)
		helpers.assert_eq(files.config, committed)
	end)

	helpers.it("reverts two owners of one checkpoint newest first, as a refused composition does", function()
		local first, _, state, files, _, prefs, save, _, original, new_owner = fixture()
		local second = new_owner("backup-second")
		helpers.assert_eq(first.apply("clear"), true)
		local between = files.config
		helpers.assert_eq(second.apply("recommended"), true)
		helpers.assert_eq(second.revert(), true)
		helpers.assert_eq(files.config, between)
		helpers.assert_eq(first.revert(), true, "the older owner still holds the reinstated revision")
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(state.layout_on_pause, "French")
		helpers.assert_eq(prefs.source_snapshot("config").content, original)
		helpers.assert_eq(first.pending(), false)
		helpers.assert_eq(save(), true, "the ordinary writer continues from the fully reverted checkpoint")
	end)

	helpers.it("a reinstated revision is forgotten once an ordinary save changes the checkpoint", function()
		local first, _, _, _, _, _, save, _, _, new_owner = fixture()
		local second = new_owner("backup-second")
		helpers.assert_eq(first.apply("clear"), true)
		helpers.assert_eq(second.apply("recommended"), true)
		helpers.assert_eq(second.revert(), true)
		helpers.assert_eq(save(), true)
		helpers.assert_eq(first.revert(), false, "an interleaved save is never overwritten by an old inverse")
	end)

	-- The maintainer retired the clear's question on 2026-09-30: a menu row
	-- and a composed request apply alike, and a caller still wiring a question
	-- port is refused rather than silently ignored.
	helpers.it("a clear applies at once and the owner refuses a question port", function()
		local owner, _, _, _, _, _, _, writes = fixture()
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_true(writes() > 0)
		local ok, err = pcall(function()
			return require("ui.menu.scoped_preferences").new({ scope = "keyboard_layout",
				confirm = function() return true end, admission = function() end, paused = function() end,
				backup_path = function() end, capture_preferences = function() end,
				checkpoint = { capture = function() end, replace = function() end, restore = function() end },
				runtime = { capture = function() end, apply = function() end, restore = function() end } })
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("asks no question", 1, true) ~= nil, tostring(err))
	end)
end)



helpers.describe("Number-row keyboard-layout scope ownership", function()
	helpers.it("keeps native restoration inert and sparse", function()
		local owner, Layout, state, files, _, _, _, _, original = fixture()
		helpers.assert_eq(Layout.DEFAULT_STATE.layout_number_row_mode, "native")
		helpers.assert_eq(owner.apply("recommended"), true)
		helpers.assert_eq(state.layout_number_row_mode, "native")
		helpers.assert_eq(files.config:find("direct_access_digits", 1, true), nil)
		helpers.assert_eq(owner.revert(), true)
		helpers.assert_eq(files.config, original)
	end)
	helpers.it("does not claim unsupported personal intent during a whole layout clear", function()
		for _, value in ipairs({ '"future-mode"', 'true', 'false', '0', '"true"', '{ future = 7 }', '["native"]' }) do
			for _, mode in ipairs({ "clear", "recommended" }) do
				local owner, _, state, files, _, _, _, writes, original = fixture(value)
				local previous = { layout_pause_switch_enabled = state.layout_pause_switch_enabled,
					layout_on_pause = state.layout_on_pause, layout_on_resume = state.layout_on_resume }
				helpers.assert_eq(owner.apply(mode), false)
				helpers.assert_eq(writes(), 0)
				helpers.assert_eq(files.config, original)
				helpers.assert_eq(files.backup, nil)
				helpers.assert_eq(state, previous, "refusal never reaches native scope application")
			end
		end
	end)
	helpers.it("restores all known choices to native without acquiring an emitter", function()
		for _, value in ipairs({ "native", "digits", "symbols" }) do
			local owner, Layout, state, files, _, _, _, _, original = fixture('"' .. value .. '"')
			helpers.assert_eq(owner.apply("recommended"), true)
			helpers.assert_eq(state.layout_number_row_mode, "native")
			helpers.assert_eq(files.config:find("direct_access_digits", 1, true), nil)
			helpers.assert_eq(Layout.scope_pending(), false)
			helpers.assert_eq(owner.revert(), true)
			helpers.assert_eq(files.config, original)
		end
	end)
	helpers.it("does not mistake absence in an existing file for a false legacy switch", function()
		local source = '[future]\nkeep = 9 # exact unrelated owner\n'
		local owner, _, state, files = fixture(nil, source)
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_eq(state.layout_number_row_mode, "native")
		helpers.assert_eq(files.config, source)
	end)

end)
