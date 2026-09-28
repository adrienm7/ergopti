--- tests/support/shortcut_bindings_fixture.lua

--- ==============================================================================
--- MODULE: Shortcut Bindings Preference Fixture
--- DESCRIPTION:
--- Loads the real Bindings registry over stateful action-owner doubles and a
--- counting native hotkey double. Preference and native binding stay separately
--- observable across start, pause, resume and stop, so a consumer that confuses
--- "the user wants this shortcut" with "this shortcut is bound right now" fails.
---
--- FEATURES & RATIONALE:
--- 1. Faithful Children: Every child lifecycle edge flips an observable paused
---    flag and answers the exact query contract Bindings settles against.
--- 2. Native Accounting: Every factory and hs.hotkey.bind candidate is counted
---    live until its exact delete, so a leaked binding behind a pause is visible.
--- 3. Scoped Cache: The subject and every injected dependency are restored when
---    the scenario returns, so suite order cannot leak registry state.
--- 4. Visible Errors: ERROR lines are recorded, because a preference edit that
---    "works" while logging an ERROR would raise the user-facing error dialog.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}

--- Selects explicit shortcut intent before a lifecycle test acquires handles.
--- @param bindings table Fresh real bindings owner.
function M.prefer_all(bindings)
	helpers.assert_eq(bindings.pause_hotkeys_only(), true)
	local count = 0
	for _, entry in ipairs(bindings.list_shortcuts()) do
		helpers.assert_eq(bindings.enable(entry.id), true)
		helpers.assert_eq(bindings.is_bound(entry.id), false)
		count = count + 1
	end
	helpers.assert_true(count > 0, "explicit preferences require a real registry")
	helpers.assert_eq(bindings.release_pause_admission(), true)
end

--- Runs a configured-user lifecycle scenario with every shortcut selected.
--- @param callback function Scenario receiving the owner and observations.
function M.with_recommended_bindings(callback)
	return M.with_bindings(function(bindings, ctx)
		M.prefer_all(bindings)
		return callback(bindings, ctx)
	end)
end

local CHILD_APIS = {
	{
		facade = "text", pause = "pause_text_actions", resume = "resume_text_actions",
		stop = "stop_text_actions", is_paused = "is_text_actions_paused",
		has_pending = "has_pending_text_action",
	},
	{
		facade = "apps", pause = "pause_apps_actions", resume = "resume_apps_actions",
		stop = "stop_apps_actions", is_paused = "is_apps_actions_paused",
		has_pending = "has_pending_apps_action",
	},
	{
		facade = "system", pause = "pause_mouse_actions", resume = "resume_mouse_actions",
		stop = "stop_mouse_actions", is_paused = "is_mouse_actions_paused",
		has_pending = "has_pending_mouse_action",
	},
	{
		facade = "system", pause = "pause_pixel_actions", resume = "resume_pixel_actions",
		stop = "stop_pixel_actions", is_paused = "is_pixel_actions_paused",
		has_pending = "has_pending_pixel_action",
	},
}

-- Raw factories Bindings calls instead of hs.hotkey.bind, keyed by shortcut id.
local RAW_FACTORIES = {
	bind_instant_screenshot = "at_hash",
	bind_layer_scroll = "layer_scroll",
	bind_wrap_text_if_selected = "wrap_text_if_selected",
	bind_cmd_star = "cmd_star",
	bind_tap_keys = "tap_keys",
}

local INERT_ACTIONS = {
	text = {
		"select_line", "surround_with_parens", "toggle_uppercase",
		"toggle_titlecase", "paste_as_plain_text",
	},
	apps = {
		"open_downloads", "open_finder", "open_chatgpt", "open_settings",
		"copy_or_open_path",
	},
	system = {
		"toggle_awake", "interactive_screenshot", "toggle_display_mirror",
		"copy_pixel_color", "toggle_capslock", "lock_screen", "open_emoji_picker",
		"spotlight_mouse", "teleport_mouse",
	},
}

--- Creates one exact native handle and records it as live until deleted.
--- @param ctx table Fixture observations.
--- @param id string Shortcut identifier or bound chord.
--- @return table handle
local function native_handle(ctx, id)
	local handle = { id = id }
	ctx.created = ctx.created + 1
	ctx.live[handle] = true
	handle.delete = function()
		ctx.live[handle] = nil
		return true
	end
	return handle
