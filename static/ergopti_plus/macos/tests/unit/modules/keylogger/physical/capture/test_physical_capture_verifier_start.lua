--- tests/unit/modules/keylogger/physical/capture/test_physical_capture_verifier_start.lua

--- Keeps original verifier start frames owned through synchronous native settlement.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run

helpers.describe("physical verifier start frame retirement", function()
	for _, outcome in ipairs({ "accepted", "refused", "throws" }) do
		helpers.it("retains cancellation until verifier start unwinds when it " .. outcome, function()
			with_capture(function(capture, observed, controls)
				capture.init(controls.dependencies)
				local inside, snapshot, notifications, notified_inside = false, nil, 0, nil
				local observer = function(value)
					helpers.assert_eq(value, true)
					notifications = notifications + 1
					notified_inside = inside
				end
				controls.on_spawn = function(task)
					controls.on_spawn = nil
					function task.start()
						inside, task.started, task.state = true, true, "running"
						local stopped, status = capture.stop(observer)
						task.settle()
						snapshot = { stopped = stopped, status = status, settled = capture.status().settled,
							notifications = notifications, source = controls.mode.credit_source(),
							successor = capture.start(controls.options), tasks = #observed.tasks }
						inside = false
						if outcome == "throws" then error("Original verifier start refusal", 0) end
						return outcome == "accepted"
					end
				end
				helpers.assert_eq(capture.start(controls.options), false)
				helpers.assert_eq(snapshot, { stopped = false, status = "pending", settled = false,
					notifications = 0, source = "gap", successor = false, tasks = 1 })
				helpers.assert_eq(notifications, 1)
				helpers.assert_eq(notified_inside, false)
				helpers.assert_eq(capture.status(), { state = "stopped", settled = true })
				helpers.assert_eq(controls.mode.credit_source(), "legacy")
				helpers.assert_eq(capture.start(controls.options), true)
			end)
		end)
	end

	helpers.it("keeps exact history retirement unacknowledged during its verifier start frame", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			local scope, token, inside_settled, notifications = nil, nil, nil, 0
			local history_owner = {}
			controls.on_spawn = function(task)
				controls.on_spawn = nil
				function task.start()
					task.started, task.state = true, "running"
					local accepted
					accepted, scope = capture.bind_history_scope(history_owner)
					helpers.assert_eq(accepted, true)
					token = scope.identity()
					capture.stop(function() notifications = notifications + 1 end)
					task.settle()
					inside_settled = scope.settled(token)
					return true
				end
			end
			helpers.assert_eq(capture.start(controls.options), false)
			helpers.assert_eq(inside_settled, false)
			helpers.assert_eq(scope.settled(token), true)
			helpers.assert_eq(notifications, 1)
			helpers.assert_eq(scope.release(history_owner, token), true)
		end)
	end)

	helpers.it("clears a thrown start frame before later exact verifier retirement", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			controls.on_spawn = function(task)
				controls.on_spawn = nil
				function task.start()
					task.started, task.state = true, "running"
					error("Original verifier start refusal", 0)
				end
			end
			helpers.assert_eq(capture.start(controls.options), false)
			helpers.assert_eq(capture.status().state, "failed")
			local notifications = 0
			local stopped, status = capture.stop(function() notifications = notifications + 1 end)
			helpers.assert_eq(stopped, false)
			helpers.assert_eq(status, "pending")
			observed.tasks[1].settle()
			helpers.assert_eq(notifications, 1)
			helpers.assert_eq(capture.status(), { state = "stopped", reason = "capture_failed", settled = true })
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)
end)
