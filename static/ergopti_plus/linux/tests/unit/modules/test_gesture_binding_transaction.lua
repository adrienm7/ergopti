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

	for name, module in pairs(saved) do package.loaded[name] = module end
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

end)
