--- tests/unit/ui/menu/test_program_parameter_transaction.lua

--- Real global writer, preference owner, checkpoint and guarded file publisher.
local helpers = require("tests.helpers")
local SCALAR = '{"version":1,"executable":"/private/secret-tool","arguments":["private-secret-argument"]}'

local function with_owner(body, options)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	local parameters, action = { retained = "unrelated" }, "none"
	local controls, observations = options or {}, { sets = 0, saves = 0, logs = {} }
	local selected = controls.action == nil and "run_program" or controls.action
	local scalar = controls.scalar == nil and SCALAR or controls.scalar
	local function copy(source) local result = {}; for key, value in pairs(source) do result[key] = value end; return result end
	local function receipt(mode)
		if mode == "throw" then error(SCALAR) end
		if mode == "nil" then return nil end
		if mode == "private-return" then return SCALAR end
		return mode ~= "false"
	end
	local ok, failure = xpcall(function()
		local logger = helpers.make_logger_stub()
		for _, severity in ipairs({ "error", "warn", "start", "success", "info", "debug", "done" }) do
			logger[severity] = function(_, template, ...)
				observations.logs[#observations.logs + 1] = string.format(template, ...)
			end
		end
		package.loaded["infra.logger"] = logger
		local gestures = {
			is_assignable = function() return true end,
			get_action_parameter_spec = function(name)
				if controls.spec_changed then return "changed-kind" end
				local row = require("_generated.action_catalogue").actions[name]
				return row and row.parameter
			end,
			validate_action_parameter = function(_, value) return value == scalar end,
			get_all_action_parameters = function() return copy(parameters) end,
			set_action_parameter = function(binding, name, value)
				observations.sets = observations.sets + 1
				parameters[binding .. "__" .. name] = value
				if controls.change_spec_on_parameter then controls.spec_changed = true end
				return receipt(controls.parameter)
			end,
			replace_action_parameters = function(snapshot)
				local acknowledged = receipt(controls.restore_parameters)
				if acknowledged ~= true then return acknowledged end
				parameters = copy(snapshot)
				return true
			end,
		}
		local state = {}
		local owner, publish, files, global, prefs, checkpoint, files_port, original
		owner, publish, files, global, prefs, checkpoint, files_port, original =
			require("tests.support.program_parameter_fixture")(gestures, state, "keyboard", function() return action end, function()
				observations.saves = observations.saves + 1
				if controls.foreign_source then files.config = controls.foreign_source end
				if controls.foreign_parameters then parameters.foreign = "keep" end
				if controls.foreign_assignment then action = "foreign-action" end
				if controls.foreign_revision then checkpoint.replace(checkpoint.capture(), {}, {}) end
				if controls.path_during_save then controls.current_path = "other-config" end
				return receipt(controls.save)
			end, controls)
		local mutation = { publishes_assignment = true, section = "shortcuts.keyboard", key = "cmd_1",
			read = function() return action end,
			apply = function(on_error)
				action = selected
				if publish(action, on_error) ~= true then return false end
				return receipt(controls.assign)
			end,
			restore = function(previous, on_error)
				if controls.partial_restore then
					action = previous
					if publish(previous, on_error) ~= true then return false end
				end
				local acknowledged = receipt(controls.restore_assignment)
				if acknowledged ~= true then return acknowledged end
				action = previous
				return publish(previous, on_error) == true
			end,
		}
		if controls.private_native_exception then
			local publish_file = files_port.write_if_unchanged
			files_port.write_if_unchanged = function(path, value, expected, on_error)
				if value:find("private-secret-argument", 1, true) then
					observations.native_refusals = (observations.native_refusals or 0) + 1
					error(SCALAR)
				end
				return publish_file(path, value, expected, on_error)
			end
		end
		local function apply()
			return owner.apply("keyboard__cmd_1", selected, scalar, mutation)
		end
		controls.reinstate_action = function() action = selected end
		controls.reinstate_parameters = function() parameters["keyboard__cmd_1__" .. selected] = scalar end
		controls.restore_action = function() action = "none" end
		controls.restore_parameters_exact = function() parameters = { retained = "unrelated" } end
		local function inspect()
			return { parameters = copy(parameters), action = action, content = files.config }
		end
		body(owner, apply, inspect, controls, observations, global, files, original, prefs, checkpoint)
	end, debug.traceback)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

helpers.describe("private program retained compensation owner", function()
	helpers.it("keeps actual full publisher exceptions private through its original bound save", function()
		with_owner(function(owner, apply, inspect, _, observations, global, _, original)
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(observations.native_refusals, 1)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(global.is_pending(), false)
			helpers.assert_eq(inspect().content, original)
			for _, line in ipairs(observations.logs) do
				helpers.assert_eq(line:find("private-secret-argument", 1, true), nil)
				helpers.assert_eq(line:find("/private/secret-tool", 1, true), nil)
			end
		end, { private_native_exception = true })
	end)
	helpers.it("adopts its delayed physical inverse only after a post-unlink foreign recreation is removed", function()
		with_owner(function(owner, apply, inspect, controls, _, global, files, _, prefs)
			controls.save = "false"
			controls.after_remove = function(source) source.config = "foreign after unlink" end
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(files.config, "foreign after unlink")
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(files.config, "foreign after unlink")
			files.config = nil
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(global.is_pending(), false)
			helpers.assert_eq(inspect().content, nil)
			helpers.assert_eq(prefs.source_snapshot("config"), { status = "absent" })
		end, { absent = true })
	end)
	helpers.it("retains and retries post-unlink release debt without removing foreign recreation", function()
		with_owner(function(owner, apply, inspect, controls, _, global, files, _, prefs)
			controls.save = "false"
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(inspect().content, nil, "physical inverse ran before native release refused")
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(global.is_pending(), true)
			local loaded = prefs.source_snapshot("config")
			helpers.assert_eq(loaded.status, "ok", "source adoption awaits lock settlement")
			files.config = "foreign recreation"
			controls.remove_release_failure = false
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(files.config, "foreign recreation")
			files.config = nil
			controls.false_remove_settlement = true
			helpers.assert_eq(owner.retry_restore(), false, "a true retry without terminal release readback cannot clear debt")
			helpers.assert_eq(owner.pending(), true)
			controls.false_remove_settlement = false
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(global.is_pending(), false)
			helpers.assert_eq(prefs.source_snapshot("config"), { status = "absent" })
		end, { absent = true, remove_release_failure = true })
	end)
	for _, mode in ipairs({ "cache_throw", "commit_throw", "durable_refusal" }) do
		helpers.it("compensates its actual full save after " .. mode, function()
			local options = { [mode] = true }
			if mode == "durable_refusal" then
				options.snapshot_view = function(snapshot)
					snapshot = require("ui.menu.preferences_transaction").clone(snapshot)
					snapshot.gesture_action_parameters.keyboard__cmd_1__run_program = SCALAR:gsub("secret%-tool", "other-tool")
					return snapshot
				end
			end
			with_owner(function(owner, apply, inspect, _, _, global, _, original, prefs, checkpoint)
				local prior = checkpoint.capture()
				helpers.assert_eq(apply(), false)
				helpers.assert_eq(prefs.publication_receipt("config").id, 1, "the actual full save wrote before refusal")
				helpers.assert_eq(owner.pending(), false, "own publication must be recoverable")
				helpers.assert_eq(global.is_pending(), false)
				helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
				local restored = checkpoint.capture()
				helpers.assert_eq(restored.state, prior.state)
				helpers.assert_eq(restored.preferences, prior.preferences)
			end, options)
		end)
	end

	for _, field in ipairs({ "action", "parameters" }) do
		helpers.it("keeps the fence when compensated " .. field .. " is reinstated before source recovery", function()
			with_owner(function(owner, apply, inspect, controls, _, global, _, original, prefs)
				controls.cache_throw = true
				local replace_source = prefs.replace_source
				prefs.replace_source = function() return false end
				helpers.assert_eq(apply(), false)
				helpers.assert_eq(owner.pending(), true)
				controls["reinstate_" .. field]()
				local reinstated = inspect()
				prefs.replace_source = replace_source
				helpers.assert_eq(owner.retry_restore(), false)
				helpers.assert_eq(owner.pending(), true)
				helpers.assert_eq(global.is_pending(), true)
				helpers.assert_eq(inspect(), reinstated)
				if field == "action" then controls.restore_action() else controls.restore_parameters_exact() end
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(owner.pending(), false)
				helpers.assert_eq(global.is_pending(), false)
				helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
			end)
		end)
	end

	helpers.it("refuses a changed live config path before any native edit", function()
		with_owner(function(owner, apply, inspect, _, observations, _, _, original)
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(observations.sets, 0)
			helpers.assert_eq(observations.saves, 0)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
		end, { current_path = "other-config" })
	end)

	helpers.it("preserves a foreign checkpoint advanced after its own save", function()
		with_owner(function(owner, apply, inspect, controls, _, global, _, _, _, checkpoint)
			controls.after_commit = function() checkpoint.replace(checkpoint.capture(), { foreign = true }, {}) end
			helpers.assert_eq(apply(), false)
			local prior = inspect()
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(global.is_pending(), true)
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(inspect(), prior)
			helpers.assert_eq(checkpoint.capture().state, { foreign = true })
		end)
	end)

	helpers.it("preserves a foreign physical source installed after its own save", function()
		with_owner(function(owner, apply, inspect, controls, _, global, files, original, prefs)
			controls.after_commit = function() files.config = '[foreign]\nkeep = "new edit"\n' end
			helpers.assert_eq(apply(), false)
			local prior = inspect()
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(global.is_pending(), true)
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(inspect(), prior)
			files.config = prefs.source_snapshot("config").content
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(global.is_pending(), false)
			helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
		end)
	end)

	helpers.it("retries its exact own publication after the live path is reinstated", function()
		with_owner(function(owner, apply, inspect, controls, _, global, _, original)
			controls.after_commit = function() controls.current_path = "other-config" end
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(global.is_pending(), true)
			local published = inspect()
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(inspect(), published)
			controls.current_path = nil
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(global.is_pending(), false)
			helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
		end)
	end)

	helpers.it("retains debt after a final source callback reinstates the program", function()
		with_owner(function(owner, apply, _, controls, _, global, _, _, prefs)
			controls.cache_throw = true
			local replace_source = prefs.replace_source
			prefs.replace_source = function(...)
				local acknowledged = replace_source(...)
				controls.reinstate_action()
				return acknowledged
			end
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(global.is_pending(), true)
			helpers.assert_eq(owner.retry_restore(), false)
		end)
	end)

	for _, port in ipairs({ "restore_parameters", "restore_assignment" }) do
		for _, mode in ipairs({ "false", "nil", "throw", "private-return" }) do
			helpers.it("retains the fence after " .. port .. " " .. mode .. " and recovers exact absence", function()
				with_owner(function(owner, apply, inspect, controls, observations, global, _, original)
					controls.save, controls[port] = "false", mode
					helpers.assert_eq(apply(), false)
					helpers.assert_eq(owner.pending(), true)
					helpers.assert_eq(global.is_pending(), true)
					local calls = observations.sets
					helpers.assert_eq(apply(), false, "another candidate cannot write through retained debt")
					helpers.assert_eq(observations.sets, calls)
					local foreign_calls = 0
					helpers.assert_eq(global.run_exclusive("Other preference", function() foreign_calls = foreign_calls + 1; return true end), false)
					helpers.assert_eq(foreign_calls, 0)
					controls[port] = nil
					helpers.assert_eq(owner.retry_restore(), true)
					helpers.assert_eq(owner.pending(), false)
					helpers.assert_eq(global.is_pending(), false)
					helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
					for _, line in ipairs(observations.logs) do
						helpers.assert_eq(line:find("secret-tool", 1, true), nil)
						helpers.assert_eq(line:find("private-secret-argument", 1, true), nil)
					end
				end)
			end)
		end
	end

	helpers.it("restores proven file absence after a domain setter created the file", function()
		with_owner(function(owner, apply, inspect, controls)
			controls.save = "false"
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none" })
		end, { absent = true })
	end)

	helpers.it("retries an inverse that published its native state before throwing", function()
		with_owner(function(owner, apply, inspect, controls, _, global, _, original)
			controls.save, controls.restore_assignment, controls.partial_restore = "false", "throw", true
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(global.is_pending(), true)
			controls.restore_assignment = nil
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
		end)
	end)

	helpers.it("preserves a foreign native assignment while recovery remains fenced", function()
		with_owner(function(owner, apply, inspect, controls)
			controls.save, controls.foreign_assignment = "false", true
			helpers.assert_eq(apply(), false)
			local prior = inspect()
			helpers.assert_eq(prior.action, "foreign-action")
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(inspect(), prior)
		end)
	end)

	helpers.it("preserves a foreign physical edit while exact recovery remains fenced", function()
		with_owner(function(owner, apply, inspect, controls, observations, global, files, original, prefs)
			local foreign = '[foreign]\nkeep = "unrelated edit"\n'
			controls.save, controls.foreign_source = "false", foreign
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(files.config, foreign)
			local prior = inspect()
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(inspect(), prior, "foreign state must survive even native compensation")
			helpers.assert_eq(global.is_pending(), true)
			files.config = prefs.source_snapshot("config").content
			controls.foreign_source = nil
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
		end)
	end)

	helpers.it("preserves a foreign parameter mutation while exact recovery remains fenced", function()
		with_owner(function(owner, apply, inspect, controls)
			controls.save, controls.foreign_parameters = "false", true
			helpers.assert_eq(apply(), false)
			local prior = inspect()
			helpers.assert_eq(prior.parameters.foreign, "keep")
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(inspect(), prior)
		end)
	end)

	helpers.it("refuses compensation over a newer publication checkpoint", function()
		with_owner(function(owner, apply, inspect, controls)
			controls.save, controls.foreign_revision = "false", true
			helpers.assert_eq(apply(), false)
			local prior = inspect()
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(inspect(), prior)
		end)
	end)

	helpers.it("keeps privacy closed for parameter and assignment throws and arbitrary returns", function()
		for _, stage in ipairs({ "parameter", "assign", "save" }) do
			for _, mode in ipairs({ "throw", "private-return" }) do
				with_owner(function(owner, apply, _, controls, observations)
					controls[stage] = mode
					helpers.assert_eq(apply(), false)
					helpers.assert_eq(owner.pending(), false)
					for _, line in ipairs(observations.logs) do
						helpers.assert_eq(line:find("secret-tool", 1, true), nil)
						helpers.assert_eq(line:find("private-secret-argument", 1, true), nil)
					end
				end)
			end
		end
	end)
end)


helpers.describe("parameterized assignment uses the retained owner", function()
	for _, stage in ipairs({ "parameter", "assign", "save" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("(action-parameter-atomicity) restores open_url after " .. stage .. " " .. mode, function()
				with_owner(function(owner, apply, inspect, _, _, global, _, original)
					helpers.assert_eq(apply(), false)
					helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
					helpers.assert_eq(owner.pending(), false)
					helpers.assert_eq(global.is_pending(), false)
				end, { action = "open_url", scalar = "https://example.com", [stage] = mode })
			end)
		end
	end
	helpers.it("(action-parameter-atomicity) publishes a non-program scalar and exact assignment", function()
		with_owner(function(owner, apply, inspect, _, observations, global)
			helpers.assert_eq(apply(), true)
			helpers.assert_eq(inspect().action, "open_url")
			helpers.assert_eq(inspect().parameters, { retained = "unrelated", keyboard__cmd_1__open_url = "https://example.com" })
			helpers.assert_eq(observations.saves, 1)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(global.is_pending(), false)
		end, { action = "open_url", scalar = "https://example.com" })
	end)
	helpers.it("(action-parameter-atomicity) does not grant parameter ownership to an unparameterized action", function()
		with_owner(function(_, apply, inspect, _, observations, _, _, original)
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
			helpers.assert_eq(observations.sets, 0)
		end, { action = "copy_selection", scalar = "https://example.com" })
	end)
	helpers.it("(action-parameter-atomicity) retains compensation when the original catalogue observation changes", function()
		with_owner(function(owner, apply, inspect, controls, observations, global, _, original)
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(inspect().action, "none")
			helpers.assert_eq(observations.saves, 0)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(global.is_pending(), true)
			controls.spec_changed = false
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(inspect(), { parameters = { retained = "unrelated" }, action = "none", content = original })
		end, { action = "open_url", scalar = "https://example.com", change_spec_on_parameter = true })
	end)
end)


helpers.describe("parameter transaction keeps physical assignments with their scope owner", function()
	helpers.it("(action-parameter-physical-scope) recognizes the original shared namespace including malformed slots", function()
		local physical = require("shortcuts.physical_slots")
		helpers.assert_eq(physical.is_namespace("physical_none_KeyA"), true)
		helpers.assert_eq(physical.is_namespace("physical_broken"), true)
		helpers.assert_eq(physical.is_namespace("cmd_1"), false)
		helpers.assert_eq(physical.is_namespace(nil), false)
	end)
	for _, action in ipairs({ "run_program", "open_url" }) do
		for _, slot in ipairs({ "physical_none_KeyA", "physical_broken" }) do
			for _, route in ipairs({ "binding", "mutation" }) do
				helpers.it("(action-parameter-physical-scope) refuses " .. action .. " physical " .. route .. " " .. slot .. " before transaction ports", function()
					helpers.with_stub_scope({ "infra.logger", "ui.menu.program_parameter_transaction" }, function()
						package.loaded["infra.logger"] = helpers.make_logger_stub()
						package.loaded["ui.menu.program_parameter_transaction"] = nil
						local calls = { admission = 0, parameter = 0, assignment = 0, save = 0, source = 0 }
						local function port(name)
							return function()
								calls[name] = calls[name] + 1
								error("unsupported physical transaction reached " .. name)
							end
						end
						local owner = require("ui.menu.program_parameter_transaction").new({
							path = "unsupported-physical-config",
							admission = port("admission"), paused = port("source"),
							current_path = port("source"), capture_checkpoint_candidate = port("source"),
							save_prefs = port("save"), checkpoint = { capture = port("source") },
							preferences = { source_snapshot = port("source") },
							files = { read_with_status = port("source") },
							gestures = { set_action_parameter = port("parameter"), get_all_action_parameters = port("source") },
						})
						local binding = route == "binding" and "keyboard__" .. slot or "keyboard__cmd_1"
						local key = route == "mutation" and slot or "cmd_1"
						local called, committed = pcall(owner.apply, binding, action,
							action == "run_program" and SCALAR or "https://example.com", {
								section = "shortcuts.keyboard", key = key,
								read = port("source"), apply = port("assignment"), restore = port("assignment"),
							})
						helpers.assert_eq(called, true, "unsupported domains return refusal before entering any transaction port")
						helpers.assert_eq(committed, false)
						helpers.assert_eq(calls, { admission = 0, parameter = 0, assignment = 0, save = 0, source = 0 })
						helpers.assert_eq(owner.pending(), false)
					end)
				end)
			end
		end
	end
end)
