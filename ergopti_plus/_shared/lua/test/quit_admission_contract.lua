--- _shared/lua/test/quit_admission_contract.lua

--- ==============================================================================
--- MODULE: Quit Admission Contract
--- DESCRIPTION:
--- Proves the one decision the macOS and Linux drivers share for the tray's
--- Quit: Quit wins over a reload in flight, a running configuration write or
--- publication is waited for within a bound, and only a missing owner or an
--- exit already under way refuses it, with the single user notification. Each
--- driver replays it and adds its own test that its owners feed the facts.
--- ==============================================================================

return function(helpers)
	local QuitAdmission = require("quit_admission")

	local function facts(overrides)
		local base = { owner_available = true, exit_pending = false, reload_pending = false,
			writer_active = false, publication_pending = false }
		for key, value in pairs(overrides or {}) do base[key] = value end
		return base
	end

	local function recording_ports()
		local record = { sent = {}, info = {}, warn = {} }
		return {
			send = function(text, level) record.sent[#record.sent + 1] = { text = text, level = level }; return true end,
			info = function(fmt, ...) record.info[#record.info + 1] = string.format(fmt, ...) end,
			warn = function(fmt, ...) record.warn[#record.warn + 1] = string.format(fmt, ...) end,
		}, record
	end

	--- Builds await ports over a fake clock and a manual scheduler.
	local function await_fixture(read_facts, overrides)
		local f = { clock = 0, queue = {}, admitted = {}, refused = {}, warns = {} }
		local ports = {
			facts = read_facts,
			now = function() return f.clock end,
			schedule = function(_, callback) f.queue[#f.queue + 1] = callback; return true end,
			timeout = 10, poll = 1,
			on_admitted = function(decision) f.admitted[#f.admitted + 1] = decision end,
			on_refused = function(decision) f.refused[#f.refused + 1] = decision end,
			warn = function(fmt, ...) f.warns[#f.warns + 1] = string.format(fmt, ...) end,
		}
		for key, value in pairs(overrides or {}) do ports[key] = value end
		f.ports = ports
		function f.tick(seconds)
			f.clock = f.clock + seconds
			local callback = table.remove(f.queue, 1)
			if callback then return callback() end
		end
		return f
	end

	helpers.describe("Quit admission", function()
		helpers.it("admits a quit when nothing owns the process", function()
			helpers.assert_eq(QuitAdmission.decide(facts()), { admitted = true, abandon_reload = false })
		end)

		helpers.it("lets Quit win over a reload in flight by abandoning the reload", function()
			helpers.assert_eq(QuitAdmission.decide(facts({ reload_pending = true })),
				{ admitted = true, abandon_reload = true })
		end)

		helpers.it("refuses a missing owner and an exit already under way", function()
			local missing = QuitAdmission.decide(facts({ owner_available = false }))
			helpers.assert_eq({ missing.admitted, missing.deferred, missing.cause },
				{ false, nil, "owner_unavailable" })
			local exiting = QuitAdmission.decide(facts({ exit_pending = true, reload_pending = true }))
			helpers.assert_eq({ exiting.admitted, exiting.deferred, exiting.cause },
				{ false, nil, "exit_pending" })
		end)

		helpers.it("defers, never refuses, for a running writer or publication", function()
			for name, cause in pairs({ writer_active = "writer_active", publication_pending = "publication_pending" }) do
				local decision = QuitAdmission.decide(facts({ [name] = true, reload_pending = true }))
				helpers.assert_eq({ decision.admitted, decision.deferred, decision.cause },
					{ false, true, cause }, name)
				helpers.assert_eq(type(decision.message), "string")
			end
		end)

		helpers.it("names the first cause when several apply", function()
			local all = facts({ owner_available = false, exit_pending = true, writer_active = true,
				publication_pending = true })
			helpers.assert_eq(QuitAdmission.decide(all).cause, "owner_unavailable")
			all.owner_available = true
			helpers.assert_eq(QuitAdmission.decide(all).cause, "exit_pending")
			all.exit_pending = false
			helpers.assert_eq(QuitAdmission.decide(all).cause, "writer_active")
			all.writer_active = false
			helpers.assert_eq(QuitAdmission.decide(all).cause, "publication_pending")
		end)

		helpers.it("rejects a missing or non-boolean fact instead of guessing", function()
			for _, name in ipairs(QuitAdmission.FACTS) do
				local incomplete = facts()
				for _, value in ipairs({ "missing", "no" }) do
					incomplete[name] = value ~= "missing" and value or nil
					local ok, err = pcall(QuitAdmission.decide, incomplete)
					helpers.assert_true(not ok and tostring(err):find("'" .. name .. "'", 1, true) ~= nil,
						name .. " as " .. value .. ": " .. tostring(err))
				end
			end
			local ok, err = pcall(QuitAdmission.decide, nil)
			helpers.assert_true(not ok and tostring(err):find("needs its facts", 1, true) ~= nil, tostring(err))
		end)

		helpers.it("logs the cause then sends the one quit refusal notice", function()
			local ports, record = recording_ports()
			local decision = QuitAdmission.decide(facts({ exit_pending = true }))
			QuitAdmission.refuse(ports, function(key) return "T:" .. key end, decision)
			helpers.assert_eq(record.warn[1], decision.message)
			helpers.assert_eq(record.sent, { { text = "T:notify.quit_refused", level = "error" } })
		end)

		helpers.it("refuses to report an admitted decision as a refusal", function()
			local ports = recording_ports()
			local admitted = QuitAdmission.decide(facts())
			local ok, err = pcall(QuitAdmission.refuse, ports, function() return "" end, admitted)
			helpers.assert_true(not ok and tostring(err):find("refused decision", 1, true) ~= nil, tostring(err))
		end)
	end)

	helpers.describe("Quit admission: waiting for a running write", function()
		helpers.it("starts at once when nothing is running", function()
			local f = await_fixture(function() return facts() end)
			helpers.assert_eq(QuitAdmission.await(f.ports), "admitted")
			helpers.assert_eq(#f.admitted, 1)
			helpers.assert_eq(#f.queue, 0)
		end)

		helpers.it("waits for the write to finish, then starts once", function()
			local state = facts({ writer_active = true, reload_pending = true })
			local f = await_fixture(function() return state end)
			helpers.assert_eq(QuitAdmission.await(f.ports), "waiting")
			helpers.assert_eq(#f.admitted + #f.refused, 0)
			f.tick(1)
			helpers.assert_eq(#f.admitted + #f.refused, 0, "still running: still waiting")
			state.writer_active = false
			helpers.assert_eq(f.tick(1), "admitted")
			helpers.assert_eq(#f.admitted, 1)
			helpers.assert_eq(f.admitted[1].abandon_reload, true)
			helpers.assert_eq(#f.warns, 1, "the wait is logged once")
		end)

		helpers.it("gives up with a timed-out refusal once the bound passes", function()
			local f = await_fixture(function() return facts({ publication_pending = true }) end)
			QuitAdmission.await(f.ports)
			f.tick(5)
			helpers.assert_eq(#f.refused, 0)
			helpers.assert_eq(f.tick(5), "refused")
			helpers.assert_eq(#f.admitted, 0)
			helpers.assert_eq({ f.refused[1].cause, f.refused[1].timed_out }, { "publication_pending", true })
		end)

		helpers.it("refuses at once when no poll timer can be armed", function()
			local f = await_fixture(function() return facts({ writer_active = true }) end,
				{ schedule = function() return false end })
			helpers.assert_eq(QuitAdmission.await(f.ports), "refused")
			helpers.assert_eq(f.refused[1].timed_out, true)
		end)

		helpers.it("refuses an exit already under way without waiting", function()
			local f = await_fixture(function() return facts({ exit_pending = true }) end)
			helpers.assert_eq(QuitAdmission.await(f.ports), "refused")
			helpers.assert_eq(#f.queue, 0)
			helpers.assert_eq(f.refused[1].timed_out, nil)
		end)

		helpers.it("needs positive bounds and every port", function()
			local f = await_fixture(function() return facts() end, { timeout = 0 })
			local ok, err = pcall(QuitAdmission.await, f.ports)
			helpers.assert_true(not ok and tostring(err):find("timeout", 1, true) ~= nil, tostring(err))
			f = await_fixture(function() return facts() end, { on_refused = false })
			ok, err = pcall(QuitAdmission.await, f.ports)
			helpers.assert_true(not ok and tostring(err):find("on_refused", 1, true) ~= nil, tostring(err))
		end)
	end)
end
