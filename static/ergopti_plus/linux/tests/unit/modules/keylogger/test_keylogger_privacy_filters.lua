--- tests/unit/modules/keylogger/test_keylogger_privacy_filters.lua

--- ==============================================================================
--- MODULE: Linux Keylogger Privacy Filters Regression Test
--- DESCRIPTION:
--- Regression guard for the blocker where the Linux keylogger recorded every
--- keystroke unconditionally: no off switch, no private-browsing filter, and no
--- secure-field signal beyond a substring match on the application name.
---
--- THE ROOT CAUSE ENCODED:
--- The three drivers are supposed to read one privacy posture from
--- _shared/modules/features/manifest.toml. Linux could not: [sections.metrics]
--- listed only ["ahk", "hs"], and the codegen emitted features_manifest.lua for
--- Windows and macOS only. The driver had nowhere to read the flags FROM, so it
--- had none of them. This suite fails if either half regresses — the manifest
--- entry disappearing, or the driver stopping reading it.
---
--- FEATURES & RATIONALE:
--- 1. Behavioural where it counts: each filter is proved to actually stop
---    keystrokes reaching the per-app accumulators, not merely to exist as a
---    setter. A privacy toggle that flips a boolean nothing consults is the
---    exact failure this blocker was.
--- 2. Coverage may never narrow. Splitting the flat eight-app list into a
---    "secure" and a "system auth" half is only safe while both defaults are on,
---    so the union is asserted explicitly, as is each half's independence.
--- 3. The daemon wiring is guarded too. Every behavioural test here would still
---    pass if ergopti_hotstrings.lua stopped feeding the window title — the
---    filter would simply never fire. That wiring is therefore asserted at the
---    source, with comments stripped so the fix's own prose cannot satisfy it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local DRIVER_ROOT = helpers.driver_root()

-- Privacy toggles persist by design. Running these behavioural tests over the
-- real adapter would therefore modify the developer's own configuration and
-- make the next suite run depend on the previous one. Keep every case on a
-- fresh in-memory store, then restore the exact modules this file displaced.
local _previous_storage = package.loaded["adapters.storage"]
local _previous_keylogger = package.loaded["modules.keylogger.keylogger"]

--- Reloads the keylogger with fresh module state.
local function fresh_keylogger()
	package.loaded["adapters.storage"] = Fakes.storage()
	package.loaded["modules.keylogger.keylogger"] = nil
	local kl = require("modules.keylogger.keylogger")
	kl.init({})
	return kl
end

--- Types one character and reports how many keystrokes the app accumulated.
local function keystrokes_after_typing(kl, app_id)
	kl.on_keydown("a", 1000, app_id)
	local stats = kl.get_app_stats()[app_id]
	return stats and stats.keystrokes or 0
end

