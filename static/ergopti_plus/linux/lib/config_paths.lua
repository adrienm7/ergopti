--- lib/config_paths.lua

--- ==============================================================================
--- MODULE: Linux User-Directory Resolver
--- DESCRIPTION:
--- Single source of truth for the user's home, config and data directories,
--- mirroring the macOS lib/paths.lua config helpers.
---
--- WHY THIS EXISTS:
--- Fifteen files derived `$HOME` themselves, across nineteen call sites, with
--- SIX different answers for what to do when it is unset:
---
---     os.getenv("HOME") or "/tmp"          -- crash reporter, updater
---     os.getenv("HOME") or "~"             -- hotstrings, kanata, keylogger…
---     os.getenv("HOME") or ""              -- gestures
---     os.getenv("HOME") or "."             -- logger sink
---     os.getenv("HOME") or "/home/user"    -- five webview bridges
---     os.getenv("HOME") .. "/…"            -- menu_builder: no fallback at all
---
--- Two of those are actively wrong rather than merely inconsistent. The bare
--- concatenation THROWS on a nil HOME, taking the menu build down. And `"~"` is
--- not expanded by io.open — Lua does no tilde expansion — so every path built
--- on that fallback silently addresses a literal directory named `~` in the
--- current folder, creating it on write and reading nothing on load.
---
--- `"/home/user"` deserves its own mention: it is a plausible-looking path that
--- belongs to nobody. Writing a user's personal hotstrings there is worse than
--- failing, because it looks like it worked.
---
--- FEATURES & RATIONALE:
--- 1. ONE policy for a missing HOME, applied everywhere: fall back to TMPDIR (or
---    /tmp). A temp path is honest — it is obviously not the user's home, it is
---    writable, and nothing there is mistaken for durable state.
--- 2. XDG-aware: XDG_CONFIG_HOME and XDG_DATA_HOME are honoured where the spec
---    says they should be, so containerised and sandboxed installs work.
--- 3. No tilde, ever. Every path returned is absolute.
--- ==============================================================================

local M = {}




-- =========================================
-- =========================================
-- ======= 1/ Base directories =============
-- =========================================
-- =========================================

--- The user's home directory.
---
--- When HOME is unset — a bare systemd unit, a container without a passwd entry
--- — the answer is a temp directory rather than a guess. `"~"` would be taken
--- literally by io.open, and `"/home/user"` is somebody else's path.
--- @return string Absolute path, no trailing slash.
function M.home()
	local home = os.getenv("HOME")
	if type(home) == "string" and home ~= "" then
		return (home:gsub("/+$", ""))
	end
	local tmp = os.getenv("TMPDIR")
	if type(tmp) == "string" and tmp ~= "" then
		return (tmp:gsub("/+$", ""))
	end
	return "/tmp"
end

--- The XDG config root ($XDG_CONFIG_HOME, or ~/.config).
--- @return string Absolute path, no trailing slash.
function M.config_home()
	local xdg = os.getenv("XDG_CONFIG_HOME")
	if type(xdg) == "string" and xdg ~= "" then
		return (xdg:gsub("/+$", ""))
	end
	return M.home() .. "/.config"
end

--- The XDG data root ($XDG_DATA_HOME, or ~/.local/share).
--- @return string Absolute path, no trailing slash.
function M.data_home()
	local xdg = os.getenv("XDG_DATA_HOME")
	if type(xdg) == "string" and xdg ~= "" then
		return (xdg:gsub("/+$", ""))
	end
	return M.home() .. "/.local/share"
end




-- =========================================
-- =========================================
-- ======= 2/ Driver directories ===========
-- =========================================
-- =========================================

--- The driver's config directory, optionally with a path appended.
--- @param rel string|nil Path relative to the driver config dir.
--- @return string Absolute path, no trailing slash.
function M.config(rel)
	local base = M.config_home() .. "/ergopti"
	if type(rel) ~= "string" or rel == "" then return base end
	return (base .. "/" .. (rel:gsub("^/+", "")))
end

--- The driver's data directory, optionally with a path appended.
--- @param rel string|nil Path relative to the driver data dir.
--- @return string Absolute path, no trailing slash.
function M.data(rel)
	local base = M.data_home() .. "/ergopti"
	if type(rel) ~= "string" or rel == "" then return base end
	return (base .. "/" .. (rel:gsub("^/+", "")))
end

return M
