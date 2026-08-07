--- tests/unit/ui/test_menu_metrics_dir_guard.lua

--- Regression test for two defects in ui/menu/menu_metrics.lua.
---
--- ui-menu-misc-3: the encrypt and decrypt toggle paths called
--- `for file in fs.dir(log_dir)` without checking whether fs.dir returned a
--- valid iterator. When the directory does not exist fs.dir returns nil, and
--- iterating nil crashes Lua mid-toggle — leaving state.keylogger_encrypt
--- mutated while the UI stayed unsynchronised.
---
--- The guard used to be asserted by counting the `dir_iter` variable, which was
--- a proxy for "both loops are guarded". Those loops are gone: they scanned for
--- *.log.gz files, a storage format retired when persistence moved to SQLite.
--- Counting a variable that no longer exists would only assert that the code was
--- deleted, so the check is now the GENERAL form of the same rule — no fs.dir
--- result may be iterated directly, anywhere in the file. That is strictly
--- stronger than the original and survives the removal.
---
--- The second defect is the one that made the whole feature a lie: the
--- "Chiffrement" entry ticked its box and persisted the setting while the
--- backend was two empty stubs. The toggle must now ask the real backend whether
--- it can encrypt before claiming that it does.

local helpers = require("tests.helpers")

-- Read by a symbol unique to menu_metrics.lua rather than a pinned path, so the
-- guard survives the file being moved. dyn_show_typing is defined only here.
-- Every assertion below is a substring or per-line check — order-independent —
-- so concatenation, were the symbol ever non-unique, could not silently change
-- what is asserted.
-- A selector unique to this file rather than its path, so moving or splitting a
-- module cannot turn these invariants into path errors. It named dyn_show_typing
-- until 2026-08-07, when that handler became a `command` — a selector has to be
-- something the file keeps.
local src = helpers.read_driver_source("local STATE_GETTERS")
if not src or src == "" then error("menu_metrics.lua source not found via read_driver_source") end

--- Drops lines whose first non-blank characters are a Lua comment marker, so the
--- prose above a call site cannot satisfy or trip a check.
local function strip_comment_lines(text)
	local kept = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if not line:match("^%s*%-%-") then kept[#kept + 1] = line end
	end
	return table.concat(kept, "\n")
end

local code = strip_comment_lines(src)

-- Self-check: a stripper that returned "" would make every absence assertion
-- below vacuously true, which is exactly the failure mode being guarded against.
helpers.assert_true(
	strip_comment_lines("-- comment\nlocal keep = 1\n"):find("local keep = 1", 1, true) ~= nil,
	"the comment stripper must keep live code, or the checks below assert nothing"
)

-- Test 1: no fs.dir result may be iterated directly. The original form named
-- log_dir specifically; this covers every variable, so the rule cannot be
-- side-stepped by iterating a differently-named directory.
helpers.assert_true(
	code:match("for%s+[%w_,%s]+in%s+fs%.dir%s*%(") == nil,
	"menu_metrics.lua must never iterate an fs.dir() result directly — capture it and nil-check first (ui-menu-misc-3)"
)

-- Test 2: any fs.dir call must bind its result before use.
for line in (code .. "\n"):gmatch("([^\n]*)\n") do
	if line:find("fs.dir", 1, true) then
		helpers.assert_true(
			line:match("local%s+[%w_]+%s*=%s*fs%.dir") ~= nil,
			"every fs.dir() call must bind its result before use, got: " .. line
		)
	end
end

-- Test 3: the encryption toggle must consult the real backend before ticking.
-- Without this the entry can regress into what it was — a box reporting
-- encryption while nothing encrypts.
helpers.assert_true(
	code:find("TextCipher.is_available()", 1, true) ~= nil,
	"the encryption toggle must ask the backend whether it can encrypt before claiming that it does"
)
helpers.assert_true(
	code:find("TextCipher.set_enabled(", 1, true) ~= nil,
	"the encryption toggle must drive the real cipher, not just persist a preference"
)

print("[PASS] test_menu_metrics_dir_guard")
