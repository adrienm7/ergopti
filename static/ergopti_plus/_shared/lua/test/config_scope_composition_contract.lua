--- _shared/lua/test/config_scope_composition_contract.lua

--- Shared behavior proves the composite scope orders, skips and reverts its
--- participants through the manifest registry on every Lua host.
return function(helpers)
	local Manifest = require("infra.manifest_reader")
	local Composition = require("config_scope_composition")

	--- A logger double recording every line by level.
	local function recording_logger()
		local lines = {}
		local logger = { lines = lines }
		for _, level in ipairs({ "start", "success", "info", "warn", "error" }) do
			logger[level] = function(_, fmt, ...)
				lines[#lines + 1] = level .. ": " .. string.format(fmt, ...)
			end
		end
		return logger
	end

	--- A stub participant journaling every port call into a shared trace.
	--- @param trace table Shared ordered journal.
	--- @param name string Journal label.
	--- @param behaviour table|nil Refusals, raises, deferred settlement and debt.
	local function participant(trace, name, behaviour)
		behaviour = behaviour or {}
		local state = { committed = false, debt = false, deferred = nil }
		local stub = { state = state }
		function stub.apply(mode, done)
			trace[#trace + 1] = name .. ":apply:" .. mode
			if behaviour.raise then error("native owner raised") end
			local function settle()
				if behaviour.refuse then
					state.debt = behaviour.refuse_debt == true
					return done(false, name .. " refused")
				end
				state.committed = true
				return done(true)
			end
			if behaviour.defer then state.deferred = settle; return end
			return settle()
		end
		function stub.revert(done)
			trace[#trace + 1] = name .. ":revert"
			if not state.committed then return done(false, "nothing to revert") end
			if behaviour.refuse_revert then
				behaviour.refuse_revert = behaviour.refuse_revert - 1
				if behaviour.refuse_revert >= 0 then
					state.debt = true
					return done(false, "revert refused")
				end
			end
			state.committed = false
			return done(true)
		end
		function stub.release()
			trace[#trace + 1] = name .. ":release"
			state.committed = false
		end
		function stub.pending() return state.debt end
		function stub.retry_restore(done)
			trace[#trace + 1] = name .. ":retry"
			if behaviour.refuse_retry then return done(false) end
			state.debt, state.committed = false, false
			return done(true)
		end
		return stub
	end

	--- Runs one synchronous composition and returns its settlement.
	local function run(owner, mode)
		local result = {}
		local accepted = owner.apply(mode, function(ok, report) result.ok, result.report = ok, report end)
		return accepted, result.ok, result.report
	end

	local function composition(registry, logger)
		return Composition.new({ manifest = Manifest, scope = "global", logger = logger or recording_logger(),
			participants = function() return registry end })
	end

	helpers.describe("configuration scope composition", function()
		helpers.it("applies registered participants in manifest order and reports the missing ones", function()
			local trace = {}
			local registry = {
				metrics = participant(trace, "metrics"),
				tap_holds = participant(trace, "tap_holds"),
				shortcuts = { participant(trace, "shortcuts.config"), participant(trace, "shortcuts.remap") },
				llm = participant(trace, "llm"),
			}
			local logger = recording_logger()
			local accepted, ok, report = run(composition(registry, logger), "recommended")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(ok, true, report and report.detail)
			helpers.assert_eq(trace, {
				"tap_holds:apply:recommended", "shortcuts.config:apply:recommended",
				"shortcuts.remap:apply:recommended", "llm:apply:recommended", "metrics:apply:recommended",
				"tap_holds:release", "shortcuts.config:release", "shortcuts.remap:release",
				"llm:release", "metrics:release",
			})
			helpers.assert_eq(report.applied, { "tap_holds", "shortcuts", "shortcuts", "llm", "metrics" })
			local includes = Manifest.scopes().global.includes
			local expected_skipped = {}
			for _, id in ipairs(includes) do
				if not registry[id] then expected_skipped[#expected_skipped + 1] = id end
			end
			expected_skipped[#expected_skipped + 1] = "global"
			helpers.assert_eq(report.skipped, expected_skipped)
			local warned = 0
			for _, line in ipairs(logger.lines) do
				if line:find("^warn: Scope global recommended skips ") then warned = warned + 1 end
			end
			helpers.assert_eq(warned, #expected_skipped, "every missing participant is reported")
		end)

		helpers.it("reverts committed participants newest first when a later one refuses", function()
			local trace = {}
			local registry = {
				tap_holds = participant(trace, "tap_holds"),
				gestures = participant(trace, "gestures"),
				llm = participant(trace, "llm", { refuse = true }),
				metrics = participant(trace, "metrics"),
			}
			local owner = composition(registry)
			local accepted, ok, report = run(owner, "clear")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(ok, false)
			helpers.assert_eq(report.failed, "llm")
			helpers.assert_eq(report.reverted, true)
			helpers.assert_eq(trace, { "tap_holds:apply:clear", "gestures:apply:clear", "llm:apply:clear",
				"gestures:revert", "tap_holds:revert" })
			helpers.assert_eq(owner.pending(), false)
		end)

		helpers.it("treats a raising participant as a refusal and rolls back", function()
			local trace = {}
			local registry = { tap_holds = participant(trace, "tap_holds"), gestures = participant(trace, "gestures", { raise = true }) }
			local _, ok, report = run(composition(registry), "recommended")
			helpers.assert_eq(ok, false)
			helpers.assert_eq(report.failed, "gestures")
			helpers.assert_true(report.detail:find("native owner raised", 1, true) ~= nil, report.detail)
			helpers.assert_eq(trace[#trace], "tap_holds:revert")
		end)

		helpers.it("waits for an asynchronous terminal before the next participant", function()
			local trace = {}
			local remap = participant(trace, "tap_holds", { defer = true })
			local registry = { tap_holds = remap, gestures = participant(trace, "gestures") }
			local owner = composition(registry)
			local settled = {}
			helpers.assert_eq(owner.apply("recommended", function(ok) settled[#settled + 1] = ok end), true)
			helpers.assert_eq(trace, { "tap_holds:apply:recommended" })
			helpers.assert_eq(owner.pending(), true, "an unsettled terminal keeps the composition busy")
			local refused = {}
			helpers.assert_eq(owner.apply("clear", function(ok) refused[#refused + 1] = ok end), false)
			helpers.assert_eq(refused, { false })
			remap.state.deferred()
			helpers.assert_eq(settled, { true })
			helpers.assert_eq(trace[2], "gestures:apply:recommended")
			helpers.assert_eq(owner.pending(), false)
		end)

		helpers.it("retains a refused rollback and settles it in the same order on retry", function()
			local trace = {}
			local tap_holds = participant(trace, "tap_holds")
			local gestures = participant(trace, "gestures", { refuse_revert = 1 })
			local llm = participant(trace, "llm", { refuse = true, refuse_debt = true })
			local owner = composition({ tap_holds = tap_holds, gestures = gestures, llm = llm })
			local _, ok, report = run(owner, "recommended")
			helpers.assert_eq(ok, false)
			helpers.assert_eq(report.reverted, false)
			helpers.assert_true(report.detail:find("rollback remains pending", 1, true) ~= nil, report.detail)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(trace, { "tap_holds:apply:recommended", "gestures:apply:recommended",
				"llm:apply:recommended", "llm:retry", "gestures:revert" })
			local blocked = {}
			helpers.assert_eq(owner.apply("clear", function(done) blocked[#blocked + 1] = done end), false)
			helpers.assert_eq(blocked, { false })
			local retried = {}
			helpers.assert_eq(owner.retry_restore(function(settled) retried[#retried + 1] = settled end), true)
			helpers.assert_eq(retried, { true })
			helpers.assert_eq(trace, { "tap_holds:apply:recommended", "gestures:apply:recommended",
				"llm:apply:recommended", "llm:retry", "gestures:revert", "gestures:retry", "tap_holds:revert" })
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(tap_holds.state.committed, false)
		end)

		helpers.it("refuses before any change while a participant retains its own debt", function()
			local trace = {}
			local gestures = participant(trace, "gestures")
			gestures.state.debt = true
			local accepted, ok, report = run(composition({ tap_holds = participant(trace, "tap_holds"), gestures = gestures }), "clear")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(ok, false)
			helpers.assert_true(report.detail:find("gestures", 1, true) ~= nil, report.detail)
			helpers.assert_eq(trace, {})
		end)

		helpers.it("refuses a participant registered outside the composite scope", function()
			local trace = {}
			local accepted, ok, report = run(composition({ unknown_scope = participant(trace, "unknown") }), "clear")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(ok, false)
			helpers.assert_true(report.detail:find("unknown_scope", 1, true) ~= nil, report.detail)
			helpers.assert_eq(trace, {})
		end)

		helpers.it("refuses an incomplete participant and an unknown mode before any change", function()
			local trace = {}
			local incomplete = participant(trace, "gestures")
			incomplete.revert = nil
			local accepted, _, report = run(composition({ gestures = incomplete }), "recommended")
			helpers.assert_eq(accepted, false)
			helpers.assert_true(report.detail:find("revert", 1, true) ~= nil, report.detail)
			accepted = run(composition({ gestures = participant(trace, "gestures") }), "factory")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(trace, {})
		end)

		helpers.it("adapts a synchronous owner so the composition reverts the owner that committed", function()
			local Participant = require("config_scope_participant")
			local owners, trace = {}, {}
			local function owner_for(index)
				local owner = { committed = false }
				function owner.revert()
					trace[#trace + 1] = "revert:" .. index
					return owner.committed, owner.committed and nil or "nothing committed"
				end
				function owner.release() trace[#trace + 1] = "release:" .. index end
				function owner.pending() return false end
				function owner.retry_restore() return true end
				return owner
			end
			local participant = Participant.synchronous({
				apply = function(mode)
					owners[#owners + 1] = owner_for(#owners + 1)
					owners[#owners].committed = mode == "recommended"
					return owners[#owners].committed, owners[#owners].committed and nil or "refused"
				end,
				owner = function() return owners[#owners] end,
			})
			local settled = {}
			participant.retry_restore(function(ok) settled[#settled + 1] = ok end)
			helpers.assert_eq(participant.pending(), false, "no owner means no debt")
			participant.revert(function(ok, detail) settled[#settled + 1] = { ok, detail } end)
			participant.apply("clear", function(ok, detail) settled[#settled + 1] = { ok, detail } end)
			participant.apply("recommended", function(ok) settled[#settled + 1] = ok end)
			participant.revert(function(ok) settled[#settled + 1] = ok end)
			participant.release()
			helpers.assert_eq(settled, { true, { false, "no committed scope to revert" }, { false, "refused" }, true, true })
			helpers.assert_eq(trace, { "revert:2", "release:2" }, "only the latest owner is addressed")
			local broken = Participant.synchronous({ apply = function() return true end,
				owner = function() return { pending = function() return false end } end })
			helpers.assert_throws(function() broken.pending() end)
		end)

		helpers.it("ignores a duplicate settlement instead of running the next participant twice", function()
			local trace = {}
			local doubled = participant(trace, "tap_holds")
			doubled.apply = function(mode, done)
				trace[#trace + 1] = "tap_holds:apply:" .. mode
				done(true)
				done(true)
			end
			local logger = recording_logger()
			local _, ok = run(composition({ tap_holds = doubled, gestures = participant(trace, "gestures") }, logger), "clear")
			helpers.assert_eq(ok, true)
			helpers.assert_eq(trace, { "tap_holds:apply:clear", "gestures:apply:clear", "tap_holds:release", "gestures:release" })
			local duplicates = 0
			for _, line in ipairs(logger.lines) do
				if line:find("Duplicate settlement", 1, true) then duplicates = duplicates + 1 end
			end
			helpers.assert_eq(duplicates, 1)
		end)
	end)
end
