--- tests/unit/ui/test_menu_paths_logs_dir.lua

--- ==============================================================================
--- MODULE: Paths Editor — Logs Folder Field
--- DESCRIPTION:
--- The shared paths editor edits two folders: the configuration folder and the
--- logs folder (LogsDirPath), each shown with its default.
---
--- WHAT IS PINNED (paths-editor-logs-dir):
--- 1. The page receives the current and the default logs folder.
--- 2. Browsing for the logs folder answers the logs field, not the other one.
--- 3. Saving hands both folders to the one paths.toml writer in one call; a
---    page that sends no logs folder keeps the stored one.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_fixture = require("tests.support.paths_editor_fixture")

--- Opens the editor over the fixture and runs `callback` with its observations.
--- @param callback function Receives (calls, evaluations, pending).
local function with_editor(callback)
	helpers.with_fresh_modules({ "infra.deferred_work" }, function()
		local pending, evaluations = {}, {}
		package.loaded["infra.deferred_work"] = { after = function(_, fn)
			pending[#pending + 1] = fn
			return true
		end }
		local view = { delete = function() end }
		function view:evaluateJavaScript(code, done)
			evaluations[#evaluations + 1] = { code = code, done = done }
			return self
		end
		local editor, calls = load_fixture(view)
		helpers.assert_true(editor.init("/virtual/app/", function() return true end))
		helpers.assert_true(editor.open_editor())
		hs.osascript = { applescript = function() return true, "/Users/test/Sync/" end }
		callback(calls, evaluations, pending)
	end)
end

helpers.describe("paths editor: logs folder field (paths-editor-logs-dir)", function()
	helpers.it("sends the current and the default logs folder", function()
		with_editor(function(calls, evaluations)
			calls.bridge_callback({ body = { action = "ready" } })
			helpers.assert_eq(#evaluations, 1)
			local code = evaluations[1].code
			helpers.assert_contains(code, "/tmp/ergopti-logs/ergopti_plus/")
			helpers.assert_contains(code, "/Users/test/Library/Logs/ergopti_plus/")
			helpers.assert_contains(code, "paths_editor.label_logs_dir")
		end)
	end)

	helpers.it("answers a logs-folder browse on the logs field", function()
		with_editor(function(calls, evaluations, pending)
			calls.bridge_callback({ body = { action = "browse", target = "logs" } })
			pending[1]()
			pending[2]()
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_contains(evaluations[1].code, "window.applyBrowseResult(")
			helpers.assert_contains(evaluations[1].code, "\"logs\")")
		end)
	end)

	helpers.it("saves both folders through one writer call", function()
		with_editor(function(calls)
			calls.bridge_callback({ body = {
				action = "save", configDir = "/Users/test/cfg/", logsDir = "/Users/test/Sync/",
			} })
			helpers.assert_eq(calls.saved, { config = "/Users/test/cfg/", logs = "/Users/test/Sync/" })
		end)
	end)

	helpers.it("keeps the stored logs folder when the page sends none", function()
		with_editor(function(calls)
			calls.bridge_callback({ body = { action = "save", configDir = "/Users/test/cfg/" } })
			helpers.assert_eq(calls.saved, { config = "/Users/test/cfg/" })
		end)
	end)
end)
