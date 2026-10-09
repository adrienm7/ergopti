--- tests/unit/modules/keymap/test_french_punctuation_terminators.lua

--- ==============================================================================
--- MODULE: Regression — French punctuation must terminate an expansion, and the
---         resume resync must identify the app the way everything else does
---         (french-punctuation-terminators)
--- DESCRIPTION:
--- Two findings whose common shape is a lookup keyed on the wrong part of a
--- value.
---
---   H10  TERMINATORS MISSED THE TAIL. The macOS layout emits French
---        punctuation as ONE event carrying its typographic space first:
---        ":" arrives as NBSP..":" and ";" / "!" / "?" as NNBSP..<char>. Those
---        spaces are default-DISABLED terminators while the punctuation itself
---        is default-enabled — so is_terminator, which probed the whole string
---        and its FIRST codepoint only, rejected every one of them. The enabled
---        character was always the tail. autocorrection is the flagship feature
---        and is entirely non-auto accent corrections that fire only on a
---        terminator, so the four canonical French sentence endings silently
---        did not fire, while the tooltip had already advertised the row.
---
---   H9   THE RESUME RESYNC READ THE WRONG API. resync_context identified the
---        frontmost app with app:title(); every other part of the pipeline —
---        including SecureFieldDetector.isSecureApp, which exact-matches
---        DISPLAY names — uses app:name(). Its own sibling capture_frontmost_app
---        documents that title() "is absent for some application instances". A
---        password manager whose title is nil or differs from its display name
---        was therefore not re-recognised as secure on resume, so keystrokes
---        typed into it were logged and mis-attributed to the previous app.
---
--- SCOPE, STATED PLAINLY: the terminator half is fully behavioural — the byte
--- sequences are reproduced here and the gate is a pure function. The H9 half
--- is asserted on source: it needs a real Mac with a live hs.application to
--- exercise, and the audit itself rates it deduced rather than measured. What
--- is proven here is the API asymmetry, which is what makes the fix correct;
--- the runtime consequence remains unverified on this platform.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The two typographic spaces the macOS layout prepends. Written as explicit
--- bytes rather than escapes so the fixture cannot drift with source encoding.
local NBSP = string.char(0xC2, 0xA0)          -- U+00A0
local NNBSP = string.char(0xE2, 0x80, 0xAF)   -- U+202F

local function terminators()
	return helpers.load_with_stubs("keymap.terminators", {})
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ A prefixed terminator still terminates =======================
-- =========================================================================
-- =========================================================================

