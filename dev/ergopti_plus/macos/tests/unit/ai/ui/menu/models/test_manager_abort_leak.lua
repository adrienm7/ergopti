--- tests/unit/ai/ui/menu/models/test_manager_abort_leak.lua

--- ==============================================================================
--- MODULE: Models Manager Download-Abort Reset Regression
--- DESCRIPTION:
--- Drives the real shared hardware-check continuation after an earlier abort.
--- The new download must clear the sticky abort state before its first icon
--- publication; source ordering alone cannot prove that runtime behavior.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===================================
-- ===================================
-- ======= 1/ Behavioral Repro =======
-- ===================================
-- ===================================

helpers.describe("models manager: aborted downloads are reset before retry", function()
	helpers.it("(models-manager-abort-leak) clears abort before invoking the approved download", function()
		local modules = {
			"hs", "core.process.adapters.shell_runner", "core.events.timer_scheduler", "core.logger.engine.logger", "core.i18n.engine.i18n",
			"core.ui.engine.dialog_util", "core.fs.engine.paths", "core.timing.engine.timings",
			"ai.engine", "ai.ui.menu.models.manager_ollama",
			"ai.ui.menu.models.manager_mlx", "ai.ui.menu.models.manager",
		}
		local saved_hs = _G.hs
		local timers = {}
		local function new_timer(callback)
			local timer = { callback = callback, running_state = false }
			function timer:start()
				self.running_state = true
				return self
			end
			function timer:stop()
				self.running_state = false
				return self
			end
			function timer:running() return self.running_state end
			function timer:fire() return self.callback() end
			timers[#timers + 1] = timer
			return timer
		end
		local hs_fixture = {
			execute = function(command)
				if command:find("memsize", 1, true) then
					return tostring(16 * 1024 * 1024 * 1024)
				end
				return "100"
			end,
			json = {decode = function()
				return {{families = {{models = {{name = "A", urls = {ollama = "A"}}}}}}}
			end},
			timer = {
				doAfter = function(_, callback)
					return new_timer(callback):start()
				end,
				new = function(_, callback) return new_timer(callback) end,
			},
		}
		local outcome = table.pack(xpcall(function()
			helpers.with_fresh_modules(modules, function()
				_G.hs = hs_fixture
				package.loaded["hs"] = hs_fixture
				require("tests.support.ui.menu.menu_llm.system_probe_stub").install(16, 100)
				package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
				package.loaded["core.i18n.engine.i18n"] = {get = function(key) return key end}
				package.loaded["core.ui.engine.dialog_util"] = {
					block_alert = function() return "menu.llm.btn_download" end,
				}
				helpers.provide_timings()
				package.loaded["core.fs.engine.paths"] = {
					shared_llm_path = function()
						return helpers.shared("ai/data/models.json")
					end,
				}
				package.loaded["ai.engine"] = {get_backend = function() return "ollama" end}
				package.loaded["ai.ui.menu.models.manager_ollama"] = {
					new = function() return {} end,
				}
				package.loaded["ai.ui.menu.models.manager_mlx"] = {
					new = function() return {} end,
				}

				local events = {}
				local deps = {
					update_icon = function(label)
						events[#events + 1] = "icon:" .. tostring(label)
						return true
					end,
					reset_menubar = function() return true end,
				}
				require("ai.ui.menu.models.manager").new(deps)
				deps.mark_download_aborted()
				events = {}

				local clear_download_abort = deps.clear_download_abort
				deps.clear_download_abort = function()
					events[#events + 1] = "clear"
					return clear_download_abort()
				end
				local requirements = {}
				local requirement_lifecycle = {
					adopt = function(child, pause_join)
						requirements[child] = pause_join
						return true
					end,
					settle = function(child)
						if requirements[child] == nil then return false end
						requirements[child] = nil
						return true
					end,
				}
				deps.shared_system_check("A", "Ollama", "A", function()
					events[#events + 1] = "download"
					deps.update_icon("first-progress")
					return true
				end, nil, { _requirement_lifecycle = requirement_lifecycle })

				helpers.assert_eq(#timers, 1)
				timers[1]:fire()
				helpers.assert_eq(events, {
					"clear", "download", "icon:first-progress",
				}, "abort reset must commit before the approved download can publish progress")
			end)
		end, debug.traceback))
		_G.hs = saved_hs
		if not outcome[1] then error(outcome[2], 0) end
	end)
end)
