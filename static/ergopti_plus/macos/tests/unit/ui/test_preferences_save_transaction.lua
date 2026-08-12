--- tests/unit/ui/test_preferences_save_transaction.lua

--- ==============================================================================
--- MODULE: Preferences Save Transaction Regression
--- DESCRIPTION:
--- Proves that Preferences.save reports exact publication success and that the
--- menu invalidates caches only after that success. Returned/raised adapter
--- failures must remain false and preserve the caller's success-only effects.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_preferences(file_system)
	package.loaded["adapters.file_system"] = file_system
	package.loaded["infra.preferences"] = nil
	return require("infra.preferences")
end

local function minimal_save(preferences)
	return preferences.save("/virtual/config.toml", {}, {}, {})
end

helpers.describe("Preferences.save: exact atomic publication result", function()
	helpers.it("returns false when the atomic writer returns false", function()
		local calls = 0
		local preferences = load_preferences({
			write = function(path, content)
				calls = calls + 1
				helpers.assert_eq(path, "/virtual/config.toml")
				helpers.assert_type(content, "string")
				return false
			end,
		})
		helpers.assert_eq(minimal_save(preferences), false,
			"a returned write failure must never look like a successful preference save")
		helpers.assert_eq(calls, 1)
	end)

	helpers.it("contains a raised writer failure and returns false", function()
		local preferences = load_preferences({
			write = function() error("disk failure", 0) end,
		})
		local call_ok, committed = pcall(minimal_save, preferences)
		helpers.assert_true(call_ok, "an adapter error must not escape a user action callback")
		helpers.assert_eq(committed, false)
	end)

	helpers.it("returns true only after the writer confirms publication", function()
		local preferences = load_preferences({ write = function() return true end })
		helpers.assert_eq(minimal_save(preferences), true)
	end)
end)

helpers.describe("menu preference side effects are success-gated", function()
	local transaction = require("ui.menu.preferences_transaction")

	helpers.it("leaves every cache untouched on false, nil, or raise", function()
		for _, save in ipairs({
			function() return false end,
			function() return nil end,
			function() error("save raised", 0) end,
		}) do
			local effects = 0
			local committed = transaction.commit(
				{ save = save },
				"/virtual/config.toml",
				{},
				{},
				{},
				{ invalidate_cache = function() effects = effects + 1 end },
				{ invalidate_cache = function() effects = effects + 1 end },
				function() effects = effects + 1 end
			)
			helpers.assert_eq(committed, false)
			helpers.assert_eq(effects, 0,
				"cache invalidation and dirty publication must require exact save success")
		end
	end)

	helpers.it("runs each success-only effect once after a confirmed save", function()
		local effects = 0
		local committed = transaction.commit(
			{ save = function() return true end },
			"/virtual/config.toml",
			{},
			{},
			{},
			{ invalidate_cache = function() effects = effects + 1 end },
			{ invalidate_cache = function() effects = effects + 1 end },
			function() effects = effects + 1 end
		)
		helpers.assert_eq(committed, true)
		helpers.assert_eq(effects, 3)
	end)
end)

-- Do not leak the final FileSystem double into later test modules in the same
-- Lua process; those modules intentionally exercise the real atomic adapter.
package.loaded["adapters.file_system"] = nil
package.loaded["infra.preferences"] = nil

return true
