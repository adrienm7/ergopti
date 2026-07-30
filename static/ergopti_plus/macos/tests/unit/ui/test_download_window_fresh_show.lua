--- tests/unit/ui/test_download_window_fresh_show.lua

--- ==============================================================================
--- MODULE: Regression — a freshly opened progress window receives its payload
--- DESCRIPTION:
--- M.show() tested `if _wv then` TWICE. The first branch created the webview when
--- it was missing and queued setKind(kind, title, subtitle) — the only carrier of
--- the resolved title, subtitle and kind. The second test then ran two lines
--- later, when _wv had just been assigned, so a FRESH window always took the
--- "window already open" branch, which
---   * cleared `_queued`, discarding that setKind outright, and
---   * forced `_ready = true`, so every following eval() bypassed the queue and
---     fired evaluateJavaScript against a WKWebView whose document had not
---     finished loading — none of resetUI, setKind or setModel exist yet.
--- It then returned, making the block written to be the fresh-window path dead
--- code. Net effect on every first open: no model name, no kind (which drives
--- mode, accent colour and layout), no titles.
---
--- ROOT CAUSE ENCODED:
--- A branch that cannot distinguish "already open" from "opened two lines ago".
--- The assertions below are on WHAT THE PAGE RECEIVES and WHEN, never on the
--- shape of the branch, so any restructuring that delivers the payload passes.
---
--- Two further traps this pins, both load-bearing rather than cosmetic:
---   * resetUI() must NOT run on a fresh page. script.js hides AND disables
---     #btn-cancel when _t('download_window.btn_cancel') is falsy, and
---     window._i18n_strings does not exist while the queue flushes — ui_builder
---     injects it after didFinishNavigation. i18n apply() only rewrites
---     textContent, so it never restores `display`: the Cancel button would be
---     permanently gone from every freshly opened window.
---   * setKind(kind, nil, nil) must not follow the real one. script.js falls back
---     to the kind's default title and BLANKS the subtitle, so it would overwrite
---     the resolved pair — and the deps checkers pass the current step label as
---     that subtitle.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODEL = "org/some-model"
local TITLE = "Téléchargement du modèle"
local SUB   = "Étape 2 sur 4"


--- Installs the minimal hs.webview stub ui/download_window/init.lua needs at
--- module load time, captures the navigation callback so the test can simulate
--- the page finishing its load, and records every JS snippet actually executed.
--- Mirrors the harness in test_download_window_setmodel_js_escaping.lua.
--- @return table overrides, function get_evaluated, function fire_navigation
local function make_webview_overrides()
	local evaluated = {}
	local nav_callback = nil
	local overrides = {
		webview = {
			new = function()
				local wv
				wv = {
					frame              = function(_self) return { x = 0, y = 0, w = 460, h = 380 } end,
					evaluateJavaScript = function(_self, code) evaluated[#evaluated + 1] = code end,
					delete             = function(_self) end,
					navigationCallback = function(_self, fn) nav_callback = fn end,
					windowCallback     = function(_self, _fn) end,
					windowTitle        = function(self) return self end,
					windowStyle        = function(self) return self end,
					level              = function(self) return self end,
					allowTextEntry     = function(self) return self end,
					allowGestures      = function(self) return self end,
					allowNewWindows    = function(self) return self end,
					html               = function(self) return self end,
					show               = function(self) return self end,
				}
				return wv
			end,
			usercontent = {
				new = function(_name) return { setCallback = function(_self, _fn) end } end,
			},
			windowMasks = {},
		},
		screen = {
			mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end }
			end,
		},
	}
	return overrides,
		function() return evaluated end,
		function() if nav_callback then nav_callback("didFinishNavigation") end end
end


--- Loads a pristine ui.download_window under the stub set.
--- @return table module, function get_evaluated, function fire_navigation
local function load_fresh()
	-- Two isolation footguns documented in the sibling download_window test:
	-- other files leave a partial lib.logger in package.loaded, and ui_builder
	-- captures `local hs = hs` at require-time, so a cached copy would call
	-- hs.webview.new() against a previous test's stale stub.
	package.loaded["lib.logger"]    = nil
	package.loaded["ui.ui_builder"] = nil
	local overrides, get_evaluated, fire_navigation = make_webview_overrides()
	return helpers.load_with_stubs("ui.download_window", overrides), get_evaluated, fire_navigation
end


--- Finds the last evaluated snippet containing a needle.
--- @param evaluated table
--- @param needle string
--- @return string|nil
local function last_matching(evaluated, needle)
	local found = nil
	for _, code in ipairs(evaluated) do
		if code:find(needle, 1, true) then found = code end
	end
	return found
end


--- Counts evaluated snippets containing a needle.
--- @param evaluated table
--- @param needle string
--- @return number
local function count_matching(evaluated, needle)
	local n = 0
	for _, code in ipairs(evaluated) do
		if code:find(needle, 1, true) then n = n + 1 end
	end
	return n
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ Nothing runs before the page has loaded ===============
-- ==================================================================
-- ==================================================================

