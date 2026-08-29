--- tests/unit/modules/llm/test_mlx_active_model_file.lua

--- =============================================================================
--- MODULE: Regression — MLX active-model file ownership and cache
--- DESCRIPTION:
--- Proves the model identifier read by inference comes from the private config
--- tree and that repeated request construction does not reopen an unchanged
--- file. The real discovery module is loaded; only its filesystem and unrelated
--- network boundaries are replaced.
--- =============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.file_system",
	"adapters.http_client",
	"adapters.json_codec",
	"adapters.shell_runner",
	"adapters.timer_scheduler",
	"infra.config_paths",
	"infra.logger",
	"infra.timings",
	"modules.llm.api_common",
	"modules.llm.api_mlx_discovery",
}

local function with_fixture(run)
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end
	local original_open = io.open
	local secure_path = "/Users/fixture/.config/ergopti_plus/hammerspoon/mlx_active_model.txt"
	local content = "/Users/fixture/model-snapshot"
	local identity = {
		mode = "file",
		dev = 1,
		ino = 2,
		size = #content,
		modification = 10,
		change = 10,
	}
	local effects = { raw_opens = {}, reads = 0, classifications = 0 }

	package.loaded["infra.logger"] = {
		debug = function() end,
		info = function() end,
		warn = function() end,
		error = function() end,
	}
	package.loaded["infra.config_paths"] = {
		get = function(key)
			helpers.assert_eq(key, "MlxActiveModelPath")
			return secure_path
		end,
	}
	package.loaded["adapters.file_system"] = {
		classify_no_follow = function(path)
			effects.classifications = effects.classifications + 1
			helpers.assert_eq(path, secure_path)
			local copy = {}
			for key, value in pairs(identity) do copy[key] = value end
			return copy, "ok"
		end,
		read_with_status = function(path)
			effects.reads = effects.reads + 1
			helpers.assert_eq(path, secure_path)
			return content, "ok"
		end,
	}
	package.loaded["adapters.http_client"] = { new = function() return {} end }
	package.loaded["adapters.json_codec"] = {
		encode = function() return "{}" end,
		decode = function() return {} end,
	}
	package.loaded["adapters.shell_runner"] = {}
	package.loaded["adapters.timer_scheduler"] = {}
	package.loaded["infra.timings"] = { sec = function() return 1 end }
	package.loaded["modules.llm.api_common"] = {
		protected_call = function(callback, _, ...)
			if type(callback) ~= "function" then return false end
			return pcall(callback, ...)
		end,
	}

	io.open = function(path)
		effects.raw_opens[#effects.raw_opens + 1] = path
		return {
			read = function() return content end,
			close = function() return true end,
		}
	end
	package.loaded["modules.llm.api_mlx_discovery"] = nil

	local ok, detail = xpcall(function()
		local Discovery = require("modules.llm.api_mlx_discovery")
		run({
			discovery = Discovery,
			effects = effects,
			secure_path = secure_path,
			set_content = function(value)
				content = value
				identity.size = #value
				identity.modification = identity.modification + 1
				identity.change = identity.change + 1
			end,
		})
	end, debug.traceback)

	io.open = original_open
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	package.loaded["adapters.shell_runner"] = saved["adapters.shell_runner"]
	if not ok then error(detail, 0) end
end

helpers.describe("MLX active-model file ownership", function()
	helpers.it("reads the private path once and invalidates on file identity change", function()
		with_fixture(function(fixture)
			helpers.assert_eq(fixture.discovery.read_active_model_arg(),
				"/Users/fixture/model-snapshot")
			helpers.assert_eq(fixture.discovery.read_active_model_arg(),
				"/Users/fixture/model-snapshot")
			helpers.assert_eq(#fixture.effects.raw_opens, 0,
				"the discovery module must read through the exact filesystem owner")
			helpers.assert_eq(fixture.effects.reads, 1,
				"an unchanged second request must reuse the cached identifier")

			fixture.set_content("/Users/fixture/new-snapshot")
			helpers.assert_eq(fixture.discovery.read_active_model_arg(),
				"/Users/fixture/new-snapshot")
			helpers.assert_eq(fixture.effects.reads, 2,
				"a changed identity must invalidate and refresh the cache")
		end)
	end)
end)

return true
