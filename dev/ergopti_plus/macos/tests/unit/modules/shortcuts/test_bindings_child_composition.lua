--- tests/unit/modules/shortcuts/test_bindings_child_composition.lua

--- ==============================================================================
--- MODULE: Shortcut Bindings Child Composition Regression
--- DESCRIPTION:
--- Exercises the real Bindings aggregate against faithful action-owner surfaces.
--- It proves exact lifecycle results, mutation-sensitive post-state checks,
--- retained ambiguity, reverse compensation, OFF intent, and screenshot claim
--- identity across the complete start/pause/resume/stop transaction.
--- ==============================================================================

local helpers = require("tests.helpers")

local CHILD_ORDER = {"text", "apps", "mouse", "pixel", "screenshot"}
local SCREENSHOT_BINDINGS_CLAIM = "shortcut_bindings"
local SCREENSHOT_GESTURES_CLAIM = "gestures"





-- ===================================
-- ===================================
-- ======= 1/ Faithful Harness =======
-- ===================================
-- ===================================

--- Resolves one injectable exact-result mode.
--- @param mode string Result mode.
--- @param fallback boolean Faithful state-derived result.
--- @return boolean|nil result
local function resolve_mode(mode, fallback)
	if mode == "throw" then error("synthetic child boundary failure") end
	if mode == "nil" then return nil end
	if mode == "false" then return false end
	if mode == "true" then return true end
	return fallback
end

