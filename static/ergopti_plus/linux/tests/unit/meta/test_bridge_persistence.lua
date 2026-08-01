--- tests/unit/meta/test_bridge_persistence.lua

--- ==============================================================================
--- MODULE: Bridge Handler TOML Persistence Spies
--- DESCRIPTION:
--- Characterization tests for the five UI bridge handlers that persist user
--- choices through the shared toml_codec.writer. Each test injects a capturing
--- fake writer into package.loaded BEFORE the handler is loaded, drives the
--- persisting action, and asserts the exact payload handed to the writer.
---
--- ROOT CAUSE ENCODED:
--- The existing ui.bridge_handlers suite only asserts each on_message return
--- value (result.saved == true, result.accepted == true, ...). A handler could
--- silently stop writing to disk, or write the wrong section/key/value, and
--- those tests would stay green. These spies lock the persistence contract: the
--- writer must be called, at the right path, with the right section/key/value.
--- Neutralise any writer.batch_write / writer.write call in a handler and the
--- matching assert_not_nil / assert_eq below turns red.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ====================================
-- ====================================
-- ======= 1/ Writer spy helper =======
-- ====================================
-- ====================================

--- Installs a capturing fake toml_codec.writer into package.loaded, loads the
--- handler fresh (so its lazy _writer cache resolves to the fake), runs the
--- caller's invocation, then restores the real writer. Returns the captured
--- call, or nil when the handler never persisted.
--- @param module_name string Dotted handler module to load under the spy.
--- @param invoke function Callback receiving the freshly loaded handler.
--- @return table|nil Captured { method, path, updates|data } or nil.
local function with_writer_spy(module_name, invoke)
	local captured = nil
	-- One fake fits every handler: batch_write (config.toml handlers) and write
	-- (hotstring group-file handlers) both capture their arguments.
	local fake = {
		batch_write = function(path, updates)
			captured = { method = "batch_write", path = path, updates = updates }
			return true
		end,
		write = function(path, data)
			captured = { method = "write", path = path, data = data }
			return true
		end,
	}
	local saved = package.loaded["toml_codec.writer"]
	package.loaded["toml_codec.writer"] = fake
	local ok, err = pcall(function()
		local handler = helpers.load_module(module_name)
		invoke(handler)
	end)
	-- Restore the real cache before asserting so a failure cannot leak the fake.
	package.loaded["toml_codec.writer"] = saved
	if not ok then error(err, 0) end
	return captured
end





-- ====================================
-- ====================================
-- ======= 2/ Persistence spies =======
-- ====================================
-- ====================================

helpers.describe("bridge handler TOML persistence", function()

	helpers.it("paths_editor_bridge.save persists {paths,key,value} via batch_write", function()
		local captured = with_writer_spy(
			"ui.paths_editor.bridge",
			function(handler)
				handler.on_message({ action = "save", key = "config_dir", value = "/tmp/test" }, {})
			end)
		helpers.assert_not_nil(captured, "save must reach the writer")
		helpers.assert_eq(captured.method, "batch_write")
		helpers.assert_eq(captured.updates, {
			{ section = "paths", key = "config_dir", value = "/tmp/test" },
		})
	end)

	helpers.it("prompt_editor_bridge.set_model persists {llm,model} via batch_write", function()
		local captured = with_writer_spy(
			"ui.prompt_editor.bridge",
			function(handler)
				handler.on_message({ action = "set_model", model = "llama3" }, {})
			end)
		helpers.assert_not_nil(captured, "set_model must reach the writer")
		helpers.assert_eq(captured.updates, {
			{ section = "llm", key = "model", value = "llama3" },
		})
	end)

	helpers.it("prompt_editor_bridge.save_prompt persists {llm,prompt} via batch_write", function()
		local captured = with_writer_spy(
			"ui.prompt_editor.bridge",
			function(handler)
				handler.on_message({ action = "save_prompt", title = "My Prompt" }, {})
			end)
		helpers.assert_not_nil(captured, "save_prompt must reach the writer")
		helpers.assert_eq(captured.updates, {
			{ section = "llm", key = "prompt", value = "My Prompt" },
		})
	end)

	helpers.it("onboarding_bridge layout step persists {script,layout} via batch_write", function()
		local captured = with_writer_spy(
			"ui.onboarding.bridge",
			function(handler)
				handler.on_message({ step = "layout", data = { layout = "azerty" } }, {})
			end)
		helpers.assert_not_nil(captured, "layout step must reach the writer")
		helpers.assert_eq(captured.updates, {
			{ section = "script", key = "layout", value = "azerty" },
		})
	end)

	helpers.it("hotstrings_config_bridge.add_hotstring persists the entry via write", function()
		local state = { config = { get_config_dir = function() return "/home/user/.config/ergopti/hotstrings" end } }
		local captured = with_writer_spy(
			"ui.hotstrings_config_window.bridge",
			function(handler)
				handler.on_message({ action = "add_hotstring", trigger = "btw", replacement = "by the way", group = "english" }, state)
			end)
		helpers.assert_not_nil(captured, "add_hotstring must reach the writer")
		helpers.assert_eq(captured.method, "write")
		helpers.assert_eq(captured.path, "/home/user/.config/ergopti/hotstrings/english.toml")
		helpers.assert_eq(captured.data.sections_order, { "english" })
		local entry = captured.data.sections.english.entries[1]
		helpers.assert_eq(entry.trigger, "btw")
		helpers.assert_eq(entry.output, "by the way")
	end)

	helpers.it("hotstring_editor_bridge.save persists the entry via write", function()
		local state = { config = { get_config_dir = function() return "/home/user/.config/ergopti/hotstrings" end } }
		local captured = with_writer_spy(
			"ui.hotstring_editor.bridge",
			function(handler)
				handler.on_message({ action = "save", trigger = "btw", replacement = "by the way", group = "english" }, state)
			end)
		helpers.assert_not_nil(captured, "save must reach the writer")
		helpers.assert_eq(captured.method, "write")
		helpers.assert_eq(captured.path, "/home/user/.config/ergopti/hotstrings/english.toml")
		local entry = captured.data.sections.english.entries[1]
		helpers.assert_eq(entry.trigger, "btw")
		helpers.assert_eq(entry.output, "by the way")
	end)

end)
