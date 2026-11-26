--- _shared/tests/lua/core/local_server_discovery_contract.lua

--- ==============================================================================
--- MODULE: Independent Local Discovery Trace Replay
--- DESCRIPTION:
--- Both Lua drivers replay authored publication/cache/source traces against the
--- same controller. No expected verdict comes from the production catalogue or
--- the native transport; this qualifies logical policy, never physical cleanup.
--- ==============================================================================

local M = {}
local Discovery = require("ai.engine.local_servers.discovery")

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

--- Builds a two-server controller on a settable clock (max age 10).
--- @return table controller
--- @return function set_clock
--- @return table probes Settle callbacks by server id, newest sweep last.
--- @return function sweep Starts one sweep of both servers.
local function paused_world()
	local clock, probes = 0, {}
	local controller = Discovery.new({ order = { "a", "b" }, clock = function() return clock end,
		max_age = function() return 10 end })
	local function sweep(on_done)
		return controller.sweep({ { id = "a", base_url = "http://127.0.0.1:1/v1" },
			{ id = "b", base_url = "http://127.0.0.1:2/v1" } }, function(target, settle)
			probes[target.id] = settle
			return true
		end, on_done)
	end
	return controller, function(value) clock = value end, probes, sweep
end

local UP = { ok = true, status = 200, body = '{"data":[{"id":"model"}]}' }
local DOWN = { ok = false, status = 0, body = "" }

--- Replays the pause policy (EDD-1): a pause holds the network work, keeps the
--- verdicts without aging, and holds them when a write or a cut-short sweep
--- leaves them without current evidence.
--- @param helpers table Driver assertion and registration owner.
function M.run_pause(helpers)
	helpers.it("local discovery pause keeps the verdicts and stops their age (edd1-local-server-rows)", function()
		local controller, set_clock, probes, sweep = paused_world()
		helpers.assert_eq(sweep(), true)
		probes.a(UP); probes.b(DOWN)
		helpers.assert_eq(controller.detected(), { "a" })
		set_clock(4)
		helpers.assert_eq(controller.pause(), true)
		helpers.assert_eq(controller.pause(), false, "a second pause changes nothing")
		set_clock(500)
		helpers.assert_eq(controller.is_stale(), false, "a paused cache does not expire")
		helpers.assert_eq(controller.detected(), { "a" }, "the verdicts survive the pause")
		helpers.assert_eq(controller.result("a").models, { "model" })
		helpers.assert_eq(controller.is_held(), false, "untouched verdicts stay current while paused")
		probes.a = nil
		helpers.assert_eq(sweep(), false, "a pause refuses a sweep")
		helpers.assert_eq(probes.a, nil, "a refused sweep probes nothing")
		helpers.assert_eq(controller.resume(), true)
		helpers.assert_eq(controller.is_stale(), false, "the resume restores the age the pause froze")
		set_clock(505)
		helpers.assert_eq(controller.is_stale(), false)
		set_clock(506)
		helpers.assert_eq(controller.is_stale(), true, "the age resumes from the pause")
	end)
	helpers.it("local discovery pause fences a running sweep and holds its verdicts (edd1-local-server-rows)", function()
		local controller, _, probes, sweep = paused_world()
		sweep(); probes.a(UP); probes.b(DOWN)
		local observed = 0
		sweep(function() observed = observed + 1 end)
		probes.a(DOWN)
		controller.pause()
		probes.b(DOWN)
		helpers.assert_eq(observed, 0, "a sweep the pause cut short tells no caller")
		helpers.assert_eq(controller.detected(), { "a" }, "its late answers publish nothing")
		helpers.assert_eq(controller.is_sweeping(), false)
		helpers.assert_eq(controller.is_held(), true, "the kept verdicts are no current evidence")
		controller.resume()
		helpers.assert_eq(controller.is_held(), false)
		helpers.assert_eq(controller.is_stale(), true, "the resume sweeps them again")
		helpers.assert_eq(controller.detected(), { "a" }, "until then they stay shown")
	end)
	for _, change in ipairs({ "write", "view" }) do
		helpers.it("local discovery keeps held verdicts across a paused " .. change .. " (edd1-local-server-rows)", function()
			local controller, _, probes, sweep = paused_world()
			sweep(); probes.a(UP); probes.b(DOWN)
			controller.pause()
			helpers.assert_eq(controller.is_held(), false)
			if change == "write" then controller.invalidate()
			else helpers.assert_eq(controller.set_order({ "a", "b" }, true), true) end
			helpers.assert_eq(controller.detected(), { "a" }, "the verdicts stay shown while paused")
			helpers.assert_eq(controller.result("a").models, { "model" })
			helpers.assert_eq(controller.is_held(), true, "without an action until the resume's sweep")
			helpers.assert_eq(controller.is_stale(), false, "no sweep while paused")
			controller.resume()
			helpers.assert_eq(controller.is_stale(), true)
			helpers.assert_eq(sweep(), true)
			probes.a(UP); probes.b(UP)
			helpers.assert_eq(controller.detected(), { "a", "b" })
			helpers.assert_eq(controller.is_held(), false)
		end)
	end
	helpers.it("local discovery pause cut short by the driver's scan holds the verdicts (edd1-local-server-rows)", function()
		local controller, _, probes, sweep = paused_world()
		sweep(); probes.a(UP); probes.b(DOWN)
		controller.pause(true)
		helpers.assert_eq(controller.is_held(), true)
		helpers.assert_eq(controller.detected(), { "a" })
	end)
	helpers.it("local discovery unpaused view change still drops the old verdicts (edd1-local-server-rows)", function()
		local controller, _, probes, sweep = paused_world()
		sweep(); probes.a(UP); probes.b(DOWN)
		helpers.assert_eq(controller.set_order({ "a", "b" }, true), true)
		helpers.assert_eq(controller.detected(), {}, "a live source change shows no stale model list")
		helpers.assert_eq(controller.is_held(), false)
	end)
end

return M
