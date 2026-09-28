--- tests/unit/modules/test_gesture_binding_transaction.lua

--- ==============================================================================
--- MODULE: Gesture Binding Transactions
--- DESCRIPTION:
--- Proves that gesture bindings and their parameters become visible only after
--- the shared TOML writer acknowledges the durable transaction.
--- ==============================================================================

local helpers = require("tests.helpers")

local MANAGER = "modules.gestures.manager"
local WRITER = "toml_codec.writer"
local LOGGER = "logger.shim"

--- Runs an isolated gesture manager against one deterministic writer.
--- @param writer table
--- @param body function
local function with_manager(writer, body)
	local saved = {
		[MANAGER] = package.loaded[MANAGER],
		[WRITER] = package.loaded[WRITER],
		[LOGGER] = package.loaded[LOGGER],
	}
	package.loaded[MANAGER] = nil
	package.loaded[WRITER] = writer
	package.loaded[LOGGER] = helpers.make_logger_stub()

	local ok, result = pcall(function()
		local manager = require(MANAGER)
		manager.init({ enabled = false, persist = false })
		return body(manager)
	end)

	for _, name in ipairs({ MANAGER, WRITER, LOGGER }) do package.loaded[name] = saved[name] end
	if not ok then error(result, 0) end
	return result
end

