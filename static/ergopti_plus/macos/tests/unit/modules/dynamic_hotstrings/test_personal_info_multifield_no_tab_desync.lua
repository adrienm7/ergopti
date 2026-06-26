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
--- Fix: arm the tracker + buffer with the TAB-FREE concatenation (`echoed`), which
--- is exactly the codepoints the OS echoes (values only). do_expand is local, so —
--- like the sibling fallback regression — this pins the invariant at source: the
--- production path must use `echoed` (no \t), never `emitted` (with \t).
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src()
	local path = helpers.driver_root() .. "modules/dynamic_hotstrings/personal_info.lua"
	local fh = assert(io.open(path, "r"))
	local src = fh:read("*a"); fh:close()
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

	helpers.it("the emit callback returns `echoed`, not `emitted`", function()
		local src = read_src()
		helpers.assert_true(src:find("return c, echoed", 1, true) ~= nil,
			"the emit callback must return the tab-free `echoed` as expected_synthetic_chars")
		helpers.assert_true(src:find("return c, emitted", 1, true) == nil,
			"the emit callback must NOT return the \\t-joined `emitted`")
	end)
end)
