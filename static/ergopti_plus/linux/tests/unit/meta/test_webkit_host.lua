--- tests/unit/meta/test_webkit_host.lua

local helpers = require("tests.helpers")
local WH      = helpers.load_module("ui.webkit_host")

-- Resolve the driver root so we can test path resolution against real directories.
-- helpers.driver_root() returns .../linux; the _shared/ui/ dir is at
-- .../ergopti_plus/_shared/ui/ relative to the linux driver.
local DRIVER_ROOT = helpers.driver_root()

helpers.describe("ui.webkit_host", function()

  -- ==========================================================================
  -- 1. Bridge handler registry
  -- ==========================================================================

  helpers.describe("get_bridge_names()", function()
    helpers.it("returns an array", function()
      local names = WH.get_bridge_names()
      helpers.assert_true(type(names) == "table", "returns table")
      helpers.assert_true(#names > 0, "non-empty")
    end)

    helpers.it("contains all expected bridge names from host_bridge.js", function()
      local names = WH.get_bridge_names()
      local expected = {
        "action_picker_bridge", "changelog_bridge", "dl_bridge",
        "hsEditor", "hotstrings_config_bridge", "hsOnboarding",
        "hsPaths", "hsPersonalInfo", "metrics_apps_bridge", "metrics_typing_bridge",
        "model_browser_bridge", "numeric_prompt_bridge", "prompt_bridge",
        "token_bridge", "healthcheck",
      }
      local set = {}
      for _, n in ipairs(names) do set[n] = true end
      for _, e in ipairs(expected) do
        helpers.assert_true(set[e], "bridge " .. e .. " is registered")
      end
    end)

    helpers.it("has exactly 15 bridges", function()
      helpers.assert_eq(#WH.get_bridge_names(), 15)
    end)
  end)

  helpers.describe("is_valid_bridge()", function()
    helpers.it("returns true for known bridges", function()
      helpers.assert_true(WH.is_valid_bridge("healthcheck"), "healthcheck valid")
      helpers.assert_true(WH.is_valid_bridge("metrics_apps_bridge"), "metrics valid")
      helpers.assert_true(WH.is_valid_bridge("metrics_typing_bridge"), "typing metrics valid")
      helpers.assert_true(WH.is_valid_bridge("token_bridge"), "token valid")
    end)

    helpers.it("returns false for unknown bridges", function()
      helpers.assert_true(not WH.is_valid_bridge("fake_bridge"), "fake invalid")
      helpers.assert_true(not WH.is_valid_bridge(""), "empty invalid")
      helpers.assert_true(not WH.is_valid_bridge(nil), "nil invalid")
    end)
  end)

	-- A global allowlist is not an authority boundary: WebKit exposes every
	-- registered name to the page. Ownership must therefore be exact per app.
	helpers.describe("bridge_for_app()", function()
		helpers.it("assigns exactly one bridge to every real webview app", function()
			local seen = {}
			for app_name, bridge_name in pairs(WH.APP_BRIDGES) do
				helpers.assert_true(type(app_name) == "string" and app_name ~= "")
				helpers.assert_true(type(bridge_name) == "string" and bridge_name ~= "")
				helpers.assert_true(not seen[bridge_name], "bridge reused by " .. app_name)
				seen[bridge_name] = true
			end
			helpers.assert_eq(WH.bridge_for_app("metrics_apps"), "metrics_apps_bridge")
			helpers.assert_eq(WH.bridge_for_app("numeric_prompt"), "numeric_prompt_bridge")
			helpers.assert_eq(WH.bridge_for_app("personal_toml_editor"), nil,
				"a bridge with no page cannot own a WebKit capability")
		end)
	end)

  -- ==========================================================================
  -- 2. Path resolution
  -- ==========================================================================

  helpers.describe("resolve_ui_root()", function()
    helpers.it("resolves _shared/ui/ from the driver root", function()
      local ui_root = WH.resolve_ui_root(DRIVER_ROOT)
      helpers.assert_true(ui_root ~= "", "resolves to non-empty path")
      helpers.assert_true(ui_root:find("_shared/ui"), "contains _shared/ui")
      -- Verify it's a real directory (contains host_bridge.js)
      helpers.assert_true(ui_root:match("_shared/ui$") ~= nil, "ends with _shared/ui")
    end)

    helpers.it("normalizes backslashes to forward slashes", function()
      local ui_root = WH.resolve_ui_root(DRIVER_ROOT)
      helpers.assert_true(not ui_root:find("\\"), "no backslashes in resolved path")
    end)

    helpers.it("returns empty for nonexistent roots", function()
      helpers.assert_eq(WH.resolve_ui_root("/nonexistent/path"), "")
    end)
  end)

  helpers.describe("resolve_app_dir()", function()
    helpers.it("resolves an existing app directory", function()
      local ui_root = WH.resolve_ui_root(DRIVER_ROOT)
      local app_dir = WH.resolve_app_dir(ui_root, "action_picker")
      helpers.assert_true(app_dir ~= "", "resolves action_picker")
      helpers.assert_true(app_dir:find("action_picker"), "contains app name")
    end)

    helpers.it("returns empty for nonexistent app", function()
      local ui_root = WH.resolve_ui_root(DRIVER_ROOT)
      helpers.assert_eq(WH.resolve_app_dir(ui_root, "nonexistent_app"), "")
    end)

    helpers.it("returns empty when ui_root is empty", function()
      helpers.assert_eq(WH.resolve_app_dir("", "action_picker"), "")
    end)
  end)

  helpers.describe("resolve_locales_dir()", function()
    helpers.it("resolves _shared/data/locales/ from the driver root", function()
      local dir = WH.resolve_locales_dir(DRIVER_ROOT)
      helpers.assert_true(dir ~= "", "resolves to non-empty path")
      helpers.assert_true(dir:find("_shared/data/locales"), "contains expected path")
    end)
  end)

  -- ==========================================================================
  -- 3. build_injected_html()
  -- ==========================================================================

  helpers.describe("build_injected_html()", function()
    helpers.it("returns error page for empty assets_dir", function()
      local html = WH.build_injected_html("")
      helpers.assert_true(html:find("Build error"), "has error message")
      helpers.assert_true(html:find("assets_dir empty"), "mentions empty dir")
    end)

    helpers.it("returns error page for nonexistent index.html", function()
      local html = WH.build_injected_html("/nonexistent")
      helpers.assert_true(html:find("Build error"), "has error message")
    end)

    helpers.it("loads a real index.html from action_picker", function()
      local ui_root  = WH.resolve_ui_root(DRIVER_ROOT)
      local app_dir  = WH.resolve_app_dir(ui_root, "action_picker")
      local html     = WH.build_injected_html(app_dir)
      helpers.assert_true(html ~= "", "non-empty HTML")
      helpers.assert_true(html:find("<html") or html:find("<HTML") or html:find("<!DOCTYPE"),
        "contains HTML tag")
    end)

    helpers.it("inlines local CSS files as <style> blocks", function()
      local ui_root  = WH.resolve_ui_root(DRIVER_ROOT)
      local app_dir  = WH.resolve_app_dir(ui_root, "action_picker")
      local html     = WH.build_injected_html(app_dir)
      -- There should be <style> blocks (inlined CSS), or at least no external
      -- local .css references
      helpers.assert_true(
        html:find("<style>") or not html:find('href="[^h][^t][^t][^p]'),
        "local assets are inlined"
      )
    end)

		helpers.it("fails closed when a page names a remote executable asset", function()
			local ui_root = WH.resolve_ui_root(DRIVER_ROOT)
			local app_dir = WH.resolve_app_dir(ui_root, "metrics_apps")
			local original_open = io.open
			io.open = function(path, mode)
				if path == app_dir .. "/hostile.html" then
					local content = '<html><head><script src="https://attacker.invalid/payload.js"></script></head></html>'
					return {
						read = function() return content end,
						close = function() end,
					}
				end
				return original_open(path, mode)
			end
			local ok, html = pcall(WH.build_injected_html, app_dir, "hostile.html")
			io.open = original_open
			if not ok then error(html, 0) end
			helpers.assert_true(html:find("Build error", 1, true) ~= nil)
			helpers.assert_true(html:find("attacker.invalid", 1, true) == nil,
				"the rejected URL must not survive into a loadable document")
		end)

    helpers.it("inlines local JS files as <script> blocks", function()
      local ui_root  = WH.resolve_ui_root(DRIVER_ROOT)
      local app_dir  = WH.resolve_app_dir(ui_root, "healthcheck")
      local html     = WH.build_injected_html(app_dir)
      helpers.assert_true(html ~= "", "non-empty HTML for healthcheck")
    end)

		helpers.it("builds both metrics pages from pinned local chart code", function()
			local ui_root = WH.resolve_ui_root(DRIVER_ROOT)
			for _, app_name in ipairs({ "metrics_apps", "metrics_typing" }) do
				local app_dir = WH.resolve_app_dir(ui_root, app_name)
				local html = WH.build_injected_html(app_dir)
				helpers.assert_true(html:find("Build error", 1, true) == nil,
					app_name .. " must build with every committed vendor present")
				helpers.assert_true(html:find("Chart.js v4.4.9", 1, true) ~= nil,
					app_name .. " must contain the reviewed local Chart.js bytes")
				helpers.assert_true(html:find('src="https://', 1, true) == nil)
				helpers.assert_true(html:find('src="http://', 1, true) == nil)
			end
		end)

		helpers.it("fails closed when a required local vendor is absent", function()
			local ui_root = WH.resolve_ui_root(DRIVER_ROOT)
			local app_dir = WH.resolve_app_dir(ui_root, "metrics_apps")
			local original_open = io.open
			io.open = function(path, mode)
				if tostring(path):find("vendor/chart.umd.js", 1, true) then return nil end
				return original_open(path, mode)
			end
			local ok, html = pcall(WH.build_injected_html, app_dir)
			io.open = original_open
			if not ok then error(html, 0) end
			helpers.assert_true(html:find("Build error", 1, true) ~= nil,
				"missing verified code must fail the page instead of silently dropping charts")
		end)
  end)

  -- ==========================================================================
  -- 4. i18n injection
  -- ==========================================================================

  helpers.describe("build_i18n_boot_script()", function()
    helpers.it("builds a script tag with locale and base URL", function()
      local script = WH.build_i18n_boot_script("/path/to/locales", "fr")
      helpers.assert_true(script:find("<script>"), "is script tag")
      helpers.assert_true(script:find("__i18n_base"), "has __i18n_base")
      helpers.assert_true(script:find("_i18n_locale"), "has _i18n_locale")
      helpers.assert_true(script:find('"fr"'), "has fr locale")
      helpers.assert_true(script:find("file:///path/to/locales/"), "has file URL")
    end)

    helpers.it("uses en locale when specified", function()
      local script = WH.build_i18n_boot_script("/locales", "en")
      helpers.assert_true(script:find('"en"'), "has en locale")
    end)

    helpers.it("defaults to fr when locale not provided", function()
      local script = WH.build_i18n_boot_script("/locales")
      helpers.assert_true(script:find('"fr"'), "defaults to fr")
    end)

    helpers.it("handles empty locales_dir gracefully", function()
      local script = WH.build_i18n_boot_script("", "fr")
      helpers.assert_true(script ~= "", "still produces a script tag")
    end)
  end)

  helpers.describe("inject_i18n_boot()", function()
    helpers.it("injects script after <head> tag", function()
      local html = "<!DOCTYPE html><html><head><title>Test</title></head><body></body></html>"
      local result = WH.inject_i18n_boot(html, "<script>TEST</script>")
      helpers.assert_true(result:find("<head><script>TEST</script>"), "injected after head")
    end)

    helpers.it("injects after <head> with attributes", function()
      local html = '<html><head lang="fr"><meta charset="utf-8"></head><body></body></html>'
      local result = WH.inject_i18n_boot(html, "<script>X</script>")
      helpers.assert_true(result:find('<head lang="fr"><script>X</script>'), "with attributes")
    end)

    helpers.it("returns original HTML when i18n_script is not a string", function()
      local html = "<html><head></head></html>"
      helpers.assert_eq(WH.inject_i18n_boot(html, nil), html)
    end)

    helpers.it("handles HTML without <head> gracefully", function()
      local html = "<html><body>No head</body></html>"
      local result = WH.inject_i18n_boot(html, "<script>X</script>")
      helpers.assert_eq(result, html)  -- unchanged, no head tag
    end)
  end)

	helpers.describe("inject_no_remote_csp()", function()
		helpers.it("denies remote script and connection origins", function()
			local html = WH.inject_no_remote_csp("<html><head></head><body></body></html>")
			helpers.assert_true(html:find("Content%-Security%-Policy") ~= nil)
			helpers.assert_true(html:find("default%-src 'none'") ~= nil)
			helpers.assert_true(html:find("connect%-src 'self' file:") ~= nil)
			helpers.assert_true(html:find("https:", 1, true) == nil)
			helpers.assert_true(html:find("http:", 1, true) == nil)
		end)
	end)

  -- ==========================================================================
  -- 5. build_app_html() — full pipeline
  -- ==========================================================================

  helpers.describe("build_app_html()", function()
    helpers.it("returns error HTML when _shared/ui/ not found", function()
      local html = WH.build_app_html("/nonexistent", "action_picker", "fr")
      helpers.assert_true(html:find("_shared/ui/ not found"), "correct error message")
    end)

    helpers.it("returns error HTML for nonexistent app", function()
      local html = WH.build_app_html(DRIVER_ROOT, "nonexistent_app", "fr")
      helpers.assert_true(html:find("not found"), "error for missing app")
    end)

    helpers.it("builds complete HTML for a real app (action_picker)", function()
      local html = WH.build_app_html(DRIVER_ROOT, "action_picker", "fr")
      helpers.assert_true(html ~= "", "non-empty")
      helpers.assert_true(html:find("<html") or html:find("<HTML") or html:find("<!DOCTYPE"),
        "is valid HTML")
    end)

    helpers.it("builds complete HTML for healthcheck app", function()
      local html = WH.build_app_html(DRIVER_ROOT, "healthcheck", "en")
      helpers.assert_true(html ~= "", "non-empty")
      helpers.assert_true(html:find("<script>"), "has inlined scripts")
    end)

    helpers.it("injects i18n boot script with correct locale", function()
      local html = WH.build_app_html(DRIVER_ROOT, "action_picker", "en")
      helpers.assert_true(html:find('"en"'), "has en locale set")
      helpers.assert_true(html:find("__i18n_base"), "has i18n base")
    end)

    helpers.it("marks generated pages for the Linux host bridge", function()
      local html = WH.build_app_html(DRIVER_ROOT, "metrics_apps", "fr")
      helpers.assert_true(html:find('window.__ergopti_host="linux"', 1, true) ~= nil,
        "metrics pages must select the Linux bridge instead of a file fetch")
    end)
  end)

end)