--- Returns a writer that records the attempted batch and rejects publication.
--- @param detail string
--- @return table, table
local function rejecting_writer(detail)
	local calls = {}
	return {
		batch_write = function(path, updates)
			calls[#calls + 1] = { path = path, updates = updates }
			return false, detail
		end,
	}, calls
end

local function enable_persistence(manager, path)
	manager.init({
		enabled = false,
		persist = true,
		config_path = path or "/tmp/ergopti-gesture-transaction.toml",
	})
end

helpers.describe("gestures: durable binding transactions", function()
	helpers.it("gesture-scope-state: restores detached assignments and parameters without saving", function()
		with_manager({ batch_write = function() error("the runtime owner must not publish") end }, function(manager)
			manager.set_action("tap_3", "enter")
			manager.set_action_parameter("tap_3", "open_url", "https://original.example")
			local snapshot = manager.capture_scope_state()
			manager.set_action("tap_3", "vol_up")
			manager.set_action_parameter("tap_3", "open_url", "https://candidate.example")
			enable_persistence(manager)
			helpers.assert_true(manager.apply_scope_state(snapshot))
			helpers.assert_eq(manager.get_action("tap_3"), "enter")
			helpers.assert_eq(manager.get_action_parameter("tap_3", "open_url"), "https://original.example")
			snapshot.actions.tap_3 = "vol_up"
			snapshot.parameters.tap_3__open_url = "https://mutated.example"
			helpers.assert_eq(manager.get_action("tap_3"), "enter", "runtime never borrows caller maps")
			helpers.assert_eq(manager.get_action_parameter("tap_3", "open_url"), "https://original.example")
		end)
	end)

	helpers.it("gesture-scope-state: validates the whole candidate before releasing a reader", function()
		with_manager({}, function(manager)
			manager._test_begin_reading({})
			helpers.assert_true(manager.enable())
			local snapshot = manager.capture_scope_state()
			snapshot.enabled, snapshot.reading = false, false
			snapshot.actions.tap_3 = "unknown_action"
			local stops = 0
			manager.stop_reading = function() stops = stops + 1 end
			helpers.assert_eq(manager.apply_scope_state(snapshot), false)
			helpers.assert_eq(stops, 0)
			helpers.assert_eq(manager.is_enabled(), true)
		end)
	end)

	helpers.it("gesture-scope-state: a refused reader acquisition publishes no candidate assignments", function()
		with_manager({}, function(manager)
			manager.set_action("tap_3", "enter")
			local candidate = manager.capture_scope_state()
			candidate.enabled, candidate.reading = true, true
			candidate.actions.tap_3 = "vol_up"
			manager.start_reading = function() return false end
			helpers.assert_eq(manager.apply_scope_state(candidate), false)
			helpers.assert_eq(manager.is_enabled(), false)
			helpers.assert_eq(manager.get_action("tap_3"), "enter")
		end)
	end)

	helpers.it("gesture-scope-state: clear requires the reader to acknowledge its stopped state", function()
		with_manager({}, function(manager)
			manager._test_begin_reading({})
			helpers.assert_true(manager.enable())
			local candidate = manager.capture_scope_state()
			candidate.enabled, candidate.reading = false, false
			candidate.actions.tap_3 = "vol_up"
			manager.stop_reading = function() end
			helpers.assert_eq(manager.apply_scope_state(candidate), false)
			helpers.assert_eq(manager.get_action("tap_3"), "none")
		end)
	end)

	helpers.it("retains one binding when the staging file cannot open", function()
		local writer, calls = rejecting_writer("cannot open staging file")
		with_manager(writer, function(manager)
			manager.set_action("tap_3", "enter")
			enable_persistence(manager)

			local committed = manager.set_action("tap_3", "vol_up")

			helpers.assert_eq(committed, false, "the setter must surface the rejected write")
			helpers.assert_eq(manager.get_action("tap_3"), "enter",
				"a failed write must retain the previously published binding")
			helpers.assert_eq(#calls, 1, "one binding change must request one atomic batch")
		end)
	end)

	helpers.it("retains one parameter when staging write fails", function()
		local writer, calls = rejecting_writer("write failed")
		with_manager(writer, function(manager)
			manager.set_action_parameter("tap_3", "open_url", "https://old.example/path")
			enable_persistence(manager)

			local committed = manager.set_action_parameter(
				"tap_3",
				"open_url",
				"https://new.example/path"
			)

			helpers.assert_eq(committed, false, "the parameter setter must surface the rejected write")
			helpers.assert_eq(
				manager.get_action_parameter("tap_3", "open_url"),
				"https://old.example/path",
				"a failed write must retain the previously published parameter"
			)
			helpers.assert_eq(#calls, 1, "one parameter change must request one atomic batch")
		end)
	end)

	helpers.it("retains every binding when reset publication cannot close", function()
		local writer, calls = rejecting_writer("close failed")
		with_manager(writer, function(manager)
			manager.set_action("tap_3", "enter")
			manager.set_action("swipe_3_left", "vol_up")
			enable_persistence(manager)

			local committed = manager.reset_defaults()

			helpers.assert_eq(committed, false, "reset must surface the rejected write")
			helpers.assert_eq(manager.get_action("tap_3"), "enter")
			helpers.assert_eq(manager.get_action("swipe_3_left"), "vol_up")
			helpers.assert_eq(#calls, 1, "reset must persist every slot in one atomic batch")
		end)
	end)

	helpers.it("retains every binding when disable-all publication cannot rename", function()
		local writer, calls = rejecting_writer("rename failed")
		with_manager(writer, function(manager)
			manager.set_action("tap_3", "enter")
			manager.set_action("swipe_3_left", "vol_up")
			enable_persistence(manager)

			local committed = manager.disable_all_actions()

			helpers.assert_eq(committed, false, "disable-all must surface the rejected write")
			helpers.assert_eq(manager.get_action("tap_3"), "enter")
			helpers.assert_eq(manager.get_action("swipe_3_left"), "vol_up")
			helpers.assert_eq(#calls, 1, "disable-all must persist every slot in one atomic batch")
		end)
	end)

	helpers.it("restores the old durable binding after a rejected change and restart", function()
		local path = os.tmpname()
		local file = assert(io.open(path, "w"))
		file:write("[gestures]\ntap_3 = \"enter\"\n")
		file:close()
		local writer = rejecting_writer("rename failed")

		local ok, err = pcall(function()
			with_manager(writer, function(manager)
				enable_persistence(manager, path)
				helpers.assert_eq(manager.get_action("tap_3"), "enter")
				helpers.assert_eq(manager.set_action("tap_3", "vol_up"), false)
				helpers.assert_eq(manager.get_action("tap_3"), "enter")

				package.loaded[MANAGER] = nil
				local restarted = require(MANAGER)
				restarted.init({ enabled = false, persist = true, config_path = path })
				helpers.assert_eq(restarted.get_action("tap_3"), "enter",
					"restart must expose the durable binding, not the rejected candidate")
			end)
		end)

		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("unknown-action: refused at assignment, so nothing reverts at restart", function()
		-- Regression: set_action() warned but committed an unknown action,
		-- while the load silently dropped it — so the binding reverted on
		-- every restart and the save looked intermittently broken. The fix
		-- that kept it bound made a stored no-op instead. The id is now refused
		-- where the user makes the choice, as Windows refuses it: nothing is
		-- written, the durable binding stays, and a restart shows the same one.
		local path = os.tmpname()
		os.remove(path)
		local saved = {
			[MANAGER] = package.loaded[MANAGER],
			[LOGGER] = package.loaded[LOGGER],
		}
		package.loaded[MANAGER] = nil
		package.loaded[LOGGER] = helpers.make_logger_stub()

		local ok, err = pcall(function()
			local manager = require(MANAGER)
			manager.init({ enabled = false, persist = true, config_path = path })
			helpers.assert_true(manager.set_action("tap_3", "enter"), "a catalogue id is stored")
			helpers.assert_eq(manager.set_action("tap_3", "future_action_xyz"), false,
				"an id the catalogue does not offer must be refused, not stored as a no-op")
			helpers.assert_eq(manager.get_action("tap_3"), "enter", "the refusal leaves the binding alone")

			package.loaded[MANAGER] = nil
			local restarted = require(MANAGER)
			restarted.init({ enabled = false, persist = true, config_path = path })
			helpers.assert_eq(restarted.get_action("tap_3"), "enter",
				"the durable binding survives the restart — nothing reverts")
		end)

		for name, module in pairs(saved) do package.loaded[name] = module end
		os.remove(path)
		if not ok then error(err, 0) end
	end)

end)
