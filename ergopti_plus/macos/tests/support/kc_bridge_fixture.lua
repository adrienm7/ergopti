--- tests/support/kc_bridge_fixture.lua

--- ==============================================================================
--- MODULE: Owned Karabiner Ledger Fixture
--- DESCRIPTION:
--- Keeps real file I/O while retiring producers and scratch paths on every exit.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"infra.logger", "infra.config_paths", "adapters.timer_scheduler",
	"modules.keylogger.kc_bridge", "modules.keylogger", "tests.stubs.hs",
}

--- Owns one real ledger and its bridge for the complete scenario lifetime.
--- @param callback function Receives paths, native handles and bridge operations.
--- @return ... Callback results.
function M.with_context(callback)
	assert(type(callback) == "function", "KC fixture callback must be a function")
	return helpers.with_stub_scope(OWNERS, function()
		local fs = require("tests.stubs.hs").fs
		local open, remove = io.open, os.remove
		local root = assert(os.tmpname())
		local base_removed, base_error, base_code = remove(root)
		assert(base_removed or base_code == 2, tostring(base_error))
		local root_owned, metrics_owned, bridge
		local ctx = { root = root, watchers = {}, timers = {} }
		local outcome = table.pack(pcall(function()
			assert(fs.attributes(root) == nil, "scratch root must not already exist")
			-- A refused constructor may already have created its target. Retain
			-- the exact attempted path so partial setup is cleaned as well.
			root_owned = true
			local root_created, root_error = fs.mkdir(root)
			assert(root_created, "could not create scratch root: " .. tostring(root_error))
			metrics_owned = true
			local metrics_created, metrics_error = fs.mkdir(root .. "/metrics")
			assert(metrics_created, "could not create scratch metrics directory: " .. tostring(metrics_error))
			local overrides = {
				keycodes = { map = {
					cmd = 55, rightcmd = 54, shift = 56, rightshift = 60,
					alt = 58, rightalt = 61, ctrl = 59, rightctrl = 62,
					a = 0, b = 1, c = 8,
				} },
				pathwatcher = { new = function(_, callback_fn)
					ctx.watcher_callback = callback_fn
					local watcher = { active = false }
					watcher.start = function() watcher.active = true; return watcher end
					watcher.stop = function() watcher.active = false; return watcher end
					ctx.watchers[#ctx.watchers + 1] = watcher
					return watcher
				end },
				timer = {
					new = function()
						local timer = { active = false }
						timer.start = function() timer.active = true; return timer end
						timer.stop = function() timer.active = false; return timer end
						timer.running = function() return timer.active end
						ctx.timers[#ctx.timers + 1] = timer
						return timer
					end,
					absoluteTime = function() return 0 end,
				},
			}
			--- Loads the real bridge once against this scenario's native doubles.
			--- @return table bridge
			function ctx.load()
				assert(bridge == nil, "fixture bridge already constructed")
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				package.loaded["infra.config_paths"] = { get_config_dir = function() return root end }
				bridge = helpers.load_with_stubs("modules.keylogger.kc_bridge", overrides)
				return bridge
			end
			--- Appends a real physical-key ledger row and always closes the writer.
			--- @param line string Physical key name, optionally prefixed with U:.
			function ctx.append(line)
				local handle = assert(open(root .. "/metrics/karabiner_kc.log", "a"))
				local written = table.pack(pcall(handle.write, handle, line .. "\n"))
				local closed = table.pack(pcall(handle.close, handle))
				assert(written[1] and written[2], tostring(written[3] or written[2]))
				assert(closed[1] and closed[2], tostring(closed[3] or closed[2]))
			end
			return callback(ctx)
		end))
		local errors = {}
		local function cleanup(label, fn)
			local ok, result, reason = pcall(fn)
			if not ok or not result then errors[#errors + 1] = label .. ": " .. tostring(ok and reason or result) end
		end
		if bridge then cleanup("bridge stop", bridge.stop) end
		if metrics_owned then
			cleanup("ledger removal", function()
				local removed, reason, code = remove(root .. "/metrics/karabiner_kc.log")
				if code == 2 then return true end
				return removed, reason
			end)
			cleanup("metrics removal", function() return fs.rmdir(root .. "/metrics") end)
		end
		if root_owned then cleanup("root removal", function() return fs.rmdir(root) end) end
		if #errors > 0 then
			error((outcome[1] and "fixture cleanup failed" or tostring(outcome[2])) .. "; " .. table.concat(errors, "; "), 0)
		end
		if not outcome[1] then error(outcome[2], 0) end
		return table.unpack(outcome, 2, outcome.n)
	end)
end
return M
