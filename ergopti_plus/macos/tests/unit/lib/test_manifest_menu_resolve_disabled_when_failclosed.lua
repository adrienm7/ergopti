--- tests/unit/lib/test_manifest_menu_resolve_disabled_when_failclosed.lua

--- ==============================================================================
--- MODULE: Regression — resolve_disabled_when fails OPEN on a manifest lookup miss (F-MED-10)
--- DESCRIPTION:
--- ManifestMenu.resolve_disabled_when(menu_key, item_id, getters) returned
--- `false` (enabled) whenever `find_item_by_id` could not locate item_id in
--- menu_key's array — directly contradicting its own docstring ("A missing
--- getter... treated as disabled so the mismatch fails loud") and the sibling
--- getter-mismatch branch a few lines below, which correctly fails CLOSED
--- with a logged ERROR. A corrupted or typo'd manifest reference (or an id
--- renamed on one side only) would silently un-gate a security-sensitive item
--- — e.g. a keylogger-disabled toggle rendering as always-enabled.
---
--- Fix: a lookup miss now fails CLOSED (returns true = disabled) and logs
--- Logger.error, matching the sibling getter-mismatch branch's pattern.
---
--- This test calls resolve_disabled_when with an item_id that does not exist
--- in the (fixture) manifest array and asserts it renders disabled (true) and
--- Logger.error fires — it fails before the fix (returns false, no log) and
--- passes after.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.manifest_menu_fixture")

local MANIFEST = [[
{
	"test_menu": [
		{ "type": "dynamic", "id": "known_item", "disabled_when": ["some_flag"] }
	]
}
]]


