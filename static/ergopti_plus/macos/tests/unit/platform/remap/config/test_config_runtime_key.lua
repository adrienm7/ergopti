--- tests/unit/platform/remap/config/test_config_runtime_key.lua

--- ==============================================================================
--- MODULE: Hidden Karabiner Runtime Key
--- DESCRIPTION:
--- Pins `[karabiner] runtime` of config_karabiner.toml (ADR 011): absent means
--- the shared runtime, `owned` opts in, anything else refuses the file, and an
--- ordinary save keeps the key the user wrote by hand.
---
--- ROOT CAUSE ENCODED: a typo such as `runtime = "ownd"` must never silently
--- select the other runtime, and the dormant default must not move for any
--- file written before the key existed.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a body over a private config file.
--- @param source string TOML source.
--- @param body function Receives { config, path, load, read, errors }.
local function with_file(source, body)
	helpers.with_stub_scope({ "platform.remap.config", "adapters.file_system", "infra.logger", "logger.shim",
		"toml_codec", "infra.toml.codec" }, function()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
		require("config_outdated").reset_for_tests()
		local config = helpers.load_with_stubs("platform.remap.config")
		local path = os.tmpname()
		local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
		local function read()
			local handle = assert(io.open(path, "rb")); local text = assert(handle:read("*a")); assert(handle:close())
			return text
		end
		-- The portable writer: publication atomicity is the filesystem adapter's own tested concern.
		local files = require("adapters.file_system")
		local function publish(destination, content)
			local handle = assert(io.open(destination, "wb")); assert(handle:write(content)); assert(handle:close())
			return true
		end
		files.write_if_unchanged = function(destination, content) return publish(destination, content) end
		files.write = publish
		local ok, err = pcall(body, { config = config, path = path, errors = errors, read = read,
			load = function() return config.load_user_config({ { id = "tab" } }, {}, path) end })
		os.remove(path); os.remove(path .. ".tmp")
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Karabiner runtime key", function()
	helpers.it("defaults to the shared runtime for a file written before the key existed", function()
		with_file("[karabiner]\nintegration_enabled = true\n", function(f)
			local state, status = f.load()
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.runtime, "shared")
			helpers.assert_eq(f.config.RUNTIME_DEFAULT, "shared")
		end)
	end)

	helpers.it("defaults to shared when there is no karabiner table at all", function()
		with_file("[tap_holds]\nenabled = true\n", function(f)
			local state = f.load()
			helpers.assert_eq(state.runtime, "shared")
		end)
	end)

	helpers.it("reads the explicit opt-in", function()
		with_file('[karabiner]\nruntime = "owned"\n', function(f)
			local state = f.load()
			helpers.assert_eq(state.runtime, "owned")
		end)
	end)

	helpers.it("refuses a misspelled or mistyped value instead of choosing a runtime", function()
		for _, literal in ipairs({ '"ownd"', "true", "1", '"OWNED"', '["owned"]' }) do
			local source = "[karabiner]\nruntime = " .. literal .. "\n"
			with_file(source, function(f)
				local state, status = f.load()
				helpers.assert_nil(state)
				helpers.assert_eq(status, "error")
				helpers.assert_eq(#f.errors, 1)
				helpers.assert_contains(f.errors[1], "runtime")
				helpers.assert_eq(f.read(), source)
			end)
		end
	end)

	helpers.it("keeps a hand-written runtime across an ordinary save", function()
		with_file('[karabiner]\nruntime = "owned"\n', function(f)
			local state = f.load()
			state.tap_hold_config.tab = { tap = "copy", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_contains(f.read(), 'runtime = "owned"')
			helpers.assert_eq(f.load().runtime, "owned")
		end)
	end)
end)
