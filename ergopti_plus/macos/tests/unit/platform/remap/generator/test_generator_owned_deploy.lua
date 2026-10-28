--- tests/unit/platform/remap/generator/test_generator_owned_deploy.lua

--- ==============================================================================
--- MODULE: Generator Owned Deploy
--- DESCRIPTION:
--- Builds the shipped Karabiner configuration and publishes it with
--- Generator.deploy_owned_config, the owned runtime's writer (ADR 011, WP7).
---
--- ROOT CAUSES ENCODED: the owned file belongs to Ergopti alone, so the shared
--- merge (which classifies personal rules and legacy signatures) must not
--- run there; the document is written whole, only to the owned path, and an
--- identical document is never published again because every publication makes
--- Karabiner reload every rule.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local TOKEN = "0123456789abcdef0123456789abcdef"
local DATA_DIR = helpers.driver_root() .. "platform/remap/data/"
local OWNED_OUT = "/ergopti-test/ErgoptiPlus/karabiner/karabiner.json"

--- Loads the generator over a one-file filesystem model.
--- @param existing string|nil Bytes already at the owned path.
--- @param run function Receives { Generator, Config, file_state, config }.
local function with_generator(existing, run)
	helpers.with_fresh_modules({
		"adapters.file_system", "adapters.json_codec", "infra.config_paths", "infra.keycodes", "infra.logger",
		"infra.toml.codec", "platform.remap.config", "platform.remap.generator",
		"modules.keymap.layout_registry", "infra.i18n", "infra.locale", "locale.core", "toml_codec",
	}, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.config_paths"] = { get_config_dir = function() return "/tmp/ergopti_test" end }
		package.loaded["infra.keycodes"] = {
			to_name = function(code) return "key_" .. tostring(code) end,
			F13_KARABINER_RETURN = 105, F14_KARABINER_BACKSPACE = 107, F15_KARABINER_ESCAPE = 113,
			F20_LAYER_NAV_ENTERED = 90, F19_LAYER_NAV_EXITED = 80,
		}
		local toml_stub = { encode = function() return "" end, decode = function() return {} end }
		package.loaded["toml_codec"], package.loaded["infra.toml.codec"] = toml_stub, toml_stub
		local file_state = { content = existing, writes = {}, merged_reads = 0 }
		package.loaded["adapters.file_system"] = {
			read = SourceFile.read,
			read_with_status = function(path)
				if path == OWNED_OUT then
					if file_state.content == nil then return nil, "absent" end
					return file_state.content, "ok"
				end
				return SourceFile.read(path), "ok"
			end,
			prepare_parent_for_create = function() return true end,
			write_if_unchanged = function(path, content, expected)
				file_state.writes[#file_state.writes + 1] = path
				if path ~= OWNED_OUT then return false, "unexpected destination" end
				if expected.status == "ok" and expected.content ~= file_state.content then
					return false, "source changed before publication"
				end
				if expected.status == "absent" and file_state.content ~= nil then
					return false, "source appeared before publication"
				end
				file_state.content = content
				return true
			end,
			write = function(path)
				file_state.writes[#file_state.writes + 1] = path
				return false, "the owned writer is conditional"
			end,
		}
		package.loaded["modules.keymap.layout_registry"] =
			require("tests.support.active_layout_registry_fixture").new("ergopti", "iso")
		local Config = helpers.load_with_stubs("platform.remap.config")
		local Generator = helpers.load_with_stubs("platform.remap.generator")
		local keys = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
		local combos = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
		local state = Config.build_recommended_state(keys, combos)
		local generated, detail = Generator.build_karabiner_json(state,
			assert(Config.load_available_actions(DATA_DIR .. "actions.json")), keys, combos,
			Config.compute_non_canonical_combos(combos), DATA_DIR, TOKEN)
		run({ Generator = Generator, file_state = file_state, generated = assert(generated, detail) })
	end)
end

helpers.describe("Generator.deploy_owned_config", function()
	helpers.it("writes the complete generated document to the owned path only", function()
		with_generator(nil, function(env)
			local deployed, detail, attempts = env.Generator.deploy_owned_config(env.generated, OWNED_OUT)
			helpers.assert_true(deployed, detail)
			helpers.assert_eq(attempts, 1)
			helpers.assert_eq(env.file_state.writes, { OWNED_OUT })
			helpers.assert_eq(hs.json.decode(env.file_state.content).profiles[1].name, env.generated.profiles[1].name)
		end)
	end)

	helpers.it("does not publish an identical document again", function()
		with_generator(nil, function(env)
			helpers.assert_true(env.Generator.deploy_owned_config(env.generated, OWNED_OUT))
			local repeated, detail, attempts = env.Generator.deploy_owned_config(env.generated, OWNED_OUT)
			helpers.assert_true(repeated)
			helpers.assert_eq(detail, "unchanged")
			helpers.assert_eq(attempts, 0)
			helpers.assert_eq(#env.file_state.writes, 1)
		end)
	end)

	helpers.it("replaces whatever the owned file held instead of merging it", function()
		with_generator('{"profiles":[{"name":"Foreign","selected":true}]}', function(env)
			helpers.assert_true(env.Generator.deploy_owned_config(env.generated, OWNED_OUT))
			local written = hs.json.decode(env.file_state.content)
			helpers.assert_true(env.file_state.content:find("Foreign", 1, true) == nil)
			helpers.assert_eq(#written.profiles, #env.generated.profiles)
		end)
	end)

	helpers.it("refuses an invalid document or path and writes nothing", function()
		with_generator(nil, function(env)
			local deployed, detail = env.Generator.deploy_owned_config({ profiles = {} }, OWNED_OUT)
			helpers.assert_eq(deployed, false)
			helpers.assert_true(detail ~= nil)
			helpers.assert_eq(env.Generator.deploy_owned_config(env.generated, ""), false)
			helpers.assert_eq(env.file_state.writes, {})
		end)
	end)

	helpers.it("reports a publication the filesystem refused", function()
		with_generator(nil, function(env)
			env.file_state.content = nil
			local files = require("adapters.file_system")
			files.write_if_unchanged = function() return false, "disk refused" end
			local deployed, detail = env.Generator.deploy_owned_config(env.generated, OWNED_OUT)
			helpers.assert_eq(deployed, false)
			helpers.assert_contains(detail, "disk refused")
		end)
	end)
end)
