--- _shared/tests/corpus/keystats/trigger_roi.lua

--- ==============================================================================
--- MODULE: Trigger ROI Behaviour Corpus
--- DESCRIPTION:
--- The same admitted-event and refusal sequences run under LuaJIT and Lua 5.4.
--- The expected payloads describe the Windows contract independently of the
--- generated policy, including UTF-16 lengths and cumulative session snapshots.
--- ==============================================================================

return function(helpers)
	local Roi = require("keystats.trigger_roi")
	local function context(window, app, title)
		return { app = app or "Editor", window = window or 1, title = title or "Document", timestamp = "2026-11-07 10:00:00.000" }
	end
	local function unknown() return false end
	local function rows(state)
		local events = {}
		helpers.assert_true(Roi.drain(state, function(event) events[#events + 1] = event; return true end))
		return events
	end
	local function repeat_word(state, word, count)
		for _ = 1, count do Roi.text(state, word .. " ", context(), unknown) end
	end

	helpers.describe("shared trigger ROI", function()
		helpers.it("excludes lowercase equivalents of the complete admitted trigger registry", function()
			local index = Roi.trigger_index({ { trigger = "UPPER" }, { trigger = "ÉCOLE" }, { trigger = "İ" } })
			helpers.assert_true(Roi.known_trigger(index, "upper"))
			helpers.assert_true(Roi.known_trigger(index, "école"))
			helpers.assert_true(Roi.known_trigger(index, "i̇"))
			helpers.assert_eq(Roi.known_trigger(index, "other"), false)
			helpers.assert_nil(Roi.known_trigger(nil, "other"))
			helpers.assert_eq(pcall(Roi.trigger_index, { { trigger = "bad\255" } }), false)
		end)

		helpers.it("counts accepted expansions cumulatively and never retains private identities", function()
			local state = Roi.new(0, true)
			for index = 1, 10 do
				helpers.assert_true(Roi.hotstring(state, "😀", "😀😀", index == 10, index, "Editor", 123))
			end
			local events = rows(state)
			helpers.assert_eq(events, { { type = "roi_snapshot", app = "Editor", timestamp = 123,
				session_saved = 20, session_fired = 10 } })
			Roi.hotstring(state, "SECRET", "s", true, 11, "Editor", "stamp")
			helpers.assert_nil(state.last_use.secret)
			helpers.assert_eq(state.last_use["😀"], 9)
			Roi.finish(state, "Editor", "final")
			helpers.assert_eq(rows(state)[1].session_saved, 20)
			helpers.assert_eq(state.fired, 11, "zero savings still count as a fire")
		end)

		helpers.it("emits only the fifth unknown word and keeps that occurrence's case", function()
			local state = Roi.new(0, true)
			repeat_word(state, "ÉCOLE", 4)
			helpers.assert_eq(#rows(state), 0)
			Roi.text(state, "École!", context(), unknown)
			repeat_word(state, "école", 3)
			local events = rows(state)
			helpers.assert_eq(#events, 1)
			helpers.assert_eq(events[1].word, "École")
			helpers.assert_eq(events[1].occurrences, 5)
			for _ = 1, 5 do Roi.text(state, "known ", context(), function() return true end) end
			helpers.assert_nil(state.words.known)
			Roi.text(state, "missing ", context(), function() return nil end)
			Roi.text(state, "throws ", context(), function() error("lookup refused") end)
			helpers.assert_nil(state.words.missing)
			helpers.assert_nil(state.words.throws)
		end)

		helpers.it("uses exact Windows boundaries and UTF-16 minimum and maximum lengths", function()
			local state = Roi.new(0, true)
			repeat_word(state, "😀😀", 5)
			helpers.assert_eq(rows(state)[1].word, "😀😀", "two supplementary scalars occupy four UTF-16 units")
			Roi.text(state, "a:b;c-d ", context(), unknown)
			helpers.assert_eq(state.words["a:b;c-d"], 1)
			Roi.text(state, "abcd\tefgh\nijkl\rmnop.qrst,uvwx!yzab?", context(), unknown)
			for _, word in ipairs({ "abcd", "efgh", "ijkl", "mnop", "qrst", "uvwx", "yzab" }) do
				helpers.assert_eq(state.words[word], 1)
			end
			local maximum = string.rep("😀", 32)
			Roi.text(state, maximum .. " ", context(), unknown)
			helpers.assert_eq(state.words[maximum], 1)
			Roi.text(state, maximum .. "x", context(), unknown)
			Roi.key(state, "Backspace", context(), unknown)
			Roi.text(state, "safe ", context(), unknown)
			helpers.assert_nil(state.words.safe, "backspace cannot rescue an overflowed run")
			Roi.text(state, "safe ", context(), unknown)
			helpers.assert_eq(state.words.safe, 1)
		end)

		helpers.it("backspaces a scalar and discards edited, unknown, malformed and changed-context fragments", function()
			local state = Roi.new(0, true)
			Roi.text(state, "word😀", context(), unknown)
			Roi.key(state, "Backspace", context(), unknown)
			Roi.key(state, "Enter", context(), unknown)
			helpers.assert_eq(state.words.word, 1)
			for _, key in ipairs({ "Escape", "PageUp", "PageDown", "End", "Home", "Left", "Up", "Right", "Down", "Delete" }) do
				Roi.text(state, "secr", context(), unknown)
				Roi.key(state, key, context(), unknown)
				Roi.text(state, "et ", context(), unknown)
			end
			helpers.assert_nil(state.words.secret)
			Roi.text(state, "secr", context(), unknown)
			Roi.observe(state, context(2))
			Roi.observe(state, context(1))
			Roi.text(state, "et ", context(), unknown)
			helpers.assert_nil(state.words.secret, "A to B to A without a key still interrupts")
			for _, bad in ipairs({ { app = "Unknown", window = 1, title = "x", timestamp = "x" },
				{ app = "Editor", title = "x", timestamp = "x" } }) do
				Roi.text(state, "secr", context(), unknown)
				helpers.assert_eq(Roi.text(state, "et ", bad, unknown), false)
			end
			Roi.text(state, "secr", context(), unknown)
			helpers.assert_eq(Roi.text(state, "et\255 ", context(), unknown), false)
			Roi.text(state, " ", context(), unknown)
			helpers.assert_nil(state.words.secret)
		end)

		helpers.it("rejects a lookup that revokes admission, including the remaining text in its callback", function()
			local state = Roi.new(0, true)
			helpers.assert_eq(Roi.text(state, "first secret ", context(), function()
				Roi.discard(state)
				return false
			end), false)
			helpers.assert_eq(state.words, {})
			helpers.assert_eq(#state.word, 0)
		end)

		helpers.it("caps tracked words while preserving frequent candidates", function()
			local state = Roi.new(0, true)
			repeat_word(state, "frequent", 4)
			for index = 1, 500 do repeat_word(state, "word" .. index, 1) end
			helpers.assert_eq(state.word_count, 1, "singletons are discarded before bounded selection")
			helpers.assert_eq(state.words.frequent, 4)
			repeat_word(state, "frequent", 1)
			helpers.assert_eq(rows(state)[1].word, "frequent")
		end)

		helpers.it("retains the highest UTF-16 keys among equal-frequency survivors", function()
			local state = Roi.new(0, true)
			for index = 500, 1, -1 do repeat_word(state, string.format("word%04d", index), 2) end
			repeat_word(state, "new-noise", 1)
			helpers.assert_eq(state.word_count, 250)
			helpers.assert_nil(state.words.word0001)
			helpers.assert_eq(state.words.word0500, 2)
		end)

		helpers.it("uses UTF-16 rather than UTF-8 ordering at the prune cutoff", function()
			local state = Roi.new(0, true)
			for index = 1, 249 do repeat_word(state, "￿word" .. index, 2) end
			repeat_word(state, "𐀀word", 2)
			repeat_word(state, "word", 2)
			for index = 1, 250 do repeat_word(state, "noise" .. index, 1) end
			helpers.assert_eq(state.word_count, 250)
			helpers.assert_nil(state.words["𐀀word"], "the D800 surrogate sorts before the E000 scalar")
			helpers.assert_eq(state.words["word"], 2)
		end)

		helpers.it("warns only about public triggers used this process, with hourly cadence and one decimal", function()
			local state = Roi.new(0, true)
			Roi.hotstring(state, "PUBLIC", "replacement", false, 0, "Editor", "start")
			Roi.hotstring(state, "PRIVATE", "replacement", true, 0, "Editor", "start")
			local day = 24 * 60 * 60 * 1000
			Roi.tick(state, 30 * day - 1, "Editor", "early")
			helpers.assert_eq(#rows(state), 0)
			helpers.assert_eq(Roi.tick(state, 30 * day, "Editor", "too-soon"), false)
			Roi.tick(state, 30 * day + 3600000, "Editor", "due")
			local event = rows(state)[1]
			helpers.assert_eq(event.trigger, "public")
			helpers.assert_eq(event.days_since_use, 30)
			Roi.tick(state, 30.2 * day, "Editor", "repeat")
			helpers.assert_eq(rows(state)[1].days_since_use, 30.2)
			helpers.assert_eq(Roi.tick(state, 0, "Editor", "backward"), false)
		end)

		helpers.it("withholds textual metrics under encryption while retaining cumulative savings", function()
			local state = Roi.new(0, false)
			for index = 1, 10 do
				helpers.assert_eq(Roi.text(state, "candidate ", context(), unknown), false)
				Roi.hotstring(state, "secret", "secret output", false, index, "Editor", "stamp")
			end
			helpers.assert_eq(state.words, {})
			helpers.assert_eq(state.last_use, {})
			helpers.assert_eq(state.word, {})
			Roi.tick(state, 31 * 24 * 60 * 60 * 1000, "Editor", "later")
			local events = rows(state)
			helpers.assert_eq(events, { { type = "roi_snapshot", app = "Editor", timestamp = "stamp",
				session_saved = 70, session_fired = 10 } })
		end)

		helpers.it("retires text on an encryption request without resurrecting it when disabled", function()
			local state = Roi.new(0, true)
			repeat_word(state, "candidate", 5)
			for index = 1, 10 do Roi.hotstring(state, "public", "expanded output", false, index, "Editor", "stamp") end
			Roi.text(state, "secr", context(), unknown)
			Roi.set_text_enabled(state, false)
			helpers.assert_eq(state.words, {})
			helpers.assert_eq(state.last_use, {})
			helpers.assert_eq(state.word, {})
			local events = rows(state)
			helpers.assert_eq(#events, 1)
			helpers.assert_eq(events[1].type, "roi_snapshot")
			Roi.set_text_enabled(state, true)
			Roi.text(state, "et ", context(), unknown)
			helpers.assert_nil(state.words.secret)
			helpers.assert_nil(state.words.candidate)
			helpers.assert_eq(state.fired, 10)
			helpers.assert_eq(pcall(Roi.set_text_enabled, state, nil), false)
			helpers.assert_eq(pcall(Roi.new, 0), false)
		end)

		helpers.it("does not acknowledge another queued row when a sink revokes text reentrantly", function()
			local state = Roi.new(0, true)
			repeat_word(state, "candidate", 5)
			for index = 1, 10 do Roi.hotstring(state, "public", "expanded output", false, index, "Editor", "stamp") end
			local kinds = {}
			helpers.assert_true(Roi.drain(state, function(event)
				kinds[#kinds + 1] = event.type
				if event.type == "new_trigger_candidate" then Roi.set_text_enabled(state, false) end
				return true
			end))
			helpers.assert_eq(kinds, { "new_trigger_candidate", "roi_snapshot" })
		end)

		helpers.it("retains a refused or throwing event sink without duplicating an accepted head", function()
			local state = Roi.new(0, true)
			repeat_word(state, "candidate", 5)
			local original = state.pending[1]
			helpers.assert_eq(Roi.drain(state, function() return nil end), false)
			helpers.assert_eq(Roi.drain(state, function() error("disk unavailable") end), false)
			helpers.assert_eq(state.pending[1], original)
			local accepted = 0
			helpers.assert_true(Roi.drain(state, function(event)
				helpers.assert_eq(event.timestamp, "2026-11-07 10:00:00.000")
				helpers.assert_eq(Roi.drain(state, function() return true end), false)
				accepted = accepted + 1
				return true
			end))
			helpers.assert_eq(accepted, 1)
			helpers.assert_eq(#state.pending, 0)
		end)
	end)
end
