--- tests/unit/platform/remap/test_legacy_rules_removal.lua

--- ==============================================================================
--- MODULE: Legacy Karabiner Rules Removal
--- DESCRIPTION:
--- A Mac upgraded from a pre-lease release keeps, in karabiner.json, rules an
--- older ErgoptiPlus wrote without the managed description marker. When no
--- released block proves them, the merge refuses every deploy (« Merge
--- aborted: 25 ambiguous legacy ErgoptiPlus rules … »), and nothing in the app
--- removed them. The fixture here is that file: the shipped rule graph left
--- untagged in two profiles, around personal rules and one managed rule.
---
--- ROOT CAUSES ENCODED:
--- 1. The refusal was only a message: a caller could not tell it from any
---    other failure without parsing it. The merge and the deploy now also
---    return it as data, { kind = "legacy_conflicts", count, descriptions }.
--- 2. No owner removed those rules. The removal takes exactly the rules the
---    merge reports, in every profile, keeps personal and managed rules byte
---    for byte, backs the original up next to karabiner.json and publishes
---    only over the exact bytes it classified.
--- ==============================================================================

local helpers    = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local TOKEN         = "0123456789abcdef0123456789abcdef"
local OLD_TOKEN     = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local DATA_DIR      = helpers.driver_root() .. "platform/remap/data/"
local KARABINER_DIR = "/ergopti-test/karabiner/"
local KARABINER_OUT = KARABINER_DIR .. "karabiner.json"
-- The historical pause-only rules close the legacy capture; an old normal
-- block never carried them.
local PAUSED_RULE_COUNT = 3

--- A rule the user wrote in Karabiner's own UI.
--- @param description string Rule description.
--- @return table rule
local function personal_rule(description)
	return {
		description = description,
		manipulators = {
			{ type = "basic", from = { key_code = "f18" }, to = { { key_code = "f19" } } },
		},
	}
end

--- A rule an earlier generation of this ErgoptiPlus tagged as managed.
--- @return table rule
local function managed_rule()
	return {
		description = string.format("[ErgoptiPlus managed:%s:normal] earlier generation", OLD_TOKEN),
		manipulators = {
			{
				type = "basic",
				from = { key_code = "a" },
				conditions = {
					{ type = "variable_if", name = "ergopti_mode_" .. OLD_TOKEN, value = 1 },
					{ type = "variable_if", name = "ergopti_revoked_" .. OLD_TOKEN, value = 0 },
				},
				to = { { key_code = "b" } },
			},
		},
	}
end

