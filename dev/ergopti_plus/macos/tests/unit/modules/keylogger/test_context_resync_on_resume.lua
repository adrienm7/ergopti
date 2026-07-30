--- tests/unit/modules/keylogger/test_context_resync_on_resume.lua

--- ==============================================================================
--- MODULE: Regression — the cached context must be re-synced on resume
--- DESCRIPTION:
--- Privacy and attribution bug caused by a CORRECT pause guard with no counterpart.
---
--- context_tracker.app_watcher_cb returns early while paused, which is right —
--- « pause = tout éteint », and test_pause_guard_position.lua pins that guard's
--- position deliberately. But the early return also skips everything that follows
--- the function's single write: the synthetic queue reset, active_app_name/bundle/
--- path/pid, is_secure_field, and the AX observer's target PID. That half is pure
--- in-memory synchronisation and logs nothing.
---
--- Nothing re-synced it afterwards. resume_all() never referenced the keylogger,
--- and no fresh activation event fires when the user resumes inside the app they
--- had already switched to during the pause. The cached context therefore stayed
--- pinned to whatever was frontmost when the pause began, for the rest of the
--- session or until the next app switch.
---
--- The dangerous half is is_secure_field. Pause in an ordinary app, switch to a
--- password manager, resume: the flag was still false, so the first keystrokes
--- typed inside the vault were logged — and attributed to the previous app.
---
--- THE FIX DIRECTION MATTERS: the guard is NOT moved or weakened. A resume-time
--- resync is added instead, so pause still records nothing at all.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Name present in SecureFieldDetector's SECURE_APP_IDS list.
local VAULT_APP = "1Password"

-- The app that was frontmost when the pause began.
local ORDINARY_APP = "TextEdit"

local NOT_PAUSED = function() return false end





-- =============================================
-- =============================================
-- ======= 1/ Frontmost-App Test Doubles =======
-- =============================================
-- =============================================

--- Builds hs overrides whose frontmost application is `app_name` and whose AX tree
--- exposes a plain (non-secure) text field — the vault-unlock-screen shape.
---
--- The double exposes BOTH name() and title(), and they deliberately disagree.
--- name() is the stable display-name API the whole pipeline is keyed on —
--- SecureFieldDetector.isSecureApp exact-matches display names — while title()
--- describes windows and is absent for some application instances. An earlier
--- version of this double defined title() ONLY, which made it structurally
--- incapable of noticing that resync_context was reading the wrong API: a vault
--- whose title is nil or differs from its display name was never re-recognised
--- as secure on resume, so keystrokes typed into it were logged.
---
--- Returning a deliberately WRONG title is what keeps that hole closed: any
--- code path that resolves the app by title now fails this fixture loudly.
--- @param app_name string Display name reported by app:name().
--- @return table hs_overrides suitable for helpers.load_with_stubs.
local function make_overrides(app_name)
	local fake_observer = {
		addWatcher = function() end, removeWatcher = function() end,
		callback   = function() end, start         = function() end, stop = function() end,
	}
	local plain_field = {
		attributeValue = function(_self, attr)
			if attr == "AXRole" then return "AXTextField" end
			return nil
		end,
	}
	local app_element = {
		attributeValue = function(_self, attr)
			if attr == "AXFocusedUIElement" then return plain_field end
			return nil
		end,
	}
	return {
		application = {
			frontmostApplication = function()
				return {
					name     = function() return app_name end,
					-- Deliberately NOT the display name: resolving the app by
					-- title must not accidentally work.
					title    = function() return "window title of " .. app_name end,
					bundleID = function() return "com.example." .. app_name end,
					path     = function() return "/Applications/" .. app_name .. ".app" end,
					pid      = function() return 4242 end,
				}
			end,
			watcher = { activated = 1 },
		},
		axuielement = {
			observer           = { new = function(_pid) return fake_observer end },
			applicationElement = function(_pid) return app_element end,
		},
	}
end





-- ==========================================
-- ==========================================
-- ======= 2/ Resume Re-syncs Context =======
-- ==========================================
-- ==========================================

helpers.describe("context is re-synchronised on resume", function()
	helpers.it("picks up the vault the user switched to while paused", function()
		package.loaded["modules.keylogger.context_tracker"] = nil
		local CT = helpers.load_with_stubs("modules.keylogger.context_tracker", make_overrides(VAULT_APP))

		-- State as the pause left it: pinned to the app that was frontmost then.
		local state = {
			active_app_name = ORDINARY_APP,
			is_secure_field = false,
			synth_queue     = { { char = "x" } },
		}
		CT.init(state, { append_log = function() end, log_app_switch = function() end }, NOT_PAUSED)

		local ok = CT.resync_context()

		helpers.assert_true(ok, "resync_context must report success when a frontmost app exists")
		helpers.assert_eq(state.active_app_name, VAULT_APP,
			"the cached app must follow the switch that happened during the pause, otherwise "
			.. "post-resume keystrokes are attributed to the previous application")
		helpers.assert_true(state.is_secure_field == true,
			"is_secure_field must be recomputed on resume — left stale-false, the first "
			.. "keystrokes typed inside the password manager are logged")
		helpers.assert_eq(#state.synth_queue, 0,
			"a resume is a context boundary like an app activation: the synthetic queue must "
			.. "be cleared so a pre-pause echo cannot mis-tag the first key after resume")
	end)

	helpers.it("leaves an ordinary app unsuppressed after resync", function()
		-- The opposite failure: a resync that pinned the flag on would silently
		-- disable metrics for everyone.
		package.loaded["modules.keylogger.context_tracker"] = nil
		local CT = helpers.load_with_stubs("modules.keylogger.context_tracker", make_overrides(ORDINARY_APP))

		local state = { active_app_name = VAULT_APP, is_secure_field = true, synth_queue = {} }
		CT.init(state, { append_log = function() end, log_app_switch = function() end }, NOT_PAUSED)

		CT.resync_context()

		helpers.assert_eq(state.active_app_name, ORDINARY_APP,
			"the cached app must follow the resume-time frontmost app in both directions")
		helpers.assert_true(state.is_secure_field == false,
			"leaving a vault during a pause must clear the flag on resume, otherwise logging "
			.. "stays suppressed forever in an ordinary app")
	end)

	helpers.it("script_control.resume_all calls the keylogger resync", function()
		-- The guarantee is transitive: resync_context existing is worthless unless the
		-- resume path actually invokes it. Assert the wiring, not just the function.
		local src = helpers.read_driver_source("local function resume_all()")
		helpers.assert_true(src ~= nil, "the resume_all source must be locatable")
		if not src then return end

		local resume_at = src:find("local function resume_all", 1, true)
		helpers.assert_true(resume_at ~= nil, "resume_all must be locatable")

		local slice = src:sub(resume_at, src:find("\nlocal function ", resume_at + 10, true) or #src)
		helpers.assert_true(slice:find("resync_context", 1, true) ~= nil,
			"resume_all must call the keylogger's resync_context — without the call the cached "
			.. "context stays pinned to the pre-pause app for the rest of the session")
	end)
end)
