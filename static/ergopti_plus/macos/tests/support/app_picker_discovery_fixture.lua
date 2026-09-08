--- tests/support/app_picker_discovery_fixture.lua

--- ==============================================================================
--- MODULE: Application Discovery Fixture
--- DESCRIPTION:
--- Runs the real picker with scoped filesystem, process and native chooser ports.
--- ==============================================================================

local helpers = require("tests.helpers")

return function(run)
	local original_getenv = os.getenv
	local original_time = os.time
	local original_hs = rawget(_G, "hs")
	local state = { home = "/fixture", status = "absent", started = true,
		now = 1000, pending = {}, choosers = {}, logs = {} }
	local ok, failure = xpcall(function()
		os.time = function() return state.now end
		os.getenv = function(key)
			if key == "HOME" then return state.home end
			return original_getenv(key)
		end
		helpers.with_fresh_modules({ "infra.app_picker", "adapters.shell_runner",
			"adapters.file_system", "infra.logger", "infra.i18n", "infra.text_utils" }, function()
			package.loaded["adapters.shell_runner"] = { spawn = function(bin, args, callback)
				state.pending[#state.pending + 1] = { bin = bin, args = args, callback = callback }
				return { start = function() return state.started end }
			end }
			package.loaded["adapters.file_system"] = { path_status = function()
				return state.status, "injected classification failure"
			end }
			local logger = {}
			for _, level in ipairs({ "debug", "info", "warn", "error" }) do
				logger[level] = function(_, message, ...)
					state.logs[#state.logs + 1] = { level = level, text = string.format(message, ...) }
				end
			end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.text_utils"] = { escape_gsub_replacement = function(value) return value end }
			_G.hs = {
				timer = { absoluteTime = function() return state.now * 1000000000 end },
				application = { frontmostApplication = function() return nil end,
					infoForBundlePath = function() return {} end },
				chooser = { new = function(callback)
					local chooser = { callback = callback, shown = 0, deleted = 0 }
					function chooser:placeholderText() return self end
					function chooser:bgDark() return self end
					function chooser:choices(rows) self.rows = rows; return self end
					function chooser:show() self.shown = self.shown + 1; return self end
					function chooser:delete()
						self.deleted = self.deleted + 1
						if state.on_delete then state.on_delete(self) end
					end
					state.choosers[#state.choosers + 1] = chooser
					return chooser
				end },
			}
			local picker = require("infra.app_picker")
			run(picker, state)
		end)
	end, debug.traceback)
	os.getenv = original_getenv
	os.time = original_time
	_G.hs = original_hs
	if not ok then error(failure, 0) end
end
