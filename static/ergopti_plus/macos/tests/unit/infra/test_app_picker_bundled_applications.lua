--- tests/unit/infra/test_app_picker_bundled_applications.lua

--- ==============================================================================
--- MODULE: Bundled macOS Application Discovery
--- DESCRIPTION:
--- Supported macOS versions keep Apple applications in a separate system tree.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.app_picker_discovery_fixture")

helpers.describe("app_picker: bundled application roots", function()
	helpers.it("discovers system applications and Utilities, then reuses the exact complete snapshot", function()
		with_picker(function(picker, state)
			state.status = "present"
			local received, cached
			picker.discover_apps(function(rows, success)
				helpers.assert_eq(success, true)
				received = rows
			end)
			local scan = state.pending[1]
			local has_bundled_root = false
			for _, arg in ipairs(scan.args) do
				if arg == "/System/Applications" then has_bundled_root = true end
			end
			scan.callback(0, has_bundled_root
				and "/System/Applications/TextEdit.app\n/System/Applications/Utilities/Terminal.app\n" or "")
			helpers.assert_eq(#received, 2)
			helpers.assert_eq(received[1].appPath, "/System/Applications/Utilities/Terminal.app")
			helpers.assert_eq(received[2].text, "TextEdit")
			helpers.assert_eq(scan.args, { "-H", "/Applications", "/System/Applications", "/fixture/Applications",
				"-maxdepth", "2", "-name", "*.app", "-not", "-name", ".*" })
			picker.discover_apps(function(rows, success) helpers.assert_eq(success, true); cached = rows end)
			helpers.assert_true(rawequal(cached, received), "cache must deliver the complete original snapshot")
			helpers.assert_eq(#state.pending, 1)
		end)
	end)

	for _, mode in ipairs({ "absent", "error", "file" }) do
		helpers.it("refuses an invalid bundled root: " .. mode, function()
			with_picker(function(picker, state)
				if mode == "file" then state.bundled_detail = { mode = "file" }
				else state.bundled_status = mode end
				local result
				picker.discover_apps(function(_, success) result = success end)
				helpers.assert_eq(#state.pending, 0)
				helpers.assert_eq(result, false)
				state.bundled_status, state.bundled_detail = "present", { mode = "directory" }
				picker.discover_apps(function(_, success) result = success end)
				helpers.assert_eq(#state.pending, 1)
				state.pending[1].callback(0, "/System/Applications/TextEdit.app\n")
				helpers.assert_eq(result, true)
			end)
		end)
	end

	helpers.it("does not enumerate a required root twice when HOME resolves to System", function()
		with_picker(function(picker, state)
			state.home = "/System/"
			picker.discover_apps(function() end)
			helpers.assert_eq(state.classified, { "/Applications", "/System/Applications" })
			helpers.assert_eq(state.pending[1].args[4], "-maxdepth")
		end)
	end)
end)
