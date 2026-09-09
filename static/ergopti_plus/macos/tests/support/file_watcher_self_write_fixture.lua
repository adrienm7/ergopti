--- tests/support/file_watcher_self_write_fixture.lua

--- ==============================================================================
--- MODULE: File Watcher Self-Write Fixture
--- DESCRIPTION:
--- Owns native doubles and module caches through construction and callback errors.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"infra.file_watchers", "infra.ui_restore", "infra.git_status", "infra.fs_dir",
	"infra.logger", "infra.i18n", "infra.notifications", "reload_gate",
}

M.CONFIG_ROOT = "/fake/config/"
M.CONFIG_TOML = M.CONFIG_ROOT .. "hammerspoon/config.toml"
M.KARABINER_TOML = M.CONFIG_ROOT .. "hammerspoon/config_karabiner.toml"
M.HOTSTRING_TOML = M.CONFIG_ROOT .. "francais.toml"

--- Runs a real file-watcher controller over deterministic external boundaries.
--- @param body function Receives event, timer and reload observations.
--- @return ... Callback results.
function M.with_watchers(body)
	local host = hs
	local previous_pathwatcher, previous_timer = host.pathwatcher, host.timer
	local previous_attributes, previous_reload = host.fs.attributes, host.reload
	local previous_roots = rawget(_G, "script_watchers")
	local outcome = table.pack(xpcall(function()
		return helpers.with_fresh_modules(OWNERS, function()
			for _, name in ipairs(OWNERS) do package.loaded[name] = nil end
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.notifications"] = { notify = function() return true end }
			package.loaded["infra.ui_restore"] = {
				defer_reload = function(fn) return fn() end,
				snapshot = function() end,
				restore = function() end,
			}
			package.loaded["infra.git_status"] = {
				operation_in_progress = function() return false end,
			}
			package.loaded["infra.file_watchers"] = nil
			local watchers = require("infra.file_watchers")
			local clock, reloads, scheduled_count = 0, 0, 0
			local callbacks, pending = {}, nil
			host.pathwatcher = { new = function(_, callback)
				callbacks[#callbacks + 1] = callback
				return { start = function(self) return self end, stop = function() end }
			end }
			host.timer = {
				doAfter = function(_, callback)
					scheduled_count = scheduled_count + 1
					pending = callback
					return { stop = function() end }
				end,
				secondsSinceEpoch = function() return clock end,
			}
			host.fs.attributes = function() return nil end
			host.reload = function() reloads = reloads + 1; return true end
			_G.script_watchers = nil
			assert(watchers.start({
				hotstrings_dir = M.CONFIG_ROOT,
				base_dir = "/fake/base/",
				personal_hotstrings_dir = "/fake/personal",
				self_written_files = { M.CONFIG_TOML, M.KARABINER_TOML },
			}), "watcher fixture startup did not commit")
			clock = 30
			return body({
				fire = function(path)
					pending = nil
					for _, callback in ipairs(callbacks) do callback({ path }) end
				end,
				scheduled = function() return pending end,
				scheduled_count = function() return scheduled_count end,
				settle = function()
					clock = clock + 10
					local callback = pending
					pending = nil
					if callback then callback() end
				end,
				reloads = function() return reloads end,
			})
		end)
	end, debug.traceback))
	host.pathwatcher, host.timer = previous_pathwatcher, previous_timer
	host.fs.attributes, host.reload = previous_attributes, previous_reload
	_G.script_watchers = previous_roots
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return M
