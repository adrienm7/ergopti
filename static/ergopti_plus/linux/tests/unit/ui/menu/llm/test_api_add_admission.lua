--- tests/unit/ui/menu/llm/test_api_add_admission.lua

--- ==============================================================================
--- MODULE: API Add Runtime Admission Regression
--- DESCRIPTION:
--- A stale native add dialog cannot publish credentials, select an entry or test
--- its provider under another AI owner. Tentative RAM stays behind a private gate.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.menu.llm.api_add_admission_fixture")

--- Verifies a refused transaction preserved both native file and selected entry.
--- @param state table Actual menu/engine/private source fixture.
local function refused(state)
	helpers.assert_eq(state.entries.active().id, "before")
	helpers.assert_eq(state.read(state.api_path), state.original)
	helpers.assert_eq(#state.requests, 0)
	helpers.assert_eq(#state.infos, 0)
	helpers.assert_eq(#state.errors, 1)
	helpers.assert_eq(state.changed, 0)
end

helpers.describe("API add exact runtime admission", function()
	helpers.it("(api-add-admission) commits once without rewriting backend preferences and tests once", function()
		Fixture.run(function(state)
			helpers.assert_eq(state.action(), true)
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(state.changed, 1)
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_eq(#state.infos, 1)
			helpers.assert_eq(#state.errors, 0)
			helpers.assert_eq(state.read(state.config_path), state.config)
			helpers.assert_eq(state.json.decode(state.read(state.api_path)).active_id, state.entries.active().id)
			helpers.assert_true(state.scope(), "successful publication releases the exact private gate")
		end)
	end)

	for _, boundary in ipairs({ "scope", "pause", "shutdown", "backend" }) do
		helpers.it("(api-add-admission) refuses " .. boundary .. " acquired while the last prompt was open", function()
			Fixture.run(function(state)
				state.on_prompt = function(index)
					if index ~= 2 then return end
					if boundary == "scope" then helpers.assert_true(state.scope())
					elseif boundary == "pause" then state.paused = true
					elseif boundary == "shutdown" then helpers.assert_true(state.engine.shutdown_runtime())
					else helpers.assert_true(state.preferences.set("llm.models.selected", "ollama")) end
				end
				helpers.assert_eq(state.action(), false)
				refused(state)
				helpers.assert_eq(state.stages, 0, "refused admission cannot create a private staging file")
			end)
		end)
	end

	helpers.it("(api-add-admission) guards RAM before a reentrant writer entry", function()
		Fixture.run(function(state)
			state.on_add = function()
				helpers.assert_eq(state.engine.predict("synthetic tentative text"), false)
				helpers.assert_eq(state.scope(), false, "the private gate cannot be borrowed by another scope")
				state.paused = true
			end
			helpers.assert_eq(state.action(), false)
			refused(state)
			helpers.assert_eq(state.stages, 0)
			state.paused = false
			helpers.assert_true(state.scope(), "acknowledged pre-write refusal releases the gate")
		end)
	end)

	helpers.it("(api-add-admission) reserves private RAM before a reentrant publication admission", function()
		Fixture.run(function(state)
			local nested, nested_entry, nested_settled = 0
			state.on_pause = function()
				if state.entries.active().id == "before" then return end
				state.on_pause = nil
				nested = nested + 1
				local entry, _, settled = state.entries.add({ provider = "cerebras", token = "nested-key",
					label = "nested", model = "nested-model" }, true, function() return true end)
				nested_entry, nested_settled = entry, settled
			end
			local accepted = state.action()
			helpers.assert_nil(nested_entry, "tentative RAM must not admit a second private transaction")
			helpers.assert_eq(nested_settled, true)
			helpers.assert_true(accepted)
			helpers.assert_eq(nested, 1)
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(#state.entries.list(), 3)
			helpers.assert_eq(#state.requests, 1)
		end)
	end)

	for _, boundary in ipairs({ "pause", "preferences", "throw" }) do
		helpers.it("(api-add-admission) rolls back tentative RAM after staging " .. boundary, function()
			Fixture.run(function(state)
				state.on_stage = function()
					helpers.assert_eq(state.engine.predict("synthetic tentative text"), false)
					if boundary == "pause" then state.paused = true
					elseif boundary == "preferences" then
						helpers.assert_true(state.preferences.set("llm.models.selected", "ollama"))
					else error("controlled private creation failure after native close") end
				end
				helpers.assert_eq(state.action(), false)
				refused(state)
				helpers.assert_eq(state.writes, 0)
				helpers.assert_true(state.scope(), "known rollback must release the private gate")
			end)
		end)
	end

	helpers.it("(api-add-admission) preserves an actual API source conflict and releases rollback", function()
		Fixture.run(function(state)
			local external = state.original .. "\n"
			state.on_add = function() state.write(state.api_path, external) end
			helpers.assert_eq(state.action(), false)
			helpers.assert_eq(state.read(state.api_path), external)
			helpers.assert_eq(state.entries.active().id, "before")
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(#state.errors, 1)
			helpers.assert_true(state.scope())
		end)
	end)

	helpers.it("(api-add-admission) retains uncertain rename debt instead of declaring rollback", function()
		Fixture.run(function(state)
			state.on_renamed = function() error("controlled interrupted native rename receipt") end
			helpers.assert_eq(state.action(), false)
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(#state.infos, 0)
			helpers.assert_eq(state.scope(), false, "unknown physical publication must retain its original gate")
			helpers.assert_eq(state.engine.predict("synthetic guarded text"), false)
		end)
	end)

	helpers.it("(api-add-admission) refuses a forged receipt without exposing the private owner", function()
		Fixture.run(function(state)
			local ticket = assert(state.engine.begin_api_selection())
			helpers.assert_nil(next(ticket), "the public receipt contains no owner token")
			helpers.assert_eq(state.engine.finish_api_selection({}, true, true), false)
			helpers.assert_eq(state.engine.finish_api_selection(ticket, false, nil), false)
			helpers.assert_eq(state.engine.finish_api_selection(ticket, {}, true), false)
			helpers.assert_eq(state.scope(), false)
			helpers.assert_true(state.engine.finish_api_selection(ticket, false, true))
			helpers.assert_true(state.scope())
		end)
	end)

	helpers.it("(api-add-admission) does not adopt a successor selected from the commit logger", function()
		Fixture.run(function(state)
			state.on_log = function(level, format)
				if level == "info" and format:find("API entry '%s'", 1, true) then
					state.on_log = nil
					helpers.assert_true(state.entries.set_active("successor"))
				end
			end
			helpers.assert_eq(state.action(), false)
			helpers.assert_eq(state.entries.active().id, "successor")
			helpers.assert_eq(state.json.decode(state.read(state.api_path)).active_id, "successor")
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(state.changed, 0)
			helpers.assert_true(state.scope())
		end)
	end)

	helpers.it("(api-add-admission) binds source validation inside the runtime admission bracket", function()
		Fixture.run(function(state)
			state.on_log = function(level, format)
				if level ~= "info" or not format:find("API entry '%s'", 1, true) then return end
				state.on_log = nil
				local reads = 0
				state.on_pause = function()
					reads = reads + 1
					if reads == 2 then
						state.on_pause = nil
						helpers.assert_true(state.entries.set_active("successor"))
					end
				end
			end
			state.action()
			helpers.assert_eq(state.entries.active().id, "successor")
			helpers.assert_eq(state.changed, 0, "no stale publication may rebuild before a source-bound receipt")
			helpers.assert_eq(#state.requests, 0)
		end)
	end)

	helpers.it("(api-add-admission) a throwing commit logger cannot lose a known publication ACK", function()
		Fixture.run(function(state)
			state.on_log = function(level, format)
				if level == "info" and format:find("API entry '%s'", 1, true) then error("controlled log sink failure") end
			end
			helpers.assert_eq(state.action(), true)
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_true(state.scope())
		end)
	end)

	for _, boundary in ipairs({ "menu", "logger", "native" }) do
		helpers.it("(api-add-admission) never posts after a successor at " .. boundary, function()
			Fixture.run(function(state)
				local function replace() helpers.assert_true(state.scope()) end
				if boundary == "menu" then state.on_changed = replace
				elseif boundary == "native" then state.on_http_admission = replace
				else state.on_log = function(level, format)
					if level == "debug" and format:find("chat() →", 1, true) then state.on_log = nil; replace() end
				end end
				helpers.assert_eq(state.action(), false)
				helpers.assert_eq(#state.requests, 0)
				helpers.assert_eq(#state.infos, 0)
			end)
		end)
	end

	for _, replacement in ipairs({ "selection", "source" }) do
		helpers.it("(api-add-admission) refuses a changed API " .. replacement .. " after menu rebuild", function()
			Fixture.run(function(state)
				state.on_changed = function()
					if replacement == "selection" then helpers.assert_true(state.entries.set_active("successor"))
					else state.write(state.api_path, state.read(state.api_path) .. "\n") end
				end
				helpers.assert_eq(state.action(), false)
				helpers.assert_eq(#state.requests, 0)
				helpers.assert_eq(#state.infos, 0)
				helpers.assert_eq(state.changed, 1)
			end)
		end)
	end

	helpers.it("(api-add-admission) suppresses a late connectivity verdict after a scope successor", function()
		Fixture.run(function(state)
			state.hold_http = true
			helpers.assert_true(state.action())
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_true(state.scope())
			state.requests[1].done({ ok = true, status = 200, body = '{"choices":[{"message":{"content":"synthetic late"}}]}' })
			helpers.assert_eq(#state.infos, 0)
			helpers.assert_eq(#state.errors, 0)
			helpers.assert_eq(state.remote.is_active(), false)
		end)
	end)
end)
