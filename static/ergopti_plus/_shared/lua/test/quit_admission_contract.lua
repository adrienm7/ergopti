--- _shared/lua/test/quit_admission_contract.lua

--- ==============================================================================
--- MODULE: Quit Admission Contract
--- DESCRIPTION:
--- Proves the one decision the macOS and Linux drivers share for refusing the
--- tray's Quit: which facts refuse it, in which order, the log line of each
--- cause, and the single user notification that follows. Each driver replays it
--- and adds its own test that its owners feed the facts.
--- ==============================================================================

return function(helpers)
	local QuitAdmission = require("quit_admission")

	local function facts(overrides)
		local base = { owner_available = true, terminal_pending = false, writer_active = false,
			publication_pending = false }
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

	helpers.describe("Quit admission", function()
		helpers.it("admits a quit when nothing owns the process", function()
			helpers.assert_eq(QuitAdmission.decide(facts()), { admitted = true })
		end)

		helpers.it("refuses with the cause of each fact", function()
			local cases = {
				{ { owner_available = false }, "owner_unavailable" },
				{ { terminal_pending = true }, "terminal_pending" },
				{ { writer_active = true }, "writer_active" },
				{ { publication_pending = true }, "publication_pending" },
			}
			for _, case in ipairs(cases) do
				local decision = QuitAdmission.decide(facts(case[1]))
				helpers.assert_eq(decision.admitted, false)
				helpers.assert_eq(decision.cause, case[2])
				helpers.assert_eq(type(decision.message), "string")
			end
		end)

		helpers.it("names the first cause when several apply", function()
			local all = facts({ owner_available = false, terminal_pending = true, writer_active = true,
				publication_pending = true })
			helpers.assert_eq(QuitAdmission.decide(all).cause, "owner_unavailable")
			all.owner_available = true
			helpers.assert_eq(QuitAdmission.decide(all).cause, "terminal_pending")
			all.terminal_pending = false
			helpers.assert_eq(QuitAdmission.decide(all).cause, "writer_active")
			all.writer_active = false
			helpers.assert_eq(QuitAdmission.decide(all).cause, "publication_pending")
		end)

		helpers.it("gives every cause its own log line", function()
			local seen = {}
			for _, name in ipairs({ "terminal_pending", "writer_active", "publication_pending" }) do
				local message = QuitAdmission.decide(facts({ [name] = true })).message
				helpers.assert_true(seen[message] == nil, "two causes share the line: " .. message)
				seen[message] = true
			end
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
			local decision = QuitAdmission.decide(facts({ writer_active = true }))
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
end
