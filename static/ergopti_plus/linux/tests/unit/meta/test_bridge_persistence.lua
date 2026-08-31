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

	helpers.it("paths_editor_bridge makes the selected config directory authoritative", function()
		local saved_storage = package.loaded["adapters.storage"]
		local saved_paths = package.loaded["infra.config_paths"]
		local values = {}
		package.loaded["adapters.storage"] = {
			get = function(key, fallback)
				local value = values[key]
				if value == nil then return fallback end
				return value
			end,
			set = function(key, value) values[key] = value; return true end,
			delete = function(key) values[key] = nil; return true end,
		}
		package.loaded["infra.config_paths"] = nil
		local ok, err = pcall(function()
			local handler = helpers.load_module("ui.paths_editor.bridge")
			local pushed = {}
			local state = {
				config = { get_config_dir = function() return "/wrong/hotstrings-pack-dir" end },
				webview_manager = {
					eval_js = function(app, code)
						pushed[#pushed + 1] = { app = app, code = code }
						return true
					end,
					hide = function() return true end,
				},
				on_reload = function() return true end,
			}
			local initial = handler.on_message({ action = "ready" }, state)
			local ConfigPaths = require("infra.config_paths")
			helpers.assert_true(initial.pushed)
			helpers.assert_eq(initial.data.configDir, ConfigPaths.default_config_dir(),
				"the hotstring catalogue directory must not masquerade as the config root")
			helpers.assert_contains(pushed[1].code, "window.initData")
			local result = handler.on_message({
				action = "save", configDir = "/tmp/ergopti-custom/",
			}, state)
			helpers.assert_true(result.saved, "the bridge must report the storage acknowledgement")
			helpers.assert_eq(values["paths.config_dir"], "/tmp/ergopti-custom")
			helpers.assert_eq(ConfigPaths.config("config.toml"),
				"/tmp/ergopti-custom/config.toml",
				"the runtime resolver must consume the exact setting the bridge wrote")

			local reset = handler.on_message({ action = "save", configDir = "" }, state)
			helpers.assert_true(reset.saved, "an empty choice must restore the XDG default")
			helpers.assert_eq(values["paths.config_dir"], nil)
			helpers.assert_eq(ConfigPaths.get_config_dir(), ConfigPaths.default_config_dir())
		end)
		package.loaded["adapters.storage"] = saved_storage
		package.loaded["infra.config_paths"] = saved_paths
		package.loaded["ui.paths_editor.bridge"] = nil
		if not ok then error(err, 0) end
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

	-- The `add_hotstring` case that stood here was removed on 2026-08-05: the
	-- shared settings window has never sent that action, so it asserted a write
	-- path nothing could reach. Writing hotstrings is the editor's job, below.
	helpers.it("hotstring_editor_bridge.save writes the personal file, named by its stem", function()
		local state = { config = { get_config_dir = function() return "/home/user/.config/ergopti/hotstrings" end } }
		local captured = with_writer_spy(
			"ui.hotstring_editor.bridge",
			function(handler)
				handler.on_message({
					action = "save",
					data = {
						sections_order = { "english" },
						sections = { english = { description = "English", entries = {
							{ trigger = "btw", output = "by the way" },
						} } },
					},
				}, state)
			end)
		helpers.assert_not_nil(captured, "save must reach the writer")
		helpers.assert_eq(captured.method, "write")
		-- personal.toml, not <section>.toml. The loader groups by FILE STEM, so the
		-- filename decides which category these entries join; writing english.toml
		-- would invent a category the menu, the priority table and the settings
		-- window all know nothing about.
		helpers.assert_eq(captured.path, "/home/user/.config/ergopti/hotstrings/personal.toml")
		helpers.assert_eq(captured.data.sections_order, { "english" })
		local entry = captured.data.sections.english.entries[1]
		helpers.assert_eq(entry.trigger, "btw")
		helpers.assert_eq(entry.output, "by the way")
	end)

end)
