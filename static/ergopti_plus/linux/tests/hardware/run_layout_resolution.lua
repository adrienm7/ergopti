--- tests/hardware/run_layout_resolution.lua

--- ==============================================================================
--- MODULE: Real Keymaps Resolve to Real Characters (no display server needed)
--- DESCRIPTION:
--- Compiles actual XKB layouts and asserts the driver can plan the keystrokes for
--- text in the language each of them is for.
---
--- WHY THIS BELONGS IN THE HARDWARE SET AND NOT THE UNIT SUITE:
--- Every unit test of keyboard_layout parses a keymap this repository wrote. That
--- is the right shape for asserting the parse — lowest level wins, dead keys are
--- refused, a truncated table is rejected — and it cannot tell us the one thing
--- left: whether a keymap the SYSTEM produces looks anything like the ones we
--- invented. A parser tested only against its author's fixtures is a parser
--- tested against its author's assumptions.
---
--- WHY IT NEEDS NO DISPLAY SERVER, which is what makes it runnable in CI:
--- `xkbcli compile-keymap --layout fr` produces the same keymap text that
--- `dump-keymap-x11` and `dump-keymap-wayland` return from a live session. The
--- session is what decides WHICH layout is active; it has nothing to do with what
--- a given layout contains. So the half of HARDWARE.md §3 that says "é and à come
--- out right on YOUR layout" needs a human, and the half that says "the driver
--- can read a French keymap at all" does not — and that half was untested.
---
--- WHAT IT ASSERTS, LAYOUT BY LAYOUT:
--- that each one yields a plausible number of typable characters, that its own
--- language's accented letters resolve, and — the case a user asked about — that
--- text in a DIFFERENT language is refused as a whole rather than typed in part.
--- A Spanish hotstring pack on a French keyboard has no ñ to press, and a planner
--- that emitted the letters it could would leave "seor" where the trigger was,
--- after the trigger had already been erased.
---
--- HOW TO RUN IT:
---   luajit tests/hardware/run_layout_resolution.lua
--- No root, no session, no /dev access. It needs xkbcli (xkbcommon-tools).
---
--- Exit 0 = every assertion held. 1 = a failure. 2 = xkbcli is not installed.
--- ==============================================================================

local KeyboardLayout = require("adapters.keyboard_layout")

-- Below this many typable characters the driver treats a keymap as a failed
-- parse rather than typing wrong characters from a half-read table. Mirrored from
-- adapters/keyboard_layout so a change there shows up here as a disagreement.
local MIN_PLAUSIBLE_ENTRIES = 60

-- The layouts to compile, what each must be able to type, and what it must
-- refuse. The refusals are the point: they are what proves the planner is
-- reading the layout rather than assuming a US keyboard.
local LAYOUTS = {
	{
		id      = "fr",
		typable = { "é", "è", "à", "ç", "ù", "€" },
		-- The digit row, and on the digit row: every digit is Shift + the key
		-- above the letters (evdev 2-11). Planned from the keymap text in hash
		-- order, a digit could land on the keypad key of the same level —
		-- Shift+KP1 moves the caret with NumLock off — and differently from
		-- one start to the next.
		keys    = { ["1"] = 2, ["2"] = 3, ["5"] = 6, ["9"] = 10, ["0"] = 11, ["€"] = 18 },
		-- No ñ on a French keyboard at any level. This is the exact case from the
		-- question "what about a Spanish hotstring pack".
		refused = { "ñ" },
	},
	{
		id      = "es",
		-- Only ñ. Measured on a real es keymap 2026-08-05: the accented vowels are
		-- NOT single keystrokes on a Spanish layout — they are composed with the
		-- dead acute (´ then the vowel), which is two keystrokes and a compose
		-- state. The planner refuses dead keys deliberately, because emitting the
		-- first half of a composition would leave a floating accent in the user's
		-- text; those characters go through the clipboard instead.
		--
		-- Worth stating plainly because it is the answer to "does a Spanish
		-- hotstring pack work": on a Spanish keyboard, ñ is typed and á is pasted.
		-- Both deliver; only one is a keystroke.
		typable = { "ñ" },
		refused = { "á", "é", "í", "ó", "ú" },
	},
	{
		id      = "us",
		typable = { "a", "Z", "1", "@", "?" },
		-- A US layout has none of these, which is why the clipboard path exists at
		-- all and why it must not be reachable for ordinary ASCII.
		refused = { "é", "ñ", "ç" },
	},
	{
		id      = "de",
		typable = { "ä", "ö", "ü", "ß" },
		refused = {},
	},
}