end

--- Builds the text, apps and system facades Bindings composes.
--- @param ctx table Fixture observations.
--- @return table facades Keyed by facade name.
local function build_facades(ctx)
	local facades = { text = {}, apps = {}, system = {} }
	for index, api in ipairs(CHILD_APIS) do
		local owner = { paused = false }
		ctx.children[index] = owner
		local facade = facades[api.facade]
		facade[api.pause] = function() owner.paused = true; return true end
		facade[api.resume] = function() owner.paused = false; return true end
		facade[api.stop] = function() owner.paused = true; return true end
		facade[api.is_paused] = function() return owner.paused end
		facade[api.has_pending] = function() return false end
	end

	-- ScreenshotSave is claim-based and shared with gestures, not a flag.
	local claims = {}
	facades.system.pause_screenshot_actions = function(parent) claims[parent] = true; return true end
	facades.system.resume_screenshot_actions = function(parent) claims[parent] = nil; return true end
	facades.system.stop_screenshot_actions = function(parent) claims[parent] = true; return true end
	facades.system.has_screenshot_pause_claim = function(parent) return claims[parent] == true end
	facades.system.has_pending_screenshot_action = function() return false end

	facades.system.pause_awake = function() return true end
	facades.system.resume_awake = function() return true end
	facades.system.stop_awake = function() return true end

	for method, id in pairs(RAW_FACTORIES) do
		facades.system[method] = function()
			if ctx.refuse[id] == true then return nil end
			return native_handle(ctx, id)
		end
	end
	for facade_name, names in pairs(INERT_ACTIONS) do
		for _, name in ipairs(names) do
			facades[facade_name][name] = function() return true end
		end
	end
	return facades
end

--- Runs one scenario against a freshly loaded real Bindings registry.
--- @param callback function Receives (bindings, ctx).
--- @return ... Callback results.
function M.with_bindings(callback)
	assert(type(callback) == "function", "bindings fixture callback must be a function")
	local ctx = { created = 0, live = {}, children = {}, refuse = {}, errors = {} }
	return helpers.with_stub_scope({
		"modules.shortcuts.bindings",
		"modules.shortcuts.actions.text",
		"modules.shortcuts.actions.apps",
		"modules.shortcuts.actions.system",
		"modules.shortcuts.tap_keys",
		"modules.gestures.actions",
		"infra.i18n",
		"infra.logger",
	}, function()
		local facades = build_facades(ctx)
		package.loaded["modules.shortcuts.actions.text"] = facades.text
		package.loaded["modules.shortcuts.actions.apps"] = facades.apps
		package.loaded["modules.shortcuts.actions.system"] = facades.system
		package.loaded["modules.shortcuts.tap_keys"] = {
			ensure_loaded = function() return true end,
			decide = function() return nil end,
		}
		-- The unassigned tap-key fixture still initializes through this owner;
		-- loading the real action catalogue would escape the native boundary.
		package.loaded["modules.gestures.actions"] = { is_assignable = function() return false end }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...)
			ctx.errors[#ctx.errors + 1] = string.format(message, ...)
		end
		package.loaded["infra.logger"] = logger
		local bindings = helpers.load_with_stubs("modules.shortcuts.bindings", {
			hotkey = {
				bind = function(mods, key)
					return native_handle(ctx, table.concat(mods, "+") .. "+" .. key)
				end,
			},
		})
		return callback(bindings, ctx)
	end)
end

--- Counts the native handles that are still owned.
--- @param ctx table Fixture observations.
--- @return integer count
function M.live_count(ctx)
	local count = 0
	for _ in pairs(ctx.live) do count = count + 1 end
	return count
end

--- Indexes list_shortcuts() by id and asserts it is not empty.
--- @param bindings table Real Bindings module.
--- @return table by_id Entry per shortcut id.
--- @return integer count Number of listed shortcuts.
function M.index(bindings)
	local by_id, count = {}, 0
	for _, entry in ipairs(bindings.list_shortcuts()) do
		by_id[entry.id] = entry
		count = count + 1
	end
	helpers.assert_true(count > 0, "the registry must list shortcuts, or every assertion is vacuous")
	return by_id, count
end

return M
