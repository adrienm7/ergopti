--- tests/unit/meta/test_prepared_native_port_import_isolation.lua

--- ==============================================================================
--- MODULE: Prepared Native Fixture Import Isolation
--- DESCRIPTION:
--- Independent receiving controls for cold backend caches and exact restoration.
--- These fixed ports prove fixture isolation, not kernel or transport delivery.
--- ==============================================================================

local helpers = require("tests.helpers")
local Ports = require("tests.support.prepared_native_ports")
local target = "adapters.curl_http_client"
local names = { "luv", target, "adapters.shell_runner", "infra.monotonic" }

local function fixture(values, callback)
	local saved, original_require = {}, require
	for _, name in ipairs(names) do
		saved[#saved + 1] = { name = name, value = package.loaded[name] }
		package.loaded[name] = values[name]
	end
	local ok, result = pcall(callback, original_require)
	_G.require = original_require
	for _, entry in ipairs(saved) do package.loaded[entry.name] = entry.value end
	if not ok then error(result, 0) end
end

helpers.describe("prepared native fixture import isolation", function()
	for _, kind in ipairs({ "nil", "false", "table" }) do
		local fixed_kind = kind
		local function values()
			local result = {}
			for _, name in ipairs(names) do
				if fixed_kind == "false" then result[name] = false
				elseif fixed_kind == "table" then result[name] = { original = name } end
			end
			return result
		end
		helpers.it("restores original " .. fixed_kind .. " backend caches after successful import", function()
			local original, returned = values(), {}
			fixture(original, function(original_require)
				_G.require = function(name)
					if name ~= target then return original_require(name) end
					helpers.assert_true(type(package.loaded.luv.new_pipe) == "function")
					package.loaded["adapters.shell_runner"] = { captured_fixture_luv = package.loaded.luv }
					package.loaded["infra.monotonic"] = { captured_fixture_luv = package.loaded.luv }
					package.loaded[target] = returned
					return returned
				end
				local client, state = Ports.fresh_client()
				helpers.assert_true(rawequal(client, returned))
				helpers.assert_true(type(state.requests) == "table")
				for _, name in ipairs(names) do
					helpers.assert_true(rawequal(package.loaded[name], original[name]), name)
				end
			end)
		end)
		helpers.it("restores original " .. fixed_kind .. " backend caches and exact failure object", function()
			local original, failure = values(), { private_failure = true }
			fixture(original, function(original_require)
				_G.require = function(name)
					if name ~= target then return original_require(name) end
					package.loaded["adapters.shell_runner"] = { captured_fixture_luv = package.loaded.luv }
					package.loaded["infra.monotonic"] = { captured_fixture_luv = package.loaded.luv }
					package.loaded[target] = { incomplete = true }
					error(failure, 0)
				end
				local ok, caught = pcall(Ports.fresh_client)
				helpers.assert_eq(ok, false)
				helpers.assert_true(rawequal(caught, failure))
				for _, name in ipairs(names) do
					helpers.assert_true(rawequal(package.loaded[name], original[name]), name)
				end
			end)
		end)
	end

	helpers.it("cold real Curl backend imports do not poison the following actual monotonic module", function()
		fixture({}, function(original_require)
			local calls = 0
			local witness = { hrtime = function() calls = calls + 1; return 123000000 end }
			_G.require = function(name)
				if name == "luv" and package.loaded.luv == nil then return witness end
				return original_require(name)
			end
			local client = Ports.fresh_client()
			helpers.assert_true(type(client.dispatch_owned) == "function")
			helpers.assert_nil(package.loaded["adapters.shell_runner"])
			helpers.assert_nil(package.loaded["infra.monotonic"])
			helpers.assert_nil(package.loaded[target])
			helpers.assert_nil(package.loaded.luv)
			local clock = original_require("infra.monotonic")
			helpers.assert_eq(clock.backend(), "luv.hrtime")
			helpers.assert_eq(clock.now_ms(), 123)
			helpers.assert_eq(calls, 1)
		end)
	end)
end)