--- Builds a logger stub that records every Logger.error call's formatted message.
--- @return table logger_stub Injectable package.loaded["infra.logger"] replacement.
--- @return table error_messages Array of formatted strings passed to Logger.error (grows live).
local function make_error_capturing_logger()
	local error_messages = {}
	local logger_stub = helpers.make_logger_stub()
	logger_stub.error = function(_module, fmt, ...)
		local ok, formatted = pcall(string.format, fmt, ...)
		error_messages[#error_messages + 1] = ok and formatted or tostring(fmt)
	end
	return logger_stub, error_messages
end

helpers.describe("ManifestMenu.resolve_disabled_when: fails CLOSED on a manifest lookup miss (F-MED-10)", function()
	helpers.it("returns true (disabled) and logs Logger.error for an item_id absent from the manifest", function()
		local logger_stub, error_messages = make_error_capturing_logger()
		fixture.with_manifest(MANIFEST, logger_stub, function(ManifestMenu)

			-- All getters truthy: if the resolver were consulting real state, every
			-- key would report "enabled" — isolates the lookup-miss code path.
			local all_true_getters = { some_flag = function() return true end }

			local disabled = ManifestMenu.resolve_disabled_when("test_menu", "does_not_exist_in_manifest", all_true_getters)

			helpers.assert_eq(disabled, true,
				"a manifest lookup miss must fail CLOSED (disabled=true), not silently render an always-enabled item (F-MED-10)")

			local logged = false
			for _, msg in ipairs(error_messages) do
				if msg:find("does_not_exist_in_manifest", 1, true) then logged = true end
			end
			helpers.assert_true(logged, "a manifest lookup miss must log Logger.error naming the missing item_id")
		end)
	end)

	helpers.it("still returns false (enabled) for a real item whose disabled_when keys are all truthy (positive control)", function()
		fixture.with_manifest(MANIFEST, nil, function(ManifestMenu)

			local all_true_getters = { some_flag = function() return true end }
			local disabled = ManifestMenu.resolve_disabled_when("test_menu", "known_item", all_true_getters)

			helpers.assert_eq(disabled, false,
				"a real item with every disabled_when getter truthy must remain enabled — the fail-closed fix must not " ..
				"regress the happy path")
		end)
	end)
end)


-- Independent provider expectations exercise the shared template and actual
-- native row materialization, without replacing the established policy owner.
local function with_group_policy_rows(platform, row, callback)
	local diagnostics, calls = {}, 0
	local logger = helpers.make_logger_stub()
	logger.error = function(_, message, ...)
		local ok, formatted = pcall(string.format, message, ...)
		diagnostics[#diagnostics + 1] = ok and formatted or message
	end
	local strings = { ["probe.group"] = "Mode: %s", ["probe.reason"] = "Unavailable： native detail" }
	local i18n = { get = function(key) return strings[key] or key end,
		section = function(key) return strings[key] or key end }
	local renderer = assert(require("menu.renderer").new({ platform = platform,
		manifest_path = function() return helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json" end,
		json_decode = function() return { group_policy_probe = { row } } end,
		i18n = i18n, logger = logger,
	}))
	local children = { { label = "Existing native child", action = function() calls = calls + 1; return false end } }
	local fixture = { renderer = renderer, diagnostics = diagnostics, children = children,
		calls = function() return calls end }
	function fixture.rows(getters)
		return renderer.template_rows("group_policy_probe", {}, getters or {}, { owned_group = children })
	end
	return callback(fixture)
end

helpers.describe("Template groups: existing readiness and reason policy (template-group-policy)", function()
	for _, platform in ipairs({ "hs", "linux", "ahk" }) do
		helpers.it("retains exact absent-policy group data and child refusal on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group" }, function(f)
				local rows = assert(f.rows())
				helpers.assert_eq(rows, { { label = "Mode: %s", items = f.children } })
				helpers.assert_true(rows[1].items == f.children, "native child payload identity is retained")
				local drawn = f.renderer.render_rows(rows, "actual_group_probe")
				helpers.assert_nil(drawn[1].disabled)
				helpers.assert_eq(drawn[1].menu[1].fn(), false)
				helpers.assert_eq(f.calls(), 1)
			end)
		end)
		helpers.it("delegates positive group readiness and literal caption to existing owners on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" }, caption_getter = "caption", disabled_reason_key = "probe.reason" }, function(f)
				local rows = assert(f.rows({ ready = function() return true end, caption = function() return "35% & $" end }))
				helpers.assert_eq(rows, { { label = "Mode: 35% & $", items = f.children } })
				local drawn = f.renderer.render_rows(rows, "actual_group_probe")
				helpers.assert_eq(drawn[1].title, "Mode: 35% & $")
				helpers.assert_nil(drawn[1].disabled)
				helpers.assert_eq(drawn[1].menu[1].fn(), false)
			end)
		end)
		for _, posture in ipairs({ { "false", false }, { "nil", nil } }) do
			helpers.it("delegates " .. posture[1] .. " group readiness and exact reason receipt on " .. platform, function()
				with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
					disabled_when = { "ready" }, caption_getter = "caption", disabled_reason_key = "probe.reason" }, function(f)
					local rows = assert(f.rows({ ready = function() return posture[2] end, caption = function() return "Incremental" end }))
					helpers.assert_eq(rows, { { label = "Mode: Incremental", items = f.children,
						disabled = true, disabled_reason_key = "probe.reason" } })
					helpers.assert_true(rows[1].items == f.children)
					local drawn = f.renderer.render_rows(rows, "actual_group_probe")
					helpers.assert_eq(drawn[1].title, "Mode: Incremental — Unavailable")
					helpers.assert_eq(drawn[1].disabled, true)
					helpers.assert_eq(f.calls(), 0, "building a disabled group cannot deliver native work")
					helpers.assert_nil(drawn[1].fn, "a group never gets a dummy actionable callback")
				end)
			end)
		end
		helpers.it("retains disabled group shape without inventing a reason on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" } }, function(f)
				local rows = assert(f.rows({ ready = function() return false end }))
				helpers.assert_eq(rows, { { label = "Mode: %s", items = f.children, disabled = true } })
				helpers.assert_eq(f.renderer.render_rows(rows, "actual_group_probe")[1].title, "Mode: %s")
			end)
		end)
		helpers.it("a missing group getter fails closed and names the missing owner on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" } }, function(f)
				helpers.assert_eq(f.rows()[1].disabled, true)
				helpers.assert_eq(#f.diagnostics, 1)
				helpers.assert_true(f.diagnostics[1]:find("ready", 1, true) ~= nil)
				helpers.assert_true(f.diagnostics[1]:find("owned_group", 1, true) ~= nil)
			end)
		end)
		helpers.it("a throwing group getter retains its actual error receipt on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" } }, function(f)
				local ok, err = pcall(f.rows, { ready = function() error("group-native-read-refused") end })
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(err):find("group-native-read-refused", 1, true) ~= nil)
				helpers.assert_eq(f.calls(), 0)
			end)
		end)
		helpers.it("uses every declared group predicate and preserves truthy resolver semantics on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "first", "second" } }, function(f)
				helpers.assert_nil(f.rows({ first = function() return "native-truthy" end, second = function() return 1 end })[1].disabled)
				helpers.assert_eq(f.rows({ first = function() return true end, second = function() return false end })[1].disabled, true)
			end)
		end)
		helpers.it("honors group platform hiding before invoking a native getter on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				platforms = { "other_platform" }, unavailable = "hide", disabled_when = { "ready" } }, function(f)
				helpers.assert_eq(f.rows({ ready = function() error("hidden native getter executed") end }), {})
			end)
		end)
		helpers.it("refuses missing group child data on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" } }, function(f)
				helpers.assert_nil(f.renderer.template_rows("group_policy_probe", {}, { ready = function() return true end }, {}))
			end)
		end)
	end
end)
