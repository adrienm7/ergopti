--- tests/hardware/installed_layout_check.lua

--- ==============================================================================
--- MODULE: Installed-Layout Check
--- DESCRIPTION:
--- Runs inside a REAL installation — a .deb, an .rpm, an extracted AppImage, a
--- Flatpak sandbox or an install.sh tarball — and proves the driver can reach
--- the data it reads. Every packaging job in CI runs it after installing, and
--- HARDWARE.md points at it for a manual check on a real machine.
---
--- WHY IT EXISTS:
--- `ergopti --help` returns before doing any work. It proves the require graph
--- loads and nothing else, so a package whose DATA tree is unreachable passes it
--- cleanly. That is not hypothetical: every package this project ever built was
--- in exactly that state. `_shared` resolved as a sibling while the packagers
--- nested it as a child, so `shared_root()` returned nil and every locale,
--- keycode table and hotstring pack was silently absent — behind a `--help` that
--- exited 0.
---
--- WHAT IT ASSERTS, AND WHY EACH ONE:
--- 1. The shared tree resolves, and to the path this format is supposed to use.
---    A resolver that finds SOME tree is not the same as one that finds the
---    installed one.
--- 2. One file from each stanza the packagers copy separately, because any one
---    of those copies can be lost on its own.
--- 3. That the locale scan returns more than a handful. This is the symptom the
---    resolver defect actually produced: the language menu offered two rows out
---    of twenty-one, because the scan ran against a directory that did not exist
---    and the {"en", "fr"} fallback quietly took over. Nothing raised. The menu
---    simply had two rows, which is why an exit code alone would not have caught
---    it and this check counts.
---
--- USAGE:
---   luajit installed_layout_check.lua <expected _shared root>
--- with LUA_PATH already exported by the installation's own launcher — replay it
--- from there rather than re-typing it, or the check can pass against a path the
--- launcher does not actually set.
--- ==============================================================================




-- =====================================
-- =====================================
-- ======= 1/ Expectations =============
-- =====================================
-- =====================================

-- One file from each tree the packagers copy in a separate stanza. Losing one
-- stanza loses one of these and nothing else, so they are checked individually.
local REQUIRED_SHARED_FILES = {
	"data/locales/en.json",
	"data/locales/fr.json",
	"data/keycodes/evdev.json",
	"modules/llm/defaults.json",
	"modules/timings/constants.toml",
}

-- Twenty-one locales ship. The hardcoded fallback that masks a missing tree has
-- two entries, so any floor between the two separates "read the tree" from "did
-- not". Ten leaves room for the catalogue to shrink without turning this into a
-- test of how many languages exist.
local MIN_LOCALES = 10

local failures = 0

--- Reports one failed expectation and counts it.
--- @param fmt string Format string.
--- @param ... any Format arguments.
local function fail(fmt, ...)
	print("FAIL " .. string.format(fmt, ...))
	failures = failures + 1
end

--- Collapses "x/../" segments and trailing slashes so two spellings of the same
--- directory compare equal.
---
--- The resolver returns the candidate it probed, not a canonical path, and the
--- two layouts spell themselves differently: a system package resolves to
--- "/usr/lib/ergopti/_shared" while a tarball install resolves to
--- "<root>/linux/../_shared". Both are correct and neither is wrong to return —
--- Lua has no realpath, so the comparison normalises instead of demanding one
--- spelling and failing a healthy install over punctuation.
--- @param p string
--- @return string
local function normalise(p)
	p = p:gsub("\\", "/")
	local changed = true
	while changed do
		-- One segment at a time: "a/b/../c" → "a/c". The pattern refuses to eat
		-- a ".." segment itself, so "../../x" is left alone rather than mangled.
		local next_p, n = p:gsub("/[^/]+/%.%./", "/", 1)
		changed = n > 0 and not next_p:find("%.%./%.%./")
		p = next_p
	end
	p = p:gsub("/[^/]+/%.%.$", "")
	p = p:gsub("/+$", "")
	return p
end




-- =====================================
-- =====================================
-- ======= 2/ Checks ===================
-- =====================================
-- =====================================

local expected_root = arg and arg[1]
if type(expected_root) ~= "string" or expected_root == "" then
	print("FAIL usage: installed_layout_check.lua <expected _shared root>")
	print("     Without the expected root this would assert only that SOME tree")
	print("     was found, which is what the packaging defect already satisfied.")
	os.exit(1)
end

-- The daemon installs this before its first shared require; mirror it so a
-- module that expects utf8 under LuaJIT is not the thing that fails.
local ok_compat, compat = pcall(require, "compat.utf8")
if ok_compat and type(compat) == "table" and type(compat.install) == "function" then
	pcall(compat.install)
end

local ok_paths, Paths = pcall(require, "infra.paths")
if not ok_paths then
	print("FAIL infra.paths could not be loaded: " .. tostring(Paths))
	print("     LUA_PATH = " .. tostring(os.getenv("LUA_PATH")))
	os.exit(1)
end

local root = Paths.shared_root()
if not root then
	fail("infra.paths resolved no shared tree from the installed driver.")
elseif normalise(root) ~= normalise(expected_root) then
	fail("shared tree resolved to %s, expected %s — the packaged layout moved.",
		normalise(root), normalise(expected_root))
else
	print("OK   shared_root() -> " .. root)
end

for _, rel in ipairs(REQUIRED_SHARED_FILES) do
	local abs = Paths.shared(rel)
	local handle = abs and io.open(abs, "r")
	if handle then
		handle:close()
		print("OK   " .. abs)
	else
		fail("unreadable: %s", tostring(abs))
	end
end

local ok_i18n, i18n = pcall(require, "infra.i18n")
if not ok_i18n then
	fail("infra.i18n could not be loaded: %s", tostring(i18n))
else
	local ok_list, locales = pcall(i18n.list_locales)
	if not ok_list or type(locales) ~= "table" then
		fail("i18n.list_locales() raised: %s", tostring(locales))
	elseif #locales < MIN_LOCALES then
		fail("only %d locale(s) discovered — the two-entry fallback took over, so the "
			.. "shared tree is not being read.", #locales)
	else
		print("OK   locales discovered: " .. #locales)
	end
end

if failures > 0 then
	print(string.format("Installed layout FAILED (%d check(s)).", failures))
	os.exit(1)
end

print("Installed layout OK.")
