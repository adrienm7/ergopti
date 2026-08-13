--- tests/meta/test_config_paths_boot_fail_fast.lua

--- ==============================================================================
--- MODULE: Root Boot Config-Path Fail-Fast Regression
--- DESCRIPTION:
--- `infra.config_paths.init()` returns false when `paths.toml` is unreadable,
--- dangling, a directory, or cannot be published. Root boot must consume that
--- exact result before it resolves the log/config directory or starts any input
--- and remap owner; otherwise the same failure silently falls through to defaults.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("root boot: config-path initialization is fail-fast", function()
	helpers.it("returns before the first config-path consumer when init does not commit", function()
		local source = helpers.read_driver_source("Path: config dir + paths.toml (config_paths.init)")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"root init.lua must remain discoverable by its config-path boot marker")
		local code = source:gsub("%-%-[^\n]*", "")
		local init_at = code:find("local config_paths_ready = config_paths.init(base_dir)", 1, true)
		local consumer_at = code:find("Logger.init_log_path(config_paths.get_config_dir()", 1, true)
		helpers.assert_true(init_at ~= nil and consumer_at ~= nil and init_at < consumer_at,
			"the exact init result must be captured before any fallback path is consumed")

		local guard = code:sub(init_at, consumer_at - 1)
		helpers.assert_true(guard:find("config_paths_ready ~= true", 1, true) ~= nil,
			"false and nil must both abort; truthiness would accept neither exact commit")
		helpers.assert_true(guard:find("Logger.error", 1, true) ~= nil,
			"a rejected path bootstrap must remain visible in the fallback boot log")
		helpers.assert_true(guard:find("return", 1, true) ~= nil,
			"boot must stop before logger, preferences, watchers, eventtaps, or Karabiner use defaults")
	end)
end)
