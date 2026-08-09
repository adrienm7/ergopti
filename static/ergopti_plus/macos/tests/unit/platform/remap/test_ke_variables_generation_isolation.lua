--- tests/unit/platform/remap/test_ke_variables_generation_isolation.lua

--- ==============================================================================
--- MODULE: Regression — Karabiner Runtime Variables Are Generation-Isolated
--- DESCRIPTION:
--- Replays two independently loaded Hammerspoon generations against one shared
--- Karabiner variable store. A delayed writer from generation A must never undo
--- generation B's newer state or overwrite an untagged personal variable that
--- happens to use the same logical name.
---
--- ROOT CAUSE ENCODED HERE:
--- 1. Each Lua generation owns an independent asynchronous writer serializer.
--- 2. Completion order is therefore not serialized across reload or Force Quit.
--- 3. Runtime variable names must carry the exact lease token so an A writer can
---    mutate only A, while bare names remain entirely personal.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKEN_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local TOKEN_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"





-- ===============================================
-- ===============================================
-- ======= 1/ Cross-Generation CLI Harness =======
-- ===============================================
-- ===============================================

--- Returns the canonical runtime-variable name owned by one exact generation.
--- @param logical_name string Driver-local logical state name.
--- @param token string Canonical lease token.
--- @return string scoped_name Token-scoped Karabiner variable name.
local function scoped_name(logical_name, token)
	return "ergopti_" .. logical_name .. "_" .. token
end

--- Replays a newer OFF write before an older delayed ON write.
--- @param logical_name string Logical Ergopti runtime-variable name.
--- @param personal_value number Sentinel owned by an untagged personal rule.
--- @return table engine Final shared Karabiner variable store.
local function replay_old_writer_after_reload(logical_name, personal_value)
	local tasks = {}
	local payloads = {}
	local payload_serial = 0
	local engine = { [logical_name] = personal_value }
	local current_token = TOKEN_A

	package.loaded["platform.remap.ke_variables"] = nil
	package.loaded["platform.remap.lease_contract"] = nil
	package.loaded["platform.remap.lease_controller"] = {
		token = function() return current_token end,
		status = function() return "active", { token = current_token } end,
	}
	package.loaded["platform.remap.ke_paths"] = { CLI = "/test/karabiner_cli" }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.json_codec"] = {
		encode = function(values)
			payload_serial = payload_serial + 1
			local payload = "payload-" .. tostring(payload_serial)
			local snapshot = {}
			for name, value in pairs(values) do snapshot[name] = value end
			payloads[payload] = snapshot
			return payload, nil
		end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args, on_done)
			local task = {
				executable = executable,
				payload = args[2],
				on_done = on_done,
				started = false,
			}
			tasks[#tasks + 1] = task
			return {
				start = function()
					task.started = true
					return true
				end,
			}
		end,
	}

	local generation_a = require("platform.remap.ke_variables")
	helpers.assert_true(generation_a.set(logical_name, 1),
		"generation A must start its delayed ON writer")

	-- A reload creates a new module instance and therefore a second independent
	-- serializer while A's already-started child can still be pending in the OS.
	current_token = TOKEN_B
	package.loaded["platform.remap.ke_variables"] = nil
	local generation_b = require("platform.remap.ke_variables")
	helpers.assert_true(generation_b.set(logical_name, 0),
		"generation B must start its newer OFF writer independently")
	helpers.assert_eq(#tasks, 2,
		"the reproduction requires one live CLI child captured by each Lua generation")

	local function complete(index)
		local task = tasks[index]
		helpers.assert_true(task.started, "only a started CLI child may complete")
		local values = payloads[task.payload]
		helpers.assert_not_nil(values, "the CLI child must carry an encoded variable map")
		for name, value in pairs(values) do engine[name] = value end
		task.on_done(0, "", "")
	end

	complete(2) -- B's explicit OFF reaches Karabiner first.
	complete(1) -- The stale A ON arrives last after reload/Force Quit.

	package.loaded["platform.remap.ke_variables"] = nil
	package.loaded["platform.remap.lease_contract"] = nil
	package.loaded["platform.remap.lease_controller"] = nil
	package.loaded["platform.remap.ke_paths"] = nil
	package.loaded["infra.logger"] = nil
	package.loaded["adapters.json_codec"] = nil
	package.loaded["adapters.shell_runner"] = nil

	return engine
end





-- =============================================
-- =============================================
-- ======= 2/ Exact-Generation Isolation =======
-- =============================================
-- =============================================

helpers.describe("karabiner runtime variables: cross-generation isolation", function()
	local cases = {
		{ logical_name = "layer_active", personal_value = 73 },
		{ logical_name = "capsword", personal_value = 91 },
	}

	for _, case in ipairs(cases) do
		helpers.it(case.logical_name .. " rejects a stale writer from generation A", function()
			local engine = replay_old_writer_after_reload(
				case.logical_name,
				case.personal_value
			)
			helpers.assert_eq(engine[case.logical_name], case.personal_value,
				"Ergopti must never overwrite an untagged personal variable with the same name")
			helpers.assert_eq(engine[scoped_name(case.logical_name, TOKEN_B)], 0,
				"generation B must remain OFF after generation A's delayed writer completes")
		end)
	end
end)
