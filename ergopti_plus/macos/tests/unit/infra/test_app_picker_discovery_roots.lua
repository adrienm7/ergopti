--- tests/unit/infra/test_app_picker_discovery_roots.lua

--- ==============================================================================
--- MODULE: Application Discovery Root Completeness
--- DESCRIPTION:
--- Only validated directory roots and a known HOME can authorize a warm cache.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.app_picker_discovery_fixture")

helpers.describe("app_picker: complete discovery roots", function()
	helpers.it("delivers the exact cached HOME snapshot across logger reentry", function()
		with_picker(function(picker, state)
			picker.discover_apps(function() end)
			state.pending[1].callback(0, "/Applications/A.app\0")
			state.on_log = function(_, message)
				if message:find("Serving", 1, true) then
					state.on_log = nil
					state.home = "/other"
					picker.discover_apps(function() end)
					state.pending[2].callback(0, "/Applications/B.app\0")
				end
			end
			local received
			picker.discover_apps(function(rows) received = rows end)
			helpers.assert_eq(received[1].text, "A")
		end)
	end)

	helpers.it("does not duplicate the system root when HOME is the filesystem root", function()
		with_picker(function(picker, state)
			state.home = "/"
			picker.discover_apps(function() end)
			helpers.assert_eq(state.classified, { "/Applications", "/System/Applications" })
			helpers.assert_eq(state.pending[1].args[4], "-maxdepth")
		end)
	end)

	helpers.it("invalid HOME revokes pending publication authority", function()
		with_picker(function(picker, state)
			picker.discover_apps(function() end)
			state.home = nil
			local failed
			picker.discover_apps(function(_, success) failed = success end)
			helpers.assert_eq(failed, false)
			helpers.assert_eq(#state.pending, 1)
			state.pending[1].callback(0, "/Applications/Old.app\0")
			state.home = "/fixture"
			picker.discover_apps(function() end)
			helpers.assert_eq(#state.pending, 2, "a refused newer request must prevent obsolete cache publication")
		end)
	end)

	for _, mode in ipairs({ "missing_home", "empty_home", "relative_home", "file_root", "missing_system", "unreadable_system" }) do
		helpers.it("refuses " .. mode .. " and immediately retries after repair", function()
			with_picker(function(picker, state)
				if mode == "missing_home" then state.home = nil end
				if mode == "empty_home" then state.home = "" end
				if mode == "relative_home" then state.home = "relative" end
				if mode == "file_root" then state.status = "present"; state.detail = { mode = "file" } end
				if mode == "missing_system" then state.system_status = "absent" end
				if mode == "unreadable_system" then state.system_status = "error" end
				local results = {}
				picker.discover_apps(function(rows, success) results[#results + 1] = { rows = rows, success = success } end)
				helpers.assert_eq(#state.pending, 0)
				helpers.assert_eq(results, { { success = false } })
				state.home, state.status, state.system_status, state.detail = "/repaired", "present", "present", { mode = "directory" }
				picker.discover_apps(function(rows, success) results[#results + 1] = { rows = rows, success = success } end)
				helpers.assert_eq(#state.pending, 1)
				helpers.assert_eq(state.pending[1].args[4], "/repaired/Applications")
				state.pending[1].callback(0, "")
				helpers.assert_eq(results[2], { rows = {}, success = true })
			end)
		end)
	end

	for _, present in ipairs({ false, true }) do
		helpers.it("uses root-only link traversal with optional directory present=" .. tostring(present), function()
			with_picker(function(picker, state)
				state.home = "/a space/O'Brien"
				if present then state.status = "present" end
				local completed = 0
				local function done(_, success) helpers.assert_eq(success, true); completed = completed + 1 end
				picker.discover_apps(done)
				local expected = { "-H", "/Applications", "/System/Applications", "-maxdepth", "2", "-name", "*.app", "-not", "-name", ".*", "-print0" }
				if present then table.insert(expected, 4, state.home .. "/Applications") end
				helpers.assert_eq(state.pending[1].args, expected)
				state.pending[1].callback(0, "")
				picker.discover_apps(done)
				helpers.assert_eq(#state.pending, 1)
				helpers.assert_eq(completed, 2)
			end)
		end)
	end

	helpers.it("does not serve a warm snapshot from another HOME", function()
		with_picker(function(picker, state)
			state.status = "present"
			picker.discover_apps(function() end)
			state.pending[1].callback(0, "/Applications/A.app\0")
			state.home = "/other"
			local received
			picker.discover_apps(function(rows) received = rows end)
			helpers.assert_eq(#state.pending, 2)
			helpers.assert_nil(received)
			state.pending[2].callback(0, "/Applications/B.app\0")
			helpers.assert_eq(received[1].text, "B")
		end)
	end)
end)
