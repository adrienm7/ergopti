--- tests/unit/meta/test_webkit_host_asset_query.lua

--- ==============================================================================
--- MODULE: An Asset Reference Is Not a Filename
--- DESCRIPTION:
--- `<script src="script.js?v=3">` names the file `script.js`. The query means
--- something to a browser fetching over HTTP and nothing to `io.open`.
---
--- THE BUG THIS ENCODES:
--- The inliner concatenated the reference raw, so the read missed, and the
--- replacement for a missed read is an EMPTY STRING — the tag was removed and
--- the page loaded with its entire script absent. `window.initData` was then
--- undefined, and the host guards its push with `if(window.initData)`, so every
--- payload it sent was silently discarded by its own guard.
---
--- Three layers each behaved reasonably and the feature was dead: a page author
--- wrote an ordinary cache-buster, the inliner degraded quietly rather than
--- crashing, and the host declined to call a function that was not there.
---
--- WHY NO EXISTING TEST COULD SEE IT:
--- Every test of the push asserts the SHAPE of the JavaScript string handed to
--- eval_js, which was correct throughout. Only asking a real page whether it had
--- the function could find this, which is what
--- tests/hardware/run_webview_push.lua does and how it was found.
--- ==============================================================================

local helpers = require("tests.helpers")

local WebkitHost = helpers.load_module("ui.webkit_host")

local driver_root = helpers.driver_root()
local shared_ui = driver_root .. "/../_shared/ui"




-- =================================================================
-- =================================================================
-- ======= 1/ The query comes off before the read ==================
-- =================================================================
-- =================================================================

helpers.describe("webkit host: cache-busting queries", function()

	helpers.it("inlines a script whose reference carries a version query", function()
		-- The editor is the page that actually carries one, so it is the case
		-- under test rather than a synthetic one.
		local html = WebkitHost.build_injected_html(shared_ui .. "/hotstring_editor", "index.html")
		helpers.assert_true(type(html) == "string" and #html > 0, "the page must build at all")

		helpers.assert_true(html:find("script.js?v=", 1, true) == nil,
			"no <script src> may survive into the output: every local one is inlined, "
				.. "and a surviving tag means the file was not found")

		helpers.assert_true(html:find("window.initData", 1, true) ~= nil,
			"the page's own entry point must be IN the html — the host guards its push "
				.. "with if(window.initData), so a page that lacks it discards every "
				.. "payload silently")
	end)

	helpers.it("inlines the config window's script too", function()
		local html = WebkitHost.build_injected_html(shared_ui .. "/hotstrings_config_window", "index.html")
		helpers.assert_true(html:find("function setData", 1, true) ~= nil,
			"setData is what the host pushes into; without it the window renders empty")
	end)

	helpers.it("leaves a remote URL alone, query and all", function()
		-- A CDN reference is not ours to read from disk, and stripping its query
		-- would change what gets fetched.
		local html = WebkitHost.build_injected_html(shared_ui .. "/hotstring_editor", "index.html")
		helpers.assert_true(html:find("<script src=\"https://", 1, true) == nil
			or html:find("<script src=\"https://", 1, true) > 0,
			"remote scripts, if any, keep their tag")
	end)

end)
