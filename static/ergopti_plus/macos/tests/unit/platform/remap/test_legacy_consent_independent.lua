--- tests/unit/platform/remap/test_legacy_consent_independent.lua

--- Scope: the executable oracle below is the independent handwritten cleanup
--- corpus. Historical helper definitions are borrowed from the existing removal
--- tests; their original introductory comments do not recover the user's missing
--- 25-rule backup. Filesystem, modal scheduling and lease ports are modeled;
--- actual production Lua owners run, native AppKit/JSON/files are unexecuted here.

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

-- Independently frozen consent expectations; borrowed helper definitions above
-- are byte-exact historical harness, not a regenerated output oracle.
local with_transaction = require("tests.support.remap_transaction_fixture")
local corpus = assert(hs.json.decode(SourceFile.read(helpers.driver_root()
    .. "../../../tools/diagnostics/fixtures/karabiner-legacy-cleanup-acceptance.json")))
local THIRD = [[{"description":"Independent newly inserted signature","manipulators":[{"type":"basic","from":{"key_code":"c"},"conditions":[{"type":"variable_if","name":"ke_held_left_shift","value":1}],"to":[{"key_code":"c"}]}]}]]

local function exercise(mode)
    local files = { [KARABINER_OUT] = corpus.original }
    with_remap(files, function(env)
        local _, _, _, context = env.build()
        local Codec = require("adapters.json_codec")
        local conflicts = assert(env.Generator.find_legacy_signature_conflicts(assert(Codec.decode(corpus.original)), context))
        helpers.assert_eq(#conflicts, 2, "frozen handwritten original has exactly two conflicts")
        local descriptions = { "Authored historical left-command signature", "Authored historical right-option signature" }
        helpers.assert_eq(conflicts[1].description, descriptions[1])
        helpers.assert_eq(conflicts[2].description, descriptions[2])
        local changed = corpus.original
        if mode == "added" then
            local tree = assert(Codec.decode(corpus.original))
            local rules = tree.profiles[2].complex_modifications.rules
            rules[#rules+1] = assert(Codec.decode(THIRD))
            changed = assert(Codec.encode(tree))
        elseif mode == "replaced" then
            changed = corpus.original:gsub("Authored historical right%-option signature", "Independent replacement signature")
        elseif mode == "same_names_changed_rule" then
            changed = corpus.original:gsub('"key_code":"b"', '"key_code":"c"')
        end
        local changed_conflicts = assert(env.Generator.find_legacy_signature_conflicts(assert(Codec.decode(changed)), context))
        helpers.assert_eq(#changed_conflicts, mode == "added" and 3 or 2, "independent count, not source-generated expectation")
        with_transaction(function(fixture)
            local remap, calls = fixture.load_enabled_remap()
            calls.lease_phase = "prepared"
            calls.legacy_context = context
            calls.deploy_override = function()
                return false, "independent legacy refusal", 1, { kind="legacy_conflicts", count=2, descriptions=descriptions, conflicts=conflicts }
            end
            remap.regenerate()
            helpers.assert_eq(remap.legacy_rule_conflicts().count, 2)
            -- The real bridge retains its loaded removal table. Replace only
            -- its fixture function by the ACTUAL captured production remover;
            -- mapping the fixture destination is explicit filesystem modeling.
            local fixture_removal = package.loaded["platform.remap.managed_rule_removal"]
            fixture_removal.remove_legacy_rules = function(path, observed_context, ...)
                helpers.assert_type(path, "string")
                helpers.assert_true(rawequal(observed_context, context))
                return env.Removal.remove_legacy_rules(KARABINER_OUT, context, ...)
            end
            -- Confirmation now reads through the bridge's fixture destination.
            -- Map that ordinary filename to the SAME captured actual-remover
            -- bytes; expectations and actual producer/remover stay unchanged.
            local actual_read = env.fs.read_with_status
            env.fs.read_with_status = function(path)
                if path:match("/karabiner%.json$") then return actual_read(KARABINER_OUT) end
                return actual_read(path)
            end
            package.loaded["adapters.file_system"] = env.fs
            -- Production remover dynamically requires this classifier; retain
            -- the original generator table for remap stubs, add its actual leaf.
            package.loaded["platform.remap.generator"].find_legacy_signature_conflicts = env.Generator.find_legacy_signature_conflicts
            if mode == "missing" or mode == "forged" then
                local capture = remap.legacy_rule_conflicts
                remap.legacy_rule_conflicts = function(...)
                    local summary = capture(...)
                    if summary then summary.confirmation = mode == "forged" and {} or nil end
                    return summary
                end
            end
            local dialogs, shown, outcomes = 0, nil, 0
            package.loaded["infra.i18n"] = {
                get=function(key) return key end,
                format=function(key, ...) local values={key}; for i=1,select("#",...) do values[#values+1]=tostring(select(i,...)) end; return table.concat(values,"|") end,
            }
            package.loaded["infra.dialog_util"] = { block_alert=function(title, body, first)
                dialogs=dialogs+1; shown=body
                helpers.assert_true(body:find("body_other|2|",1,true)~=nil)
                helpers.assert_true(body:find(descriptions[1],1,true)~=nil)
                helpers.assert_true(body:find(descriptions[2],1,true)~=nil)
                -- Models an EXTERNAL file edit while the genuine modal waits;
                -- no assumption about Lua timer reentry or AppKit behavior.
                files[KARABINER_OUT] = changed
                if mode == "record_changed" then remap.regenerate() end
                if mode == "pause" then remap.pause() end
                return first
            end }
            package.loaded["infra.deferred_work"] = { after=function() outcomes=outcomes+1; return true end }
            local cleanup = helpers.with_fresh_modules({ "ui.legacy_rules_cleanup" }, function()
                return require("ui.legacy_rules_cleanup")
            end)
            local deploys = calls.deploy
            helpers.assert_true(cleanup.open(remap))
            if mode == "record_changed" then deploys = deploys + 1 end
            helpers.assert_eq(dialogs, 1)
            helpers.assert_type(shown, "string")
            if mode == "unchanged" then
                helpers.assert_eq(#env.fs.creates, 1)
                helpers.assert_eq(#env.fs.writes, 1)
                helpers.assert_eq(files[KARABINER_OUT], corpus.expected_retained)
                helpers.assert_eq(calls.deploy, deploys+1)
            else
                helpers.assert_eq(#env.fs.creates, 0, "changed consent source must refuse BEFORE backup")
                helpers.assert_eq(#env.fs.writes, 0, "unconfirmed changed source must not publish")
                helpers.assert_eq(files[KARABINER_OUT], changed, "all changed source bytes are preserved")
                helpers.assert_eq(calls.deploy, deploys, "refused consent must not regenerate")
            end
        end)
    end)
end

helpers.describe("independent consent/source freshness",function()
    for _, mode in ipairs({"unchanged", "added", "replaced", "same_names_changed_rule"}) do
        helpers.it(mode, function() exercise(mode) end)
    end
end)

-- Additional owner controls frozen before the generation-invalidation revision.
helpers.describe("independent consent ownership", function()
    for _, mode in ipairs({"missing", "forged", "record_changed", "pause"}) do
        helpers.it(mode, function() exercise(mode) end)
    end
end)
