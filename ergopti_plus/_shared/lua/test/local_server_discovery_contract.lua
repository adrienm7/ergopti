--- _shared/lua/test/local_server_discovery_contract.lua

--- ==============================================================================
--- MODULE: Independent Local Discovery Trace Replay
--- DESCRIPTION:
--- Both Lua drivers replay authored publication/cache/source traces against the
--- same controller. No expected verdict comes from the production catalogue or
--- the native transport; this qualifies logical policy, never physical cleanup.
--- ==============================================================================

local M = {}
local Discovery = require("llm.local_server_discovery")

--- Replays every independent case through the driver's registered helpers.
--- @param corpus table Authored JSON expectations.
--- @param helpers table Driver assertion and registration owner.
function M.run(corpus, helpers)
	assert(corpus.version == 1 and #corpus.cases == 8, "independent discovery trace inventory")
	for _, case in ipairs(corpus.cases) do
		helpers.it("local discovery trace: " .. case.name, function()
			local clock, published = 0, 0
			local callbacks, inputs, done, errors, starts = {}, {}, {}, {}, {}
			local controller = Discovery.new({
				order = corpus.order,
				clock = function() return clock end,
				max_age = function() return corpus.max_age end,
				on_publish = function() published = published + 1 end,
				on_error = function(kind) errors[#errors + 1] = kind end,
			})
			for number, step in ipairs(case.steps) do
				if step.kind == "sweep" then
					inputs[step.name], callbacks[step.name] = step.targets, {}
					local refuse, throwing = {}, {}
					for _, id in ipairs(step.refuse or {}) do refuse[id] = true end
					for _, id in ipairs(step.throw or {}) do throwing[id] = true end
					controller.sweep(step.targets, function(target, settle)
						starts[#starts + 1] = target.id
						callbacks[step.name][target.id] = settle
						if throwing[target.id] then error("controlled producer refusal") end
						if step.sync and step.sync[target.id] then settle(step.sync[target.id]) end
						return not refuse[target.id]
					end, function(changed)
						done[#done + 1] = { name = step.name, changed = changed }
						if step.observer_throws then error("controlled observer refusal") end
					end)
				elseif step.kind == "answer" then
					assert(callbacks[step.sweep] and callbacks[step.sweep][step.id], "trace must answer a real dispatched probe")
					callbacks[step.sweep][step.id](step.response)
				elseif step.kind == "clock" then
					clock = step.value
				elseif step.kind == "mutate" then
					local target = inputs[step.sweep][step.index]
					for key, value in pairs(step.fields) do target[key] = value end
				else
					error("unknown independent discovery step")
				end
				local observed = {
					active = controller.is_sweeping(), stale = controller.is_stale(),
					detected = controller.detected(), done = done,
					published = published, errors = errors, starts = starts,
				}
				-- Assertions stay outside the protected producer/observer callbacks.
				for key, expected in pairs(step.expected or {}) do
					if key == "results" then
						for id, result in pairs(expected) do
							helpers.assert_eq(controller.result(id), result, case.name .. " result " .. id)
						end
					else
						helpers.assert_eq(observed[key], expected, case.name .. " step " .. number .. " " .. key)
					end
				end
			end
		end)
	end
end

return M
