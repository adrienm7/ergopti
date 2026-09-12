--- tests/support/tooltip_watcher_fixture.lua

--- ==============================================================================
--- MODULE: Tooltip Watcher Fixture
--- DESCRIPTION:
--- Owns native context overrides and real tooltip dependencies for one test scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local TooltipContext = require("tests.support.tooltip_context_watchers")
local IDLE_TIMEOUT_SEC = 10

local CASES = {
	{
		label = "LLM",
		module_name = "ui.tooltip.tooltip_llm",
		watcher_count = 3,
		render = function(tooltip)
			return tooltip.show_predictions({ "prediction" }, 1, true)
		end,
	},
	{
		label = "hotstring",
		module_name = "ui.tooltip.tooltip_hotstring",
		watcher_count = 2,
		render = function(tooltip)
			return tooltip.show("expansion", false, true)
		end,
	},
}

--- Returns the currently running timers from a test context.
--- @param timers table Timer objects.
--- @return table Running timers.
local function running_timers(timers)
	local result = {}
	for _, timer in ipairs(timers) do
		if timer.running then result[#result + 1] = timer end
	end
	return result
end

--- Builds a physical key event with only the fields tooltip watchers read.
--- @param keycode number Quartz keycode.
--- @param flags table|nil Modifier flags.
--- @param characters string|nil Produced characters.
--- @return table Event double.
local function hardware_key_event(keycode, flags, characters)
	local event = { properties = {} }
	function event:getProperty(property) return self.properties[property] or 0 end
	function event:copy()
		local replay = { properties = {} }
		for property, value in pairs(self.properties) do replay.properties[property] = value end
		function replay:getProperty(property) return self.properties[property] or 0 end
		function replay:setProperty(property, value)
			self.properties[property] = value
			return self
		end
		function replay:post() return self end
		return replay
	end
	function event:getKeyCode() return keycode end
	function event:getFlags() return flags or {} end
	function event:getCharacters() return characters or "" end
	return event
end

--- Builds one copyable physical mouse event and exposes its eventual replay.
--- @return table Event double.
local function hardware_mouse_event()
	local event = { properties = {}, replay = nil, on_replay = nil }
	function event:getProperty(property) return self.properties[property] or 0 end
	function event:copy()
		local replay = { properties = {}, post_calls = 0 }
		for property, value in pairs(self.properties) do replay.properties[property] = value end
		function replay:getProperty(property) return self.properties[property] or 0 end
		function replay:setProperty(property, value)
			self.properties[property] = value
			return self
		end
		function replay:post()
			self.post_calls = self.post_calls + 1
			if type(event.on_replay) == "function" then event.on_replay(self) end
			return self
		end
		self.replay = replay
		return replay
	end
	return event
end

--- Fires every pending zero-delay dispatcher without expiring idle timers.
--- @param timers table Timer objects.
local function drain_deferred_actions(timers)
	for _ = 1, 10 do
		local fired = false
		for _, timer in ipairs(timers) do
			if timer.running and timer.delay == 0 then
				timer:fire()
				fired = true
			end
		end
		if not fired then return end
	end
	error("deferred action queue did not become idle")
end

local function with_fixture(callback)
	return helpers.with_stub_scope({
		"ui.tooltip.config",
		"ui.tooltip.renderer",
		"ui.tooltip.tooltip_llm",
		"ui.tooltip.tooltip_hotstring",
		"ui.tooltip",
		"adapters.event_provenance",
		"adapters.key_state",
		"adapters.synthetic_input",
		"adapters.timer_scheduler",
		"adapters.storage",
		"infra.hotpath_profiler",
		"infra.logger",
	}, function()
		local restore_context = function() end
		local outcome = table.pack(xpcall(function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			-- Facade-only cases also need fresh native capabilities before importing Config.
			helpers.load_with_stubs("hs")
			--- Loads one real tooltip module with observable renderer and eventtap ports.
			--- @param spec table Tooltip case descriptor.
			--- @param faults table|nil Fault kind keyed by eventtap creation index.
			--- @return table Test context.
			local function load_tooltip(spec, faults)
				restore_context()
				local Config = helpers.load_with_stubs("ui.tooltip.config")
				restore_context = TooltipContext.install()
				Config.settings.timeout_sec = IDLE_TIMEOUT_SEC
				Config.settings.llm_timeout_sec = IDLE_TIMEOUT_SEC
				-- These adapters retain hs.timer/eventtap objects in module locals. Reload
				-- them with the fresh hs stub so deferred-action assertions cannot inspect a
				-- different timer table and pass without ever draining the real queue.
				package.loaded["adapters.event_provenance"] = nil
				package.loaded["adapters.key_state"] = nil
				package.loaded["adapters.synthetic_input"] = nil
				package.loaded["adapters.timer_scheduler"] = nil
				package.loaded["adapters.storage"] = nil
				package.loaded["infra.hotpath_profiler"] = nil

				local renderer
				renderer = {
					ELEM_INFO = 6,
					hide_calls = 0,
					render_calls = 0,
					stacked_render_calls = 0,
					partial_render_calls = 0,
					visible = false,
					stacked_visible = false,
					canvas = {
						minimumTextSize = function() return { w = 100, h = 20 } end,
					},
					render = function(_content, _state, on_shown)
						if faults and faults.render_throw then error("simulated renderer failure") end
						renderer.render_calls = renderer.render_calls + 1
						renderer.visible = true
						if faults and faults.render_skip_callback then
							renderer.hide()
							return faults.render_result
						end
						if type(on_shown) == "function" then on_shown() end
						if faults and faults.render_result ~= nil then return faults.render_result end
						return true
					end,
					render_stacked = function(_rows, _state, on_shown)
						renderer.stacked_render_calls = renderer.stacked_render_calls + 1
						renderer.stacked_visible = true
						if type(on_shown) == "function" then on_shown() end
						if faults and faults.stacked_render_result ~= nil then
							return faults.stacked_render_result
						end
						return true
					end,
					hide = function()
						renderer.hide_calls = renderer.hide_calls + 1
						if not faults or faults.hide_result ~= false then renderer.visible = false end
						if faults and faults.hide_result ~= nil then return faults.hide_result end
						return true
					end,
					hide_stacked = function()
						if not faults or faults.hide_stacked_result ~= false then
							renderer.stacked_visible = false
						end
						if faults and faults.hide_stacked_result ~= nil then
							return faults.hide_stacked_result
						end
						return true
					end,
					set_element_text = function()
						renderer.partial_render_calls = renderer.partial_render_calls + 1
						if faults and faults.partial_render_result ~= nil then
							return faults.partial_render_result
						end
						return true
					end,
				}
				package.loaded["ui.tooltip.renderer"] = renderer

				local created = {}
				local creation_calls = 0
				local real_new = hs.eventtap.new
				hs.eventtap.new = function(types, callback)
					creation_calls = creation_calls + 1
					local fault = faults and faults[creation_calls] or nil
					if fault == "creation_throw" then
						error("simulated eventtap creation failure")
					end
					local watcher = real_new(types, callback)
					if fault == "start_disabled" then
						watcher.start = function(self)
							self.started = self.started + 1
							self.enabled = false
							return self
						end
					elseif fault == "start_throw" or fault == "start_throw_stop_throw" then
						watcher.start = function(self)
							self.started = self.started + 1
							self.enabled = true
							error("simulated eventtap start failure")
						end
					elseif fault == "is_enabled_throw" or fault == "is_enabled_throw_stop_throw" then
						local real_is_enabled = watcher.isEnabled
						local failed_once = false
						watcher.isEnabled = function(self)
							if not failed_once then
								failed_once = true
								error("simulated eventtap status failure")
							end
							return real_is_enabled(self)
						end
					end
					if fault == "start_throw_stop_throw" or fault == "is_enabled_throw_stop_throw" then
						watcher.stop = function(self)
							self.stopped = self.stopped + 1
							error("simulated persistent eventtap stop failure")
						end
					end
					created[#created + 1] = watcher
					return watcher
				end

				package.loaded[spec.module_name] = nil
				local tooltip = require(spec.module_name)

				return {
					created = created,
					config = Config,
					renderer = renderer,
					timers = hs.timer.__timers,
					tooltip = tooltip,
				}
			end
			return callback({ load_tooltip = load_tooltip })
		end, debug.traceback))
		restore_context()
		if not outcome[1] then error(outcome[2], 0) end
		return table.unpack(outcome, 2, outcome.n)
	end)
end

return {
	with_fixture = with_fixture,
	CASES = CASES,
	IDLE_TIMEOUT_SEC = IDLE_TIMEOUT_SEC,
	running_timers = running_timers,
	hardware_key_event = hardware_key_event,
	hardware_mouse_event = hardware_mouse_event,
	drain_deferred_actions = drain_deferred_actions,
}
