--- tests/unit/modules/keylogger/test_metrics_toggles_persist.lua

--- ==============================================================================
--- MODULE: A Metrics Toggle Survives the Restart
--- DESCRIPTION:
--- That the five metrics switches are read from storage at load and written back
--- when they change.
---
--- WHERE THE CHOICE IS APPLIED:
--- In init(), not at module load. Loading is when a consumer asks for the TYPE;
--- reading $HOME there gave the module a file-system dependency it never had,
--- and made its state depend on load order — which differs between `dir /b /s`
--- and `find`, and cost a CI run to learn.
---
--- THE DEFECT THIS PINS:
--- None of them were stored. Every one reverted to its manifest default at the
--- next start, and the directions are not equally harmless. The two privacy
--- filters revert to ON, which tightens what a user had deliberately relaxed —
--- annoying and safe. The master switch reverts to ON, which is the other
--- direction entirely: a user who turned metrics off got them back after a
--- reboot, and the driver was recording again without being asked twice.
---
--- Encryption is worse still. A user who turned it on and found it off after a
--- reboot ends up with a database half encrypted and half not, with nothing in
--- it saying when the posture changed.
---
--- WHY ONLY THE CHANGE IS STORED:
--- Writing the default too would freeze today's default for anyone who had
--- already run the driver — a later change to what ships would reach new
--- installs and nobody else. The dynamic-hotstring families are stored the same
--- way for the same reason.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

-- What was in package.loaded before this file displaced it. RESTORED rather than
-- cleared, and that distinction cost a CI run: clearing left the next test file
-- to re-require a fresh keylogger, which no longer had the password_apps its own
-- init() had configured — so four suppression tests failed on Linux and passed
-- on Windows, purely because `find` and `dir /b /s` return files in a different
-- order. A test that reaches into package.loaded owes the files after it the
-- state it found.
local _displaced = { storage = nil, keylogger = nil, held = false }

--- Loads the keylogger over a fake storage, so nothing touches a real file.
--- @param initial table|nil Pre-existing stored values.
--- @return table keylogger, table storage
local function load_over_storage(initial)
	if not _displaced.held then
		_displaced.storage   = package.loaded["adapters.storage"]
		_displaced.keylogger = package.loaded["modules.keylogger.keylogger"]
		_displaced.held      = true
	end
	local storage = Fakes.storage({ initial = initial })
	package.loaded["adapters.storage"] = storage
	package.loaded["modules.keylogger.keylogger"] = nil
	local keylogger = require("modules.keylogger.keylogger")
	-- init(), because that is where the stored choice is applied. Reading it at
	-- module load gave this module a file-system dependency at require time and
	-- made its state depend on which test file happened to load it first.
	keylogger.init({ sqlite_path = "/tmp/ergopti_toggle_probe.sqlite" })
	return keylogger, storage
end

--- Puts back exactly what was there.
local function drop_storage()
	package.loaded["adapters.storage"] = _displaced.storage
	package.loaded["modules.keylogger.keylogger"] = _displaced.keylogger
end




-- =================================================================
-- =================================================================
-- ======= 1/ A change is written ==================================
-- =================================================================
-- =================================================================

helpers.describe("metrics toggles: what gets written", function()

	helpers.it("stores nothing while every switch is at its shipped default", function()
		local keylogger, storage = load_over_storage()
		-- Reading them must not write them.
		keylogger.is_enabled()
		local written = 0
		for _, key in ipairs(storage.keys()) do
			if key:find("^metrics%.") then written = written + 1 end
		end
		drop_storage()
		helpers.assert_eq(written, 0,
			"persisting the default would freeze today's default for anyone who had "
				.. "already run the driver: a later change to what ships would reach "
				.. "new installs and nobody else")
	end)

	helpers.it("stores the master switch when it is turned off", function()
		local keylogger, storage = load_over_storage()
		keylogger.set_enabled(false)
		local stored = storage.get("metrics.enabled")
		drop_storage()
		helpers.assert_eq(stored, false,
			"this is the one that reverts in the dangerous direction — a user who "
				.. "switched metrics off had them back after a reboot, recording "
				.. "again without being asked twice")
	end)

	helpers.it("clears the key when a switch returns to its default", function()
		local keylogger, storage = load_over_storage({ ["metrics.enabled"] = false })
		keylogger.set_enabled(true)
		local has = storage.has("metrics.enabled")
		drop_storage()
		helpers.assert_true(not has,
			"back to the default means back to no entry, so the default stays live "
				.. "for this user rather than being pinned at the moment they toggled")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ A stored choice is read back =========================
-- =================================================================
-- =================================================================

helpers.describe("metrics toggles: what gets read", function()

	helpers.it("comes up disabled when the user left it disabled", function()
		local keylogger = load_over_storage({ ["metrics.enabled"] = false })
		local enabled = keylogger.is_enabled()
		drop_storage()
		helpers.assert_eq(enabled, false,
			"the whole point: the switch is read at load, not reset to the manifest "
				.. "default every start")
	end)

	helpers.it("comes up with a relaxed filter still relaxed", function()
		local keylogger = load_over_storage({ ["metrics.private_filter_enabled"] = false })
		local state = keylogger.get_privacy_state()
		drop_storage()
		helpers.assert_eq(state.private_filter_enabled, false,
			"a filter silently tightening again is the harmless direction, and still "
				.. "means the control did not do what it said")
	end)

	helpers.it("falls back to the manifest default when nothing is stored", function()
		local keylogger = load_over_storage()
		local Manifest = helpers.load_module("infra.manifest_reader")
		local shipped = Manifest.default_for("metrics.enabled")
		local enabled = keylogger.is_enabled()
		drop_storage()
		helpers.assert_eq(enabled, shipped,
			"an install with no stored choice must follow the shared manifest, which "
				.. "is the only thing that keeps the three drivers' defaults together")
	end)

end)
