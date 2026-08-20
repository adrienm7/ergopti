--- tests/unit/modules/keylogger/test_context_tracker_url_decode.lua

--- Regression tests for two context_tracker bugs:
---
--- keylogger-support-3: The AXDocument percent-decode pass included
---   path:gsub("+", " ")
--- '+' is a literal character in file:// URLs (form-encoded bodies use + for
--- space, but not path segments). A file named "C++_notes.txt" would have its
--- name corrupted to "C  _notes.txt". Fix: remove the + substitution entirely.
---
--- keylogger-support-5: Native autocorrect detection compared #val vs
--- #_last_ax_value (byte lengths). For multi-byte UTF-8 characters (é, à, …)
--- a single-char edit changes the byte count by 2, falsely triggering the
--- "> 1" threshold. Fix: use utf8.len for character counts.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/keylogger/context_tracker.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function update_secure_field_state")
helpers.assert_true(src ~= nil, "modules/keylogger/context_tracker.lua source must be locatable")

-- Test 1 (keylogger-support-3): + must not be decoded as space in the path decode.
local has_plus_decode = src:find('gsub("+", " ")', 1, true) ~= nil
helpers.assert_true(
	not has_plus_decode,
	'context_tracker.lua must not decode "+" as space in file:// path (corrupts paths with + in name) (keylogger-support-3)'
)

-- Test 2 (keylogger-support-3): percent-decode must still be present.
local has_percent_decode = src:find('gsub("%%(%x%x)"', 1, true) ~= nil
helpers.assert_true(
	has_percent_decode,
	"context_tracker.lua must still percent-decode %%XX sequences in AXDocument path (keylogger-support-3)"
)

-- Test 3 (keylogger-support-5): utf8.len must be used for autocorrect char counting.
local has_utf8_len = src:find("utf8.len(val)", 1, true) ~= nil
helpers.assert_true(
	has_utf8_len,
	"context_tracker.lua must use utf8.len(val) for autocorrect character count, not #val (keylogger-support-5)"
)

-- Test 4 (keylogger-support-5): byte-length comparison must be absent from the autocorrect block.
-- Find the autocorrect detection block around handle_ax_value_changed.
local detect_start = src:find("handle_ax_value_changed", 1, true)
helpers.assert_true(
	detect_start ~= nil,
	"context_tracker.lua must have handle_ax_value_changed function (keylogger-support-5)"
)
local detect_block = src:sub(detect_start, detect_start + 600)
local has_raw_hash_comparison = detect_block:find("#val - #_last_ax_value", 1, true) ~= nil
helpers.assert_true(
	not has_raw_hash_comparison,
	"context_tracker.lua handle_ax_value_changed must not compare #val - #_last_ax_value (byte lengths) — use utf8.len (keylogger-support-5)"
)

print("[PASS] test_context_tracker_url_decode")
