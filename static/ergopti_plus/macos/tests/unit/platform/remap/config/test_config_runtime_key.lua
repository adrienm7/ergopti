--- tests/unit/platform/remap/config/test_config_runtime_key.lua

--- ==============================================================================
--- MODULE: Hidden Karabiner Runtime Key
--- DESCRIPTION:
--- Pins `[karabiner] runtime` of tap_hold.toml (ADR 011): absent means
--- Ergopti's own runtime, `shared` keeps the official application by hand,
--- anything else refuses the file, and an ordinary save keeps the key the user
--- wrote by hand and writes none for the default.
---
--- ROOT CAUSE ENCODED: a typo such as `runtime = "ownd"` must never silently
--- select the other runtime.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a body over a private config file.
--- @param source string TOML source.
--- @param body function Receives { config, path, load, read, errors }.
local function with_file(source, body)
	helpers.with_stub_scope({ "platform.remap.config", "platform.remap.tap_hold_file", "core.fs.adapters.file_system", "infra.logger", "core.logger.engine.shim",
		"core.text.engine.toml_codec", "infra.toml.codec" }, function()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"], package.loaded["core.logger.engine.shim"] = logger, logger
		require("settings.engine.migration.outdated").reset_for_tests()
		local config = helpers.load_with_stubs("platform.remap.config")
		local path = os.tmpname()
		local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
		local function read()
			local handle = assert(io.open(path, "rb")); local text = assert(handle:read("*a")); assert(handle:close())
			return text
		end
		-- The portable writer: publication atomicity is the filesystem adapter's own tested concern.
		local files = require("core.fs.adapters.file_system")
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
	helpers.it("defaults to Ergopti's own runtime for a file that names none", function()
		with_file("[karabiner]\nintegration_enabled = true\n", function(f)
			local state, status = f.load()
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.runtime, "owned")
			helpers.assert_eq(f.config.RUNTIME_DEFAULT, "owned")
		end)
	end)

	helpers.it("defaults to owned when there is no karabiner table at all", function()
		with_file("[tap_hold]\nenabled = true\n", function(f)
			local state = f.load()
			helpers.assert_eq(state.runtime, "owned")
		end)
	end)

	helpers.it("reads an explicit owned runtime and the hand-kept shared one", function()
		with_file('[karabiner]\nruntime = "owned"\n', function(f)
			helpers.assert_eq(f.load().runtime, "owned")
		end)
		with_file('[karabiner]\nruntime = "shared"\n', function(f)
			helpers.assert_eq(f.load().runtime, "shared")
		end)
	end)

	helpers.it("writes no runtime key for the default on an ordinary save", function()
		with_file("[tap_hold]\nenabled = true\n", function(f)
			local state = f.load()
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_eq(f.read():find("runtime", 1, true), nil)
			helpers.assert_eq(f.load().runtime, "owned")
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

helpers.describe("hidden [karabiner] close_other_instances key", function()
	helpers.it("defaults to the decided consent when absent", function()
		with_file('[karabiner]\nruntime = "owned"\n', function(f)
			helpers.assert_eq(f.load().close_other_instances, true)
		end)
		with_file("[tap_hold]\nenabled = true\n", function(f)
			helpers.assert_eq(f.load().close_other_instances, true)
		end)
	end)

	helpers.it("reads an explicit refusal of the consent", function()
		with_file("[karabiner]\nclose_other_instances = false\n", function(f)
			helpers.assert_eq(f.load().close_other_instances, false)
		end)
	end)

	helpers.it("refuses a value that is not a boolean instead of guessing the consent", function()
		for _, literal in ipairs({ '"no"', "0", "1", '"false"' }) do
			with_file("[karabiner]\nclose_other_instances = " .. literal .. "\n", function(f)
				local state, status = f.load()
				helpers.assert_nil(state)
				helpers.assert_eq(status, "error")
				helpers.assert_contains(f.errors[1], "close_other_instances")
			end)
		end
	end)

	helpers.it("keeps a hand-written refusal across an ordinary save", function()
		with_file("[karabiner]\nclose_other_instances = false\n", function(f)
			local state = f.load()
			state.tap_hold_config.tab = { tap = "copy", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_contains(f.read(), "close_other_instances = false")
		end)
	end)

	helpers.it("writes the consent the menu changes, and writes nothing while it is the default", function()
		with_file('[karabiner]\nruntime = "owned"\n', function(f)
			local state = f.load()
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_eq(f.read():find("close_other_instances", 1, true), nil)
			state.close_other_instances = false
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_contains(f.read(), "close_other_instances = false")
			helpers.assert_eq(f.load().close_other_instances, false)
			state.close_other_instances = true
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_contains(f.read(), "close_other_instances = true")
			helpers.assert_eq(f.load().close_other_instances, true)
		end)
	end)
end)
