-- .luacheckrc
-- Linting configuration for the Hammerspoon driver and its test suite.

std = "lua54"

-- The Hammerspoon runtime injects a global `hs` table; tests inject `keymap`
-- onto _G via init.lua. Both must be allowed as read/write globals.
globals = {
	"hs",
	"keymap",
}

-- Treat helper-test globals as read-only
read_globals = {
	"describe",
	"it",
	"before_each",
	"after_each",
	"setup",
	"teardown",
	"assert",
}

ignore = {
	"212/self",  -- unused method argument self
	"611",       -- line contains only whitespace
	"612",       -- line contains trailing whitespace
	"613",       -- trailing whitespace in a string
	"614",       -- trailing whitespace in a comment
	"631",       -- line is too long
}

exclude_files = {
	"static/drivers/hammerspoon/hs/_asm/**",
}

files["static/drivers/hammerspoon/tests/"] = {
	-- Tests legitimately do dynamic requires and global stub injection
	ignore = { "111", "112", "113", "121", "122", "143" },
}
