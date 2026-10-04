--- tests/unit/modules/keylogger/test_physical_capture.lua

--- Proves explicit capture ownership without activating a default boot path.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run

helpers.describe("dormant physical capture owner", function()
	helpers.it("initializes once without spawning or changing legacy accounting", function()
		with_capture(function(capture, observed, controls)
			helpers.assert_true(capture.init(controls.dependencies))
			helpers.assert_eq(capture.init(controls.dependencies), false)
			helpers.assert_eq(observed.spawns, {})
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)

	helpers.it("verifies the exact caller requirement and awaits native settlement before spawn", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			helpers.assert_true(capture.start(controls.options))
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_eq(observed.spawns, { { executable = "/usr/bin/codesign",
				arguments = { "--verify", "--strict", "-R", "=" .. controls.options.requirement, controls.options.executable } } })
			observed.tasks[1].done(0)
			helpers.assert_eq(#observed.spawns, 1, "Completion is not exact task settlement")
			observed.tasks[1].settle()
			helpers.assert_eq(#observed.spawns, 2)
			helpers.assert_eq(observed.spawns[2].executable, controls.options.executable)
			helpers.assert_eq(observed.spawns[2].arguments, { "--hs274-clock" })
			controls.clocked()
			helpers.assert_eq(observed.spawns[3].arguments, controls.options.arguments)
			controls.open()
			helpers.assert_eq(capture.status().state, "capturing")
			helpers.assert_eq(controls.mode.credit_source(), "stream")
		end)
	end)

	helpers.it("publishes only real receiver credits through the explicitly bound sink", function()
		with_capture(function(capture, observed, controls)
			controls.frames.batch = { version = 1, kind = "batch", coverage = "complete",
				incarnation = "production-fixture", lease = "7", records = {
					{ sequence = "1", device = "41", timestamp = "10", has_page = true, has_usage = true,
						page = 7, usage = 44, value = "1", has_cookie = true, cookie = 44 },
				} }
			capture.init(controls.dependencies)
			capture.start(controls.options)
			controls.verified()
			controls.open()
			observed.tasks[3].chunk(nil, "batch\n")
			helpers.assert_eq(observed.credits, { { capture = "production-fixture/7", device = "41",
				keycode = 49, app = "ObservedApp", timestamp = "2026-09-12 12:00:00.000" } })
			helpers.assert_eq(observed.writes[#observed.writes], "1\n")
			helpers.assert_eq(observed.errors, {})
		end)
	end)

	helpers.it("copies pending target arguments instead of trusting later caller mutation", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			capture.start(controls.options)
			controls.options.executable = "/different/executable"
			controls.options.arguments[1] = "different-command"
			controls.options.requirement = "different-requirement"
			controls.verified()
			controls.clocked()
			helpers.assert_eq(observed.spawns[3], { executable = "/owned/runtime/karabiner_cli",
				arguments = { "--hs274-capture", "25" } })
		end)
	end)

	helpers.it("refuses failed or incomplete identity verification without spawning capture", function()
		for _, outcome in ipairs({ "failed", "incomplete" }) do
			with_capture(function(capture, observed, controls)
				capture.init(controls.dependencies)
				capture.start(controls.options)
				local task = observed.tasks[1]
				if outcome == "failed" then task.done(1) end
				task.settle()
				helpers.assert_eq(capture.status().state, "unavailable")
				helpers.assert_eq(#observed.warnings, 1)
				helpers.assert_eq(observed.errors, {})
				helpers.assert_eq(#observed.spawns, 1)
				helpers.assert_eq(controls.mode.credit_source(), "gap")
			end)
		end
	end)

	helpers.it("awaits verifier start acceptance even after synchronous completion and settlement", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			controls.on_spawn = function(task)
				function task.start()
					task.done(0)
					task.settle()
					return false
				end
			end
			helpers.assert_eq(capture.start(controls.options), false)
			helpers.assert_eq(#observed.spawns, 1)
			helpers.assert_eq(capture.status().state, "failed")
			helpers.assert_eq(#observed.errors, 1)
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_true(capture.stop())
		end)
	end)

	helpers.it("maps unsupported versions to one unavailable warning without a retry or credit", function()
		for _, target in ipairs({ "opening", "baseline" }) do
			with_capture(function(capture, observed, controls)
				if target == "opening" then controls.frames.opened.version = 2
				else controls.frames.opened.baseline.version = 1 end
				capture.init(controls.dependencies)
				capture.start(controls.options)
				controls.verified()
				controls.open()
				local task = observed.tasks[3]
				task.chunk(nil, "opened\n")
				task.done(1)
				task.settle()
				helpers.assert_eq(capture.status().state, "unavailable")
				helpers.assert_eq(capture.status().reason, "unsupported_" .. target .. "_version")
				helpers.assert_eq(#observed.warnings, 1)
				helpers.assert_eq(observed.errors, {})
				helpers.assert_eq(observed.credits, {})
				helpers.assert_eq(observed.writes, {})
				helpers.assert_eq(#observed.spawns, 3)
				helpers.assert_eq(controls.mode.credit_source(), "gap")
				helpers.assert_eq(capture.start(controls.options), false)
				helpers.assert_true(capture.stop())
				helpers.assert_eq(controls.mode.credit_source(), "legacy")
			end)
		end
	end)

	helpers.it("refuses fixture-only coverage with one warning and no acknowledgement", function()
		with_capture(function(capture, observed, controls)
			controls.frames.opened.coverage = "fixture_only"
			capture.init(controls.dependencies)
			capture.start(controls.options)
			controls.verified()
			controls.open()
			helpers.assert_eq(capture.status().reason, "incomplete_coverage")
			helpers.assert_eq(#observed.warnings, 1)
			helpers.assert_eq(observed.errors, {})
			helpers.assert_eq(observed.writes, {})
			helpers.assert_eq(controls.mode.credit_source(), "gap")
		end)
	end)

	helpers.it("retains a verifier returned after cancellation during acquisition", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			-- Deliberately delayed prepared settlement is hostile callback hardening.
			controls.delay_prepared_settlement = true
			controls.on_spawn = function(task)
				if task.executable ~= "/usr/bin/codesign" then error("Cancelled verifier cannot spawn capture") end
				helpers.assert_eq(capture.stop(), false)
				task.done(0)
			end
			helpers.assert_eq(capture.start(controls.options), false)
			local task = observed.tasks[1]
			helpers.assert_eq(task.started, nil)
			helpers.assert_eq(task.stops, 1)
			helpers.assert_eq(capture.status().settled, false)
			helpers.assert_eq(capture.start(controls.options), false)
			task.settle()
			helpers.assert_eq(capture.status().state, "stopped")
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)

	helpers.it("settles an unstarted prepared verifier synchronously after acquisition cancellation", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			controls.on_spawn = function()
				helpers.assert_eq(capture.stop(), false, "Acquisition must still retain the unreturned handle")
			end
			helpers.assert_eq(capture.start(controls.options), false)
			helpers.assert_eq(#observed.spawns, 1)
			helpers.assert_eq(observed.tasks[1].started, nil)
			helpers.assert_eq(observed.tasks[1].stops, 1)
			helpers.assert_eq(capture.status().state, "stopped")
			helpers.assert_eq(capture.status().settled, true)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(observed.errors, {})
		end)
	end)

	helpers.it("accepts early verifier completion only after its returned task settles", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			controls.on_spawn = function(task) if task.executable == "/usr/bin/codesign" then task.done(0) end end
			helpers.assert_true(capture.start(controls.options))
			helpers.assert_eq(#observed.spawns, 1)
			observed.tasks[1].settle()
			helpers.assert_eq(#observed.spawns, 2)
		end)
	end)

	helpers.it("fences successor startup until a refusing verifier actually settles", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			capture.start(controls.options)
			local task = observed.tasks[1]
			task.refuse_stop = true
			helpers.assert_eq(capture.stop(), false)
			helpers.assert_eq(capture.start(controls.options), false)
			task.done(0)
			helpers.assert_eq(#observed.spawns, 1)
			helpers.assert_eq(capture.stop(), false)
			helpers.assert_eq(task.stops, 2)
			task.settle()
			helpers.assert_eq(capture.status().state, "stopped")
			helpers.assert_true(capture.start(controls.options))
			task.done(0)
			task.settle()
			helpers.assert_eq(#observed.spawns, 2, "A retired verifier cannot activate its successor")
		end)
	end)

	helpers.it("revokes stream accounting immediately and releases legacy only after settlement", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			capture.start(controls.options)
			controls.verified()
			controls.open()
			local task = observed.tasks[3]
			helpers.assert_eq(capture.stop(), false)
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_eq(capture.start(controls.options), false)
			task.chunk(nil, "opened\n")
			task.done(0)
			helpers.assert_eq(capture.status().settled, false)
			task.settle()
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_true(capture.stop())
			helpers.assert_eq(observed.errors, {})
		end)
	end)

	for _, phase in ipairs({ "select", "admit", "interrupt", "release" }) do
		helpers.it("latches cancellation during real " .. phase .. " settlement without recursive accounting", function()
			with_capture(function(capture, observed, controls)
				local selected_phase, cancellation
				helpers.assert_true(controls.mode.bind_settlement({}, function()
					if selected_phase == phase then
						cancellation = table.pack(pcall(capture.stop))
					end
					return true
				end))
				capture.init(controls.dependencies)
				selected_phase = "select"
				local started = capture.start(controls.options)
				if phase == "select" then
					helpers.assert_eq(started, false)
					helpers.assert_eq(observed.spawns, {})
					helpers.assert_eq(controls.mode.credit_source(), "legacy")
					helpers.assert_eq(capture.status().state, "stopped")
				else
					controls.verified()
					selected_phase = "admit"
					controls.open()
					if phase ~= "admit" then
						selected_phase = "interrupt"
						helpers.assert_eq(capture.stop(), false)
					end
					helpers.assert_eq(capture.status().state, "stopping")
					helpers.assert_eq(controls.mode.credit_source(), "gap")
					helpers.assert_eq(controls.mode.admitted_capture(), nil)
					helpers.assert_eq(observed.credits, {})
					selected_phase = "release"
					observed.tasks[3].settle()
					helpers.assert_eq(capture.status().state, "stopped")
					helpers.assert_eq(controls.mode.credit_source(), "legacy")
				end
				helpers.assert_eq(cancellation[1], true, "Settlement cancellation cannot attempt nested accounting")
				helpers.assert_eq(cancellation[2], false, "Cancellation remains pending until accounting unwinds")
				helpers.assert_eq(cancellation[3], "pending")
				helpers.assert_eq(observed.errors, {})
			end)
		end)
	end

	helpers.it("keeps a refused initial selection in legacy without releasing nonexistent ownership", function()
		with_capture(function(capture, observed, controls)
			local accept = false
			controls.mode.bind_settlement({}, function() return accept end)
			capture.init(controls.dependencies)
			helpers.assert_eq(capture.start(controls.options), false)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(observed.spawns, {})
			helpers.assert_true(capture.stop())
			accept = true
			helpers.assert_true(capture.start(controls.options))
		end)
	end)

	helpers.it("never substitutes early settlement for a successfully accepted verifier start", function()
		with_capture(function(capture, observed, controls)
			capture.init(controls.dependencies)
			controls.on_spawn = function(task)
				function task.onSettled(settled)
					task.done(0)
					settled()
					return true
				end
			end
			helpers.assert_eq(capture.start(controls.options), false)
			helpers.assert_eq(#observed.spawns, 1)
			helpers.assert_eq(observed.tasks[1].started, nil)
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_true(capture.stop())
		end)
	end)

	helpers.it("refuses already-settled handles regardless of their early completion code", function()
		for _, code in ipairs({ 0, 1 }) do
			with_capture(function(capture, observed, controls)
				capture.init(controls.dependencies)
				controls.on_spawn = function(task)
					task.done(code)
					task.state = "settled"
				end
				helpers.assert_eq(capture.start(controls.options), false)
				helpers.assert_eq(#observed.spawns, 1)
				helpers.assert_eq(observed.tasks[1].started, nil)
				helpers.assert_eq(controls.mode.credit_source(), "gap")
				helpers.assert_true(capture.stop())
			end)
		end
	end)
end)