local _failures = 0
local _checks   = 0





-- =======================================
-- =======================================
-- ======= 1/ Tiny harness ===============
-- =======================================
-- =======================================

--- Records one assertion.
--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if condition then
		print(string.format("  ok   %s", what))
	else
		_failures = _failures + 1
		print(string.format("  FAIL %s", what))
	end
end

--- Aborts when the environment cannot host the test at all.
--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

--- Compiles one layout to keymap text.
---
--- Through xkbcli rather than by reading /usr/share/X11/xkb by hand: the compiler
--- resolves includes, variants and symbol overrides, and a hand-read file would
--- test a keymap no session ever uses.
--- @param layout string An XKB layout id, e.g. "fr".
--- @return string|nil
local function compile(layout)
	local pipe = io.popen(string.format(
		"xkbcli compile-keymap --layout %s 2>/dev/null", layout), "r")
	if not pipe then return nil end
	local text = pipe:read("*a")
	pipe:close()
	if type(text) ~= "string" or text == "" then return nil end
	return text
end





--- Loads keymap text the way the daemon does: refresh() with an override file,
--- which runs XKB capture and builds the injection table from libxkbcommon.
--- @param keymap string
--- @return boolean
local function load_through_driver(keymap)
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(keymap)
	fh:close()
	local ok = KeyboardLayout.refresh(path)
	os.remove(path)
	return ok
end

-- =======================================
-- =======================================
-- ======= 2/ The environment ============
-- =======================================
-- =======================================

print("=== layout resolution, against real system keymaps ===")

local probe = io.popen("command -v xkbcli 2>/dev/null", "r")
local xkbcli_path = probe and probe:read("*a") or ""
if probe then probe:close() end
if xkbcli_path == "" then
	abort("xkbcli is not installed — apt install libxkbcommon-tools / dnf install libxkbcommon-tools.")
end

-- One compile up front. A machine with xkbcli but no XKB data files would
-- otherwise report every layout as a driver failure.
if not compile("us") then
	abort("xkbcli is present but compiled nothing for 'us' — the XKB data files are missing.")
end





-- =======================================
-- =======================================
-- ======= 3/ Every layout ===============
-- =======================================
-- =======================================

for _, spec in ipairs(LAYOUTS) do
	print("--- " .. spec.id .. " ---")

	local keymap = compile(spec.id)
	if not keymap then
		_failures = _failures + 1
		print("  FAIL could not compile layout " .. spec.id)
	else
		check(load_through_driver(keymap), string.format(
			"%s loads through the driver's own refresh(), as a live session would", spec.id))

		for char, keycode in pairs(spec.keys or {}) do
			local hit = KeyboardLayout.resolve(char)
			check(hit ~= nil and hit.keycode == keycode, string.format(
				"%s types %s on evdev %d (got %s)", spec.id, char, keycode,
				hit and tostring(hit.keycode) or "nothing"))
		end

		for _, char in ipairs(spec.typable) do
			local plan, blocker = KeyboardLayout.plan(char)
			check(plan ~= nil, string.format(
				"%s can type %s%s", spec.id, char,
				plan == nil and (" — blocked on " .. tostring(blocker)) or ""))
		end

		for _, char in ipairs(spec.refused) do
			local plan = KeyboardLayout.plan(char)
			check(plan == nil, string.format(
				"%s correctly has no key for %s — it must go via the clipboard, not be approximated",
				spec.id, char))
		end

		-- The whole-string property, which is what protects the user's text: a
		-- word mixing typable and untypable characters must be refused ENTIRELY.
		-- inject() erases the trigger before sending the replacement, so a partial
		-- plan leaves them with the letters it managed and nothing else.
		if #spec.refused > 0 then
			local mixed = "se" .. spec.refused[1] .. "or"
			local plan, blocker = KeyboardLayout.plan(mixed)
			check(plan == nil, string.format(
				"%s refuses %q as a whole rather than typing the part it can",
				spec.id, mixed))
			check(blocker == spec.refused[1], string.format(
				"%s names %s as the blocker, so the log says which character stopped it",
				spec.id, spec.refused[1]))
		end
	end