--- Records one lifecycle boundary in global observation order.
--- @param ctx table Harness context.
--- @param owner table Child state.
--- @param edge string Lifecycle edge.
local function record_edge(ctx, owner, edge)
	owner.calls[edge] = owner.calls[edge] + 1
	ctx.order[#ctx.order + 1] = owner.id .. "." .. edge
end

--- Creates one faithful non-shared child API.
--- @param ctx table Harness context.
--- @param id string Child ID.
--- @param names table Public API names.
--- @param options table|nil Initial state.
--- @return table api
--- @return table owner
local function make_child(ctx, id, names, options)
	options = options or {}
	local owner = {
		id = id,
		paused = options.paused == true,
		pending = options.pending == true,
		calls = {pause = 0, resume = 0, stop = 0},
		args = {},
		query_args = {},
		modes = {
			pause = "true",
			resume = "true",
			stop = "true",
			is_paused = "state",
			has_pending = "state",
		},
	}
	ctx.owners[id] = owner
	local api = {}

	api[names.pause] = function(parent)
		record_edge(ctx, owner, "pause")
		owner.args[#owner.args + 1] = { edge = "pause", parent = parent }
		owner.paused = true
		owner.pending = false
		return resolve_mode(owner.modes.pause, true)
	end
	api[names.resume] = function(parent)
		record_edge(ctx, owner, "resume")
		owner.args[#owner.args + 1] = { edge = "resume", parent = parent }
		owner.paused = false
		owner.pending = false
		return resolve_mode(owner.modes.resume, true)
	end
	api[names.stop] = function(parent)
		record_edge(ctx, owner, "stop")
		owner.args[#owner.args + 1] = { edge = "stop", parent = parent }
		owner.paused = true
		owner.pending = false
		return resolve_mode(owner.modes.stop, true)
	end
	api[names.is_paused] = function(parent)
		owner.query_args[#owner.query_args + 1] = { edge = "paused", parent = parent }
		return resolve_mode(owner.modes.is_paused, owner.paused)
	end
	api[names.has_pending] = function(parent)
		owner.query_args[#owner.query_args + 1] = { edge = "pending", parent = parent }
		return resolve_mode(owner.modes.has_pending, owner.pending)
	end
	return api, owner
end

--- Creates the shared ScreenshotSave claim surface exposed by system.lua.
--- @param ctx table Harness context.
--- @param options table|nil Initial state.
--- @return table api
--- @return table owner
local function make_screenshot_child(ctx, options)
	options = options or {}
	local claims = {}
	if options.gestures_claim == true then claims[SCREENSHOT_GESTURES_CLAIM] = true end
	if options.bindings_claim == true then claims[SCREENSHOT_BINDINGS_CLAIM] = true end
	local owner = {
		id = "screenshot",
		claims = claims,
		pending = options.pending == true,
		calls = {pause = 0, resume = 0, stop = 0},
		args = {},
		query_args = {},
		modes = {
			pause = "true",
			resume = "true",
			stop = "true",
			is_paused = "state",
			has_pending = "state",
		},
	}
	ctx.owners.screenshot = owner

	local function record_claim(edge, parent)
		record_edge(ctx, owner, edge)
		owner.args[#owner.args + 1] = {edge = edge, parent = parent}
	end

	local api = {}
	api.pause_screenshot_actions = function(parent)
		record_claim("pause", parent)
		owner.claims[parent] = true
		owner.pending = false
		return resolve_mode(owner.modes.pause, true)
	end
	api.resume_screenshot_actions = function(parent)
		record_claim("resume", parent)
		owner.claims[parent] = nil
		owner.pending = false
		return resolve_mode(owner.modes.resume, true)
	end
	api.stop_screenshot_actions = function(parent)
		record_claim("stop", parent)
		owner.claims[parent] = true
		owner.pending = false
		return resolve_mode(owner.modes.stop, true)
	end
	api.has_screenshot_pause_claim = function(parent)
		owner.query_args[#owner.query_args + 1] = parent
		return resolve_mode(owner.modes.is_paused, owner.claims[parent] == true)
	end
	api.has_pending_screenshot_action = function(parent)
		owner.query_args[#owner.query_args + 1] = parent
		return resolve_mode(owner.modes.has_pending, owner.pending)
	end
	return api, owner
end

--- Adds inert user-action and exact keep-awake APIs to the system facade.
--- @param ctx table Harness context.
--- @param system table System lifecycle facade.
local function complete_system_facade(ctx, system, options)
	options = options or {}
	local function handle(id, admission_guard)
		ctx.hotkey_creations = ctx.hotkey_creations + 1
		local owner = { id = id, delete_calls = 0 }
		owner.delete = function()
				owner.delete_calls = owner.delete_calls + 1
				ctx.hotkey_deletions = ctx.hotkey_deletions + 1
				local mode = options.raw_release_modes
					and options.raw_release_modes[id] or "true"
				if mode == "false" then return false end
				if mode == "nil" then return nil end
				if mode == "throw" then error("synthetic raw release refusal") end
				return true
			end
		ctx.raw_handles[id] = owner
		owner.callback = function()
			local admitted = type(admission_guard) == "function" and admission_guard() == true
			if admitted then ctx.raw_side_effects = ctx.raw_side_effects + 1 end
			return admitted
		end
		if options.reenter_raw_factory == id and options.raw_reentered ~= true then
			options.raw_reentered = true
			ctx.reentrant_pause_result = ctx.pause_hook()
			ctx.reentrant_callback_result = owner.callback()
		end
		return owner
	end
	for method, id in pairs({
		bind_instant_screenshot = "at_hash",
		bind_layer_scroll = "layer_scroll",
		bind_wrap_text_if_selected = "wrap_text_if_selected",
		bind_cmd_star = "cmd_star",
	}) do
		system[method] = function(...)
			local args = {...}
			return handle(id, args[#args])
		end
	end
	for _, name in ipairs({
		"toggle_awake",
		"interactive_screenshot",
		"toggle_display_mirror",
		"copy_pixel_color",
		"toggle_capslock",
		"lock_screen",
		"open_emoji_picker",
		"spotlight_mouse",
		"teleport_mouse",
	}) do
		system[name] = function() return true end
	end
	system.pause_awake = function() return true end
	system.resume_awake = function() return true end
	system.stop_awake = function() return true end
end

--- Adds inert action callbacks required by the declarative hotkey registry.
--- @param text table Text child facade.
--- @param apps table Apps child facade.
local function complete_action_facades(text, apps)
	for _, name in ipairs({
		"select_line",
		"surround_with_parens",
		"toggle_uppercase",
		"toggle_titlecase",
		"paste_as_plain_text",
	}) do
		text[name] = function() return true end
	end
	for _, name in ipairs({
		"open_downloads",
		"open_finder",
		"open_chatgpt",
		"open_settings",
		"copy_or_open_path",
	}) do
		apps[name] = function() return true end
	end
end

--- Loads real Bindings against exact child APIs and isolated module state.
--- @param options table|nil Harness options.
--- @return table subject Real Bindings module.
--- @return table ctx Mutable observations.
local function load_subject(options)
	options = options or {}
	local ctx = {
		order = {},
		owners = {},
		hotkey_creations = 0,
		hotkey_deletions = 0,
		raw_handles = {},
		raw_side_effects = 0,
	}
	local text = make_child(ctx, "text", {
		pause = "pause_text_actions",
		resume = "resume_text_actions",
		stop = "stop_text_actions",
		is_paused = "is_text_actions_paused",
		has_pending = "has_pending_text_action",
	}, options.text)
	local apps = make_child(ctx, "apps", {
		pause = "pause_apps_actions",
		resume = "resume_apps_actions",
		stop = "stop_apps_actions",
		is_paused = "is_apps_actions_paused",
		has_pending = "has_pending_apps_action",
	}, options.apps)
	local mouse = make_child(ctx, "mouse", {
		pause = "pause_mouse_actions",
		resume = "resume_mouse_actions",
		stop = "stop_mouse_actions",
		is_paused = "is_mouse_actions_paused",
		has_pending = "has_pending_mouse_action",
	}, options.mouse)
	local pixel = make_child(ctx, "pixel", {
		pause = "pause_pixel_actions",
		resume = "resume_pixel_actions",
		stop = "stop_pixel_actions",
		is_paused = "is_pixel_actions_paused",
		has_pending = "has_pending_pixel_action",
	}, options.pixel)
	local screenshot = make_screenshot_child(ctx, options.screenshot)

	local system = {}
	for name, fn in pairs(mouse) do system[name] = fn end
	for name, fn in pairs(pixel) do system[name] = fn end
	for name, fn in pairs(screenshot) do system[name] = fn end
	complete_system_facade(ctx, system, options)
	complete_action_facades(text, apps)

	return helpers.with_fresh_modules({
		"modules.shortcuts.bindings",
		"modules.shortcuts.actions.text",
		"modules.shortcuts.actions.apps",
		"modules.shortcuts.actions.system",
		"infra.i18n",
		"infra.logger",
	}, function()
		package.loaded["modules.shortcuts.actions.text"] = text
		package.loaded["modules.shortcuts.actions.apps"] = apps
		package.loaded["modules.shortcuts.actions.system"] = system
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local subject = helpers.load_with_stubs("modules.shortcuts.bindings", {
			hotkey = {
				bind = function()
					ctx.hotkey_creations = ctx.hotkey_creations + 1
					return {
						delete = function()
							ctx.hotkey_deletions = ctx.hotkey_deletions + 1
							return true
						end,
					}
				end,
			},
		})
		return subject, ctx
	end)
end

--- Returns one child lifecycle edge in observed order.
--- @param ctx table Harness context.
--- @param edge string Lifecycle edge.
--- @return table ids
local function edge_order(ctx, edge)
	local ids = {}
	local suffix = "." .. edge
	for _, entry in ipairs(ctx.order) do
		if entry:sub(-#suffix) == suffix then
			ids[#ids + 1] = entry:sub(1, #entry - #suffix)
		end
	end
	return ids
end

--- Asserts an exact ordered ID array.
--- @param actual table Actual IDs.
--- @param expected table Expected IDs.
--- @param message string Failure context.
local function assert_order(actual, expected, message)
	helpers.assert_eq(#actual, #expected, message .. " count")
	for index, id in ipairs(expected) do
		helpers.assert_eq(actual[index], id, message .. " at index " .. tostring(index))
	end
end





-- =====================================
-- =====================================
-- ======= 2/ Complete Lifecycle =======
-- =====================================
-- =====================================

helpers.describe("shortcut bindings: exact child-owner composition", function()
	helpers.it("owns every child in deterministic order across the complete cycle", function()
		local subject, ctx = load_subject()
		helpers.assert_eq(subject.start(), true)
		helpers.assert_eq(subject.pause(), true)
		assert_order(edge_order(ctx, "pause"), CHILD_ORDER, "pause order")
		for _, id in ipairs(CHILD_ORDER) do
			helpers.assert_eq(ctx.owners[id].calls.pause, 1, id .. " must pause once")
		end

		ctx.order = {}
		helpers.assert_eq(subject.resume_after_pause(), true)
		assert_order(edge_order(ctx, "resume"), CHILD_ORDER, "resume order")
		local resume_counts = {}
		for _, id in ipairs(CHILD_ORDER) do
			resume_counts[id] = ctx.owners[id].calls.resume
		end
		helpers.assert_eq(subject.resume_after_pause(), true)
		for _, id in ipairs(CHILD_ORDER) do
			helpers.assert_eq(ctx.owners[id].calls.resume, resume_counts[id],
				"duplicate RESUME must not re-enter " .. id)
		end

		ctx.order = {}
		helpers.assert_eq(subject.stop(), true)
		assert_order(edge_order(ctx, "stop"), CHILD_ORDER, "stop order")
		helpers.assert_eq(subject.is_started(), false)
		helpers.assert_eq(subject.has_pause_debt(), false)

		ctx.order = {}
		helpers.assert_eq(subject.start(), true)
		assert_order(edge_order(ctx, "resume"), CHILD_ORDER, "restart order")
	end)
end)





-- ========================================
-- ========================================
-- ======= 3/ Refusal and Ambiguity =======
-- ========================================
-- ========================================

helpers.describe("shortcut bindings: exact refusal matrix", function()
	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("retains " .. mode .. " pause debt without short-circuiting siblings", function()
			local subject, ctx = load_subject()
			helpers.assert_eq(subject.start(), true)
			ctx.owners.apps.modes.pause = mode
			helpers.assert_eq(subject.pause(), false)
			assert_order(edge_order(ctx, "pause"), CHILD_ORDER, "refused pause order")
			for _, id in ipairs(CHILD_ORDER) do
				helpers.assert_eq(ctx.owners[id].calls.pause, 1,
					id .. " pause must run after a sibling refusal")
			end
			helpers.assert_eq(subject.has_pause_debt(), true,
				"a non-literal pause result must remain aggregate debt")
			ctx.owners.apps.modes.pause = "true"
			helpers.assert_eq(subject.pause(), true)
			helpers.assert_eq(subject.has_pause_debt(), false)
		end)

		helpers.it("retains " .. mode .. " stop debt without short-circuiting siblings", function()
			local subject, ctx = load_subject()
			helpers.assert_eq(subject.start(), true)
			ctx.owners.mouse.modes.stop = mode
			helpers.assert_eq(subject.stop(), false)
			assert_order(edge_order(ctx, "stop"), CHILD_ORDER, "refused stop order")
			for _, id in ipairs(CHILD_ORDER) do
				helpers.assert_eq(ctx.owners[id].calls.stop, 1,
					id .. " stop must run after a sibling refusal")
			end
			helpers.assert_eq(subject.has_pause_debt(), true)
			ctx.owners.mouse.modes.stop = "true"
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(subject.has_pause_debt(), false)
		end)

		helpers.it("compensates a " .. mode .. " mutate-then-refuse resume", function()
			local subject, ctx = load_subject()
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.pause(), true)
			ctx.order = {}
			ctx.owners.mouse.modes.resume = mode
			helpers.assert_eq(subject.resume_after_pause(), false)
			helpers.assert_eq(subject.is_started(), false)
			assert_order(edge_order(ctx, "resume"), {"text", "apps", "mouse"},
				"partial resume order")
			assert_order(edge_order(ctx, "pause"), {"mouse", "apps", "text"},
				"reverse compensation order")
			for _, id in ipairs(CHILD_ORDER) do
				if id == "screenshot" then
					helpers.assert_eq(
						ctx.owners.screenshot.claims[SCREENSHOT_BINDINGS_CLAIM], true,
						"screenshot must retain the untouched Bindings claim")
				else
					helpers.assert_eq(ctx.owners[id].paused, true,
						id .. " must remain fenced after partial resume")
				end
			end
			helpers.assert_eq(ctx.owners.mouse.calls.pause, 2,
				"the mutate-then-refuse child itself must be compensated")
			ctx.owners.mouse.modes.resume = "true"
			helpers.assert_eq(subject.resume_after_pause(), true,
				"the exact compensated transition must remain retryable")
		end)
	end

	for _, mode in ipairs({"nil", "throw"}) do
		helpers.it("fails start closed on a " .. mode .. " paused-state query", function()
			local subject, ctx = load_subject()
			ctx.owners.apps.modes.is_paused = mode
			helpers.assert_eq(subject.start(), false)
			helpers.assert_eq(subject.is_started(), false)
			helpers.assert_eq(ctx.hotkey_creations, 0)
			for _, id in ipairs(CHILD_ORDER) do
				helpers.assert_eq(ctx.owners[id].calls.resume, 0,
					"ambiguous preflight may not reopen " .. id)
			end
			helpers.assert_eq(subject.has_pause_debt(), true)
		end)

		helpers.it("fails pause closed on a " .. mode .. " pending query", function()
			local subject, ctx = load_subject()
			helpers.assert_eq(subject.start(), true)
			ctx.owners.pixel.modes.has_pending = mode
			helpers.assert_eq(subject.pause(), false)
			assert_order(edge_order(ctx, "pause"), CHILD_ORDER,
				"ambiguous post-query pause order")
			helpers.assert_eq(subject.has_pause_debt(), true)
			ctx.owners.pixel.modes.has_pending = "state"
			helpers.assert_eq(subject.pause(), true)
		end)
	end

	helpers.it("rejects a false paused-state post-query after an exact pause", function()
		local subject, ctx = load_subject()
		helpers.assert_eq(subject.start(), true)
		ctx.owners.text.modes.is_paused = "false"
		helpers.assert_eq(subject.pause(), false,
			"a true lifecycle return cannot outrank contradictory state")
		helpers.assert_eq(subject.has_pause_debt(), true)
		ctx.owners.text.modes.is_paused = "state"
		helpers.assert_eq(subject.pause(), true)
	end)

	helpers.it("accepts literal false as the exact no-pending query result", function()
		local subject, ctx = load_subject()
		helpers.assert_eq(subject.start(), true)
		for _, id in ipairs(CHILD_ORDER) do
			ctx.owners[id].modes.has_pending = "false"
		end
		helpers.assert_eq(subject.pause(), true)
		helpers.assert_eq(subject.has_pause_debt(), false)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 4/ OFF Intent and Shared Claim =======
-- ==============================================
-- ==============================================

helpers.describe("shortcut bindings: OFF intent and screenshot claim identity", function()
	helpers.it("settles OFF cleanup debt without inventing an ON resume", function()
		local subject, ctx = load_subject({apps = {pending = true}})
		helpers.assert_eq(subject.is_started(), false)
		helpers.assert_eq(subject.has_pause_debt(), true)
		helpers.assert_eq(subject.pause(), true)
		helpers.assert_eq(subject.is_started(), false)
		helpers.assert_eq(ctx.hotkey_creations, 0)
		local resume_before = {}
		for _, id in ipairs(CHILD_ORDER) do
			resume_before[id] = ctx.owners[id].calls.resume
		end
		helpers.assert_eq(subject.resume_after_pause(), true)
		helpers.assert_eq(subject.is_started(), false,
			"cleanup-only RESUME may not resurrect an OFF bindings layer")
		helpers.assert_eq(ctx.hotkey_creations, 0)
		for _, id in ipairs(CHILD_ORDER) do
			helpers.assert_eq(ctx.owners[id].calls.resume, resume_before[id],
				"cleanup-only RESUME may not reopen " .. id)
		end
	end)

	helpers.it("owns only shortcut_bindings while preserving the gestures claim", function()
		local subject, ctx = load_subject({
			screenshot = {gestures_claim = true},
		})
		local screenshot = ctx.owners.screenshot
		helpers.assert_eq(subject.start(), true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_GESTURES_CLAIM], true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_BINDINGS_CLAIM], nil)

		helpers.assert_eq(subject.pause(), true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_GESTURES_CLAIM], true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_BINDINGS_CLAIM], true)
		helpers.assert_eq(subject.resume_after_pause(), true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_GESTURES_CLAIM], true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_BINDINGS_CLAIM], nil)

		helpers.assert_eq(subject.stop(), true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_GESTURES_CLAIM], true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_BINDINGS_CLAIM], true)
		helpers.assert_eq(subject.start(), true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_GESTURES_CLAIM], true)
		helpers.assert_eq(screenshot.claims[SCREENSHOT_BINDINGS_CLAIM], nil)
		for _, call in ipairs(screenshot.args) do
			helpers.assert_eq(call.parent, SCREENSHOT_BINDINGS_CLAIM,
				"Bindings may never release or forge another parent's claim")
		end
		for _, parent in ipairs(screenshot.query_args) do
			helpers.assert_eq(parent, SCREENSHOT_BINDINGS_CLAIM,
				"Bindings may never inspect another parent's claim as its own")
		end
	end)

	helpers.it("passes shortcut ownership only to the shared Text and Mouse children", function()
		local subject, ctx = load_subject()
		helpers.assert_eq(subject.start(), true)
		helpers.assert_eq(subject.pause(), true)
		helpers.assert_eq(subject.resume_after_pause(), true)
		helpers.assert_eq(subject.stop(), true)
		for _, id in ipairs({ "text", "mouse" }) do
			local owner = ctx.owners[id]
			helpers.assert_true(#owner.args > 0 and #owner.query_args > 0)
			for _, call in ipairs(owner.args) do
				helpers.assert_eq(call.parent, SCREENSHOT_BINDINGS_CLAIM,
					id .. " lifecycle must carry shortcut_bindings")
			end
			for _, call in ipairs(owner.query_args) do
				helpers.assert_eq(call.parent, SCREENSHOT_BINDINGS_CLAIM,
					id .. " queries must carry shortcut_bindings")
			end
		end
		for _, id in ipairs({ "apps", "pixel" }) do
			local owner = ctx.owners[id]
			helpers.assert_true(#owner.args > 0 and #owner.query_args > 0)
			for _, call in ipairs(owner.args) do
				helpers.assert_eq(call.parent, nil,
					id .. " remains an exclusive Bindings child")
			end
			for _, call in ipairs(owner.query_args) do
				helpers.assert_eq(call.parent, nil,
					id .. " exclusive queries must not forge a parent")
			end
		end
	end)
end)

helpers.describe("shortcut bindings: raw owner release identity", function()
	for _, id in ipairs({
		"at_hash", "layer_scroll", "cmd_star", "wrap_text_if_selected",
	}) do
		helpers.it("fences a raw " .. id .. " callback when its factory reenters pause", function()
			local options = { reenter_raw_factory = id }
			local subject, ctx = load_subject(options)
			ctx.pause_hook = subject.pause
			helpers.assert_eq(subject.start(), false)
			helpers.assert_eq(ctx.reentrant_pause_result, false,
				"PAUSE cannot certify settlement while a native factory is in flight")
			helpers.assert_eq(ctx.reentrant_callback_result, false,
				"a candidate callback must read the local admission fence")
			helpers.assert_eq(ctx.raw_side_effects, 0)
			helpers.assert_eq(ctx.raw_handles[id].delete_calls, 1,
				"the outer attempt must retire the exact hidden factory candidate")
			helpers.assert_eq(subject.is_started(), false)
			helpers.assert_eq(subject.pause(), true)
	end)
	end

	for _, id in ipairs({
		"at_hash", "layer_scroll", "cmd_star", "wrap_text_if_selected",
	}) do
		helpers.it("fences a raw " .. id .. " enable factory that reenters pause", function()
			local options = {}
			local subject, ctx = load_subject(options)
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.disable(id), true)
			options.reenter_raw_factory = id
			options.raw_reentered = false
			ctx.pause_hook = subject.pause
			helpers.assert_eq(subject.enable(id), false)
			helpers.assert_eq(ctx.reentrant_pause_result, false)
			helpers.assert_eq(ctx.reentrant_callback_result, false)
			helpers.assert_eq(ctx.raw_handles[id].delete_calls, 1)
			helpers.assert_eq(subject.is_enabled(id), false)
			helpers.assert_eq(subject.pause(), true)
		end)
	end

	for _, id in ipairs({
		"at_hash", "layer_scroll", "cmd_star", "wrap_text_if_selected",
	}) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains " .. id .. " on pause delete " .. mode, function()
				local options = { raw_release_modes = { [id] = mode } }
				local subject, ctx = load_subject(options)
				helpers.assert_eq(subject.start(), true)
				local exact_handle = ctx.raw_handles[id]
				helpers.assert_eq(subject.pause(), false)
				helpers.assert_true(ctx.raw_handles[id] == exact_handle)
				helpers.assert_eq(exact_handle.delete_calls, 1)
				options.raw_release_modes[id] = "true"
				helpers.assert_eq(subject.pause(), true,
					"pause retry must settle the retained raw handle")
				helpers.assert_eq(exact_handle.delete_calls, 2)
			end)

			helpers.it("retains " .. id .. " on direct disable delete " .. mode, function()
				local options = { raw_release_modes = { [id] = mode } }
				local subject, ctx = load_subject(options)
				helpers.assert_eq(subject.start(), true)
				local exact_handle = ctx.raw_handles[id]
				helpers.assert_eq(subject.disable(id), false)
				helpers.assert_eq(subject.is_enabled(id), true,
					"an ambiguous raw release must retain the exact owner")
				helpers.assert_eq(exact_handle.delete_calls, 1)
				options.raw_release_modes[id] = "true"
				helpers.assert_eq(subject.disable(id), true)
				helpers.assert_eq(exact_handle.delete_calls, 2)
				helpers.assert_eq(subject.is_enabled(id), false)
			end)
		end
	end
end)

return true
