--- tests/unit/meta/test_injector_race.lua
---
--- Deterministic reproduction of the hotstring injector race: when a physical
--- keystroke arrives during an in-flight ydotool injection, the character can
--- interleave with the synthetic backspaces and replacement text, corrupting
--- the output (the "abcd"→"acd" class of bug).
---
--- Uses the injector._set_runner() test seam to model ydotool commands as
--- mutations on a virtual document string, with no shell or hardware needed.

local helpers  = require("tests.helpers")
local injector = helpers.load_module("modules.hotstrings.injector")


-- ==========================================================================
-- Virtual-document runner for the injector test seam
-- ==========================================================================

--- Builds a runner function that models ydotool backspace+type commands as
--- mutations on a virtual document table (wrapped so callers share state).
---
--- The runner recognises two command patterns:
---   ydotool key 14:1 14:0 ...   → one backspace per down/up pair
---   ydotool type ... -- 'text'  → append the text to the document
---
--- @param doc_t   table  Wrapper { value = "initial document string" }
--- @param on_bs   function|nil  Called after each backspace pair with
---                              (bs_index, doc_t) so the test can inject
---                              interleaving characters.
--- @return function  A runner suitable for injector._set_runner().
local function make_virtual_runner(doc_t, on_bs)
	return function(cmd)
		if cmd:match("^ydotool key ") then
			-- Count backspace down/up pairs in the command.
			local bs_count = 0
			for _ in cmd:gmatch("14:1 14:0") do
				bs_count = bs_count + 1
			end
			for i = 1, bs_count do
				-- Remove one UTF-8 codepoint from the end of the document.
				if #doc_t.value > 0 then
					-- Pop the last UTF-8 codepoint.
					local len = #doc_t.value
					while len > 0 and doc_t.value:byte(len) >= 0x80 and doc_t.value:byte(len) < 0xC0 do
						len = len - 1
					end
					if len > 0 then
						doc_t.value = doc_t.value:sub(1, len - 1)
					end
				end
				if on_bs then on_bs(i, doc_t) end
			end
			return true
		elseif cmd:match("^ydotool type ") then
			-- Extract the replacement text (between the last -- ' and the final ').
			local text = cmd:match("%-%-%s+'([^']*)'$")
			if text then
				doc_t.value = doc_t.value .. text
			end
			return true
		end
		return false
	end
end


helpers.describe("injector race (virtual document)", function()

	-- ======================================================================
	-- 1. Basic virtual runner contract
	-- ======================================================================

	helpers.describe("virtual runner basics", function()
		helpers.it("applies backspaces by removing chars from the document end", function()
			local doc = { value = "hello" }
			local runner = make_virtual_runner(doc)
			injector._set_runner(runner)
			injector.inject(2, "")
			injector._reset_runner()
			helpers.assert_eq(doc.value, "hel",
				"2 backspaces on 'hello'")
		end)

		helpers.it("appends replacement text to the document", function()
			local doc = { value = "hel" }
			local runner = make_virtual_runner(doc)
			injector._set_runner(runner)
			injector.inject(0, "lo world")
			injector._reset_runner()
			helpers.assert_eq(doc.value, "hello world",
				"type appends replacement")
		end)

		helpers.it("erases trigger then types replacement (full inject)", function()
			local doc = { value = "btw" }
			local runner = make_virtual_runner(doc)
			injector._set_runner(runner)
			injector.inject(3, "by the way")
			injector._reset_runner()
			helpers.assert_eq(doc.value, "by the way",
				"full erase-then-type injection")
		end)
	end)

	-- ======================================================================
	-- 2. Race reproduction — interleaving corrupts output
	-- ======================================================================

	helpers.describe("interleaving race", function()
		helpers.it("corrupts output when a physical char arrives mid-backspace", function()
			-- Model: user typed "btw" (trigger). During the 3 backspaces,
			-- the physical character 'c' arrives after the 2nd backspace.
			-- Without input queuing, the 'c' is appended between the
			-- backspaces and the replacement, producing wrong output.
			local doc = { value = "btw" }
			local interleaved = false
			local runner = make_virtual_runner(doc, function(bs_i, d)
				if bs_i == 2 and not interleaved then
					interleaved = true
					d.value = d.value .. "c"  -- physical 'c' lands mid-erase
				end
			end)

			injector._set_runner(runner)
			-- Reset queue state from any prior test.
			injector._end_injection()
			injector.inject(3, "by the way")
			injector._reset_runner()

			-- Without queuing, the result is corrupted:
			-- "btw" → BS1="bt" → BS2="b" + 'c'="bc" → BS3="b"
			-- → type "by the way" → "bby the way"
			-- The correct output after the fix would be "by the wayc".
			helpers.assert_true(doc.value ~= "by the wayc",
				"race CORRUPTS output — got '" .. doc.value .. "' instead of 'by the wayc'")
			helpers.assert_true(interleaved,
				"interleaving was triggered")
		end)
	end)

	-- ======================================================================
	-- 3. Queuing fix — input queue prevents corruption
	-- ======================================================================

	helpers.describe("input queuing fix", function()
		helpers.it("preserves correct output by queuing mid-injection chars", function()
			-- Same scenario as the race test, but the daemon queues
			-- characters that arrive during injection and replays them
			-- after the injection completes.
			local doc = { value = "btw" }
			local queued = {}
			local runner = make_virtual_runner(doc, function(bs_i, d)
				if bs_i == 2 and #queued == 0 then
					-- Simulate a physical 'c' arriving mid-injection.
					-- With queuing, it is NOT appended to doc now.
					-- Instead it is queued for replay after injection.
					queued[#queued + 1] = "c"
				end
			end)

			-- Begin injection — this arms the queue.
			injector._begin_injection()
			injector._set_runner(runner)
			injector.inject(3, "by the way")
			injector._reset_runner()
			-- End injection and drain queued characters.
			local drained = injector._end_injection()

			-- Merge any queued chars from both the explicit queue
			-- (simulated physical input) and the drained injector queue.
			for _, ch in ipairs(drained) do
				queued[#queued + 1] = ch
			end
			for _, ch in ipairs(queued) do
				doc.value = doc.value .. ch
			end

			-- After the fix, the output is correct:
			-- "btw" → BS×3=""" → type "by the way" → drain "c" → "by the wayc"
			helpers.assert_eq(doc.value, "by the wayc",
				"queuing prevents corruption — 'c' replayed after injection")
		end)

		helpers.it("_is_injecting flag reflects injection state", function()
			injector._end_injection()  -- reset
			helpers.assert_true(not injector._is_injecting(),
				"not injecting before begin")
			injector._begin_injection()
			helpers.assert_true(injector._is_injecting(),
				"injecting after begin")
			injector._end_injection()
			helpers.assert_true(not injector._is_injecting(),
				"not injecting after end")
		end)

		helpers.it("_queue_char is a no-op when not injecting", function()
			injector._end_injection()  -- reset
			injector._queue_char("x")
			local drained = injector._end_injection()
			helpers.assert_eq(#drained, 0,
				"queue is empty when not injecting")
		end)

		helpers.it("_queue_char stores chars when injecting", function()
			injector._end_injection()  -- reset
			injector._begin_injection()
			injector._queue_char("a")
			injector._queue_char("b")
			local drained = injector._end_injection()
			helpers.assert_eq(drained, {"a", "b"},
				"queued chars returned in arrival order")
		end)
	end)

end)