helpers.describe("terminators: French punctuation arrives space-prefixed", function()
	helpers.it("the bare punctuation is a terminator to begin with", function()
		local T = terminators()
		for _, ch in ipairs({ "?", "!", ":", ";" }) do
			helpers.assert_true(T.is_terminator(ch),
				"'" .. ch .. "' must be an enabled terminator by default — if it is not, the "
					.. "prefixed assertions below would be measuring the wrong thing")
		end
	end)

	helpers.it("an NNBSP-prefixed punctuation is recognised", function()
		local T = terminators()
		for _, ch in ipairs({ "?", "!", ";" }) do
			helpers.assert_true(T.is_terminator(NNBSP .. ch),
				"the layout emits '" .. ch .. "' as one event with a leading NNBSP. Probing only "
					.. "the whole string and its FIRST codepoint misses it — NNBSP is a "
					.. "default-disabled terminator, so the enabled character is always the tail. "
					.. "Every French sentence ending then failed to fire the correction, while the "
					.. "tooltip had already offered it")
		end
	end)

	helpers.it("an NBSP-prefixed colon is recognised", function()
		local T = terminators()
		helpers.assert_true(T.is_terminator(NBSP .. ":"),
			"':' arrives with a leading NBSP rather than NNBSP, and must be handled identically")
	end)

	helpers.it("the disabled space alone is still not a terminator", function()
		local T = terminators()
		helpers.assert_true(not T.is_terminator(NNBSP),
			"NNBSP on its own is default-disabled and must stay so. Accepting it would make every "
					.. "typographic space terminate an expansion, which is the opposite failure")
		helpers.assert_true(not T.is_terminator(NBSP),
			"NBSP on its own must likewise stay a non-terminator")
	end)

	helpers.it("an unrelated multi-codepoint event is still rejected", function()
		local T = terminators()
		helpers.assert_true(not T.is_terminator("ab"),
			"the tail probe must not turn arbitrary text into a terminator — only a genuinely "
				.. "enabled terminator character may match")

		local STAR = utf8.char(0x2605)
		T.update_magic_key(":")
		local ok, err = pcall(function()
			helpers.assert_true(not T.is_terminator("x:"),
				"even when ':' is the consumed magic terminator, an arbitrary suffix event must pass")
			helpers.assert_true(not T.terminator_is_consumed("x:"),
				"a rejected composite must never swallow both of its physical codepoints")
			helpers.assert_true(T.is_terminator(":x"),
				"the documented leading-codepoint IME terminator behavior must remain available")
			helpers.assert_true(not T.matches_magic_event(":x", ":"),
				"an IME payload must not acquire configured-magic identity from its first codepoint")
			helpers.assert_true(not T.terminator_is_consumed(":x"),
				"a leading consumed terminator may fire, but the full IME payload must be replayed")
		end)
		T.update_magic_key(STAR)
		if not ok then error(err, 0) end
	end)

	helpers.it("the consume verdict tracks the same tail", function()
		local T = terminators()
		-- Whatever the consume policy is for a given terminator, the prefixed
		-- form must agree with the bare one. A terminator recognised by one probe
		-- and not the other is either consumed when it should be re-typed, or
		-- re-typed when it should be consumed.
		for _, ch in ipairs({ "?", "!", ";" }) do
			helpers.assert_eq(
				T.terminator_is_consumed(NNBSP .. ch),
				T.terminator_is_consumed(ch),
				"the consume verdict for '" .. ch .. "' must not depend on whether the layout "
					.. "prepended its typographic space")
		end
	end)

	helpers.it("recognises only exact or known French composite magic events", function()
		local T = terminators()
		for _, ch in ipairs({ "?", "!", ":", ";", "%", "€" }) do
			helpers.assert_true(T.matches_magic_event(ch, ch),
				"an exact configured magic key must always validate itself")
			helpers.assert_true(T.matches_magic_event(NBSP .. ch, ch),
				"NBSP-prefixed French punctuation must validate its configured tail")
			helpers.assert_true(T.matches_magic_event(NNBSP .. ch, ch),
				"NNBSP-prefixed French punctuation must validate its configured tail")
		end
		helpers.assert_true(not T.matches_magic_event("x:", ":"),
			"an arbitrary multi-codepoint event must never acquire magic-key identity by suffix")
		helpers.assert_true(not T.matches_magic_event(NBSP .. "?", ":"),
			"a known carrier for a different punctuation key must not validate the configured key")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ The resume resync uses the display-name API ==================
-- =========================================================================
-- =========================================================================

--- Returns every `function M.resync_context` body found in the driver, keyed by
--- nothing — order is deliberately not relied on.
---
--- There are TWO definitions: the real one in the context tracker, and a thin
--- forwarder in the keylogger that delegates to it. `read_driver_source` returns
--- them concatenated, and the concatenation ORDER depends on how the corpus was
--- walked — lfs on one machine, a shell listing on another. The first version of
--- these cases looked only at the first occurrence, so it read the real
--- implementation locally and the forwarder on CI, where it failed for a reason
--- that had nothing to do with the code under test.
--- @return table Array of body strings.
local function resync_bodies()
	local src = helpers.read_driver_source("resync_context")
	helpers.assert_true(src ~= nil and src ~= "",
		"the context tracker must be locatable by its resync_context symbol")

	-- Comments stripped FIRST. The fix's own comment explains why title() is wrong
	-- and therefore contains the string "app:title()" — scanning raw source flags
	-- the fix as the bug. The repo's meta-test guidance calls this out explicitly.
	local code = src:gsub("%-%-[^\n]*", "")

	local bodies, from = {}, 1
	while true do
		local at = code:find("function M.resync_context", from, true)
		if not at then break end
		table.insert(bodies, code:sub(at, at + 900))
		from = at + 1
	end
	return bodies
end


--- True when a body delegates instead of resolving the app itself.
--- @param body string
--- @return boolean
local function delegates(body)
	return body:find("ContextTracker.resync_context", 1, true) ~= nil
end


--- Returns every `function M.resync_context` body found in the driver, keyed by
--- nothing — order is deliberately not relied on.
---
--- There are TWO definitions: the real one in the context tracker, and a thin
--- forwarder in the keylogger that delegates to it. `read_driver_source` returns
--- them concatenated, and the concatenation ORDER depends on how the corpus was
--- walked — lfs on one machine, a shell listing on another. The first version of
--- these cases looked only at the first occurrence, so it read the real
--- implementation locally and the forwarder on CI, where it failed for a reason
--- that had nothing to do with the code under test.
--- @return table Array of body strings.
local function resync_bodies()
	local src = helpers.read_driver_source("resync_context")
	helpers.assert_true(src ~= nil and src ~= "",
		"the context tracker must be locatable by its resync_context symbol")

	-- Comments stripped FIRST. The fix's own comment explains why title() is wrong
	-- and therefore contains the string "app:title()" — scanning raw source flags
	-- the fix as the bug. The repo's meta-test guidance calls this out explicitly.
	local code = src:gsub("%-%-[^\n]*", "")

	local bodies, from = {}, 1
	while true do
		local at = code:find("function M.resync_context", from, true)
		if not at then break end
		table.insert(bodies, code:sub(at, at + 900))
		from = at + 1
	end
	return bodies
end


--- True when a body delegates instead of resolving the app itself.
--- @param body string
--- @return boolean
local function delegates(body)
	return body:find("ContextTracker.resync_context", 1, true) ~= nil
end


helpers.describe("context_tracker: resync identifies the app by name", function()

	helpers.it("every resync_context either reads app:name() or delegates", function()
		local bodies = resync_bodies()
		helpers.assert_true(#bodies >= 1,
			"at least one M.resync_context must exist; zero would make every assertion "
			.. "below vacuous")

		local offenders = {}
		local resolvers = 0
		for i, body in ipairs(bodies) do
			if delegates(body) then
				-- A forwarder must not ALSO reach for the app itself, or the two would
				-- disagree about what the active context is.
				if body:find("app:name()", 1, true) or body:find("app:title()", 1, true) then
					table.insert(offenders, "#" .. i .. " both delegates and resolves")
				end
			else
				resolvers = resolvers + 1
				if body:find("app:name()", 1, true) == nil then
					table.insert(offenders, "#" .. i .. " resolves without app:name()")
				end
				if body:find("app:title()", 1, true) ~= nil then
					table.insert(offenders, "#" .. i .. " still reads app:title()")
				end
			end
		end

		helpers.assert_true(resolvers >= 1,
			"exactly one definition must actually resolve the app; if they all delegate, "
			.. "nothing does the work and this test would pass over a driver that never "
			.. "identifies the foreground app at all")

		helpers.assert_eq(#offenders, 0,
			"the whole pipeline is keyed on display names — SecureFieldDetector.isSecureApp "
			.. "exact-matches them — so reading title() means a vault whose title is nil or "
			.. "differs is not re-recognised as secure on resume, and keystrokes typed into "
			.. "it get logged: " .. table.concat(offenders, ", "))
	end)

	helpers.it("the resolver rejects an empty name as well as a missing one", function()
		local bodies = resync_bodies()

		local checked = 0
		for _, body in ipairs(bodies) do
			if not delegates(body) then
				checked = checked + 1
				helpers.assert_true(body:find('app_name == ""', 1, true) ~= nil,
					"an app with a blank name must not be adopted as the active context — the "
					.. "type check alone accepts \"\", which would set an unusable "
					.. "active_app_name and defeat every later comparison against it")
			end
		end
		helpers.assert_true(checked >= 1, "at least one resolver must have been checked")
	end)

	helpers.it("it matches the sibling resume helper", function()
		local src = helpers.read_driver_source("capture_frontmost_app")
		helpers.assert_true(src ~= nil and src ~= "",
			"the sibling resume helper must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		-- Same hazard as above: iterate every occurrence rather than trusting the
		-- first, so a second file merely MENTIONING the helper cannot decide the
		-- outcome depending on how the corpus was walked.
		local found_with_name = false
		local from = 1
		while true do
			local at = code:find("capture_frontmost_app", from, true)
			if not at then break end
			if code:sub(at, at + 900):find("app:name()", 1, true) then
				found_with_name = true
				break
			end
			from = at + 1
		end

		helpers.assert_true(found_with_name,
			"capture_frontmost_app must still use name(). It is the reference implementation "
			.. "the resync fix aligns with — if it ever changes, the two must change together")
	end)

end)