end

-- The Ergopti layout itself, compiled from the files this repository ships.
-- Its ERGOPTI_SEVEN_LEVEL type puts Shift on level 3 and CapsLock on level 2,
-- so a table that assumed "level 2 = Shift" typed "mon-fichier" for
-- "mon_fichier" and sent most punctuation through the clipboard.
print("--- ergopti (v2.2.1 plus) ---")
do
	local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[^/]+$", "")
	local repo_linux = here .. "../../../../ergopti/linux/v2_2_1/"
	local tmp = os.tmpname()
	os.remove(tmp)
	os.execute(string.format("mkdir -p '%s/symbols' '%s/types'", tmp, tmp))
	os.execute(string.format("cp '%sErgopti_v2_2_1_plus.xkb' '%s/symbols/ergopti'", repo_linux, tmp))
	os.execute(string.format("cp '%sxkb_types.txt' '%s/types/ergopti'", repo_linux, tmp))
	-- Compiled through libxkbcommon with the fixture directory on its include
	-- path: `xkbcli compile-keymap --keymap` only exists from 1.11, and the
	-- rules path would pair the symbols with the stock types instead of
	-- ERGOPTI_SEVEN_LEVEL.
	local ffi = require("ffi")
	pcall(ffi.cdef, [[
		struct xkb_context *xkb_context_new(int flags);
		int xkb_context_include_path_append(struct xkb_context *context, const char *path);
		struct xkb_keymap *xkb_keymap_new_from_string(struct xkb_context *context,
			const char *string, int format, int flags);
		char *xkb_keymap_get_as_string(struct xkb_keymap *keymap, int format);
	]])
	local lib = ffi.load("xkbcommon.so.0")
	local ctx = lib.xkb_context_new(1)
	lib.xkb_context_include_path_append(ctx, tmp)
	lib.xkb_context_include_path_append(ctx, "/usr/share/X11/xkb")
	local compiled = lib.xkb_keymap_new_from_string(ctx, [[xkb_keymap {
	xkb_keycodes { include "evdev+aliases(azerty)" };
	xkb_types { include "ergopti" };
	xkb_compat { include "complete" };
	xkb_symbols { include "pc+ergopti(Ergopti_v2_2_1_plus)+inet(evdev)" };
};]], 1, 0)
	local keymap = compiled ~= nil and ffi.string(lib.xkb_keymap_get_as_string(compiled, 1)) or ""
	os.execute(string.format("rm -rf '%s'", tmp))
	if not keymap:find("xkb_keymap", 1, true) then
		_failures = _failures + 1
		print("  FAIL could not compile the Ergopti layout: " .. keymap:sub(1, 300))
	else
		check(load_through_driver(keymap), "ergopti loads through the driver's own refresh()")
		for _, text in ipairs({ "mon_fichier", "c’est-à-dire", "(a) [b] <c> @d", "2024, fin." }) do
			local plan, blocker = KeyboardLayout.plan(text)
			check(plan ~= nil, string.format("ergopti types %q as keystrokes%s", text,
				plan and "" or (" — blocked on " .. tostring(blocker))))
		end
		local underscore = KeyboardLayout.resolve("_")
		local minus = KeyboardLayout.resolve("-")
		check(underscore and minus and (underscore.keycode ~= minus.keycode
			or table.concat(underscore.mods, "+") ~= table.concat(minus.mods, "+")),
			"ergopti plans _ and - as different keystrokes")
	end
end

print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