helpers.describe("download_window: a fresh window runs no JS before its page loads", function()

	helpers.it("executes nothing until didFinishNavigation", function()
		local DownloadWindow, get_evaluated, fire_navigation = load_fresh()

		DownloadWindow.show({ kind = "mlx_model", model = MODEL, title = TITLE, subtitle = SUB })

		helpers.assert_eq(#get_evaluated(), 0,
			"the page has not finished loading, so none of resetUI, setKind or setModel exists "
			.. "yet — every call made now is silently lost. The queue exists precisely for "
			.. "this, and forcing _ready = true on a window created two lines earlier bypasses it")

		fire_navigation()
		helpers.assert_true(#get_evaluated() > 0,
			"and once the page is loaded the queued payload must actually flush — without this "
			.. "the assertion above would pass against a show() that does nothing at all")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 2/ The payload survives the flush ========================
-- ==================================================================
-- ==================================================================

helpers.describe("download_window: a fresh window receives kind, titles and model", function()

	helpers.it("delivers the resolved title and subtitle, not the kind defaults", function()
		local DownloadWindow, get_evaluated, fire_navigation = load_fresh()

		DownloadWindow.show({ kind = "mlx_model", model = MODEL, title = TITLE, subtitle = SUB })
		fire_navigation()

		local evaluated = get_evaluated()
		local set_kind = last_matching(evaluated, "setKind(")
		helpers.assert_true(set_kind ~= nil,
			"setKind carries the kind, which drives the page's mode, accent colour and layout; "
			.. "found " .. #evaluated .. " evaluated call(s)")

		helpers.assert_true(set_kind:find(TITLE, 1, true) ~= nil,
			"the resolved title must reach the page. It was queued and then discarded by a "
			.. "`_queued = {}` on the branch meant for an already-open window")
		helpers.assert_true(set_kind:find(SUB, 1, true) ~= nil,
			"and so must the subtitle: the MLX and Ollama deps checkers pass the CURRENT STEP "
			.. "label as this value, so blanking it erases the only progress text the user has")

		helpers.assert_eq(count_matching(evaluated, "setKind("), 1,
			"exactly one setKind: a second one with nil title and subtitle makes script.js fall "
			.. "back to the kind's default title and blank the subtitle, undoing the first")
	end)

	helpers.it("delivers the model name", function()
		local DownloadWindow, get_evaluated, fire_navigation = load_fresh()

		DownloadWindow.show({ kind = "mlx_model", model = MODEL, title = TITLE, subtitle = SUB })
		fire_navigation()

		local set_model = last_matching(get_evaluated(), "setModel(")
		helpers.assert_true(set_model ~= nil and set_model:find(MODEL, 1, true) ~= nil,
			"the model being downloaded must be named on the page; got: " .. tostring(set_model))
	end)

	helpers.it("does not reset a page that has only just loaded", function()
		local DownloadWindow, get_evaluated, fire_navigation = load_fresh()

		DownloadWindow.show({ kind = "mlx_model", model = MODEL, title = TITLE, subtitle = SUB })
		fire_navigation()

		helpers.assert_eq(count_matching(get_evaluated(), "resetUI()"), 0,
			"there is nothing to reset on a brand-new page, and running it here is actively "
			.. "harmful: script.js hides AND disables #btn-cancel when the i18n strings are "
			.. "not in the page yet, and ui_builder injects them only after this flush. "
			.. "i18n apply() rewrites textContent and never restores `display`, so Cancel "
			.. "would be gone for the whole life of the window")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 3/ Reusing an open window still resets it ================
-- ==================================================================
-- ==================================================================

helpers.describe("download_window: reopening an existing window resets its state", function()

	helpers.it("a second show on the same window does reset the UI", function()
		local DownloadWindow, get_evaluated, fire_navigation = load_fresh()

		DownloadWindow.show({ kind = "mlx_model", model = MODEL, title = TITLE, subtitle = SUB })
		fire_navigation()
		local before = #get_evaluated()

		-- Same window, new occupant: here the reset is required, or the previous
		-- download's percentage, log lines and "done" banner stay on screen.
		DownloadWindow.show({ kind = "mlx_model", model = "org/other", title = "T2", subtitle = "S2" })

		local after = {}
		for i = before + 1, #get_evaluated() do after[#after + 1] = get_evaluated()[i] end

		helpers.assert_true(count_matching(after, "resetUI()") >= 1,
			"without this case the fresh-path assertion above would pass against a show() that "
			.. "never resets anything, leaving zombie placeholders from the previous occupant")
		local set_kind = last_matching(after, "setKind(")
		helpers.assert_true(set_kind ~= nil and set_kind:find("T2", 1, true) ~= nil,
			"and the reused window must pick up the NEW title, not keep the previous one")
	end)

end)
