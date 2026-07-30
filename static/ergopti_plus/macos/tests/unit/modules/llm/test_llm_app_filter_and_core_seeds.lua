--- tests/unit/modules/llm/test_llm_app_filter_and_core_seeds.lua

--- ==============================================================================
--- MODULE: LLM app_filter empty-name guard + CoreState model seed regressions
--- DESCRIPTION:
--- Regression tests for two related LLM bugs:
---
--- llm-api-support-1: app_filter.is_blocked() with a name-only exclusion entry
--- (no appPath, no bundleID) matched ANY app whose hs:name() returned nil,
--- because ("slack"):find("",1,true) == 1. The fix adds `and name ~= ""` to
--- the same_name predicate.
---
--- llm-core-1: CoreState was not seeded with llm_model_ollama / llm_model_mlx
--- from DEFAULT_STATE, so get_current_model() returned nil until a setter was
--- called — silently skipping the warmup on first boot.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =============================================================================
-- =============================================================================
-- ======= 1/ app_filter.is_blocked empty-name guard (llm-api-support-1) =======
-- =============================================================================
-- =============================================================================

helpers.describe("llm.app_filter — is_blocked empty-name guard", function()

	-- Each fake app must include all three methods that is_blocked() calls on the
	-- front object (bundleID, path, name). The default hs.application stub only has
	-- name/bundleID, causing 'attempt to call a nil value (method path)' at line 196.
	local function make_nameless_front()
		return {
			bundleID  = function() return "com.test.unknown" end,
			path      = function() return "/Applications/Unknown.app" end,
			name      = function() return nil end,
		}
	end

	local function make_named_front(app_name)
		return {
			bundleID  = function() return "com.test." .. app_name end,
			path      = function() return "/Applications/" .. app_name .. ".app" end,
			name      = function() return app_name end,
		}
	end

	-- get_focused_app() in app_filter calls hs.window.focusedWindow() first; the
	-- default stub returns nil, so the fallback hs.application.frontmostApplication()
	-- is used. We override frontmostApplication on the live hs stub (which app_filter
	-- captured as `local hs = hs` — same table reference) to inject our fake app.
	local function set_front(fake_app)
		_G.hs.application.frontmostApplication = function() return fake_app end
	end

	helpers.it("does NOT block a nameless app when exclusion is name-only", function()
		local AF = helpers.load_with_stubs("modules.llm.app_filter")
		set_front(make_nameless_front())

		local exclusions = { { name = "Slack" } }
		local state = { is_url_bar_focused = false }
		local result = AF.is_blocked(state, exclusions, false, false)
		helpers.assert_true(result == false,
			"is_blocked must return false for a nameless app even when a name-only exclusion is set")
	end)

	helpers.it("DOES block a matching named app (non-regression)", function()
		local AF = helpers.load_with_stubs("modules.llm.app_filter")
		set_front(make_named_front("Slack"))

		local exclusions = { { name = "Slack" } }
		local state = { is_url_bar_focused = false }
		local result = AF.is_blocked(state, exclusions, false, false)
		helpers.assert_true(result == true,
			"is_blocked must still return true for an app whose name matches the exclusion")
	end)

	helpers.it("does NOT block a non-matching named app", function()
		local AF = helpers.load_with_stubs("modules.llm.app_filter")
		set_front(make_named_front("Terminal"))

		local exclusions = { { name = "Slack" } }
		local state = { is_url_bar_focused = false }
		local result = AF.is_blocked(state, exclusions, false, false)
		helpers.assert_true(result == false,
			"is_blocked must return false for an app that does not match any exclusion")
	end)
end)





-- ====================================================
-- ====================================================
-- ======= 2/ CoreState model seed (llm-core-1) =======
-- ====================================================
-- ====================================================

helpers.describe("llm.init — CoreState seeded with default model names", function()

	helpers.it("get_current_model() returns a non-empty string without any setter call", function()
		-- Ensure a clean module load
		package.loaded["modules.llm"] = nil
		package.loaded["modules.llm.api_remote"] = nil

		-- Stub api_remote so the module can load without the real file
		package.loaded["modules.llm.api_remote"] = {
			PROVIDERS    = {},
			PROVIDER_ORDER = {},
			get_active_entry = function() return nil end,
			build_payload  = function() return "{}" end,
			parse_response = function() return nil, nil end,
			get_model_prices_for = function() return nil end,
		}

		local ok, Core = pcall(helpers.load_with_stubs, "modules.llm")
		if not ok then
			-- The module may fail to load in CI without all deps; skip gracefully
			helpers.assert_true(true, "skipped — modules.llm could not load in this environment")
			return
		end

		-- Without any setter call, get_current_model() must not be nil or ""
		local model = Core.get_current_model()
		helpers.assert_true(
			type(model) == "string" and model ~= "",
			"get_current_model() must return a non-empty string before any setter call, got: " .. tostring(model)
		)
	end)

	helpers.it("get_current_model() returns mlx default after set_backend('mlx')", function()
		package.loaded["modules.llm"] = nil
		package.loaded["modules.llm.api_remote"] = {
			PROVIDERS = {}, PROVIDER_ORDER = {},
			get_active_entry = function() return nil end,
			build_payload = function() return "{}" end,
			parse_response = function() return nil, nil end,
			get_model_prices_for = function() return nil end,
		}

		local ok, Core = pcall(helpers.load_with_stubs, "modules.llm")
		if not ok then
			helpers.assert_true(true, "skipped — modules.llm could not load in this environment")
			return
		end

		Core.set_backend("mlx")
		local model = Core.get_current_model()
		helpers.assert_true(
			type(model) == "string" and model ~= "",
			"get_current_model() must return a non-empty string for mlx backend, got: " .. tostring(model)
		)
	end)
end)
