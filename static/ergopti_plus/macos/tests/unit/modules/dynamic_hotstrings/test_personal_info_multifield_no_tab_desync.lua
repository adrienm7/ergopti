--- tests/unit/modules/dynamic_hotstrings/test_personal_info_multifield_no_tab_desync.lua

--- ==============================================================================
--- MODULE: personal_info — production multi-field path must not arm a literal \t
--- DESCRIPTION:
--- Audit finding F-H3. The FALLBACK path was fixed to arm_synthetic(n_back, "")
--- because inter-field tabs fire as real Tab keyStrokes the keymap never sees as a
--- literal \t (guarded by test_personal_info_sync_injection.lua). But the PRODUCTION
--- path routes through _keymap.inject_dynamic whose emit callback returned the
--- \t-joined `emitted` as its second value — perform_text_replacement stores that in
--- expected_synthetic_chars and inject_dynamic writes it into CoreState.buffer. The
--- unmatched \t then desynced the keymap buffer after every multi-field @-tag combo
--- (e.g. @pn → first_name + last_name).
---
--- Fix: arm the BUFFER with the TAB-FREE concatenation (`echoed`). A Tab moves
--- focus to the next form field — it inserts no character on screen — so
--- CoreState.buffer must never contain a \t. That invariant is unchanged and is
--- still pinned by the first two cases below.
---
--- CORRECTION (audit G3). F-H3 also applied the tab-free string to the emit
--- callback's SECOND return value, on the premise that a synthetic Tab is "never
--- seen as a literal \t". That premise is wrong: the expander's own terminator
--- path fires the identical `hs.eventtap.keyStroke({}, "tab", 0)` and explicitly
--- appends "\t" to its physical-echo string, and `is_terminator("\t")` classifies
--- real Tab presses from `getCharacters()` — a Tab keydown DOES echo as "\t".
--- The second return value is the PHYSICAL ECHO ("only OS key events that must be
--- discarded", per perform_text_replacement's contract), not the buffer text, and
--- it must therefore enumerate the inter-field tabs. Omitting them left the
--- keylogger's synth_queue N-1 entries short for N fields — its fast path pops an
--- entry even on a char mismatch — so the payload's trailing characters were
--- recorded as HUMAN keystrokes.
---
--- The emitter now returns three values: (count, physical_echo WITH tabs,
--- logical_text WITHOUT tabs). The third case below is re-encoded onto that
--- corrected contract; the behavioural proof lives in
--- test_synth_echo_includes_tabs.lua, which drives the real interceptor.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src()
	-- Selected by a declaration unique to modules/dynamic_hotstrings/personal_info.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function parse_toml_section")
	helpers.assert_true(src ~= nil, "modules/dynamic_hotstrings/personal_info.lua source must be locatable")
	return src
end

helpers.describe("personal_info production path arms a tab-free synthetic string", function()
	helpers.it("defines a tab-free `echoed` joined with no separator", function()
		local src = read_src()
		helpers.assert_true(src:find('echoed%s*=%s*table%.concat%(parts,%s*""%)') ~= nil,
			"must derive `echoed = table.concat(parts, \"\")` (values only, no inter-field tab)")
	end)

	helpers.it("calls inject_dynamic with the tab-free `echoed`, not the \\t-joined `emitted`", function()
		local src = read_src()
		helpers.assert_true(src:find("inject_dynamic(n_back, echoed", 1, true) ~= nil,
			"inject_dynamic's result_text must be `echoed` (tab-free) so CoreState.buffer holds no \\t")
		helpers.assert_true(src:find("inject_dynamic(n_back, emitted", 1, true) == nil,
			"inject_dynamic must NOT be armed with the \\t-joined `emitted` (re-introduces the desync)")
	end)

	helpers.it("the emit callback returns the tab-JOINED physical echo and the tab-free logical text", function()
		local src = read_src()
		-- physical_echo (2nd) enumerates every keydown the OS delivers, tabs
		-- included; logical_text (3rd) is what was actually inserted on screen.
		helpers.assert_true(src:find("return c, emitted, echoed", 1, true) ~= nil,
			"the emit callback must return (count, physical_echo WITH tabs, logical_text WITHOUT tabs) — "
			.. "a tab-free physical echo under-fills the keylogger's synth_queue")
		-- Guard the correction in BOTH directions: the two-value forms are the
		-- historical shapes, each of which broke one of the two trackers.
		helpers.assert_true(src:find("return c, echoed\n", 1, true) == nil,
			"a two-value `return c, echoed` drops the tabs from the physical echo (the G3 leak)")
		helpers.assert_true(src:find("return c, emitted\n", 1, true) == nil,
			"a two-value `return c, emitted` would put a \\t into the logical text and CoreState.buffer (the F-H3 desync)")
	end)
end)