--- An in-memory karabiner directory over the real shipped data files.
--- @param files table Path -> content for paths under KARABINER_DIR.
--- @return table file_system Adapter double with its observations.
local function memory_file_system(files)
	local fs = { writes = {}, creates = {}, before_publication = nil }
	local function owned(path) return path:sub(1, #KARABINER_DIR) == KARABINER_DIR end
	function fs.read(path)
		if owned(path) then return files[path] end
		return SourceFile.read(path)
	end
	function fs.read_with_status(path)
		if not owned(path) then return SourceFile.read(path), "ok" end
		if files[path] == nil then return nil, "absent" end
		return files[path], "ok"
	end
	function fs.prepare_parent_for_create() return true end
	function fs.create_if_absent(path, content)
		if files[path] ~= nil then return false, "exists", "already exists" end
		files[path] = content
		fs.creates[#fs.creates + 1] = path
		return true, "created"
	end
	function fs.write_if_unchanged(path, content, expected_source)
		local hook = fs.before_publication
		fs.before_publication = nil
		if hook then hook(path) end
		local current = files[path]
		local status = current == nil and "absent" or "ok"
		if type(expected_source) ~= "table" or expected_source.status ~= status
			or (status == "ok" and expected_source.content ~= current) then
			return false, "source changed before publication"
		end
		files[path] = content
		fs.writes[#fs.writes + 1] = path
		return true
	end
	return fs
end

--- Loads the generator, the removal owner and the shipped catalogues.
--- @param files table In-memory karabiner directory.
--- @param run function Receives { Generator, Removal, fs, build }.
local function with_remap(files, run)
	helpers.with_fresh_modules({
		"adapters.file_system",
		"adapters.json_codec",
		"infra.config_paths",
		"infra.keycodes",
		"infra.logger",
		"infra.toml.codec",
		"platform.remap.config",
		"platform.remap.generator",
		"platform.remap.managed_rule_removal",
		"toml_codec",
	}, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.config_paths"] = {
			get_config_dir = function() return "/tmp/ergopti_test" end,
		}
		package.loaded["infra.keycodes"] = {
			to_name                 = function(code) return "key_" .. tostring(code) end,
			F13_KARABINER_RETURN    = 105,
			F14_KARABINER_BACKSPACE = 107,
			F15_KARABINER_ESCAPE    = 113,
			F20_LAYER_NAV_ENTERED   = 90,
			F19_LAYER_NAV_EXITED    = 80,
		}
		local toml_stub = { encode = function() return "" end, decode = function() return {} end }
		package.loaded["toml_codec"] = toml_stub
		package.loaded["infra.toml.codec"] = toml_stub
		local fs = memory_file_system(files)
		package.loaded["adapters.file_system"] = fs

		local Config    = helpers.load_with_stubs("platform.remap.config")
		local Generator = helpers.load_with_stubs("platform.remap.generator")
		local Removal   = helpers.load_with_stubs("platform.remap.managed_rule_removal")
		local keys      = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
		local combos    = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
		local actions   = assert(Config.load_available_actions(DATA_DIR .. "actions.json"))
		local function build()
			local state = Config.build_default_state(keys, combos)
			return Generator.build_karabiner_json(state, actions, keys, combos,
				Config.compute_non_canonical_combos(combos), DATA_DIR, TOKEN)
		end
		run({ Generator = Generator, Removal = Removal, fs = fs, build = build })
	end)
end

--- Writes the upgraded Mac's karabiner.json: the untagged shipped graph in an
--- unselected and in the selected profile, around personal rules, with the
--- selected profile also holding one managed rule.
--- @param legacy_rules table Third return value of build_karabiner_json.
--- @return string content
--- @return table old_block The untagged rules written in each profile.
local function upgraded_karabiner_json(legacy_rules)
	local old_block = {}
	for index = 1, #legacy_rules - PAUSED_RULE_COUNT do old_block[#old_block + 1] = legacy_rules[index] end
	local work_rules = { personal_rule("Work: personal rule") }
	local selected_rules = { personal_rule("Personal: before") }
	for _, rule in ipairs(old_block) do
		work_rules[#work_rules + 1] = rule
		selected_rules[#selected_rules + 1] = rule
	end
	selected_rules[#selected_rules + 1] = managed_rule()
	selected_rules[#selected_rules + 1] = personal_rule("Personal: after")
	local content = hs.json.encode({
		global = { show_in_menu_bar = true },
		profiles = {
			{ name = "Work", selected = false, complex_modifications = { rules = work_rules } },
			{
				name = "Default",
				selected = true,
				complex_modifications = {
					-- Not the two exact historical timings: no released block is provable.
					parameters = { ["basic.to_if_alone_timeout_milliseconds"] = 777, personal_parameter = 42 },
					rules = selected_rules,
				},
			},
		},
	}, true)
	return content, old_block
end

--- Lists the descriptions of one profile's rules.
--- @param content string karabiner.json content.
--- @param profile_index integer Profile index.
--- @return table descriptions
local function profile_descriptions(content, profile_index)
	local config = assert(hs.json.decode(content))
	local descriptions = {}
	for index, rule in ipairs(config.profiles[profile_index].complex_modifications.rules) do
		descriptions[index] = rule.description
	end
	return descriptions
end

--- Counts the occurrences of a description.
--- @param descriptions table Description list.
--- @param expected string Description.
--- @return integer count
local function count_of(descriptions, expected)
	local count = 0
	for _, description in ipairs(descriptions) do
		if description == expected then count = count + 1 end
	end
	return count
end

helpers.describe("legacy Karabiner rules that block every deploy (karabiner-legacy-cleanup)", function()
	helpers.it("the merge reports an unprovable untagged block as legacy_conflicts data (karabiner-legacy-cleanup)",
		function()
			local files = {}
			with_remap(files, function(env)
				local config, build_err, legacy_rules, legacy_context = env.build()
				helpers.assert_true(config ~= nil, "build: " .. tostring(build_err))
				files[KARABINER_OUT] = upgraded_karabiner_json(legacy_rules)
				local original = files[KARABINER_OUT]

				local merged, merge_err, _, _, refusal = env.Generator.merge_into_existing_config(
					config, KARABINER_OUT, legacy_rules, legacy_context)
				helpers.assert_nil(merged, "the unprovable block must still refuse the merge")
				helpers.assert_true(tostring(merge_err):find("ambiguous legacy ErgoptiPlus rules", 1, true) ~= nil,
					"the diagnostic is unchanged: " .. tostring(merge_err))
				helpers.assert_type(refusal, "table", "the refusal must be recognisable without parsing the message")
				helpers.assert_eq(refusal.kind, "legacy_conflicts")
				helpers.assert_eq(refusal.kind, env.Generator.REFUSAL_LEGACY_CONFLICTS)
				helpers.assert_eq(refusal.count, #refusal.descriptions)
				helpers.assert_true(refusal.count > 2, "every signature-carrying rule of both profiles is reported")
				helpers.assert_true(count_of(refusal.descriptions, "CapsWord — toggle and deactivation") == 2,
					"the CapsWord anchor of both profiles is reported")
				helpers.assert_eq(files[KARABINER_OUT], original, "a refusal writes nothing")

				local deployed, detail, attempts, deploy_refusal = env.Generator.merge_and_deploy_config(
					config, KARABINER_OUT, legacy_rules, legacy_context)
				helpers.assert_eq(deployed, false)
				helpers.assert_true(tostring(detail):find("ambiguous legacy", 1, true) ~= nil)
				helpers.assert_eq(attempts, 1)
				helpers.assert_type(deploy_refusal, "table", "the deploy passes the refusal on")
				helpers.assert_eq(deploy_refusal.kind, "legacy_conflicts")
				helpers.assert_eq(deploy_refusal.count, refusal.count)
				helpers.assert_eq(files[KARABINER_OUT], original)
			end)
		end)

	helpers.it("every other merge failure carries no refusal (karabiner-legacy-cleanup)", function()
		local files = { [KARABINER_OUT] = "{ not JSON" }
		with_remap(files, function(env)
			local config, build_err, legacy_rules, legacy_context = env.build()
			helpers.assert_true(config ~= nil, "build: " .. tostring(build_err))
			local deployed, _, _, refusal = env.Generator.merge_and_deploy_config(
				config, KARABINER_OUT, legacy_rules, legacy_context)
			helpers.assert_eq(deployed, false)
			helpers.assert_nil(refusal, "only the legacy-signature refusal is offered for removal")
		end)
	end)

	helpers.it("removes exactly the reported rules in every profile, with a backup (karabiner-legacy-cleanup)",
		function()
			local files = {}
			with_remap(files, function(env)
				local config, build_err, legacy_rules, legacy_context = env.build()
				helpers.assert_true(config ~= nil, "build: " .. tostring(build_err))
				files[KARABINER_OUT] = upgraded_karabiner_json(legacy_rules)
				local original = files[KARABINER_OUT]
				local _, _, _, _, refusal = env.Generator.merge_into_existing_config(
					config, KARABINER_OUT, legacy_rules, legacy_context)
				helpers.assert_type(refusal, "table")

				local ok, detail, removed_count, backup_path = env.Removal.remove_legacy_rules(
					KARABINER_OUT, legacy_context)
				helpers.assert_eq(ok, true, "removal: " .. tostring(detail))
				helpers.assert_eq(detail, "removed")
				helpers.assert_eq(removed_count, refusal.count, "exactly the rules the merge reported")

				helpers.assert_type(backup_path, "string")
				helpers.assert_eq(backup_path:sub(1, #KARABINER_OUT), KARABINER_OUT,
					"the backup lies next to karabiner.json")
				helpers.assert_eq(files[backup_path], original, "the backup holds the original bytes")

				local published = files[KARABINER_OUT]
				local reported = {}
				for _, description in ipairs(refusal.descriptions) do reported[description] = true end
				local removed_total = 0
				for _, profile_index in ipairs({ 1, 2 }) do
					local before = profile_descriptions(original, profile_index)
					local after = profile_descriptions(published, profile_index)
					removed_total = removed_total + #before - #after
					for _, description in ipairs(before) do
						local expected = reported[description] and 0 or count_of(before, description)
						helpers.assert_eq(count_of(after, description), expected,
							string.format("profile %d keeps only unreported rules: %s", profile_index, description))
					end
				end
				helpers.assert_eq(removed_total, refusal.count, "nothing but the reported rules left the file")

				local work = profile_descriptions(published, 1)
				local selected = profile_descriptions(published, 2)
				helpers.assert_eq(work[1], "Work: personal rule", "the unselected profile keeps its own rule")
				helpers.assert_eq(selected[1], "Personal: before")
				helpers.assert_eq(selected[#selected], "Personal: after")
				helpers.assert_eq(count_of(selected,
					string.format("[ErgoptiPlus managed:%s:normal] earlier generation", OLD_TOKEN)), 1,
					"a managed rule is the merge's to replace, not this removal's")

				-- The merge that refused the file now accepts it.
				local merged, merge_err, _, _, second_refusal = env.Generator.merge_into_existing_config(
					config, KARABINER_OUT, legacy_rules, legacy_context)
				helpers.assert_true(merged ~= nil, "merge after removal: " .. tostring(merge_err))
				helpers.assert_nil(second_refusal)
				local deployed, deploy_detail = env.Generator.merge_and_deploy_config(
					config, KARABINER_OUT, legacy_rules, legacy_context)
				helpers.assert_eq(deployed, true, "deploy after removal: " .. tostring(deploy_detail))
				local deployed_selected = profile_descriptions(files[KARABINER_OUT], 2)
				helpers.assert_eq(deployed_selected[1], "Personal: before")
				helpers.assert_eq(deployed_selected[#deployed_selected], "Personal: after")
			end)
		end)

	helpers.it("keeps every kept rule byte for byte (karabiner-legacy-cleanup)", function()
		local files = {}
		with_remap(files, function(env)
			local _, _, legacy_rules, legacy_context = env.build()
			-- Hand-written bytes Karabiner or an editor could leave: odd spacing,
			-- a key order the encoder would not produce, an escaped slash.
			local personal = '{"manipulators":[{"type":"basic","from":{"key_code":"f18"},'
				.. '"to":[{"shell_command":"open -a \\/Applications\\/Notes.app"}]}],'
				.. '  "description"  :  "Hand-written"}'
			local capsword = hs.json.encode(legacy_rules[1])
			helpers.assert_true(capsword:find("CapsWord", 1, true) ~= nil,
				"the first legacy rule is the CapsWord anchor")
			files[KARABINER_OUT] = '{"profiles":[{"name":"Default","selected":true,'
				.. '"complex_modifications":{"rules":[' .. personal .. ',\n' .. capsword .. ']}}]}'
			local ok, detail, removed_count = env.Removal.remove_legacy_rules(KARABINER_OUT, legacy_context)
			helpers.assert_eq(ok, true, "removal: " .. tostring(detail))
			helpers.assert_eq(removed_count, 1)
			helpers.assert_eq(files[KARABINER_OUT], '{"profiles":[{"name":"Default","selected":true,'
				.. '"complex_modifications":{"rules":[' .. personal .. ']}}]}',
				"only the legacy rule and its separator leave the file")
		end)
	end)

	helpers.it("refuses, without publishing, when karabiner.json changed after it was read (karabiner-legacy-cleanup)",
		function()
			local files = {}
			with_remap(files, function(env)
				local _, _, legacy_rules, legacy_context = env.build()
				files[KARABINER_OUT] = upgraded_karabiner_json(legacy_rules)
				local concurrent = '{"profiles":[{"name":"Edited meanwhile","selected":true}]}'
				env.fs.before_publication = function(path) files[path] = concurrent end
				local ok, detail, removed_count = env.Removal.remove_legacy_rules(KARABINER_OUT, legacy_context)
				helpers.assert_eq(ok, false, "a changed source must refuse the publication")
				helpers.assert_true(tostring(detail):find("publication refused", 1, true) ~= nil,
					"the refusal is precise: " .. tostring(detail))
				helpers.assert_eq(removed_count, 0)
				helpers.assert_eq(files[KARABINER_OUT], concurrent, "the concurrent write is never overwritten")
				helpers.assert_eq(#env.fs.writes, 0)
			end)
		end)

	helpers.it("writes nothing when no reported rule is left (karabiner-legacy-cleanup)", function()
		local files = {}
		with_remap(files, function(env)
			local _, _, _, legacy_context = env.build()
			files[KARABINER_OUT] = hs.json.encode({
				profiles = {
					{ name = "Default", selected = true,
						complex_modifications = { rules = { personal_rule("Only mine") } } },
				},
			})
			local original = files[KARABINER_OUT]
			local ok, detail, removed_count, backup_path = env.Removal.remove_legacy_rules(
				KARABINER_OUT, legacy_context)
			helpers.assert_eq(ok, true)
			helpers.assert_eq(detail, "unchanged")
			helpers.assert_eq(removed_count, 0)
			helpers.assert_nil(backup_path, "no backup without a removal")
			helpers.assert_eq(files[KARABINER_OUT], original)
			helpers.assert_eq(#env.fs.creates + #env.fs.writes, 0)
		end)
	end)

	helpers.it("refuses a file it cannot classify, untouched (karabiner-legacy-cleanup)", function()
		local files = {}
		with_remap(files, function(env)
			local _, _, _, legacy_context = env.build()
			for _, content in ipairs({
				"{ not JSON",
				'{"profiles":[{"name":"A","selected":true},{"name":"B","selected":true}]}',
			}) do
				files[KARABINER_OUT] = content
				local ok, detail = env.Removal.remove_legacy_rules(KARABINER_OUT, legacy_context)
				helpers.assert_eq(ok, false, "refused: " .. content)
				helpers.assert_type(detail, "string")
				helpers.assert_eq(files[KARABINER_OUT], content)
			end
			local ok, detail = env.Removal.remove_legacy_rules(KARABINER_OUT, nil)
			helpers.assert_eq(ok, false, "the merge's context is required")
			helpers.assert_true(tostring(detail):find("context", 1, true) ~= nil)
			helpers.assert_eq(#env.fs.creates + #env.fs.writes, 0)
		end)
	end)
end)
