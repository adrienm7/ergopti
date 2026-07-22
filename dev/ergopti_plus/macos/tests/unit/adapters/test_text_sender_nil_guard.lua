--- tests/unit/adapters/test_text_sender_nil_guard.lua

--- Regression test for adapters-input-1: text_sender.send() called `#text`
--- and Clipboard.write(text) without first checking that text was a string.
--- Passing nil or a non-string value caused an immediate Lua error
--- ("attempt to get length of a nil value") before any pcall could catch it.
---
--- Fix: a type-check guard at the top of M.send() logs an error and returns
--- early if text is not a string.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "adapters/text_sender.lua"
local fh = io.open(src_path, "r")
if not fh then error("adapters/text_sender.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: type-check on `text` exists near the top of M.send().
local guard = src:find('type(text) ~= "string"', 1, true)
helpers.assert_true(
	guard ~= nil,
	'adapters/text_sender.lua must guard send() with type(text) ~= "string" (adapters-input-1)'
)

-- Test 2: the guard appears before the first `#text` usage (which would
-- crash on nil). Detect `#text` as it appears in the mode-resolution block.
local hash_text = src:find("#text >", 1, true)
helpers.assert_true(
	hash_text ~= nil,
	"adapters/text_sender.lua must still contain #text > CLIPBOARD_THRESHOLD logic"
)
helpers.assert_true(
	guard < hash_text,
	"type-check guard must appear before the first #text usage (adapters-input-1)"
)

print("[PASS] test_text_sender_nil_guard")
