--- tests/unit/ui/menu/llm/test_profile_editor_configuration_owner.lua

--- ==============================================================================
--- MODULE: Profile Editor Configuration Ownership (Linux)
--- DESCRIPTION:
--- A draft opened by the real tray menu must not become a write to a successor
--- configuration, even when both files have identical bytes.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.menu.llm.numeric_configuration_fixture")

local function find(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local found = find(row.menu, title)
		if found then return found end
	end
end

local function with_profile(body)
	Fixture.with_configuration(function(f)
		local profiles = require("modules.llm.profile_settings")
		assert(profiles.save_user_profile({ id = "user_owned", label = "Owned draft",
			system_single = "Original prompt", batch = false }, false, false))
		local baseline = f.bytes("a")
		local file = assert(io.open(f.dirs.b .. "/config.toml", "wb"))
		assert(file:write(baseline)); assert(file:close())
		local bridge = helpers.load_module("ui.prompt_editor.bridge")
		local i18n = require("infra.i18n")
		local rows = require("ui.menu.menu_builder").build({
			_version = "0.0.0-dev.12", paused = false, is_paused = function() return false end,
			llm = { is_enabled = function() return true end, get_live = function() return nil end,
				set_live = function() return true end }, webview = f.host,
		})
		local parent = assert(find(rows, "Owned draft"), "the real custom profile row exists")
		local edit = assert(find(parent.menu, i18n.get("menu.profiles.edit_profile")))
		assert(type(edit.fn) == "function")
		f.select = assert(find(parent.menu, i18n.get("menu.profiles.use_profile"))).fn
		local remove = assert(find(parent.menu, i18n.get("menu.profiles.delete_profile"))).fn
		function f.delete(during_confirmation)
			local execute, confirmations = os.execute, 0
			os.execute = function(command)
				if command == "command -v zenity >/dev/null 2>&1" then return 0 end
				if command:match("^zenity %-%-question ") then
					confirmations = confirmations + 1
					if during_confirmation then during_confirmation() end
					return 0
				end
				return execute(command)
			end
			local okay, result = pcall(remove)
			os.execute = execute
			if not okay then error(result, 0) end
			return result, confirmations
		end
		local function open(kind)
			local action = edit
			if kind then action = assert(find(rows, i18n.get("menu.profiles." .. kind))) end
			action.fn()
			local context = { app_name = "prompt_editor", epoch = f.host.current_epoch("prompt_editor"),
				close_owned_window = function() return f.host.hide("prompt_editor") end }
			local state = { webview_manager = f.host }
			local ready = bridge.on_message({ action = "ready" }, state, context)
			if not ready then return nil end
			assert(ready.pushed)
			return function()
				return bridge.on_message({ action = "save", edit_id = ready.data.edit_id,
					epoch = ready.data.epoch, name = "Edited draft", prompt = "Edited prompt", batch = false }, state, context)
			end
		end
		body(f, baseline, open, profiles)
	end)
end

helpers.describe("profile editor originating configuration", function()
	helpers.it("saves a draft in its unchanged opening folder (profile-editor-root-owner)", function()
		with_profile(function(f, baseline, open)
			helpers.assert_eq(assert(open())(), { saved = true, closed = true })
			helpers.assert_true(f.bytes("a") ~= baseline)
			helpers.assert_eq(f.bytes("b"), baseline)
		end)
	end)
	helpers.it("refuses a draft after the paths editor selects a byte-identical folder (profile-editor-root-owner)", function()
		with_profile(function(f, baseline, open)
			local save = assert(open()); f.switch("b")
			helpers.assert_eq(save(), { saved = false, closed = false })
			helpers.assert_eq(f.bytes("a"), baseline); helpers.assert_eq(f.bytes("b"), baseline)
		end)
	end)
	helpers.it("refuses a stale menu edit before opening in the successor folder (profile-editor-root-owner)", function()
		with_profile(function(f, baseline, open)
			f.switch("b")
			helpers.assert_nil(open())
			helpers.assert_eq(f.bytes("a"), baseline); helpers.assert_eq(f.bytes("b"), baseline)
		end)
	end)
	for _, kind in ipairs({ "create_profile", "clone_builtin" }) do
		helpers.it("saves " .. kind .. " in its unchanged folder (profile-editor-root-owner)", function()
			with_profile(function(f, baseline, open)
				helpers.assert_eq(assert(open(kind))(), { saved = true, closed = true })
				helpers.assert_true(f.bytes("a") ~= baseline); helpers.assert_eq(f.bytes("b"), baseline)
			end)
		end)
		helpers.it("refuses " .. kind .. " after folder replacement (profile-editor-root-owner)", function()
			with_profile(function(f, baseline, open)
				local save = assert(open(kind)); f.switch("b")
				helpers.assert_eq(save(), { saved = false, closed = false })
				helpers.assert_eq(f.bytes("a"), baseline); helpers.assert_eq(f.bytes("b"), baseline)
			end)
		end)
	end
	helpers.it("refuses a changed opening source while its folder stays selected (profile-editor-root-owner)", function()
		with_profile(function(f, baseline, open)
			local save = assert(open())
			assert(f.preferences.set("llm.generation.context_length", 1800))
			local changed = f.bytes("a")
			helpers.assert_eq(save(), { saved = false, closed = false })
			helpers.assert_eq(f.bytes("a"), changed); helpers.assert_eq(f.bytes("b"), baseline)
		end)
	end)
	helpers.it("refuses a cooperative source ABA (profile-editor-root-owner)", function()
		with_profile(function(f, baseline, open)
			local save = assert(open())
			assert(f.preferences.set("llm.generation.temperature", 0.8))
			assert(f.preferences.set("llm.generation.temperature", 0.7))
			local changed = f.bytes("a")
			helpers.assert_eq(save(), { saved = false, closed = false })
			helpers.assert_eq(f.bytes("a"), changed); helpers.assert_eq(f.bytes("b"), baseline)
		end)
	end)
	helpers.it("rechecks its root at the original conditional writer (profile-editor-root-owner)", function()
		with_profile(function(f, baseline, open)
			local save = assert(open())
			local original, switched = f.writer.batch_write, false
			f.writer.batch_write = function(...)
				if not switched then switched = true; f.switch("b") end
				return original(...)
			end
			local okay, err = pcall(function()
				helpers.assert_eq(save(), { saved = false, closed = false })
				helpers.assert_true(switched, "the original writer boundary was reached")
				helpers.assert_eq(f.bytes("a"), baseline); helpers.assert_eq(f.bytes("b"), baseline)
			end)
			f.writer.batch_write = original
			if not okay then error(err, 0) end
		end)
	end)
	helpers.it("refuses a replacement persistence port without calling it (profile-editor-root-owner)", function()
		with_profile(function(f, baseline, open)
			local save = assert(open())
			local called = 0
			f.preferences.set_many = function() called = called + 1; return true end
			helpers.assert_eq(save(), { saved = false, closed = false })
			helpers.assert_eq(called, 0)
			helpers.assert_eq(f.bytes("a"), baseline); helpers.assert_eq(f.bytes("b"), baseline)
		end)
	end)
	for _, action in ipairs({ "select", "delete" }) do
		helpers.it("commits " .. action .. " in its unchanged menu folder (profile-menu-root-owner)", function()
			with_profile(function(f, baseline)
				local committed, confirmations = f[action]()
				helpers.assert_eq(committed, true)
				if action == "delete" then helpers.assert_eq(confirmations, 1) end
				helpers.assert_true(f.bytes("a") ~= baseline); helpers.assert_eq(f.bytes("b"), baseline)
			end)
		end)
		helpers.it("refuses stale " .. action .. " after folder replacement (profile-menu-root-owner)", function()
			with_profile(function(f, baseline)
				f.switch("b")
				helpers.assert_eq(f[action](), false)
				helpers.assert_eq(f.bytes("a"), baseline); helpers.assert_eq(f.bytes("b"), baseline)
			end)
		end)
		helpers.it("rechecks " .. action .. " at the original conditional writer (profile-menu-root-owner)", function()
			with_profile(function(f, baseline)
				local original, switched = f.writer.batch_write, false
				f.writer.batch_write = function(...)
					if not switched then switched = true; f.switch("b") end
					return original(...)
				end
				local okay, err = pcall(function()
					helpers.assert_eq(f[action](), false)
					helpers.assert_true(switched, "the original conditional writer was reached")
					helpers.assert_eq(f.bytes("a"), baseline); helpers.assert_eq(f.bytes("b"), baseline)
				end)
				f.writer.batch_write = original
				if not okay then error(err, 0) end
			end)
		end)
	end
	helpers.it("refuses Delete after the actual modal confirmation changes folders (profile-menu-root-owner)", function()
		with_profile(function(f, baseline)
			local deleted, confirmations = f.delete(function() f.switch("b") end)
			helpers.assert_eq(confirmations, 1, "the original Modal confirmation was reached")
			helpers.assert_eq(deleted, false)
			helpers.assert_eq(f.bytes("a"), baseline); helpers.assert_eq(f.bytes("b"), baseline)
		end)
	end)
end)
