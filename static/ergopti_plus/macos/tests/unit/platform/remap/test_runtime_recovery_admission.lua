--- tests/unit/platform/remap/test_runtime_recovery_admission.lua

--- Native inert admission boundaries; frozen independent expectations.

local helpers = require("tests.helpers")
local fixture = require("tests.support.runtime_recovery_fixture")
local with_source, settled_scope, hold_settings = fixture.with_source, fixture.settled_scope, fixture.hold_settings
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'

helpers.describe("inert owned recovery local admission", function()
	helpers.it("refuses before actual local teardown", function()
		with_source(OWNED, function(remap)
			helpers.assert_nil(remap.runtime_recovery_admission())
		end)
	end)
	helpers.it("requires no acquisition and completed local teardown without shared effects", function()
		with_source(OWNED, function(remap, calls, _, read)
			local scope = settled_scope(remap)
			helpers.assert_eq(scope.current(), true)
			helpers.assert_eq(read(), OWNED)
			helpers.assert_eq(calls.lease_init, 0)
			helpers.assert_eq(calls.start, 0)
			helpers.assert_eq(calls.deploy, 0)
			helpers.assert_eq(calls.save, 0)
		end)
	end)
	helpers.it("refuses a token-bearing controller snapshot", function()
		with_source(OWNED, function(remap, _, lease)
			local scope = settled_scope(remap)
			lease.status = function() return "uninitialized", { phase = "uninitialized", token = "foreign" } end
			helpers.assert_eq(scope.current(), false)
			helpers.assert_nil(remap.runtime_recovery_admission())
		end)
	end)
	helpers.it("revokes after explicit stop intent without claiming STOPPED", function()
		with_source(OWNED, function(remap)
			local scope = settled_scope(remap)
			helpers.assert_eq(remap.stop_lease(function() end), true)
			helpers.assert_eq(scope.current(), false)
		end)
	end)
	helpers.it("rejects replacement of the published remap owner", function()
		with_source(OWNED, function(remap)
			local scope = settled_scope(remap)
			local original = package.loaded["platform.remap"]
			package.loaded["platform.remap"] = {}
			helpers.assert_eq(scope.current(), false)
			package.loaded["platform.remap"] = original
			helpers.assert_eq(scope.current(), false, "revocation must be sticky")
		end)
	end)
	helpers.it("rejects replacement of the public absence query", function()
		with_source(OWNED, function(remap)
			local scope = settled_scope(remap)
			remap.runtime_not_acquired = function() return true end
			helpers.assert_eq(scope.current(), false)
			helpers.assert_nil(remap.runtime_recovery_admission())
		end)
	end)
	helpers.it("refuses existing unsettled settings ownership", function()
		with_source(OWNED, function(remap)
			local scope = settled_scope(remap)
			hold_settings(remap)
			helpers.assert_eq(scope.current(), false)
			helpers.assert_nil(remap.runtime_recovery_admission())
		end)
	end)
	helpers.it("invalidates the old receipt when a later teardown refuses", function()
		with_source(OWNED, function(remap)
			local scope = settled_scope(remap)
			local watchers = require("platform.remap.watchers")
			watchers.stop_input_source_watcher = function() return false end
			helpers.assert_eq(remap.teardown_local(), false)
			helpers.assert_eq(scope.current(), false)
			helpers.assert_nil(remap.runtime_recovery_admission())
		end)
	end)
	helpers.it("retains a one-way local capability without mutation or native claims", function()
		with_source(OWNED, function(remap)
			local scope = settled_scope(remap)
			local changed = pcall(function() scope.current = function() return true end end)
			helpers.assert_eq(changed, false)
			helpers.assert_nil(scope.stopped)
			helpers.assert_nil(scope.ready)
			helpers.assert_nil(scope.reload_completed)
			helpers.assert_eq(scope.revoke(), true)
			helpers.assert_eq(scope.current(), false)
		end)
	end)
end)


-- Frozen independent boundaries: created before the corrective source.
helpers.describe("inert recovery exact owner boundaries", function()
	for _, name in ipairs({ "runtime_recovery_admission", "teardown_local", "stop_lease" }) do
		helpers.it("revokes after original public port replacement: " .. name, function()
			with_source(OWNED, function(remap)
				local scope = settled_scope(remap)
				local original = remap[name]
				remap[name] = function() return true end
				helpers.assert_eq(scope.current(), false)
				remap[name] = original
				helpers.assert_eq(scope.current(), false, "revocation remains sticky")
			end)
		end)
	end
	for _, owner in ipairs({ { "platform.remap.watchers", "stop_input_source_watcher" },
		{ "platform.remap.ke_lifecycle", "stop" } }) do
		helpers.it("revokes after actual teardown callback replacement: " .. owner[1], function()
			with_source(OWNED, function(remap)
				local scope = settled_scope(remap)
				local module = require(owner[1])
				module[owner[2]] = function() return true end
				helpers.assert_eq(scope.current(), false)
			end)
		end)
		helpers.it("revokes after loaded teardown owner replacement: " .. owner[1], function()
			with_source(OWNED, function(remap)
				local scope = settled_scope(remap)
				package.loaded[owner[1]] = {}
				helpers.assert_eq(scope.current(), false)
			end)
		end)
	end
	for _, field in ipairs({ "_running", "_shutdown_requested", "_enabled_preflight" }) do
		helpers.it("refuses incompatible private lifecycle: " .. field, function()
			with_source(OWNED, function(remap)
				local scope = settled_scope(remap)
				local found = false
				local value = field == "_enabled_preflight" and {} or field == "_running"
				for index = 1, 80 do
					local name = debug.getupvalue(remap.set_enabled, index)
					if name == field then debug.setupvalue(remap.set_enabled, index, value); found = true; break end
				end
				helpers.assert_eq(found, true, "original lifecycle cell must be reached")
				helpers.assert_eq(scope.current(), false)
			end)
		end)
	end
	helpers.it("refuses counterfeit controller status captured before initialization", function()
		with_source(OWNED, function(remap, _, lease)
			-- The original fixture supplies controller methods before M.init.
			helpers.assert_eq(remap.teardown_local(), true)
			helpers.assert_nil(remap.runtime_recovery_admission())
		end, nil, { counterfeit_controller = true })
	end)
	helpers.it("requires an actual owner witness for independently reacquired watchers", function()
		with_source(OWNED, function(remap)
			local scope = settled_scope(remap)
			local watchers = require("platform.remap.watchers")
			helpers.assert_eq(watchers.start_input_source_watcher(function() end), true)
			helpers.assert_eq(scope.current(), false, "a historical stop cannot admit reacquired consumers")
		end)
	end)
end)
