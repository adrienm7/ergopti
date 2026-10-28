--- tests/unit/modules/shortcuts/keyboard/test_deferred_action_configuration_owner.lua

--- ==============================================================================
--- MODULE: Deferred Shortcut Actions Keep Their Configuration Owner
--- DESCRIPTION:
--- A logging sink or admission callback can synchronously reserve, replace or
--- pause the original binding. A queued callback cannot revive that old intent.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox

--- Runs an actual owner over a private TOML file and acknowledged manual queue.
--- @param domain string Tap key or script-control chord.
--- @param body function body(context)
local function with_owner(domain, body)
	local module_name = domain == "tap" and "modules.shortcuts.tap_keys" or "modules.shortcuts.script_chords"
	local names = { "infra.config_paths", "modules.gestures.manager", "logger.shim", module_name }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local source = '[shortcuts.tap_keys]\nnumber_row_left = "screen_capture"\n'
		.. '[shortcuts.script_control]\nchords_enabled = true\nscript_altgr_enter = "screen_capture"\n'
	local called, failure = pcall(function()
		Sandbox.with_config(source, function(path)
			local ctx = { deferred = {}, executed = {}, paused = false, path = path }
			local Logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
			Logger.set_level("debug")
			Logger.set_sink(function(line)
				if line:find("fired", 1, true) and ctx.on_log then ctx.on_log() end
			end)
			package.loaded["logger.shim"] = Logger
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["modules.gestures.manager"] = {
				is_assignable = function(id) return id == "screen_capture" or id == "send_text" or id == "script_pause_toggle" end,
				execute_action = function(action, binding) ctx.executed[#ctx.executed + 1] = { action, binding } end,
			}
			package.loaded[module_name] = nil
			local owner = require(module_name)
			ctx.owner = owner
			ctx.id = domain == "tap" and "number_row_left" or "script_altgr_enter"
			ctx.binding = owner.binding_id(ctx.id)
			ctx.detail = domain == "tap" and { code = 41, mods = {} } or { code = 28, mods = { altgr = true } }
			local function observe()
				if ctx.on_admission then ctx.on_admission() end
				return ctx.paused
			end
			owner.init({ is_active = function() return not observe() end, is_paused = observe,
				defer = function(fn) ctx.deferred[#ctx.deferred + 1] = fn; return true end })
			function ctx.run()
				local pending = ctx.deferred; ctx.deferred = {}
				for _, callback in ipairs(pending) do callback() end
			end
			body(ctx)
		end)
	end)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not called then error(failure, 0) end
end

helpers.describe("deferred shortcut final owner (linux-deferred-action-owner)", function()
	for _, domain in ipairs({ "tap", "script" }) do
		for _, change in ipairs({ "none", "reserved", "aba", "pause", "assignment" }) do
			helpers.it("keeps the " .. domain .. " dispatch current after a " .. change .. " logging callback", function()
				with_owner(domain, function(ctx)
					local token, interrupted = {}, false
					ctx.on_log = function()
						if interrupted then return end
						interrupted = true
						if change == "reserved" or change == "aba" then
							assert(ctx.owner.acquire_configuration(token))
							if change == "aba" then assert(ctx.owner.release_configuration(token)) end
						elseif change == "pause" then ctx.paused = true
						elseif change == "assignment" then assert(ctx.owner.set_action(ctx.id, "send_text")) end
					end
					helpers.assert_eq(ctx.owner.on_key(ctx.detail), true, "the original physical press was queued")
					helpers.assert_eq(ctx.executed, {}, "dispatch is deferred past consumption")
					ctx.run()
					helpers.assert_eq(interrupted, true, "the actual logger sink crosses the final boundary")
					helpers.assert_eq(ctx.executed, change == "none" and { { "screen_capture", ctx.binding } } or {},
						"a changed owner cannot execute its captured action")
					if change == "none" then return end
					if change == "reserved" then assert(ctx.owner.release_configuration(token)) end
					ctx.paused, ctx.on_log = false, nil
					helpers.assert_eq(ctx.owner.on_key(ctx.detail), true)
					ctx.run()
					helpers.assert_eq(ctx.executed, { { change == "assignment" and "send_text" or "screen_capture", ctx.binding } },
						"only a fresh physical press executes the current binding")
				end)
			end)
		end
		if domain == "script" then
			helpers.it("retains an admitted script-management action when logging pauses the driver", function()
				with_owner(domain, function(ctx)
					assert(ctx.owner.set_action(ctx.id, "script_pause_toggle"))
					ctx.on_log = function() ctx.paused = true end
					helpers.assert_eq(ctx.owner.on_key(ctx.detail), true)
					ctx.run()
					helpers.assert_eq(ctx.executed, { { "script_pause_toggle", ctx.binding } },
						"the final guard applies the script-management pause policy")
				end)
			end)
		end
		helpers.it("rechecks " .. domain .. " ownership after its admission provider returns", function()
			with_owner(domain, function(ctx)
				helpers.assert_eq(ctx.owner.on_key(ctx.detail), true)
				local changed = false
				ctx.on_admission = function()
					if changed then return end
					changed = true
					local token = {}; assert(ctx.owner.acquire_configuration(token)); assert(ctx.owner.release_configuration(token))
				end
				ctx.run()
				helpers.assert_eq(changed, true)
				helpers.assert_eq(ctx.executed, {}, "a true answer cannot revive a revoked queued action")
			end)
		end)
	end
end)


helpers.describe("tap initial admission keeps its source (linux-tap-initial-admission-owner)", function()
	for _, change in ipairs({ "assignment", "reserved", "aba", "pause" }) do
		helpers.it("refuses a tap revoked during initial " .. change .. " admission", function()
			with_owner("tap", function(ctx)
				local token, changed = {}, false
				ctx.on_admission = function()
					if changed then return end
					changed = true
					if change == "assignment" then assert(ctx.owner.set_action(ctx.id, "send_text"))
					elseif change == "pause" then ctx.paused = true
					else
						assert(ctx.owner.acquire_configuration(token))
						if change == "aba" then assert(ctx.owner.release_configuration(token)) end
					end
				end
				helpers.assert_eq(ctx.owner.on_key(ctx.detail), false, "revoked initial admission cannot consume the physical press")
				helpers.assert_eq(changed, true, "the original admission provider crossed its mutation boundary")
				helpers.assert_eq(#ctx.deferred, 0, "no stale intent is queued after admission revocation")
				ctx.run()
				helpers.assert_eq(ctx.executed, {})
				if change == "reserved" then assert(ctx.owner.release_configuration(token)) end
				ctx.paused, ctx.on_admission = false, nil
				helpers.assert_eq(ctx.owner.on_key(ctx.detail), true, "a fresh press admits the current binding")
				ctx.run()
				helpers.assert_eq(ctx.executed, { { change == "assignment" and "send_text" or "screen_capture", ctx.binding } })
			end)
		end)
	end
end)
