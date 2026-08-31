--- tests/unit/modules/shortcuts/test_master_state.lua
--- Regression coverage for the durable Linux shortcuts master switch.

local helpers = require("tests.helpers")

local function write(path, content)
	local fh = assert(io.open(path, "w"))
	fh:write(content)
	fh:close()
end

helpers.describe("shortcuts master state", function()

	helpers.it("restores and commits both states across fresh module loads", function()
		local path = os.tmpname()
		write(path, "[shortcuts]\nenabled = false\n")

		local ok, err = pcall(function()
			local Manager = helpers.load_module("modules.shortcuts.manager")
			Manager.init({ persist = true, config_path = path })
			helpers.assert_eq(Manager.is_enabled(), false,
				"the persisted off state must override the shared on default")
			helpers.assert_true(Manager.enable(), "enabling must commit")

			Manager = helpers.load_module("modules.shortcuts.manager")
			Manager.init({ persist = true, config_path = path })
			helpers.assert_eq(Manager.is_enabled(), true,
				"a fresh manager must restore the committed on state")
			helpers.assert_true(Manager.disable(), "disabling must commit")

			Manager = helpers.load_module("modules.shortcuts.manager")
			Manager.init({ persist = true, config_path = path })
			helpers.assert_eq(Manager.is_enabled(), false,
				"a fresh manager must restore the committed off state")
		end)

		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("rejects a state transition when persistence fails", function()
		local blocker = os.tmpname()
		write(blocker, "not a directory")
		local Manager = helpers.load_module("modules.shortcuts.manager")
		Manager.init({
			persist = true,
			config_path = blocker .. "/config.toml",
			enabled = false,
		})

		helpers.assert_eq(Manager.enable(), false,
			"a failed write must reject the transition")
		helpers.assert_eq(Manager.is_enabled(), false,
			"a failed write must not publish a session-only state")
		os.remove(blocker)
	end)

	helpers.it("fails closed when the persisted state is malformed", function()
		local path = os.tmpname()
		write(path, "[shortcuts]\nenabled = maybe\n")
		local Manager = helpers.load_module("modules.shortcuts.manager")
		Manager.init({ persist = true, config_path = path })
		helpers.assert_eq(Manager.is_enabled(), false,
			"invalid config must not activate global bindings from the default")
		os.remove(path)
	end)

end)