--- Drops lines whose first non-blank characters are a Lua comment marker.
local function strip_comment_lines(src)
	local kept = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		if not line:match("^%s*%-%-") then kept[#kept + 1] = line end
	end
	return table.concat(kept, "\n")
end

--- Returns the comment-free source of a driver file, failing loudly if absent.
local function code_of(rel_path)
	local fh = io.open(DRIVER_ROOT .. "/" .. rel_path, "r")
	helpers.assert_not_nil(fh, "missing source file: " .. rel_path)
	local src = fh:read("*a")
	fh:close()
	return strip_comment_lines(src)
end





-- ==========================================
-- ==========================================
-- ======= 1/ Posture Comes From Data =======
-- ==========================================
-- ==========================================

helpers.describe("keylogger privacy — the posture is read, not re-typed", function()
	helpers.it("exposes every flag the shared manifest declares", function()
		local Manifest = require("infra.manifest_reader")
		local kl = fresh_keylogger()
		local state = kl.get_privacy_state()

		local pairs_to_check = {
			{ "enabled",                    "metrics.enabled" },
			{ "private_filter_enabled",     "metrics.private_filter_enabled" },
			{ "secure_filter_enabled",      "metrics.secure_filter_enabled" },
			{ "system_auth_filter_enabled", "metrics.system_auth_filter_enabled" },
		}
		for _, entry in ipairs(pairs_to_check) do
			helpers.assert_eq(state[entry[1]], Manifest.default_for(entry[2]),
				entry[1] .. " must come from " .. entry[2] .. ", not a driver-local literal")
		end
	end)

	helpers.it("does not hardcode the four defaults in the driver", function()
		local code = code_of("modules/keylogger/keylogger.lua")
		for _, path in ipairs({
			"metrics.enabled",
			"metrics.private_filter_enabled",
			"metrics.secure_filter_enabled",
			"metrics.system_auth_filter_enabled",
		}) do
			helpers.assert_contains(code, 'Manifest.default_for("' .. path .. '")',
				"the posture must be read from the shared manifest")
		end
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ Each Filter Actually Stops ===
-- =========================================
-- =========================================

helpers.describe("keylogger privacy — the off switch", function()
	helpers.it("records nothing once disabled", function()
		local kl = fresh_keylogger()
		kl.set_enabled(false)
		helpers.assert_eq(keystrokes_after_typing(kl, "gedit"), 0,
			"a disabled keylogger must record nothing")
	end)

	helpers.it("records again once re-enabled", function()
		local kl = fresh_keylogger()
		kl.set_enabled(false)
		keystrokes_after_typing(kl, "gedit")
		kl.set_enabled(true)
		helpers.assert_true(keystrokes_after_typing(kl, "gedit") > 0,
			"re-enabling must resume collection")
	end)

	helpers.it("records normally by default", function()
		-- Without this the two tests above pass on a keylogger that records
		-- nothing at all, which is not the behaviour being tested.
		local kl = fresh_keylogger()
		helpers.assert_true(keystrokes_after_typing(kl, "gedit") > 0,
			"the default posture must still collect")
	end)
end)


helpers.describe("keylogger privacy — private browsing", function()
	helpers.it("recognises the markers every major browser uses", function()
		local kl = fresh_keylogger()
		for _, title in ipairs({
			"Mozilla Firefox — Private Browsing",
			"New Tab - Google Chrome (Incognito)",
			"Microsoft Edge — InPrivate",
			"Anonymous session",
			"reddit - private browsing",  -- lower case must match too
		}) do
			helpers.assert_true(kl.is_private_window(title),
				"must flag a private window: " .. title)
		end
	end)

	helpers.it("does not flag an ordinary window", function()
		local kl = fresh_keylogger()
		helpers.assert_eq(kl.is_private_window("Inbox — Mozilla Firefox"), false)
		helpers.assert_eq(kl.is_private_window(""), false)
		helpers.assert_eq(kl.is_private_window(nil), false)
	end)

	helpers.it("drops keystrokes while a private window is focused", function()
		local kl = fresh_keylogger()
		kl.set_private_window(true)
		helpers.assert_eq(keystrokes_after_typing(kl, "firefox"), 0,
			"keystrokes typed in a private window must not be recorded")
	end)

	helpers.it("resumes when focus leaves the private window", function()
		local kl = fresh_keylogger()
		kl.set_private_window(true)
		keystrokes_after_typing(kl, "firefox")
		kl.set_private_window(false)
		helpers.assert_true(keystrokes_after_typing(kl, "firefox") > 0,
			"leaving the private window must resume collection")
	end)

	helpers.it("honours the filter toggle", function()
		local kl = fresh_keylogger()
		kl.set_private_filter_enabled(false)
		kl.set_private_window(true)
		helpers.assert_true(keystrokes_after_typing(kl, "firefox") > 0,
			"a disabled filter must not drop anything")
	end)
end)


helpers.describe("keylogger privacy — secure fields", function()
	helpers.it("drops keystrokes when the adapter reports a secure field", function()
		local kl = fresh_keylogger()
		kl.set_secure_field(true)
		helpers.assert_eq(keystrokes_after_typing(kl, "gedit"), 0,
			"the AT-SPI verdict must suppress collection on ANY app, not just known ones")
	end)

	helpers.it("is additive to the application-name list", function()
		-- The adapter matches WM_CLASS exactly on a shorter list. It is consulted
		-- IN ADDITION to the substring list, never instead of it — delegating
		-- would drop gpg/ssh-agent/polkit/sudo and leak those keystrokes.
		local kl = fresh_keylogger()
		kl.set_secure_field(false)
		helpers.assert_true(kl.is_password_app("gpg-agent"),
			"the substring list must keep working when the adapter says 'not secure'")
	end)
end)





-- =========================================
-- =========================================
-- ======= 3/ Coverage Never Narrows =======
-- =========================================
-- =========================================

helpers.describe("keylogger privacy — coverage never narrows", function()
	local ALL_PRIVACY_APPS = {
		"1password", "bitwarden", "keepass", "lastpass",
		"gpg", "ssh-agent", "polkit", "sudo",
	}

	helpers.it("matches every privacy-critical app at the default posture", function()
		local kl = fresh_keylogger()
		for _, app in ipairs(ALL_PRIVACY_APPS) do
			helpers.assert_true(kl.is_password_app(app),
				"splitting the list into two flags must not drop " .. app)
		end
	end)

	helpers.it("keeps the two halves independent", function()
		local kl = fresh_keylogger()

		kl.set_system_auth_filter_enabled(false)
		helpers.assert_true(kl.is_password_app("keepassxc"),
			"turning off the system-auth filter must not disable password managers")
		helpers.assert_eq(kl.is_password_app("sudo"), false,
			"turning off the system-auth filter must actually turn it off")

		kl.set_system_auth_filter_enabled(true)
		kl.set_secure_filter_enabled(false)
		helpers.assert_true(kl.is_password_app("sudo"),
			"turning off the secure filter must not disable OS auth prompts")
		helpers.assert_eq(kl.is_password_app("keepassxc"), false,
			"turning off the secure filter must actually turn it off")

		-- PUT THEM BACK. These setters persist since 2026-08-06, so a flip left
		-- behind is not a value in one module's memory any more — it is a line in
		-- the user's store that every later fresh load reads. It cost a CI run to
		-- learn: on Linux `find` returns this file BEFORE tests/unit/meta/
		-- test_keylogger.lua, so four password-suppression tests there saw a filter
		-- this one had switched off, and on Windows `dir /b /s` returns them the
		-- other way round and everything passed.
		kl.set_secure_filter_enabled(true)
		kl.set_system_auth_filter_enabled(true)
	end)

	helpers.it("still ignores ordinary applications", function()
		local kl = fresh_keylogger()
		helpers.assert_eq(kl.is_password_app("firefox"), false)
		helpers.assert_eq(kl.is_password_app(""), false)
		helpers.assert_eq(kl.is_password_app(nil), false)
	end)
end)

-- =========================================
-- =========================================
-- ======= 4/ The Daemon Feeds Them ========
-- =========================================
-- =========================================

helpers.describe("keylogger privacy — the daemon supplies the signals", function()
	helpers.it("feeds the focused window title to the private-browsing filter", function()
		-- Every behavioural test above still passes if this wiring is deleted:
		-- the filter would simply never fire. The window title used to be
		-- received as `_windowTitle` and discarded, which is precisely how the
		-- driver ended up with no private-browsing filter.
		local code = code_of("ergopti_hotstrings.lua")
		helpers.assert_contains(code, "keylogger.set_private_window(",
			"the daemon must push the private-window verdict to the keylogger")
		helpers.assert_contains(code, "keylogger.is_private_window(windowTitle)",
			"the verdict must be computed from the focus callback's window title")
		helpers.assert_true(code:find("_windowTitle", 1, true) == nil,
			"the window title must no longer be received and discarded")
	end)

	helpers.it("asks AT-SPI whether the focused element is a password field", function()
		-- The sibling of the defect above, and worse, because this one had a whole
		-- adapter behind it. adapters/secure_field_detector.lua was written and
		-- tested, keylogger.set_secure_field was written, and `refresh()` had no
		-- caller anywhere in the driver — so isSecureField() answered false forever
		-- and the setter was never called. metrics.secure_filter_enabled ships
		-- enabled by default, so the manifest promised a password-field filter the
		-- driver did not have, and it failed in the direction that RECORDS what the
		-- filter exists to suppress.
		--
		-- Asserted on the wiring rather than behaviourally for the same reason the
		-- case above is: every behavioural test of the filter still passes with the
		-- call deleted, because the filter simply never fires.
		local code = code_of("ergopti_hotstrings.lua")
		helpers.assert_contains(code, "adapters.secure_field_detector",
			"the daemon must reach the detector at all")
		helpers.assert_contains(code, "keylogger.set_secure_field(",
			"and push its verdict to the keylogger, or the setter stays a setter "
				.. "nothing sets")
		helpers.assert_contains(code, "Detector.isSecureField()",
			"the verdict pushed must be the one the probe just produced")

		-- COUNTED, not merely present. A first version asserted only that those
		-- three strings existed, and deleting both call sites left it green: the
		-- helper still contained every one of them. A probe that is defined and
		-- never invoked is the exact defect this test was written for, one level
		-- down.
		--
		-- Three occurrences: the definition, the focus callback, and the priming
		-- call for the window already focused at startup — which on a login that
		-- restores a password manager is the window that matters most.
		local uses = 0
		for _ in code:gmatch("update_secure_field") do uses = uses + 1 end
		helpers.assert_true(uses >= 3,
			"the probe must be CALLED, from the focus change and from the startup "
				.. "priming — found " .. uses .. " mention(s), which is not enough for "
				.. "a definition plus both call sites")
	end)

	helpers.it("uses the shared keyword list rather than a driver-local copy", function()
		local code = code_of("modules/keylogger/keylogger.lua")
		helpers.assert_contains(code, 'require("keylogger.private_window")',
			"the markers are a cross-driver privacy guarantee and live in _shared")
		helpers.assert_true(code:find("Incognito", 1, true) == nil,
			"the keyword list must not be duplicated into this driver")
	end)
end)

package.loaded["adapters.storage"] = _previous_storage
package.loaded["modules.keylogger.keylogger"] = _previous_keylogger
