-- tests/unit/modules/dynamic_hotstrings/test_personal_info_first_boot.lua

--- ==============================================================================
--- MODULE: Personal Information First Boot
--- DESCRIPTION:
--- Proves that a missing personal_info.toml is materialised from the shared
--- placeholders at initialisation (as on macOS), so the editor can capture and
--- save a source on a fresh install, and that an existing file is never replaced.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_all(path)
	local file = assert(io.open(path, "rb"))
	local content = file:read("a")
	file:close()
	return content
end

helpers.describe("personal information first boot (linux)", function()

	helpers.it("(personal-first-boot) creates the missing source so the editor can capture and save", function()
		local directory = os.tmpname()
		os.remove(directory)
		assert(os.execute("mkdir -p '" .. directory .. "'"))
		local path = directory .. "/personal_info.toml"
		local ok, err = pcall(function()
			local manager = helpers.load_module("modules.dynamic_hotstrings.manager")
			helpers.assert_true(manager.init({ trigger_char = "★", personal_info_path = path }),
				"first boot must initialise")
			local receipt, info = manager.capture_info_edit()
			helpers.assert_true(receipt ~= nil, "the editor must obtain a source receipt")
			helpers.assert_eq(info.first_name, require("hotstrings.engine.personal_info.defaults").info.first_name)
			helpers.assert_true(manager.save_info({ first_name = "Ada" }, receipt), "the first save must commit")
			helpers.assert_true(read_all(path):find('first_name = "Ada"', 1, true) ~= nil)
		end)
		os.execute("rm -rf '" .. directory .. "'")
		if not ok then error(err, 0) end
	end)

	helpers.it("(personal-first-boot) never replaces an existing source", function()
		local directory = os.tmpname()
		os.remove(directory)
		assert(os.execute("mkdir -p '" .. directory .. "'"))
		local path = directory .. "/personal_info.toml"
		local file = assert(io.open(path, "wb"))
		file:write('[info]\nfirst_name = "Grace"\n\n[letters]\np = "first_name"\n')
		file:close()
		local before = read_all(path)
		local ok, err = pcall(function()
			local manager = helpers.load_module("modules.dynamic_hotstrings.manager")
			helpers.assert_true(manager.init({ trigger_char = "★", personal_info_path = path }))
			helpers.assert_eq(read_all(path), before)
		end)
		os.execute("rm -rf '" .. directory .. "'")
		if not ok then error(err, 0) end
	end)

end)
