--- tests/unit/platform/remap/test_native_karabiner_config_fixture.lua
--- Portable lifecycle regression for the native diagnostic, not native evidence.
local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local NONCE = "0123456789abcdef0123456789abcdef"
local SOURCE = "{\"foreign\":true}\n"
local FIXTURE = helpers.driver_root() .. "../../../tools/diagnostics/hs_karabiner_config_native.lua"

local function write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content))
	assert(file:close())
end

local function observe(options)
	options = options or {}
	local destination, receipt = os.tmpname(), os.tmpname()
	os.remove(receipt)
	write(destination, SOURCE)
	local result = { builds = 0, deployments = 0, restores = 0, variants = {} }
	local ok, failure = xpcall(function()
		helpers.with_stub_scope({
			"adapters.json_codec", "infra.logger", "platform.remap.config",
			"platform.remap.generator", "adapters.file_system", "platform.remap.lease_controller",
		}, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local Codec = helpers.load_with_stubs("adapters.json_codec", {
				configdir = "/private/unrelated-hammerspoon-loader",
				processInfo = { processID = 7001, executablePath = "/private/test/Hammerspoon",
					bundleID = "org.hammerspoon.Hammerspoon", version = "1.1.1" },
			})
			package.loaded["platform.remap.config"] = {
				load_available_actions = function(path)
					result.actions_source = SourceFile.read(path)
					return {}
				end,
				load_tap_hold_keys = function(path)
					result.keys_source = SourceFile.read(path)
					return {}
				end,
				load_mod_combos = function(path)
					result.combos_source = SourceFile.read(path)
					return {}
				end,
				compute_non_canonical_combos = function() return {} end,
				build_default_state = function() return { preset = "default" } end,
				build_recommended_state = function() return { preset = "recommended" } end,
			}
			package.loaded["platform.remap.generator"] = {
				build_karabiner_json = function(state)
					result.builds = result.builds + 1
					result.variants[#result.variants + 1] = {
						state.preset, state.tap_holds_enabled, state.mod_combos_enabled,
					}
					if result.builds == options.fail_build then return nil, "independent build refusal" end
					return { ordinal = result.builds }
				end,
				merge_into_existing_config = function(config, path)
					return config, nil, { status = "ok", content = SourceFile.read(path) }
				end,
				merge_and_deploy_config = function(config, path)
					result.deployments = result.deployments + 1
					local encoded = assert(Codec.encode(config))
					if SourceFile.read(path) == encoded then return true, "unchanged", 0 end
					write(path, encoded)
					return true, nil, 1
				end,
			}
			package.loaded["adapters.file_system"] = {
				write_if_unchanged = function(path, content, expected)
					result.restores = result.restores + 1
					result.restore_expected = expected.content
					result.restore_actual = SourceFile.read(path)
					if options.throw_restore then error("independent restoration exception") end
					if options.refuse_restore then return false, "independent restoration refusal" end
					if expected.content ~= result.restore_actual then return false, "source changed" end
					write(path, content)
					return true
				end,
			}
			package.loaded["platform.remap.lease_controller"] = {
				is_initialized = function() return options.initialized == true end,
			}
			local diagnostic = assert(loadfile(FIXTURE))()
			result.returned = diagnostic.run(receipt, destination, NONCE)
			result.receipt = assert(Codec.decode(SourceFile.read(receipt)))
		end)
	end, debug.traceback)
	result.ok, result.failure = ok, failure
	result.source = SourceFile.read(destination)
	local receipt_file = io.open(receipt, "rb")
	result.receipt_exists = receipt_file ~= nil
	if receipt_file then receipt_file:close() end
	os.remove(destination)
	os.remove(receipt)
	os.remove(receipt .. ".pending")
	return result
end

