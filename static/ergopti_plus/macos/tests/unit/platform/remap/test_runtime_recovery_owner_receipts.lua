--- tests/unit/platform/remap/test_runtime_recovery_owner_receipts.lua

--- Actual native local owner generations, cancellation debt and original ports.
local helpers = require("tests.helpers")
helpers.with_stub_scope({ "platform.remap.watchers", "platform.remap.ke_lifecycle",
	"adapters.input_source_broker", "adapters.timer_scheduler" }, function()
	local function owner(name)
		local original = package.loaded[name]
		package.loaded[name] = nil
		local loaded = require(name)
		package.loaded[name] = original
		return loaded
	end
	-- Frozen before repair. Real owner bodies; all native fixture doubles remain explicit.
	helpers.describe("actual local owner teardown witnesses", function()
		for _, spec in ipairs({
			{ "platform.remap.watchers", "stop_input_source_watcher", "input_source_teardown_admission", "start_input_source_watcher" },
			{ "platform.remap.ke_lifecycle", "stop", "notification_teardown_admission", "notify_ready" },
		}) do
			helpers.it("refuses without successful stop: " .. spec[1], function()
				local loaded = owner(spec[1])
				package.loaded[spec[1]] = loaded
				helpers.assert_nil(loaded[spec[3]]())
			end)
			helpers.it("retains actual inert generation after stop: " .. spec[1], function()
				local loaded = owner(spec[1]); package.loaded[spec[1]] = loaded
				helpers.assert_eq(loaded[spec[2]](), true)
				local receipt = loaded[spec[3]]()
				helpers.assert_eq(type(receipt), "table")
				helpers.assert_eq(receipt.current(), true)
				helpers.assert_nil(receipt.ready); helpers.assert_nil(receipt.stopped)
			end)
			helpers.it("revokes before reacquisition entry: " .. spec[1], function()
				local loaded = owner(spec[1]); package.loaded[spec[1]] = loaded
				helpers.assert_eq(loaded[spec[2]](), true)
				local receipt = loaded[spec[3]]()
				pcall(loaded[spec[4]], function() end)
				helpers.assert_eq(receipt.current(), false)
			end)
			for _, port in ipairs({ spec[2], spec[3], spec[4] }) do
				helpers.it("revokes after public port replacement: " .. spec[1] .. "." .. port, function()
					local loaded = owner(spec[1]); package.loaded[spec[1]] = loaded
					helpers.assert_eq(loaded[spec[2]](), true)
					local receipt = loaded[spec[3]]()
					local original = loaded[port]; loaded[port] = function() return true end
					helpers.assert_eq(receipt.current(), false)
					loaded[port] = original; helpers.assert_eq(receipt.current(), false)
				end)
			end
		end
	end)

	helpers.describe("notification owner exact cancellation boundary", function()
		helpers.it("retains false native stop instead of issuing a retirement receipt", function()
			local owner = require("platform.remap.ke_lifecycle")
			local supplied = false
			for index = 1, 40 do
				local name = debug.getupvalue(owner.stop, index)
				if name == "_karabiner_ready_notify_timer" then
					debug.setupvalue(owner.stop, index, { stop = function() return false end })
					supplied = true; break
				end
			end
			helpers.assert_eq(supplied, true, "actual original timer owner must be reached")
			helpers.assert_eq(owner.stop(), false)
			helpers.assert_nil(owner.notification_teardown_admission())
		end)
	end)

	helpers.describe("local owner original native callback ports", function()
		for _, spec in ipairs({ { "adapters.input_source_broker", "unsubscribe" }, { "adapters.timer_scheduler", "cancel" } }) do
			helpers.it("revokes original watcher callback replacement: " .. spec[1], function()
				package.loaded["platform.remap.watchers"] = nil
				local owner = require("platform.remap.watchers")
				helpers.assert_eq(owner.stop_input_source_watcher(), true)
				local receipt = owner.input_source_teardown_admission()
				local adapter = require(spec[1]); local original = adapter[spec[2]]
				adapter[spec[2]] = function() return true end
				local current = receipt.current(); adapter[spec[2]] = original
				helpers.assert_eq(current, false)
				helpers.assert_eq(receipt.current(), false)
			end)
		end
		helpers.it("revokes original notification timer acquisition replacement", function()
			package.loaded["platform.remap.ke_lifecycle"] = nil
			local owner = require("platform.remap.ke_lifecycle")
			helpers.assert_eq(owner.stop(), true)
			local receipt = owner.notification_teardown_admission()
			local original = hs.timer.doAfter; hs.timer.doAfter = function() return {} end
			local current = receipt.current(); hs.timer.doAfter = original
			helpers.assert_eq(current, false)
			helpers.assert_eq(receipt.current(), false)
		end)
	end)

end)
