--- tests/unit/infra/test_app_picker_path_framing.lua

--- ==============================================================================
--- MODULE: Application Discovery Path Framing
--- DESCRIPTION:
--- Preserves pathname bytes and rejects incomplete subprocess records before use.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.app_picker_discovery_fixture")

local function complete_paths(scan, paths)
	local separator = "\n"
	for _, arg in ipairs(scan.args) do
		if arg == "-print0" then separator = "\0" end
	end
	scan.callback(0, table.concat(paths, separator) .. separator)
end

helpers.describe("app_picker: lossless path framing", function()
	for label, path in pairs({
		basename = "/Applications/Line\nBreak.app",
		parent = "/Applications/Parent\nFolder/Editor.app",
	}) do
		helpers.it("preserves LF in the " .. label .. " and the exact cached snapshot", function()
			with_picker(function(picker, state)
				local received, cached
				picker.discover_apps(function(rows, success)
					helpers.assert_eq(success, true)
					received = rows
				end)
				complete_paths(state.pending[1], { path })
				helpers.assert_eq(#received, 1)
				helpers.assert_eq(received[1].appPath, path)
				helpers.assert_eq(received[1].subText, path)
				helpers.assert_eq(received[1].text, label == "basename" and "Line\nBreak" or "Editor")
				picker.discover_apps(function(rows) cached = rows end)
				helpers.assert_true(rawequal(received, cached))
				helpers.assert_eq(#state.pending, 1)
			end)
		end)
	end

	helpers.it("hydrates exact mixed pathname bytes without trimming or phantom fragments", function()
		with_picker(function(picker, state)
			local paths = { "/Applications/Plain.app", "/Applications/Éditeur\t 100%.app",
				"/Applications/Line\nBreak.app" }
			local hydrated, received = {}, nil
			_G.hs.application.infoForBundlePath = function(path)
				hydrated[#hydrated + 1] = path
				return {}
			end
			picker.discover_apps(function(rows) received = rows end)
			complete_paths(state.pending[1], paths)
			helpers.assert_eq(hydrated, paths)
			helpers.assert_eq(#received, #paths)
		end)
	end)

	for index, output in ipairs({ "/Applications/Truncated.app",
		"/Applications/Complete.app\0/Applications/Truncated.app",
		"/Applications/Legacy.app\n" }) do
		helpers.it("refuses malformed framing before hydration and retries: " .. index, function()
			with_picker(function(picker, state)
				local receipts, hydrated = {}, 0
				_G.hs.application.infoForBundlePath = function() hydrated = hydrated + 1; return {} end
				local function receive(rows, success)
					receipts[#receipts + 1] = { rows = rows, success = success }
				end
				picker.discover_apps(receive)
				state.pending[1].callback(0, output)
				helpers.assert_eq(receipts, { { success = false } })
				helpers.assert_eq(hydrated, 0)
				local warned = false
				for _, log in ipairs(state.logs) do
					if log.level == "warn" and log.text:find("framing", 1, true) then warned = true end
				end
				helpers.assert_true(warned, "framing refusal must leave a diagnostic")
				picker.discover_apps(receive)
				helpers.assert_eq(#state.pending, 2)
				complete_paths(state.pending[2], { "/Applications/Recovered.app" })
				helpers.assert_eq(receipts[2].success, true)
				helpers.assert_eq(receipts[2].rows[1].appPath, "/Applications/Recovered.app")
			end)
		end)
	end
end)
