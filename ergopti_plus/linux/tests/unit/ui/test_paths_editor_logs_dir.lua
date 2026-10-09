--- tests/unit/ui/test_paths_editor_logs_dir.lua

--- ==============================================================================
--- MODULE: Paths Editor Logs Folder (Linux bridge)
--- DESCRIPTION:
--- The shared paths editor edits two folders: the configuration folder and the
--- logs folder (LogsDirPath, kept in bootstrap storage on this driver).
---
--- WHAT IS PINNED (paths-editor-logs-dir):
--- 1. The page receives the current and the default logs folder.
--- 2. Browsing for the logs folder answers the logs field.
--- 3. Saving stores the logs folder the resolver will use, and a page that
---    sends none keeps the stored one.
--- 4. A refused logs folder saves nothing: validating it after the
---    configuration folder was stored reported a failed save that had half
---    happened.
--- 5. A logs folder that cannot be created is refused before anything is
---    stored: the next start would fall back to stdout for it.
--- 6. A saved logs folder moves the running sink. The daemon outlives the
---    editor's reload, so without the move the lines kept going to the old
---    folder while every opener named the new one.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs `body` with an in-memory bootstrap store behind the real resolver.
--- @param stored table Initial storage values.
--- @param body function Receives (handler, state, values, pushed).
local function with_bridge(stored, body)
	local saved_storage = package.loaded["adapters.storage"]
	local saved_paths = package.loaded["infra.config_paths"]
	local saved_picker = package.loaded["ui.config_dir_picker"]
	local values = stored
	package.loaded["adapters.storage"] = {
		get = function(key, fallback)
			if values[key] == nil then return fallback end
			return values[key]
		end,
		set = function(key, value) values[key] = value; return true end,
		delete = function(key) values[key] = nil; return true end,
	}
	package.loaded["infra.config_paths"] = nil
	package.loaded["ui.config_dir_picker"] = {
		pick = function(_, _, _, current) return "/picked/from/" .. tostring(current) end,
	}
	package.loaded["ui.paths_editor.bridge"] = nil
	local ok, err = pcall(function()
		local handler = helpers.load_module("ui.paths_editor.bridge")
		local pushed = {}
		-- The running sink: a save must move it, since the daemon outlives
		-- this editor's reload.
		local sink = { moves = 0, prepared = {} }
		function sink.prepare_dir(dir)
			sink.prepared[#sink.prepared + 1] = dir
			if sink.prepare_result == false then return false, "the folder cannot be created" end
			return true
		end
		function sink.repoint()
			sink.moves = sink.moves + 1
			return sink.repoint_result ~= false, "the folder is not writable"
		end
		local state = {
			webview_manager = {
				eval_js = function(_, code)
					pushed[#pushed + 1] = code
					return true
				end,
				hide = function() return true end,
			},
			on_reload = function() return true end,
			logger_sink = sink,
		}
		body(handler, state, values, pushed)
	end)
	package.loaded["adapters.storage"] = saved_storage
	package.loaded["infra.config_paths"] = saved_paths
	package.loaded["ui.config_dir_picker"] = saved_picker
	package.loaded["ui.paths_editor.bridge"] = nil
	if not ok then error(err, 0) end
end

helpers.describe("paths editor: logs folder (paths-editor-logs-dir)", function()
	helpers.it("sends the current and the default logs folder", function()
		with_bridge({ ["paths.logs_dir"] = "/sync/ergopti_plus" }, function(handler, state)
			local result = handler.on_message({ action = "ready" }, state)
			local ConfigPaths = require("infra.config_paths")
			helpers.assert_eq(result.data.logsDir, "/sync/ergopti_plus")
			helpers.assert_eq(result.data.defaultLogsDir, ConfigPaths.default_logs_dir())
		end)
	end)

	helpers.it("answers a logs-folder browse on the logs field", function()
		with_bridge({ ["paths.logs_dir"] = "/sync/ergopti_plus" }, function(handler, state, _, pushed)
			local result = handler.on_message({ action = "browse", target = "logs" }, state)
			helpers.assert_true(result.picked == true)
			helpers.assert_eq(result.path, "/picked/from//sync/ergopti_plus")
			helpers.assert_contains(pushed[#pushed], "\"logs\")")
		end)
	end)

	helpers.it("stores the logs folder with the configuration folder", function()
		with_bridge({}, function(handler, state, values)
			local result = handler.on_message({
				action = "save", configDir = "/tmp/ergopti-custom/", logsDir = "/sync/logs",
			}, state)
			helpers.assert_true(result.saved == true)
			helpers.assert_eq(values["paths.logs_dir"], "/sync/logs/ergopti_plus")
			helpers.assert_eq(values["paths.config_dir"], "/tmp/ergopti-custom")
		end)
	end)

	helpers.it("keeps the stored logs folder when the page sends none", function()
		with_bridge({ ["paths.logs_dir"] = "/sync/ergopti_plus" }, function(handler, state, values)
			local result = handler.on_message({ action = "save", configDir = "" }, state)
			helpers.assert_true(result.saved == true)
			helpers.assert_eq(values["paths.logs_dir"], "/sync/ergopti_plus")
		end)
	end)

	helpers.it("refuses a relative logs folder before saving the configuration folder", function()
		with_bridge({}, function(handler, state, values)
			local result = handler.on_message({
				action = "save", configDir = "/tmp/ergopti-custom/", logsDir = "logs",
			}, state)
			helpers.assert_true(result.saved == false)
			helpers.assert_nil(values["paths.config_dir"], "a refused save must not half happen")
			helpers.assert_nil(values["paths.logs_dir"])
			helpers.assert_eq(state.logger_sink.moves, 0)
		end)
	end)

	helpers.it("moves the running sink to the saved logs folder", function()
		with_bridge({}, function(handler, state, values)
			local result = handler.on_message({ action = "save", configDir = "", logsDir = "/sync/logs" }, state)
			helpers.assert_true(result.saved == true)
			helpers.assert_eq(values["paths.logs_dir"], "/sync/logs/ergopti_plus")
			helpers.assert_eq(state.logger_sink.moves, 1, "the sink must follow the saved folder")
		end)
	end)

	helpers.it("creates the logs folder before storing it", function()
		with_bridge({}, function(handler, state)
			local result = handler.on_message({ action = "save", configDir = "", logsDir = "/sync/logs" }, state)
			helpers.assert_true(result.saved == true)
			helpers.assert_eq(state.logger_sink.prepared, { "/sync/logs/ergopti_plus" })
		end)
	end)

	helpers.it("refuses a logs folder that cannot be created and stores nothing", function()
		with_bridge({}, function(handler, state, values)
			state.logger_sink.prepare_result = false
			local result = handler.on_message({
				action = "save", configDir = "/tmp/ergopti-custom/", logsDir = "/sync/logs",
			}, state)
			helpers.assert_true(result.saved == false)
			helpers.assert_nil(values["paths.config_dir"], "a refused save must not half happen")
			helpers.assert_nil(values["paths.logs_dir"],
				"a folder the next start could not use is never stored")
			helpers.assert_eq(state.logger_sink.moves, 0)
		end)
	end)

	helpers.it("keeps the editor open when the sink cannot move to the saved folder", function()
		with_bridge({}, function(handler, state)
			state.logger_sink.repoint_result = false
			local result = handler.on_message({ action = "save", configDir = "", logsDir = "/sync/logs" }, state)
			helpers.assert_true(result.saved == false)
		end)
	end)

	helpers.it("leaves the sink alone when the page sends no logs folder", function()
		with_bridge({ ["paths.logs_dir"] = "/sync/ergopti_plus" }, function(handler, state)
			local result = handler.on_message({ action = "save", configDir = "" }, state)
			helpers.assert_true(result.saved == true)
			helpers.assert_eq(state.logger_sink.moves, 0)
		end)
	end)

	helpers.it("refuses a relative logs folder and keeps the editor open", function()
		with_bridge({}, function(handler, state, values)
			local result = handler.on_message({ action = "save", configDir = "", logsDir = "logs" }, state)
			helpers.assert_true(result.saved == false)
			helpers.assert_nil(values["paths.logs_dir"])
		end)
	end)
end)
