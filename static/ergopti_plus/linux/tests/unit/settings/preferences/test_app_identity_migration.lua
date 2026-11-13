--- tests/unit/settings/preferences/test_app_identity_migration.lua

--- ==============================================================================
--- MODULE: Application Identity Migration Tests
--- DESCRIPTION:
--- ADD-3 (decided by the maintainer on 2026-11-11): the Linux application
--- identity is the WM class or app_id, /proc comm only as fallback. Saved
--- exclusion lists named by comm are converted once, known names only; an
--- unknown entry is kept and logged, and a refused write retries next start.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the migration over fake owners and a fake storage.
--- @param lists table path -> saved array (nil for a refused read)
--- @param opts table|nil { refuse_write = path, store = table }
--- @return table world { storage, written, done, logs }
local function migrate(lists, opts)
	opts = opts or {}
	local Migration = helpers.load_module("core.lifecycle.engine.app_identity_migration")
	local world = { written = {}, store = opts.store or {} }
	world.storage = {
		get = function(key, default) local value = world.store[key]; if value == nil then return default end return value end,
		set = function(key, value) world.store[key] = value; return true end,
	}
	local function owner(kind)
		return {
			get_list = function(path) return lists[path] end,
			get_with_status = function(path)
				if lists[path] == nil then return nil, "invalid" end
				return lists[path], "ok"
			end,
			set = function(path, value)
				if opts.refuse_write == path then return false end
				world.written[path] = value
				lists[path] = value
				return true
			end,
			kind = kind,
		}
	end
	local saved = { metrics = package.loaded["metrics.engine.preferences"], llm = package.loaded["ai.engine.preferences"] }
	package.loaded["metrics.engine.preferences"] = owner("metrics")
	package.loaded["ai.engine.preferences"] = owner("llm")
	local ok, result = pcall(Migration.run, { storage = world.storage })
	package.loaded["metrics.engine.preferences"] = saved.metrics
	package.loaded["ai.engine.preferences"] = saved.llm
	if not ok then error(result, 0) end
	world.done = result
	world.Migration = Migration
	return world
end

helpers.describe("ADD-3: saved application lists move to the WM class (add3-app-identity)", function()
	helpers.it("converts known comm names, keeps unknown entries, removes duplicates (add3-app-identity)", function()
		local Migration = helpers.load_module("core.lifecycle.engine.app_identity_migration")
		local aliases, same = Migration.load_table()
		local converted, changed, unknown = Migration.convert(
			{ "chrome", "gnome-terminal-", "firefox", "My-Tool", "google-chrome" }, aliases, same)
		helpers.assert_eq(converted, { "google-chrome", "gnome-terminal", "firefox", "My-Tool" })
		helpers.assert_true(changed)
		helpers.assert_eq(unknown, { "My-Tool", "google-chrome" },
			"an entry the table does not know is kept and reported, never dropped")
		local again, changed_again = Migration.convert(converted, aliases, same)
		helpers.assert_eq(again, converted, "the conversion is idempotent on its own output")
		helpers.assert_eq(changed_again, false)
	end)

	helpers.it("converts the three lists once and marks it (add3-app-identity)", function()
		local lists = {
			["metrics.disabled_apps"] = { "telegram-deskto", "keepassxc" },
			["llm.trigger.disabled_apps"] = { "soffice.bin" },
			["llm.agent_disabled_apps"] = { "firefox" },
		}
		local world = migrate(lists)
		helpers.assert_true(world.done)
		helpers.assert_eq(world.written["metrics.disabled_apps"], { "telegramdesktop", "keepassxc" })
		helpers.assert_eq(world.written["llm.trigger.disabled_apps"], { "libreoffice" })
		helpers.assert_eq(world.written["llm.agent_disabled_apps"], nil, "an unchanged list is not rewritten")
		helpers.assert_eq(world.store[world.Migration.MARKER_KEY], world.Migration.MARKER_VALUE)
		-- A later comm-named entry (a window without WM_CLASS) is never rewritten.
		lists["metrics.disabled_apps"] = { "chrome" }
		local second = migrate(lists, { store = world.store })
		helpers.assert_true(second.done)
		helpers.assert_eq(second.written, {}, "a marked migration never runs again")
		helpers.assert_eq(lists["metrics.disabled_apps"], { "chrome" })
	end)

	helpers.it("retries at the next start when a list cannot be written (add3-app-identity)", function()
		local lists = {
			["metrics.disabled_apps"] = { "chrome" },
			["llm.trigger.disabled_apps"] = {},
			["llm.agent_disabled_apps"] = {},
		}
		local world = migrate(lists, { refuse_write = "metrics.disabled_apps" })
		helpers.assert_eq(world.done, false)
		helpers.assert_eq(world.store[world.Migration.MARKER_KEY], nil, "no marker before every list is persisted")
	end)
end)
