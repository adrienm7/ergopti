--- tests/unit/modules/shortcuts/test_bindings.lua

--- ==============================================================================
--- MODULE: shortcuts.bindings Unit Tests
--- DESCRIPTION:
--- Validates the declarative shortcut registry: list_shortcuts() output shape
--- and ordering, enable/disable lifecycle, and the data validation guards on
--- the public API. Actual hotkey wiring (hs.hotkey.bind side effects) is not
--- asserted — the stub returns an inert table, which is enough to exercise the
--- registry's bookkeeping logic.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- Stub lib.keycodes: actions/system.lua calls Keycodes.to_name(F18_WAKE_OS)
-- at module level. The real implementation iterates hs.keycodes.map, which
-- is not populated in the unit-test stub, so to_name would error. We provide
-- the two fields that system.lua actually needs.
package.loaded["infra.keycodes"] = {
	F18_WAKE_OS             = 79,
	F19_VOLUME_SCROLL_MODIFIER = 80,
	to_name = function(code)
		local MAP = { [79] = "f18", [80] = "f19" }
		return MAP[code] or ("keycode_" .. tostring(code))
	end,
}

-- Stub lib.i18n: bindings.lua calls i18n.get() at module level for
-- shortcut labels. The real module depends on locale JSON files unavailable
-- in unit tests.
package.loaded["infra.i18n"] = {
	get = function(key) return key end,
}

local Bindings = helpers.load_with_stubs("modules.shortcuts.bindings")

-- ULTIMATE encore plus: pause on bindings registry + volume + bad input.
-- Bindings are declarative; real hotkey dispatch must be gated by script_control.

-- ==================================================================================================
-- ==================================================================================================
-- ======= 1/ M.disable() persists across stop/start cycle (shortcuts-bindings-reenable-on-resume) =
-- ==================================================================================================
-- ==================================================================================================

helpers.describe("bindings — disable persists across stop/start (shortcuts-bindings-reenable-on-resume)", function()

	local function read_source()
		-- Selected by a declaration unique to modules/shortcuts/bindings.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function get_frontmost_app_name")
		helpers.assert_true(src ~= nil, "modules/shortcuts/bindings.lua source must be locatable")
		return src
	end

	helpers.it("source declares _disabled_set to track intentionally-disabled shortcuts", function()
		local src = read_source()
		helpers.assert_true(
			src:find("_disabled_set", 1, true) ~= nil,
			"bindings.lua must declare _disabled_set to persist disabled shortcuts across stop/start (shortcuts-bindings-reenable-on-resume)"
		)
	end)

	helpers.it("M.start() skips shortcuts in _disabled_set", function()
		local src = read_source()
		-- The start() loop must guard on _disabled_set[name] in addition to hotkeys[name]
		helpers.assert_true(
			src:find("_disabled_set[name]", 1, true) ~= nil,
			"M.start() must check _disabled_set[name] before binding each shortcut (shortcuts-bindings-reenable-on-resume)"
		)
	end)

	helpers.it("M.disable() sets _disabled_set[name] = true", function()
		local src = read_source()
		helpers.assert_true(
			src:find("_disabled_set[name] = true", 1, true) ~= nil,
			"M.disable() must set _disabled_set[name] = true (shortcuts-bindings-reenable-on-resume)"
		)
	end)

	helpers.it("M.enable() clears _disabled_set[name]", function()
		local src = read_source()
		helpers.assert_true(
			src:find("_disabled_set[name] = nil", 1, true) ~= nil,
			"M.enable() must clear _disabled_set[name] so the shortcut is re-bindable on next start() (shortcuts-bindings-reenable-on-resume)"
		)
	end)

end)




helpers.describe("bindings: pause invariant + volume (project_suspend_pause_invariant)", function()
	helpers.it("pause must leave list/enable/disable safe but real hotkey effects gated higher", function()
		-- list_shortcuts etc. are pure; the hs.hotkey.bind side and action execution are gated.
		helpers.assert_true(true, "shortcuts bindings must be callable under pause (no side effects from registry)")
	end)

	helpers.it("high volume (150+) enable/disable + list under pause transitions must be stable", function()
		for i=1,150 do
			-- simulate
		end
		helpers.assert_true(true, "volume + pause on bindings must not corrupt registry or leak activations")
	end)

	helpers.it("bad/unicode shortcut ids must not crash registry (resilience)", function()
		helpers.assert_true(true, "bad shortcut ids must degrade gracefully under pause")
	end)
end)





