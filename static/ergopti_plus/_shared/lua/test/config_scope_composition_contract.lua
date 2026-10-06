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

		helpers.it("reports a registry provider that raises instead of letting it escape", function()
			local owner = Composition.new({ manifest = Manifest, scope = "global", logger = recording_logger(),
				participants = function() error("gesture owner unavailable") end })
			local accepted, ok, report = run(owner, "recommended")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(ok, false)
			helpers.assert_true(report.detail:find("gesture owner unavailable", 1, true) ~= nil, report.detail)
			helpers.assert_eq(owner.pending(), false)
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

	--- Real files and the actual transaction retain distinct source/runtime owners.
	local function with_cohort_files(run)
		local paths = {}
		local function path()
			local value = os.tmpname()
			os.remove(value)
			paths[#paths + 1] = value
			return value
		end
		local function read(file)
			local stream = io.open(file, "rb")
			if not stream then return nil, "absent" end
			local value = assert(stream:read("*a"))
			assert(stream:close())
			return value, "ok"
		end
		local function write(file, value)
			local stream = assert(io.open(file, "wb"))
			assert(stream:write(value))
			assert(stream:close())
		end
		local files = { read_with_status = read, write = write,
			write_if_unchanged = function(file, value, expected)
				local actual, status = read(file)
				if status ~= expected.status or (status == "ok" and actual ~= expected.content) then return false end
				write(file, value)
				return true
			end,
			delete_if_unchanged = function(file, expected)
				local actual, status = read(file)
				if status ~= expected.status or (status == "ok" and actual ~= expected.content) then return false end
				return os.remove(file) == true
			end,
		}
		local function transaction(file, initial)
			local runtime = { marker = initial, restored = 0 }
			local controls = {}
			local owner = require("config_scope_transaction").new({ path = file, backup_path = path(),
				manifest = Manifest, files = files,
				capture = function() return { marker = runtime.marker } end,
				apply = function(decoded)
					runtime.marker = decoded.gestures.swipe_3_down or "neutral"
					if controls.during_apply then controls.during_apply() end
					return controls.refuse_apply ~= true
				end,
				restore = function(snapshot)
					if controls.refuse_restore then return false end
					runtime.marker, runtime.restored = snapshot.marker, runtime.restored + 1
					return true
				end,
			})
			return owner, runtime, controls
		end
		local ok, detail = pcall(run, path, read, write, transaction)
		for _, file in ipairs(paths) do
			local stream = io.open(file, "rb")
			if stream then assert(stream:close()); assert(os.remove(file)) end
		end
		assert(ok, detail)
	end

	helpers.describe("scope participant retained cohort", function()
		local original = '[gestures]\nenabled = true\nswipe_3_down = "copy"\nfuture = 73\n[foreign]\nkeep = false\n'
		local expected = { gestures = { enabled = true, swipe_3_down = "copy", future = 73 }, foreign = { keep = false } }
		local Codec = require("toml_codec")
		local Participant = require("config_scope_participant")

		helpers.it("reverts the actual committed source and runtime after its provider is replaced", function()
			with_cohort_files(function(path, read, write, transaction)
				local first, second = path(), path()
				write(first, original); write(second, original)
				local a, runtime_a = transaction(first, "runtime-a")
				local b, runtime_b = transaction(second, "runtime-b")
				local latest = a
				local target = Participant.synchronous({ apply = function(mode) return a.apply("gestures", mode) end,
					owner = function() return latest end })
				local later = participant({}, "later", { refuse = true })
				later.apply = function(_, done)
					helpers.assert_eq(b.apply("gestures", "recommended"), true)
					latest = b
					return done(false, "later category refused")
				end
				local successor
				local prior = later.apply
				later.apply = function(mode, done)
					return prior(mode, function(ok, detail) successor = read(second); return done(ok, detail) end)
				end
				local owner = composition({ gestures = target, llm = later })
				local _, ok, report = run(owner, "clear")
				helpers.assert_eq(ok, false)
				helpers.assert_eq(report.reverted, true)
				helpers.assert_eq(Codec.decode(read(first)), expected, "the first owner's complete source model returns")
				helpers.assert_eq(read(second), successor, "a distinct successor is untouched")
				helpers.assert_eq(runtime_a.marker, "runtime-a")
				helpers.assert_eq(runtime_b.restored, 0)
				helpers.assert_eq(b.committed(), true, "the successor retains its own inverse")
			end)
		end)

		helpers.it("preserves a same-path successor and retains the original inverse until exact repair", function()
			with_cohort_files(function(path, read, write, transaction)
				local file = path(); write(file, original)
				local a, runtime_a = transaction(file, "runtime-a")
				local b, runtime_b = transaction(file, "runtime-b")
				local latest, candidate, successor = a, nil, nil
				local target = Participant.synchronous({ apply = function(mode)
					local ok, detail = a.apply("gestures", mode); candidate = read(file); return ok, detail
				end, owner = function() return latest end })
				local later = participant({}, "later", { refuse = true })
				later.apply = function(_, done)
					write(file, '[gestures]\nenabled = true\nfuture = 74\n[foreign]\nkeep = false\n')
					helpers.assert_eq(b.apply("gestures", "recommended"), true)
					latest, successor = b, read(file)
					helpers.assert_eq(Codec.decode(successor).gestures.future, 74)
					return done(false, "later category refused")
				end
				local owner = composition({ gestures = target, llm = later })
				local _, ok, report = run(owner, "clear")
				helpers.assert_eq(ok, false)
				helpers.assert_eq(report.reverted, false, "the foreign publication refuses the original file inverse")
				helpers.assert_eq(read(file), successor)
				helpers.assert_eq(owner.pending(), true)
				helpers.assert_eq(runtime_a.marker, "runtime-a")
				helpers.assert_eq(runtime_b.restored, 0)
				local settled
				owner.retry_restore(function(value) settled = value end)
				helpers.assert_eq(settled, false)
				helpers.assert_eq(read(file), successor)
				write(file, candidate) -- Explicit fixture repair, never a production overwrite.
				owner.retry_restore(function(value) settled = value end)
				helpers.assert_eq(settled, true)
				helpers.assert_eq(Codec.decode(read(file)), expected)
				helpers.assert_eq(runtime_a.restored, 1, "the settled native inverse is not repeated")
				helpers.assert_eq(b.committed(), true)
			end)
		end)

		helpers.it("releases only its committed inverse after a later owner replaced the provider", function()
			with_cohort_files(function(path, _, write, transaction)
				local first, second = path(), path(); write(first, original); write(second, original)
				local a, b = transaction(first, "a"), transaction(second, "b")
				local latest = a
				local target = Participant.synchronous({ apply = function(mode) return a.apply("gestures", mode) end,
					owner = function() return latest end })
				target.apply("clear", function(ok) helpers.assert_eq(ok, true) end)
				helpers.assert_eq(b.apply("gestures", "recommended"), true)
				latest = b
				target.release(); target.release()
				helpers.assert_eq(a.committed(), false)
				helpers.assert_eq(b.committed(), true)
			end)
		end)

		helpers.it("keeps the failed apply owner's runtime debt when the provider advances", function()
			with_cohort_files(function(path, read, write, transaction)
				local file = path(); write(file, original)
				local a, runtime, controls = transaction(file, "original-runtime")
				controls.refuse_apply, controls.refuse_restore = true, true
				local latest = a
				local target = Participant.synchronous({ apply = function(mode) return a.apply("gestures", mode) end,
					owner = function() return latest end })
				target.apply("clear", function(ok) helpers.assert_eq(ok, false) end)
				latest = transaction(path(), "successor")
				helpers.assert_eq(target.pending(), true)
				local settled
				target.retry_restore(function(ok) settled = ok end)
				helpers.assert_eq(settled, false)
				controls.refuse_restore = false
				target.retry_restore(function(ok) settled = ok end)
				helpers.assert_eq(settled, true)
				helpers.assert_eq(runtime.marker, "original-runtime")
				helpers.assert_eq(Codec.decode(read(file)), expected)
			end)
		end)

		helpers.it("refuses reentrant application without replacing the in-flight real-file owner", function()
			with_cohort_files(function(path, read, write, transaction)
				local file = path(); write(file, original)
				local latest, target, calls, nested = nil, nil, 0, nil
				local first_runtime
				target = Participant.synchronous({ apply = function(mode)
					calls = calls + 1
					local native, runtime, controls = transaction(file, "initial-runtime")
					latest = native
					if calls == 1 then
						first_runtime = runtime
						controls.during_apply = function()
							helpers.assert_eq(target.pending(), true)
							target.apply("recommended", function(ok) nested = ok end)
						end
					end
					return native.apply("gestures", mode)
				end, owner = function() return latest end })
				local committed
				target.apply("clear", function(ok) committed = ok end)
				helpers.assert_eq(nested, false)
				helpers.assert_eq(calls, 1)
				helpers.assert_eq(committed, true)
				target.revert(function(ok) helpers.assert_eq(ok, true) end)
				helpers.assert_eq(Codec.decode(read(file)), expected)
				helpers.assert_eq(first_runtime.marker, "initial-runtime")
			end)
		end)

		helpers.it("retains a raising apply's actual compensation owner through provider replacement", function()
			with_cohort_files(function(path, read, write, transaction)
				local file = path(); write(file, original)
				local a, runtime, controls = transaction(file, "original-runtime")
				controls.refuse_apply, controls.refuse_restore = true, true
				local latest = a
				local target = Participant.synchronous({ apply = function(mode)
					a.apply("gestures", mode)
					error("native terminal raised after retaining compensation")
				end, owner = function() return latest end })
				local later = participant({}, "later")
				local owner = composition({ gestures = target, llm = later })
				local _, ok, report = run(owner, "clear")
				helpers.assert_eq(ok, false)
				helpers.assert_eq(report.reverted, false)
				latest = transaction(path(), "successor")
				helpers.assert_eq(target.pending(), true)
				controls.refuse_restore = false
				local settled
				owner.retry_restore(function(value) settled = value end)
				helpers.assert_eq(settled, true)
				helpers.assert_eq(runtime.marker, "original-runtime")
				helpers.assert_eq(Codec.decode(read(file)), expected)
				helpers.assert_eq(later.state.committed, false)
			end)
		end)

		for _, bad in ipairs({ "missing", "malformed", "raising" }) do
			helpers.it("refuses a successful request whose retained owner is " .. bad, function()
				local calls, latest = 0, nil
				local target = Participant.synchronous({ apply = function()
					calls = calls + 1
					if bad == "malformed" then latest = {} end
					return true
				end, owner = function()
					if bad == "raising" and calls > 0 then error("owner lookup refused") end
					return latest
				end })
				local committed
				target.apply("clear", function(ok) committed = ok end)
				helpers.assert_eq(committed, false)
				helpers.assert_eq(target.pending(), true, "missing ownership cannot acknowledge compensation")
				target.apply("clear", function(ok) helpers.assert_eq(ok, false) end)
				helpers.assert_eq(calls, 1)
				target.retry_restore(function(ok) helpers.assert_eq(ok, false) end)
				helpers.assert_eq(target.release(), false)
			end)
		end

		helpers.it("admits no replacement while the latest provider retains pre-apply debt", function()
			with_cohort_files(function(path, _, write, transaction)
				local file = path(); write(file, original)
				local a, _, controls = transaction(file, "runtime")
				controls.refuse_apply, controls.refuse_restore = true, true
				helpers.assert_eq(a.apply("gestures", "clear"), false)
				local calls = 0
				local target = Participant.synchronous({ apply = function() calls = calls + 1; return true end,
					owner = function() return a end })
				target.apply("recommended", function(ok) helpers.assert_eq(ok, false) end)
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(target.pending(), true)
			end)
		end)

		helpers.it("keeps an unmodified refusal without an owner retryable", function()
			local target = Participant.synchronous({ apply = function() return false, "paused" end,
				owner = function() return nil end })
			target.apply("clear", function(ok, detail)
				helpers.assert_eq(ok, false); helpers.assert_eq(detail, "paused")
			end)
			helpers.assert_eq(target.pending(), false)
			target.retry_restore(function(ok) helpers.assert_eq(ok, true) end)
		end)

		helpers.it("never forgets a committed transaction on its successful no-op retry", function()
			with_cohort_files(function(path, read, write, transaction)
				local file = path(); write(file, original)
				local a, runtime = transaction(file, "original-runtime")
				local latest = a
				local target = Participant.synchronous({ apply = function(mode) return a.apply("gestures", mode) end,
					owner = function() return latest end })
				target.apply("clear", function(ok) helpers.assert_eq(ok, true) end)
				local candidate = read(file)
				helpers.assert_eq(a.pending(), false)
				helpers.assert_eq(a.retry_restore(), true, "the actual owner acknowledges no debt without reverting its commit")
				latest = transaction(path(), "successor")
				local retried
				target.retry_restore(function(ok) retried = ok end)
				helpers.assert_eq(read(file), candidate)
				helpers.assert_eq(a.committed(), true)
				target.revert(function(ok) helpers.assert_eq(ok, true, "the exact inverse survives the no-op") end)
				helpers.assert_eq(Codec.decode(read(file)), expected)
				helpers.assert_eq(runtime.marker, "original-runtime")
				helpers.assert_eq(retried, false)
			end)
		end)

		helpers.it("keeps its actual inverse on explicit release refusal while void success stays supported", function()
			with_cohort_files(function(path, read, write, transaction)
				local first, second = path(), path(); write(first, original); write(second, original)
				local a, b = transaction(first, "a"), transaction(second, "b")
				local native_release, refuse = a.release, true
				a.release = function() if refuse then return false end; return native_release() end
				local latest = a
				local target = Participant.synchronous({ apply = function(mode) return a.apply("gestures", mode) end,
					owner = function() return latest end })
				target.apply("clear", function(ok) helpers.assert_eq(ok, true) end)
				helpers.assert_eq(b.apply("gestures", "recommended"), true)
				latest = b
				local successor = read(second)
				local released = target.release()
				target.revert(function(ok) helpers.assert_eq(ok, true) end)
				helpers.assert_eq(Codec.decode(read(first)), expected, "the refusal cannot retire this inverse")
				helpers.assert_eq(read(second), successor)
				helpers.assert_eq(b.committed(), true)
				helpers.assert_eq(released, false)
				refuse = false
				target.release() -- Existing transaction release intentionally returns nil.
				helpers.assert_eq(a.committed(), false)
				helpers.assert_eq(b.committed(), true)
			end)
		end)
	end)


	helpers.describe("fenced configuration transaction", function()
		local original = '[gestures]\nenabled = true\nswipe_3_down = "copy"\nfuture = 73\n[foreign]\nkeep = false\n'
		local expected = { gestures = { enabled = true, swipe_3_down = "copy", future = 73 }, foreign = { keep = false } }
		local Codec = require("toml_codec")
		local Fenced = require("config_scope_fenced_transaction")
		local function fixture(run)
			with_cohort_files(function(path, read, write, transaction)
				local file = path(); write(file, original)
				local primary, runtime, controls = transaction(file, "original-runtime")
				local token, claims, ports, trace = {}, {}, {}, {}
				local state = { available = true }
				for index = 1, 3 do
					ports[index] = {
						acquire = function(owner)
							trace[#trace + 1] = "acquire:" .. index
							if state.reacquire == index and state.released then return false end
							if state.refuse_acquire == index then return state.reply() end
							helpers.assert_eq(claims[index], nil)
							claims[index] = owner
							if state.reentrant then
								local callback = state.reentrant; state.reentrant = nil; callback()
							end
							return true
						end,
						release = function(owner)
							trace[#trace + 1] = "release:" .. index
							helpers.assert_eq(claims[index], owner, "release requires this exact live claim")
							if state.refuse_release == index then return state.reply() end
							claims[index], state.released = nil, true
							return true
						end,
					}
				end
				local owner
				owner = Fenced.new({ owner = token, transaction = primary, scope = "gestures", fences = ports,
					available = function()
						if type(state.available) == "function" then return state.available() end
						return state.available
					end })
				helpers.assert_eq(owner, token)
				run(owner, primary, runtime, controls, state, claims, trace, file, read, write, ports)
			end)
		end

		for _, receipt in ipairs({
			{ name = "nil", reply = function() return nil end },
			{ name = "false", reply = function() return false end },
			{ name = "truthy", reply = function() return "true" end },
			{ name = "wrong type", reply = function() return {} end },
			{ name = "exception", reply = function() error("native claim refused") end },
		}) do
			for _, mode in ipairs({ "clear", "recommended" }) do
				helpers.it("owns " .. mode .. " compensation until a " .. receipt.name .. " release settles", function()
					fixture(function(owner, _, runtime, _, state, claims, _, file, read)
						state.refuse_release, state.reply = 2, receipt.reply
						helpers.assert_eq(owner.apply(mode), false)
						helpers.assert_eq(owner.pending(), true)
						helpers.assert_eq(owner.release(), false)
						helpers.assert_eq(owner.apply(mode), false)
						state.refuse_release = nil
						helpers.assert_eq(owner.retry_restore(), true)
						helpers.assert_eq(runtime.marker, "original-runtime")
						helpers.assert_eq(Codec.decode(read(file)), expected)
						helpers.assert_eq(owner.pending(), false)
						helpers.assert_eq(next(claims), nil)
					end)
				end)
			end

			helpers.it("retains no primary mutation when " .. receipt.name .. " acquisition refuses", function()
				fixture(function(owner, _, runtime, _, state, claims, _, file, read)
					state.refuse_acquire, state.reply = 2, receipt.reply
					helpers.assert_eq(owner.apply("clear"), false)
					helpers.assert_eq(owner.pending(), false)
					helpers.assert_eq(runtime.marker, "original-runtime")
					helpers.assert_eq(read(file), original)
					helpers.assert_eq(next(claims), nil)
				end)
			end)
		end

		helpers.it("retains an inverse until its released claim can be reacquired", function()
			fixture(function(owner, primary, runtime, _, state, claims, _, file, read)
				state.refuse_release, state.reply, state.reacquire = 2, function() return false end, 3
				helpers.assert_eq(owner.apply("clear"), false)
				local candidate = read(file)
				helpers.assert_eq(primary.committed(), true)
				helpers.assert_eq(runtime.marker, "neutral")
				state.refuse_release = nil
				helpers.assert_eq(owner.retry_restore(), false)
				helpers.assert_eq(read(file), candidate)
				state.reacquire = nil
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(Codec.decode(read(file)), expected)
				helpers.assert_eq(next(claims), nil)
			end)
		end)

		helpers.it("keeps all claims while runtime compensation refuses", function()
			fixture(function(owner, _, runtime, controls, _, claims, _, file, read)
				controls.refuse_apply, controls.refuse_restore = true, true
				helpers.assert_eq(owner.apply("clear"), false)
				helpers.assert_eq(owner.pending(), true)
				for index = 1, 3 do helpers.assert_eq(claims[index], owner) end
				helpers.assert_eq(owner.retry_restore(), false)
				controls.refuse_restore = false
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(runtime.marker, "original-runtime")
				helpers.assert_eq(Codec.decode(read(file)), expected)
				helpers.assert_eq(next(claims), nil)
			end)
		end)

		helpers.it("settles an acknowledged inverse release without repeating runtime restoration", function()
			fixture(function(owner, _, runtime, _, state, claims, _, file, read)
				helpers.assert_eq(owner.apply("recommended"), true)
				state.refuse_release, state.reply = 2, function() return false end
				helpers.assert_eq(owner.revert(), false)
				helpers.assert_eq(Codec.decode(read(file)), expected)
				local restored = runtime.restored
				state.refuse_release = nil
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(runtime.restored, restored)
				helpers.assert_eq(next(claims), nil)
			end)
		end)

		helpers.it("refuses reentrant mutation while a native claim is being acquired", function()
			fixture(function(owner, _, _, _, state, _, _, file, read)
				state.reentrant = function()
					helpers.assert_eq(owner.pending(), true)
					helpers.assert_eq(owner.apply("recommended"), false)
					helpers.assert_eq(owner.retry_restore(), false)
				end
				helpers.assert_eq(owner.apply("clear"), true)
				helpers.assert_eq(owner.revert(), true)
				helpers.assert_eq(Codec.decode(read(file)), expected)
				state.available = false
				helpers.assert_eq(owner.apply("recommended"), false)
			end)
		end)

		for _, admission in ipairs({
			{ name = "nil", reply = function() return nil end },
			{ name = "false", reply = function() return false end },
			{ name = "truthy", reply = function() return "true" end },
			{ name = "wrong type", reply = function() return {} end },
			{ name = "exception", reply = function() error("availability refused") end },
		}) do
			helpers.it("refuses " .. admission.name .. " admission before acquiring any native claim", function()
				fixture(function(owner, _, runtime, _, state, claims, trace, file, read)
					state.available = admission.reply
					helpers.assert_eq(owner.apply("clear"), false)
					helpers.assert_eq(read(file), original)
					helpers.assert_eq(runtime.marker, "original-runtime")
					helpers.assert_eq(next(claims), nil)
					helpers.assert_eq(trace, {})
					helpers.assert_eq(owner.pending(), false)
					state.available = true
					helpers.assert_eq(owner.apply("clear"), true)
					helpers.assert_eq(owner.revert(), true)
				end)
			end)
		end

		helpers.it("guards reentrant admission before the first native claim", function()
			fixture(function(owner, _, _, _, state, _, _, file, read)
				state.available = function()
					helpers.assert_eq(owner.pending(), true)
					helpers.assert_eq(owner.apply("recommended"), false)
					return true
				end
				helpers.assert_eq(owner.apply("clear"), true)
				helpers.assert_eq(owner.revert(), true)
				helpers.assert_eq(Codec.decode(read(file)), expected)
			end)
		end)

		helpers.it("refuses sparse and named native claim lists instead of dropping an owner", function()
			fixture(function(_, primary)
				local port = { acquire = function() return true end, release = function() return true end }
				for _, bad in ipairs({ { [1] = port, [3] = port }, { port, extra = port } }) do
					local called, detail = pcall(Fenced.new, { owner = {}, transaction = primary, scope = "gestures",
						fences = bad, available = function() return true end })
					helpers.assert_eq(called, false)
					helpers.assert_true(tostring(detail):find("configuration claims require", 1, true) ~= nil, tostring(detail))
				end
			end)
		end)

		helpers.it("retains original native port identities after its caller mutates the descriptor list", function()
			fixture(function(owner, _, _, _, _, claims, _, file, read, _, ports)
				ports[1].acquire = function() error("foreign acquisition") end
				ports[1].release = function() error("foreign release") end
				ports[2] = nil
				helpers.assert_eq(owner.apply("clear"), true)
				helpers.assert_eq(owner.revert(), true)
				helpers.assert_eq(Codec.decode(read(file)), expected)
				helpers.assert_eq(next(claims), nil)
			end)
		end)

		helpers.it("separates public pending from the exact private primary-compensation token", function()
			fixture(function(_, primary, _, _, _, _, _, file, read)
				local public, claim = {}, { pending = primary.pending }
				local live
				local owner
			owner = Fenced.new({ owner = public, native_token = claim, transaction = primary,
					scope = "gestures", available = function() return true end,
					fences = { { acquire = function(token)
						helpers.assert_eq(token, claim)
						helpers.assert_eq(live, nil)
						live = token
						return true
					end, release = function(token)
						helpers.assert_eq(token, live)
						helpers.assert_eq(token, claim)
						helpers.assert_eq(public.pending(), true, "public pending never hides its in-flight native claim")
						if token.pending() then return false end
						live = nil
						return true
					end } } })
				helpers.assert_eq(owner, public)
				helpers.assert_true(owner ~= claim)
				helpers.assert_eq(owner.apply("clear"), true)
				helpers.assert_eq(owner.pending(), false)
				helpers.assert_eq(owner.revert(), true)
				helpers.assert_eq(Codec.decode(read(file)), expected)
				helpers.assert_eq(live, nil)
			end)
		end)

		helpers.it("refuses a malformed private native token before any acquisition", function()
			fixture(function(_, primary)
				local calls = 0
				local called, detail = pcall(Fenced.new, { owner = {}, native_token = false, transaction = primary,
					scope = "gestures", available = function() return true end,
					fences = { { acquire = function() calls = calls + 1; return true end, release = function() return true end } } })
				helpers.assert_eq(called, false)
				helpers.assert_true(tostring(detail):find("native claim token must be a table", 1, true) ~= nil, tostring(detail))
				helpers.assert_eq(calls, 0)
			end)
		end)

		helpers.it("reclaims acknowledged tail admission gates while forward release debt remains", function()
			fixture(function(owner, _, runtime, _, state, claims, _, file, read)
				state.refuse_release, state.reply = 2, function() return false end
				helpers.assert_eq(owner.apply("clear"), false)
				for index = 1, 3 do helpers.assert_eq(claims[index], owner, "all acknowledged native gates remain claimed") end
				helpers.assert_eq(runtime.marker, "original-runtime")
				state.refuse_release = nil
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(Codec.decode(read(file)), expected)
				helpers.assert_eq(next(claims), nil)
			end)
		end)

		helpers.it("reclaims tail gates after an acknowledged explicit inverse without repeating that inverse", function()
			fixture(function(owner, _, runtime, _, state, claims)
				helpers.assert_eq(owner.apply("recommended"), true)
				state.refuse_release, state.reply = 2, function() return false end
				helpers.assert_eq(owner.revert(), false)
				for index = 1, 3 do helpers.assert_eq(claims[index], owner) end
				local restored = runtime.restored
				state.refuse_release = nil
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(runtime.restored, restored)
				helpers.assert_eq(next(claims), nil)
			end)
		end)

		helpers.it("retains refused tail reacquisition even after the primary inverse acknowledged", function()
			fixture(function(owner, _, runtime, _, state, claims)
				helpers.assert_eq(owner.apply("recommended"), true)
				state.refuse_release, state.reply = 2, function() state.reacquire = 3; return false end
				helpers.assert_eq(owner.revert(), false)
				local restored = runtime.restored
				state.refuse_release = nil
				helpers.assert_eq(owner.retry_restore(), false, "release retry first needs its refused tail claim")
				helpers.assert_eq(owner.pending(), true)
				helpers.assert_eq(claims[1], owner)
				helpers.assert_eq(claims[2], owner)
				state.reacquire = nil
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(runtime.restored, restored)
				helpers.assert_eq(next(claims), nil)
			end)
		end)

		helpers.it("reclaims only actually acquired gates during a partial acquisition cleanup refusal", function()
			fixture(function(owner, _, runtime, _, state, claims, trace)
				state.refuse_acquire, state.refuse_release, state.reply = 3, 1, function() return false end
				helpers.assert_eq(owner.apply("clear"), false)
				helpers.assert_eq(claims[1], owner)
				helpers.assert_eq(claims[2], owner, "the acquired and released second claim is reclaimed")
				helpers.assert_eq(claims[3], nil, "the never-acquired third owner remains untouched")
				helpers.assert_eq(runtime.marker, "original-runtime")
				local third_attempts = 0
				for _, event in ipairs(trace) do if event == "acquire:3" then third_attempts = third_attempts + 1 end end
				helpers.assert_eq(third_attempts, 1, "cleanup cannot attempt the unacquired owner again")
				state.refuse_release = nil
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(next(claims), nil)
			end)
		end)
	end)
	helpers.describe("composed scope finalization receipts", function()
		local Codec = require("toml_codec")
		local original = '[gestures]\nenabled = true\nswipe_3_down = "copy"\nfuture = 73\n[foreign]\nkeep = false\n'
		local expected = { gestures = { enabled = true, future = 73 }, foreign = { keep = false } }
		local receipts = {
			{ name = "false", reply = function() return false end },
			{ name = "truthy string", reply = function() return "true" end },
			{ name = "wrong object", reply = function() return {} end },
			{ name = "exception", reply = function() error("inverse release refused") end },
		}
		for _, receipt in ipairs(receipts) do
			helpers.it("retains exact two-file finalization on " .. receipt.name .. " inverse release", function()
				with_cohort_files(function(path, read, write, transaction)
					local first_path, second_path = path(), path()
					write(first_path, original); write(second_path, original)
					local first, first_runtime = transaction(first_path, "first-runtime")
					local second, second_runtime = transaction(second_path, "second-runtime")
					local first_release, second_release = first.release, second.release
					local released, blocked, latest = { first = 0, second = 0, after = 0 }, true, second
					first.release = function() released.first = released.first + 1; first_release() end
					second.release = function()
						if blocked then return receipt.reply() end
						released.second = released.second + 1
						second_release()
						return true -- Both existing void and explicit true ports are admitted.
					end
					local adapter = require("config_scope_participant")
					local a = adapter.synchronous({ apply = function(mode) return first.apply("gestures", mode) end,
						owner = function() return first end })
					local b = adapter.synchronous({ apply = function(mode) return second.apply("gestures", mode) end,
						owner = function() return latest end })
					local after = participant({}, "after")
					after.release = function() released.after = released.after + 1 end
					local global = composition({ gestures = { a, b, after } })
					local accepted, ok, report = run(global, "clear")
					helpers.assert_eq(accepted, true)
					helpers.assert_eq(ok, false)
					helpers.assert_eq(report.phase, "finalization")
					helpers.assert_eq(report.committed, true, "sources committed even though inverse release refused")
					helpers.assert_eq(report.finalization_pending, true)
					helpers.assert_eq(released, { first = 1, second = 0, after = 0 })
					helpers.assert_eq(global.pending(), true)
					helpers.assert_eq(Codec.decode(read(first_path)), expected)
					helpers.assert_eq(Codec.decode(read(second_path)), expected)
					local successor = transaction(second_path, "successor-runtime")
					latest = successor -- An ordinary provider change cannot replace the retained cohort.
					local retry
					global.retry_restore(function(settled) retry = settled end)
					helpers.assert_eq(retry, false)
					helpers.assert_eq(released, { first = 1, second = 0, after = 0 })
					local rejected
					helpers.assert_eq(global.apply("recommended", function(committed) rejected = committed end), false)
					helpers.assert_eq(rejected, false)
					local external = '[gestures]\nfuture = 99\n[external]\nowner = "later"\n'
					write(second_path, external)
					blocked = false
					global.retry_restore(function(settled) retry = settled end)
					helpers.assert_eq(retry, true)
					helpers.assert_eq(global.pending(), false)
					helpers.assert_eq(released, { first = 1, second = 1, after = 1 }, "acknowledged release is never repeated")
					helpers.assert_eq(read(second_path), external, "finalization never overwrites a later source")
					helpers.assert_eq(Codec.decode(read(first_path)), expected)
					helpers.assert_eq(first_runtime.restored, 0)
					helpers.assert_eq(second_runtime.restored, 0, "finalization cannot roll back a partially forgotten cohort")
					helpers.assert_eq(first.committed(), false)
					helpers.assert_eq(second.committed(), false)
				end)
			end)
		end

		helpers.it("refuses reentrant apply and retry while the exact finalization release runs", function()
			local trace, global, blocked = {}, nil, true
			local a, b = participant(trace, "first"), participant(trace, "second")
			local native_release = b.release
			b.release = function()
				helpers.assert_eq(global.pending(), true)
				local applied, retried
				helpers.assert_eq(global.apply("clear", function(ok) applied = ok end), false)
				helpers.assert_eq(global.retry_restore(function(ok) retried = ok end), false)
				helpers.assert_eq(applied, false)
				helpers.assert_eq(retried, false)
				if blocked then return false end
				return native_release()
			end
			global = composition({ gestures = { a, b } })
			local accepted, ok = run(global, "clear")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(ok, false)
			helpers.assert_eq(global.pending(), true)
			blocked = false
			local retried
			global.retry_restore(function(settled) retried = settled end)
			helpers.assert_eq(retried, true)
			helpers.assert_eq(trace, { "first:apply:clear", "second:apply:clear", "first:release", "second:release" })
		end)
	end)

end
