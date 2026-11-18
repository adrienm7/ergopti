--- tests/meta/corpus/test_corpus_keystats_session_events.lua

--- ==============================================================================
--- MODULE: Session Events Corpus Consumer (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/keystats/session_events_vectors.json through the
--- real keystats event tap, the real idle timer (watchers.check_idle) and the
--- real engine stop. Linux replays the same vectors through the shared state
--- machine and Windows through its watchers.
---
--- FEATURES & RATIONALE:
--- 1. The first replay found three disagreements, fixed in
---    modules/keystats/session_machine.lua: a click or a scroll ended an idle
---    span but did not keep the session alive, an input after a missed timeout
---    extended the old session instead of ending it, and a stop left the open
---    session without its session_end.
--- 2. Only the four events_session kinds are compared; the other rows the
---    engine writes (typing runs, system events) belong to other corpora.
--- 3. Synthetic text is not an input of the corpus: Windows and Linux never
---    show it to their session machine. The macOS deferred snapshot used to open
---    a session without writing its session_start, so a later stop or timeout
---    wrote a session_end nothing had opened.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_module = require("tests.support.keystats_provenance_fixture")
local Timings = require("core.timing.engine.timings")

local fh = assert(io.open(helpers.shared("tests/corpus/keystats/session_events_vectors.json"), "r"))
local corpus = require("hs").json.decode(fh:read("*a"))
fh:close()

local SESSION_KINDS = { session_start = true, session_end = true, idle_start = true, idle_end = true }
local NS_PER_MS = 1000000

--- Builds a physical event, carrying no synthetic ownership tag.
--- @param hs_table table Active Hammerspoon stub.
--- @param keystroke boolean A typed key rather than a click.
--- @return table event
local function physical_event(hs_table, keystroke)
	local types = hs_table.eventtap.event.types
	local event = keystroke and fixture_module.physical_key(hs_table, "a")
		or hs_table.eventtap.event.newMouseEvent(types.leftMouseDown, { x = 0, y = 0 }, {})
	function event:getType() return keystroke and types.keyDown or types.leftMouseDown end
	function event:getKeyCode() return 0 end
	function event:getFlags() return {} end
	function event:getCharacters() return "a" end
	return event
end

--- Starts a fresh real engine whose session rows are captured in order.
--- @return table replay { input(at, keystroke), tick(at), stop(), rows(), errors }
local function start_replay()
	local fixture = fixture_module.load_keystats()
	fixture.hs.caffeinate = { watcher = { new = function()
		return { start = function(self) return self end, stop = function(self) return self end }
	end } }
	fixture.start({ is_paused = function() return false end })
	local rows = {}
	package.loaded["modules.keystats.log_manager"].append_log = function(entry)
		if SESSION_KINDS[entry.type] then rows[#rows + 1] = entry end
		return true
	end
	local replay = { errors = {} }
	package.loaded["core.logger.engine.logger"].error = function(_, message)
		replay.errors[#replay.errors + 1] = message
	end
	local now_ms = 0
	fixture.hs.timer.absoluteTime = function() return now_ms * NS_PER_MS end
	package.loaded["modules.keystats.watchers"] = nil
	local watchers = require("modules.keystats.watchers")
	helpers.assert_true(watchers.init(fixture.state, function() return false end))
	function replay.input(at, keystroke)
		now_ms = at
		fixture.dispatch(physical_event(fixture.hs, keystroke))
	end
	function replay.tick(at)
		now_ms = at
		watchers.check_idle()
	end
	function replay.stop() fixture.keystats.stop() end
	--- Expands synthetic text (a hotstring or an AI answer) and runs its
	--- deferred snapshot, as the log manager does after the event tap returns.
	function replay.synthetic(at, text)
		now_ms = at
		helpers.assert_true(fixture.keystats.notify_synthetic(text, "hotstring", 0), "the synthetic text is accepted")
		fixture.drain()
	end
	function replay.rows()
		local taken = rows
		rows = {}
		return taken
	end
	return replay
end

helpers.describe("corpus: keystats/session_events_vectors.json on macOS", function()
	helpers.it("the corpus timings are the registry's", function()
		helpers.assert_eq(Timings.ms("keystats", "micro_idle_timeout_ms"), corpus.timings.micro_idle_ms)
		helpers.assert_eq(Timings.ms("keystats", "session_timeout_ms"), corpus.timings.session_timeout_ms)
		helpers.assert_true(#corpus.cases > 0, "the session cases must be read")
	end)

	for _, case in ipairs(corpus.cases) do
		helpers.it("session-events: vector " .. case.id, function()
			local replay = start_replay()
			for index, step in ipairs(case.steps) do
				if step.op == "input" then replay.input(step.at, step.keystroke)
				elseif step.op == "tick" then replay.tick(step.at)
				elseif step.op == "stop" then replay.stop()
				else error("unknown corpus operation " .. tostring(step.op)) end
				local label = case.id .. " step " .. index
				local rows = replay.rows()
				helpers.assert_eq(#rows, #step.expected, label .. " row count")
				for row_index, expected in ipairs(step.expected) do
					helpers.assert_eq(rows[row_index].type, expected.kind, label)
					helpers.assert_eq(rows[row_index].duration_ms, expected.duration_ms, label)
				end
			end
			replay.stop()
			helpers.assert_eq(replay.errors, {}, "every callback must complete without a hidden failure")
		end)
	end

	helpers.it("session-events: synthetic text alone opens no session", function()
		local replay = start_replay()
		local timeout_ms = corpus.timings.session_timeout_ms
		replay.synthetic(timeout_ms, "abc")
		helpers.assert_eq(replay.rows(), {}, "synthetic text writes no session row")
		replay.tick(timeout_ms * 2 + 1)
		replay.stop()
		helpers.assert_eq(replay.rows(), {}, "no session_end may close a session nothing opened")
		helpers.assert_eq(replay.errors, {}, "every callback must complete without a hidden failure")
	end)

	helpers.it("session-events: synthetic text inside a session leaves its span to the inputs", function()
		local replay = start_replay()
		local first, last = corpus.timings.micro_idle_ms, corpus.timings.micro_idle_ms * 2
		replay.input(first, true)
		replay.input(last, true)
		replay.synthetic(last + corpus.timings.micro_idle_ms - 1, "abc")
		replay.stop()
		local rows = replay.rows()
		helpers.assert_eq(#rows, 2, "one session, opened and closed")
		helpers.assert_eq(rows[1].type, "session_start")
		helpers.assert_eq(rows[2].type, "session_end")
		helpers.assert_eq(rows[2].duration_ms, last - first, "the session spans its inputs, as on Windows and Linux")
		helpers.assert_eq(replay.errors, {}, "every callback must complete without a hidden failure")
	end)
end)