helpers.describe("native Karabiner diagnostic portable lifecycle", function()
	helpers.it("runs all eight independent preset vectors and restores the exact private bytes", function()
		local result = observe()
		helpers.assert_true(result.ok, tostring(result.failure))
		helpers.assert_eq(result.returned, NONCE)
		helpers.assert_eq(result.builds, 8)
		helpers.assert_eq(result.deployments, 16)
		helpers.assert_eq(result.restores, 1)
		helpers.assert_eq(result.restore_expected, result.restore_actual)
		helpers.assert_eq(result.source, SOURCE)
		helpers.assert_true(result.receipt.complete)
		helpers.assert_true(result.receipt.codec_independent)
		helpers.assert_true(result.receipt.native_equal_values_shared)
		helpers.assert_eq(result.actions_source, SourceFile.read(helpers.driver_root() .. "platform/remap/data/actions.json"))
		helpers.assert_eq(result.keys_source, SourceFile.read(helpers.driver_root() .. "platform/remap/data/tap_hold_keys.json"))
		helpers.assert_eq(result.combos_source, SourceFile.read(helpers.driver_root() .. "platform/remap/data/mod_combos.json"))
		helpers.assert_eq(#result.receipt.variants, 8)
		local expected = {
			{ "default", false, false }, { "default", false, true },
			{ "default", true, false }, { "default", true, true },
			{ "recommended", false, false }, { "recommended", false, true },
			{ "recommended", true, false }, { "recommended", true, true },
		}
		for index, vector in ipairs(expected) do
			for field = 1, 3 do helpers.assert_eq(result.variants[index][field], vector[field]) end
		end
	end)

	helpers.it("keeps the build refusal and restores after an actual earlier private publication", function()
		local result = observe({ fail_build = 3 })
		helpers.assert_true(result.ok, tostring(result.failure))
		helpers.assert_eq(result.builds, 3)
		helpers.assert_eq(result.deployments, 4)
		helpers.assert_eq(result.restores, 1)
		helpers.assert_eq(result.source, SOURCE)
		helpers.assert_eq(result.receipt.complete, false)
		helpers.assert_true(result.receipt.private_source_restored)
		helpers.assert_true(result.receipt.errors[1]:find("independent build refusal", 1, true) ~= nil)
		helpers.assert_eq(#result.receipt.variants, 2)
	end)

	helpers.it("preserves primary and restoration refusals and never admits a complete receipt", function()
		local result = observe({ fail_build = 3, refuse_restore = true })
		helpers.assert_true(result.ok, tostring(result.failure))
		helpers.assert_eq(result.receipt.complete, false)
		helpers.assert_eq(result.receipt.private_source_restored, false)
		helpers.assert_true(result.source ~= SOURCE)
		helpers.assert_eq(#result.receipt.errors, 2)
		helpers.assert_true(result.receipt.errors[1]:find("independent build refusal", 1, true) ~= nil)
		helpers.assert_true(result.receipt.errors[2]:find("independent restoration refusal", 1, true) ~= nil)
	end)

	helpers.it("refuses an initialized real lease before building or touching the source", function()
		local result = observe({ initialized = true })
		helpers.assert_eq(result.ok, false)
		helpers.assert_true(result.failure:find("A real lease owner already exists", 1, true) ~= nil)
		helpers.assert_eq(result.builds, 0)
		helpers.assert_eq(result.deployments, 0)
		helpers.assert_eq(result.restores, 0)
		helpers.assert_eq(result.source, SOURCE)
		helpers.assert_eq(result.receipt_exists, false)
	end)

	helpers.it("writes both causes when restoration throws after the primary build refusal", function()
		local result = observe({ fail_build = 3, throw_restore = true })
		helpers.assert_true(result.ok, tostring(result.failure))
		helpers.assert_eq(result.receipt.complete, false)
		helpers.assert_eq(result.receipt.private_source_restored, false)
		helpers.assert_eq(#result.receipt.errors, 2)
		helpers.assert_true(result.receipt.errors[1]:find("independent build refusal", 1, true) ~= nil)
		helpers.assert_true(result.receipt.errors[2]:find("independent restoration exception", 1, true) ~= nil)
	end)
end)
