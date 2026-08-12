--- tests/unit/ui/menu/test_keymap_start_commit_gate.lua

--- ==============================================================================
--- MODULE: Menu Keymap Start Commit Gate
--- DESCRIPTION:
--- Proves both halves of the strict lifecycle contract: the shared gate rejects
--- nil/false/throwing starts without publishing enabled state, and every menu
--- entry point that can wake keymap-backed features routes through that gate.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fresh_gate()
	return helpers.load_with_stubs("ui.menu.keymap_lifecycle")
end

local function count_literal(source, needle)
	local count, from = 0, 1
	while true do
		local at = source:find(needle, from, true)
		if not at then return count end
		count = count + 1
		from = at + #needle
	end
end

helpers.describe("menu keymap lifecycle: strict start commitment", function()
	helpers.it("publishes enabled state only after exact true", function()
		local Gate = fresh_gate()
		local calls = 0
		local ctx = {
			state = { keymap = false },
			keymap = { start = function() calls = calls + 1; return true end },
		}
		helpers.assert_true(Gate.ensure_started(ctx, "test"))
		helpers.assert_true(ctx.state.keymap)
		helpers.assert_eq(calls, 1)
	end)

	helpers.it("rejects false, nil, throw, and a missing start without retaining stale state", function()
		local previous_notifications = package.loaded["infra.notifications"]
		local notices = 0
		package.loaded["infra.notifications"] = {
			notify = function(_title, _body, kind)
				helpers.assert_eq(kind, "error")
				notices = notices + 1
			end,
		}
		local ok, err = xpcall(function()
			local Gate = fresh_gate()
			local cases = {
				{ name = "false", start = function() return false end },
				{ name = "nil", start = function() return nil end },
				{ name = "throw", start = function() error("start failed") end },
				{ name = "missing", start = nil },
			}
			for _, case in ipairs(cases) do
				local ctx = { state = { keymap = true }, keymap = { start = case.start } }
				helpers.assert_eq(Gate.ensure_started(ctx, case.name), false,
					case.name .. " must not be accepted as lifecycle commitment")
				helpers.assert_eq(ctx.state.keymap, false,
					case.name .. " must clear a stale enabled checkmark")
			end
			helpers.assert_eq(notices, #cases,
				"every rejected click must surface a user-visible error")
		end, debug.traceback)
		package.loaded["ui.menu.keymap_lifecycle"] = nil
		package.loaded["infra.notifications"] = previous_notifications
		if not ok then error(err, 0) end
	end)

	helpers.it("routes every menu-side keymap start through the shared gate", function()
		local units = {
			{ marker = "function M.build_bulk_actions", expected = 4, label = "common hotstrings" },
			{ marker = "function M.build_custom", expected = 3, label = "custom hotstrings" },
			{ marker = "function M.schedule_pause_layout_switch", expected = 1, label = "layout menu" },
			{ marker = "function M.sync_state_to_modules", expected = 1, label = "state synchronization" },
			{ marker = "local function bind_managed_hotkey", expected = 1, label = "enable-all action" },
		}
		for _, unit in ipairs(units) do
			local source, err = helpers.read_driver_unit(unit.marker)
			helpers.assert_true(source ~= nil, unit.label .. " source must be unique: " .. tostring(err))
			helpers.assert_eq(count_literal(source, "KeymapLifecycle.ensure_started"), unit.expected,
				unit.label .. " must gate every enabling entry point")
		end

		local all_source = helpers.read_driver_source(nil) or ""
		helpers.assert_true(all_source:find("pcall(ctx.keymap.start", 1, true) == nil,
			"no ctx.keymap.start sibling may swallow its commitment")
		helpers.assert_true(all_source:find("pcall(km.start", 1, true) == nil,
			"no aliased keymap start sibling may swallow its commitment")
		helpers.assert_true(all_source:find('try("keymap.start", keymap.start)', 1, true) == nil,
			"state synchronization must not use the return-blind compatibility wrapper")
	end)

	helpers.it("fails root boot before publishing a Keymap engine started marker", function()
		local source, err = helpers.read_driver_unit("local function has_common_hotstring_groups")
		helpers.assert_true(source ~= nil, "root init.lua must be unique: " .. tostring(err))
		local call_at = source:find("local keymap_started = keymap.start()", 1, true)
		local check_at = source:find("if keymap_started ~= true then", call_at or 1, true)
		local error_at = source:find('error("keymap.start did not commit")', check_at or 1, true)
		local mark_at = source:find('Boot.mark("Keymap engine started")', call_at or 1, true)
		helpers.assert_true(call_at ~= nil and check_at ~= nil and error_at ~= nil and mark_at ~= nil)
		helpers.assert_true(call_at < check_at and check_at < error_at and error_at < mark_at,
			"boot must fail fast before claiming the typing eventtap is live")
	end)
end)
