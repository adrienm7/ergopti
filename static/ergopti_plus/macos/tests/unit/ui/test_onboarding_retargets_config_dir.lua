--- tests/unit/ui/test_onboarding_retargets_config_dir.lua

--- ==============================================================================
--- MODULE: Onboarding Wizard — Config-Dir Retarget (regression)
--- DESCRIPTION:
--- Locks down that the first-run wizard re-resolves its config.toml write target
--- through MenuPaths after persisting a user-chosen config directory.
---
--- ROOT CAUSE ENCODED — A STALE CAPTURED PATH, not "the wizard shows twice":
--- _config_path was captured once in M.run() from the config dir as it stood
--- BEFORE the wizard opened. commit() then persisted the user's chosen directory
--- (rewriting paths.toml and MOVING the resolver) yet still wrote through that
--- stale capture. The NEW directory therefore never received a config.toml, so
--- should_run() was true again after the post-wizard reload and the wizard
--- re-opened BLANK — every answer lost, the orphaned file left behind in the old
--- directory where nothing reads it. Only the locale survived, because it
--- persists via hs.settings rather than config.toml, which made the failure read
--- as "the wizard forgot some things" instead of "it wrote to the wrong place".
---
--- The retarget lives in the pure M._resolve_commit_path so the decision is
--- testable without standing up a webview.
--- ==============================================================================

local helpers = require("tests.helpers")

local Onboarding = helpers.load_with_stubs("ui.onboarding")

-- The directory the wizard was launched from (the stale capture) and the one the
-- user picked mid-wizard. The retarget must land on the latter.
local OLD_CONFIG_PATH = "/old/hammerspoon/config.toml"
local NEW_CONFIG_PATH = "/new/hammerspoon/config.toml"

--- Builds a menu_paths double whose get() returns whatever the resolver yields.
--- @param resolver function Called with the requested path key.
--- @return table The menu_paths double.
local function menu_paths_double(resolver)
	return { get = resolver }
end





-- ============================================
-- ============================================
-- ======= 1/ Happy Path — The Retarget =======
-- ============================================
-- ============================================

helpers.describe("onboarding retargets config.toml after a config-dir change", function()
	helpers.it("writes to the NEWLY resolved directory, not the stale capture", function()
		local seen_key
		local resolved = Onboarding._resolve_commit_path(
			menu_paths_double(function(key)
				seen_key = key
				return NEW_CONFIG_PATH
			end),
			OLD_CONFIG_PATH
		)
		helpers.assert_eq(resolved, NEW_CONFIG_PATH,
			"the wizard must write into the directory the user just chose — writing "
			.. "through the pre-wizard capture leaves the new dir with no config.toml")
		helpers.assert_eq(seen_key, "ConfigTomlPath",
			"the retarget must go through the canonical MenuPaths key")
	end)

	helpers.it("keeps the fallback when the resolver yields the same path", function()
		local resolved = Onboarding._resolve_commit_path(
			menu_paths_double(function() return OLD_CONFIG_PATH end),
			OLD_CONFIG_PATH
		)
		helpers.assert_eq(resolved, OLD_CONFIG_PATH)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 2/ Degraded Resolver Fallbacks =======
-- ==============================================
-- ==============================================

helpers.describe("onboarding retarget falls back rather than losing the answers", function()
	helpers.it("returns the fallback verbatim when the resolver raises", function()
		local resolved = Onboarding._resolve_commit_path(
			menu_paths_double(function() error("resolver exploded") end),
			OLD_CONFIG_PATH
		)
		helpers.assert_eq(resolved, OLD_CONFIG_PATH,
			"a throwing resolver must not redirect the write — the answers still "
			.. "need a readable destination")
	end)

	helpers.it("returns the fallback verbatim when the resolver yields an empty string", function()
		local resolved = Onboarding._resolve_commit_path(
			menu_paths_double(function() return "" end),
			OLD_CONFIG_PATH
		)
		helpers.assert_eq(resolved, OLD_CONFIG_PATH,
			"an empty target would drop the answers on the floor")
	end)

	helpers.it("returns the fallback verbatim when the resolver yields a non-string", function()
		for _, bad in ipairs({ 42, true, {} }) do
			local resolved = Onboarding._resolve_commit_path(
				menu_paths_double(function() return bad end),
				OLD_CONFIG_PATH
			)
			helpers.assert_eq(resolved, OLD_CONFIG_PATH,
				"a non-string resolution is not a path — keep the fallback")
		end
		-- nil is the same class of failure and must behave identically.
		helpers.assert_eq(
			Onboarding._resolve_commit_path(menu_paths_double(function() return nil end), OLD_CONFIG_PATH),
			OLD_CONFIG_PATH)
	end)

	helpers.it("returns the fallback when menu_paths itself is unusable", function()
		helpers.assert_eq(Onboarding._resolve_commit_path(nil, OLD_CONFIG_PATH), OLD_CONFIG_PATH)
		helpers.assert_eq(Onboarding._resolve_commit_path({}, OLD_CONFIG_PATH), OLD_CONFIG_PATH)
		helpers.assert_eq(Onboarding._resolve_commit_path({ get = "not callable" }, OLD_CONFIG_PATH),
			OLD_CONFIG_PATH)
	end)
end)





-- =================================================
-- =================================================
-- ======= 3/ The Retarget Is Actually Wired =======
-- =================================================
-- =================================================

helpers.describe("onboarding commit() honours the retarget", function()
	-- The pure helper is only useful if commit() calls it. Guard the wiring at the
	-- source level: a future edit that drops the reassignment reintroduces the bug
	-- with every unit test above still green.
	helpers.it("assigns the re-resolved path before the config.toml write", function()
		-- _resolve_commit_path is unique to the onboarding module, so the scan
		-- yields exactly one file and the assign_at < write_at ordering below
		-- stays meaningful.
		local src = helpers.read_driver_source("_resolve_commit_path")
		helpers.assert_not_nil(src, "the onboarding commit source must be locatable")

		local assign_at = src:find("_config_path%s*=%s*M%._resolve_commit_path")
		helpers.assert_not_nil(assign_at,
			"commit() must reassign _config_path from M._resolve_commit_path")

		-- The write must go through _config_path. Two spellings satisfy that:
		--   toml_writer.batch_write(_config_path, …)        -- direct
		--   M._commit_write(toml_writer, _config_path, …)   -- via the extraction
		-- The call moved into M._commit_write so a write that FAILS WITHOUT RAISING
		-- can be detected (batch_write returns false, it does not throw); the path
		-- argument, and the ordering asserted below, are unchanged.
		local write_at = src:find("toml_writer%.batch_write%(_config_path")
			or src:find("_commit_write%(toml_writer,%s*_config_path")
		helpers.assert_not_nil(write_at, "commit() must write through _config_path")
		helpers.assert_true(assign_at < write_at,
			"the retarget must happen BEFORE the batch_write, or the write still "
			.. "goes to the pre-wizard directory")
	end)
end)
