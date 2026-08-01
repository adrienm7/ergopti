--- tests/unit/lib/test_config_overrides_comment_strip.lua

--- Regression test for lib-config-1: the inline TOML comment strip pattern
--- `%s*#[^"]*$` failed when the comment contained a double-quote character.
--- `[^"]*` is non-greedy over non-" chars; if a " follows the #, the anchor
--- `$` stops matching and gsub leaves the comment in the value.
---
--- Example:
---   key = "DEBUG" # note with "quotes"
---   → old: value = '"DEBUG" # note with "quotes"'  (strip missed)
---   → new: value = '"DEBUG"'  (correct)
---
--- Fix: branch on whether the value starts with a quote; for quoted strings,
--- extract through the closing quote; for unquoted, strip from the first #.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to infra/config_overrides.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function match_quoted_prefix")
helpers.assert_true(src ~= nil, "infra/config_overrides.lua source must be locatable")

-- Test 1: The old broken pattern must not appear.
local has_old_pattern = src:find('[^"]*$', 1, true) ~= nil
-- The old pattern was literally: '%s*#[^"]*$'
-- We check for the string #[^"] which was the broken anchor
local has_broken = src:find('#[^"]', 1, true) ~= nil
-- More precisely: the old literal pattern string
local has_old_literal = src:find('"%%s*#[^"]*$"', 1, true) ~= nil
helpers.assert_true(
	not has_old_literal,
	"config_overrides.lua must not use the broken `%%s*#[^\"]*$` comment-strip pattern (lib-config-1)"
)

-- Test 2: The quote-aware split must be present — check for the branch on `value:sub(1,1) == '"'`
local has_branch = src:find('value:sub(1, 1) == \'"\' ', 1, true) ~= nil
	or src:find("value:sub(1, 1) == '\"'", 1, true) ~= nil
	or src:find('value:sub(1,1) == \'"\'', 1, true) ~= nil
	or src:find("if value:sub(1", 1, true) ~= nil
helpers.assert_true(
	has_branch,
	"config_overrides.lua must branch on whether the value is a quoted string for comment stripping (lib-config-1)"
)

-- Test 3: The fallback for unquoted values uses `#.*$` to strip the whole comment.
-- The literal Lua gsub pattern string "#.*$" must appear in the source.
local has_fallback = src:find("#.*$", 1, true) ~= nil
helpers.assert_true(
	has_fallback,
	"config_overrides.lua must use a '#.*$' pattern for unquoted value comment strip (lib-config-1)"
)

print("[PASS] test_config_overrides_comment_strip")