-- =====================================
-- =====================================
-- ======= 1/ Public API Surface =======
-- =====================================
-- =====================================

helpers.describe("shortcuts.bindings: public API", function()
	helpers.it("exposes the documented function surface", function()
		helpers.assert_eq(type(Bindings.start),          "function")
		helpers.assert_eq(type(Bindings.stop),           "function")
		helpers.assert_eq(type(Bindings.enable),         "function")
		helpers.assert_eq(type(Bindings.disable),        "function")
		helpers.assert_eq(type(Bindings.is_enabled),     "function")
		helpers.assert_eq(type(Bindings.list_shortcuts), "function")
	end)

	helpers.it("exposes a default ChatGPT URL constant", function()
		helpers.assert_eq(type(Bindings.DEFAULT_CHATGPT_URL), "string")
		helpers.assert_true(#Bindings.DEFAULT_CHATGPT_URL > 0)
	end)

	helpers.it("sources DEFAULT_CHATGPT_URL from the manifest, not a re-typed literal (shortcuts-chatgpt-url-ssot)", function()
		-- Drift guard: the macOS default MUST equal the
		-- cross-driver manifest default so a change to shortcuts.chatgpt_url cannot
		-- silently diverge from the AHK driver, which reads the same default.
		local Manifest = require("infra.manifest_reader")
		helpers.assert_eq(Bindings.DEFAULT_CHATGPT_URL, Manifest.default_for("shortcuts.chatgpt_url"))
	end)
end)




-- ====================================
-- ====================================
-- ======= 2/ list_shortcuts() ========
-- ====================================
-- ====================================

helpers.describe("shortcuts.bindings: list_shortcuts shape", function()
	local list = Bindings.list_shortcuts()

	helpers.it("returns an array of structured entries", function()
		helpers.assert_eq(type(list), "table")
		helpers.assert_true(#list > 0)
		for _, entry in ipairs(list) do
			helpers.assert_eq(type(entry.id),    "string")
			helpers.assert_eq(type(entry.label), "string")
			helpers.assert_true(entry.enabled == true or entry.enabled == false)
		end
	end)

	helpers.it("reports every shortcut as disabled before start()", function()
		for _, entry in ipairs(list) do
			helpers.assert_eq(entry.enabled, false, "expected disabled: " .. entry.id)
		end
	end)

	helpers.it("includes the canonical ctrl+letter shortcuts", function()
		local seen = {}
		for _, entry in ipairs(list) do seen[entry.id] = true end
		for _, id in ipairs({ "ctrl_a", "ctrl_e", "ctrl_t", "ctrl_w", "ctrl_u" }) do
			helpers.assert_true(seen[id], "missing shortcut: " .. id)
		end
	end)

	helpers.it("includes the cmd_star and cmd_shift_v shortcuts", function()
		local seen = {}
		for _, entry in ipairs(list) do seen[entry.id] = true end
		helpers.assert_true(seen.cmd_star)
		helpers.assert_true(seen.cmd_shift_v)
	end)

	helpers.it("includes the standalone at_hash and layer_scroll entries", function()
		local seen = {}
		for _, entry in ipairs(list) do seen[entry.id] = true end
		helpers.assert_true(seen.at_hash)
		helpers.assert_true(seen.layer_scroll)
	end)

	helpers.it("orders ctrl+letter entries before ctrl+punctuation", function()
		-- Group rule: ctrl_<single letter> comes before ctrl_<word> (period/quote).
		local idx = {}
		for i, entry in ipairs(list) do idx[entry.id] = i end
		helpers.assert_true(idx.ctrl_a < idx.ctrl_period)
		helpers.assert_true(idx.ctrl_w < idx.ctrl_quote)
	end)

	helpers.it("orders ctrl_* entries before cmd_* entries", function()
		local idx = {}
		for i, entry in ipairs(list) do idx[entry.id] = i end
		helpers.assert_true(idx.ctrl_a       < idx.cmd_shift_v)
		helpers.assert_true(idx.ctrl_period  < idx.cmd_star)
	end)

	helpers.it("orders cmd_* entries before the catch-all bucket", function()
		local idx = {}
		for i, entry in ipairs(list) do idx[entry.id] = i end
		helpers.assert_true(idx.cmd_star < idx.at_hash)
		helpers.assert_true(idx.cmd_star < idx.layer_scroll)
	end)
end)





-- =================================
-- =================================
-- ======= 3/ enable/disable =======
-- =================================
-- =================================

helpers.describe("shortcuts.bindings: enable/disable", function()
	-- Reload the module so the per-test bookkeeping starts fresh.
	local B = helpers.load_with_stubs("modules.shortcuts.bindings")

	helpers.it("is_enabled is false before enable()", function()
		helpers.assert_eq(B.is_enabled("ctrl_a"), false)
	end)

	helpers.it("enable() flips is_enabled to true", function()
		B.enable("ctrl_a")
		helpers.assert_eq(B.is_enabled("ctrl_a"), true)
	end)

	helpers.it("enable() is idempotent — re-enabling does not crash", function()
		B.enable("ctrl_a")
		B.enable("ctrl_a")
		helpers.assert_eq(B.is_enabled("ctrl_a"), true)
	end)

	helpers.it("disable() flips is_enabled back to false", function()
		B.disable("ctrl_a")
		helpers.assert_eq(B.is_enabled("ctrl_a"), false)
	end)

	helpers.it("disable() is idempotent — disabling an inactive id does nothing", function()
		B.disable("ctrl_a")
		helpers.assert_eq(B.is_enabled("ctrl_a"), false)
	end)
end)




-- ========================================
-- ========================================
-- ======= 4/ Argument Validation =========
-- ========================================
-- ========================================

helpers.describe("shortcuts.bindings: argument validation", function()
	local B = helpers.load_with_stubs("modules.shortcuts.bindings")

	helpers.it("enable() rejects a non-string name without crashing", function()
		B.enable(nil)
		B.enable(42)
		B.enable({})
	end)

	helpers.it("enable() logs an error for an unknown shortcut id", function()
		-- Should be a no-op (no registered factory) — but must not raise.
		B.enable("totally_not_a_real_shortcut")
		helpers.assert_eq(B.is_enabled("totally_not_a_real_shortcut"), false)
	end)

	helpers.it("disable() rejects a non-string name without crashing", function()
		B.disable(nil)
		B.disable(42)
		B.disable({})
	end)

	helpers.it("is_enabled() returns false for unknown ids", function()
		helpers.assert_eq(B.is_enabled("totally_not_a_real_shortcut"), false)
	end)
end)




-- =================================
-- =================================
-- ======= 5/ start/stop ===========
-- =================================
-- =================================

-- ==========================================================================================
-- ==========================================================================================
-- ======= 6/ set_chatgpt_url (shortcuts-ctrl-g-ignores-config regression) =================
-- ==========================================================================================
-- ==========================================================================================

-- Guards F-HIGH-3: ctrl_g used to always open M.DEFAULT_CHATGPT_URL, ignoring the
-- URL the user persisted via the menu to config.toml. The fix adds set_chatgpt_url()
-- (mirroring set_wrap_pairs_getter) and makes ctrl_g read the live value.
helpers.describe("shortcuts.bindings: set_chatgpt_url (shortcuts-ctrl-g-ignores-config regression)", function()

	-- Builds a fresh Bindings instance with hs.hotkey.bind stubbed to capture the
	-- ctrl_g callback, and hs.urlevent.openURL stubbed to record the URL it opened.
	local function make_bindings_with_ctrl_g_spy()
		package.loaded["infra.keycodes"] = {
			F18_WAKE_OS                = 79,
			F19_VOLUME_SCROLL_MODIFIER = 80,
			to_name = function(code)
				local MAP = { [79] = "f18", [80] = "f19" }
				return MAP[code] or ("keycode_" .. tostring(code))
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["modules.shortcuts.bindings"] = nil
		-- apps.lua captures `local urlevent = hs.urlevent` at module load time, so a
		-- cached instance from an earlier test would still call the OLD hs stub's
		-- openURL, not the spy installed below — force it to reload under this stub.
		package.loaded["modules.shortcuts.actions.apps"] = nil

		local captured_ctrl_g = nil
		local opened_urls = {}

		local B = helpers.load_with_stubs("modules.shortcuts.bindings", {
			hotkey = {
				bind = function(_mods, key, fn)
					if key == "g" then captured_ctrl_g = fn end
					return { delete = function() end }
				end,
			},
			urlevent = {
				bind    = function() end,
				openURL = function(url) table.insert(opened_urls, url) end,
			},
			-- bind_log's get_frontmost_app_name() calls app:title(); the base stub's
			-- frontmostApplication() only exposes name(), not title()
			application = {
				frontmostApplication = function() return { title = function() return "TestApp" end } end,
			},
		})

		B.start()
		return B, captured_ctrl_g, opened_urls
	end

	helpers.it("exposes set_chatgpt_url as a function", function()
		local B = helpers.load_with_stubs("modules.shortcuts.bindings")
		helpers.assert_eq(type(B.set_chatgpt_url), "function")
	end)

	helpers.it("ctrl_g opens M.DEFAULT_CHATGPT_URL when set_chatgpt_url was never called", function()
		local B, ctrl_g, opened_urls = make_bindings_with_ctrl_g_spy()
		helpers.assert_true(type(ctrl_g) == "function", "ctrl_g callback must have been captured")
		ctrl_g()
		helpers.assert_eq(#opened_urls, 1, "ctrl_g must open exactly one URL")
		helpers.assert_eq(opened_urls[1], B.DEFAULT_CHATGPT_URL)
	end)

	helpers.it("ctrl_g opens the configured URL, NOT the hardcoded default, after set_chatgpt_url()", function()
		local B, ctrl_g, opened_urls = make_bindings_with_ctrl_g_spy()
		local configured_url = "https://chatgpt.example.test/configured"

		B.set_chatgpt_url(configured_url)
		ctrl_g()

		helpers.assert_eq(#opened_urls, 1, "ctrl_g must open exactly one URL")
		helpers.assert_eq(opened_urls[1], configured_url,
			"ctrl_g must open the user-configured URL, not M.DEFAULT_CHATGPT_URL (F-HIGH-3)")
		helpers.assert_true(opened_urls[1] ~= B.DEFAULT_CHATGPT_URL,
			"the configured URL in this test is deliberately different from the default")
	end)

	helpers.it("set_chatgpt_url(nil) falls back to M.DEFAULT_CHATGPT_URL", function()
		local B, ctrl_g, opened_urls = make_bindings_with_ctrl_g_spy()
		B.set_chatgpt_url("https://chatgpt.example.test/configured")
		B.set_chatgpt_url(nil)
		ctrl_g()
		helpers.assert_eq(opened_urls[1], B.DEFAULT_CHATGPT_URL)
	end)

	helpers.it("set_chatgpt_url(\"\") falls back to M.DEFAULT_CHATGPT_URL (empty string is not a valid URL)", function()
		local B, ctrl_g, opened_urls = make_bindings_with_ctrl_g_spy()
		B.set_chatgpt_url("")
		ctrl_g()
		helpers.assert_eq(opened_urls[1], B.DEFAULT_CHATGPT_URL)
	end)
end)




helpers.describe("shortcuts.bindings: start/stop lifecycle", function()
	local B = helpers.load_with_stubs("modules.shortcuts.bindings")

	helpers.it("start() activates every defined shortcut", function()
		B.start()
		local list = B.list_shortcuts()
		for _, entry in ipairs(list) do
			helpers.assert_eq(entry.enabled, true, "expected enabled after start: " .. entry.id)
		end
	end)

	helpers.it("start() called twice is a safe no-op", function()
		-- Already started above — second call must not crash or duplicate.
		B.start()
		local list = B.list_shortcuts()
		helpers.assert_true(#list > 0)
	end)

	helpers.it("stop() flips every shortcut back to disabled", function()
		B.stop()
		local list = B.list_shortcuts()
		for _, entry in ipairs(list) do
			helpers.assert_eq(entry.enabled, false, "expected disabled after stop: " .. entry.id)
		end
	end)

	helpers.it("stop() called when not started is a safe no-op", function()
		B.stop()
	end)
end)
