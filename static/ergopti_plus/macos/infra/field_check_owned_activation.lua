--- infra/field_check_owned_activation.lua

--- ==============================================================================
--- MODULE: Field Check Of The Owned Runtime Activation Rule
--- DESCRIPTION:
--- The developer field run's proof, on the maintainer's Mac and with no manual
--- action, of the maintainer's rule for Ergopti's own Karabiner runtime
--- (ADR 011; platform/remap/runtime_activation.lua):
--- 1. artifact: the pinned runtime artifact is downloaded and verified into
---    Ergopti's own folder, or was already;
--- 2. off_inactive: with Tap-Hold off, Ergopti's runtime is not active;
--- 3. on_active: with Tap-Hold on, Ergopti's runtime is ready (or the owner's
---    named reason why not);
--- 4. on_closed_other: a user Karabiner that ran with Tap-Hold off is closed
---    with Tap-Hold on, and the close is recorded;
--- 5. off_restored: turning Tap-Hold off again gives that Karabiner back and
---    clears the record.
---
--- FEATURES & RATIONALE:
--- 1. Self-Restoring: unlike the read-only Debug checks, this one changes the
---    Tap-Hold switch, so it always ends by writing back the value it found,
---    even after a failing step. Every wait is bounded by M.WAIT_SEC.
--- 2. Skips Honestly: a boot on the shared runtime skips every step with
---    `shared_runtime`; a Mac without a running user Karabiner skips the close
---    and restore steps with `no_user_karabiner`, never passes them.
--- 3. Ports Only: every fact and effect comes through `ports.owned_activation`
---    (adapters/field_check_ports.lua), so the portable suite drives each step.
--- 4. Tokens Only: states, counts and reason tokens; no path or URL is reported.
--- ==============================================================================

local M = {}

--- Seconds between two looks while a transition settles.
M.POLL_SEC = 0.5
--- Seconds one transition may take: the owner's own readiness timeout (30 s)
--- plus the closer's exit wait (10 s), with a margin.
M.WAIT_SEC = 45

local ACTIVE = { starting = true, admitted = true, peers_starting = true, ready = true, stopping = true }
local SETTLED_ON = { ready = true, unavailable = true, failed = true }

--- Runs the check.
--- @param ports table Field check ports; uses `owned_activation` and `after`.
--- @param report table Step reporter.
--- @param finish function Settles the check.
function M.run(ports, report, finish)
	local port = ports.owned_activation
	if type(port) ~= "table" or port.selected() ~= true then
		for _, id in ipairs({ "artifact", "off_inactive", "on_active", "on_closed_other", "off_restored" }) do
			report.step(id, "skip", "shared_runtime")
		end
		return finish()
	end
	local initial = port.tap_holds() == true

	--- Writes back the switch the check found, then settles once.
	local function done()
		if port.tap_holds() ~= initial then port.set_tap_holds(initial) end
		report.step("tap_holds_restored", port.tap_holds() == initial and "pass" or "fail", initial and "on" or "off")
		finish()
	end

	--- Polls until `settled(state)` holds or the wait ends.
	local function wait_for(settled, callback, waited)
		waited = waited or 0
		local state = port.owner_state()
		if settled(state) or waited >= M.WAIT_SEC then return callback(state, settled(state)) end
		ports.after(M.POLL_SEC, function() wait_for(settled, callback, waited + M.POLL_SEC) end)
	end

	--- Counts the running user Karabiner, as a token when unreadable.
	local function others(callback)
		port.other_active(function(count) callback(count) end)
	end

	port.fetch(function(ok, value)
		report.step("artifact", ok and "pass" or "fail", ok and "verified" or tostring(value))
		if not ok then
			for _, id in ipairs({ "off_inactive", "on_active", "on_closed_other", "off_restored" }) do
				report.step(id, "skip", "no_artifact")
			end
			return done()
		end
		port.set_tap_holds(false)
		wait_for(function(state) return not ACTIVE[state] end, function(off_state, off_settled)
			report.step("off_inactive", off_settled and "pass" or "fail", off_state)
			others(function(before)
				report.step("user_karabiner_before", "info", before == nil and "unknown" or before)
				port.set_tap_holds(true)
				wait_for(function(state) return SETTLED_ON[state] == true end, function(on_state)
					report.step("on_active", on_state == "ready" and "pass" or "fail",
						on_state == "ready" and "ready" or (on_state .. ":" .. tostring(port.owner_reason())))
					others(function(during)
						if type(before) ~= "number" or before == 0 then
							report.step("on_closed_other", "skip", "no_user_karabiner")
						else
							report.step("on_closed_other", during == 0 and port.marker() == true and "pass" or "fail",
								during == nil and "unknown" or during)
						end
						port.set_tap_holds(false)
						wait_for(function(state) return not ACTIVE[state] end, function()
							if type(before) ~= "number" or before == 0 then
								report.step("off_restored", "skip", "no_user_karabiner")
								return done()
							end
							local waited = 0
							local function look()
								others(function(after)
									local back = type(after) == "number" and after > 0 and port.marker() ~= true
									if back or waited >= M.WAIT_SEC then
										report.step("off_restored", back and "pass" or "fail", after == nil and "unknown" or after)
										return done()
									end
									waited = waited + M.POLL_SEC
									ports.after(M.POLL_SEC, look)
								end)
							end
							look()
						end)
					end)
				end)
			end)
		end)
	end)
end

return M
