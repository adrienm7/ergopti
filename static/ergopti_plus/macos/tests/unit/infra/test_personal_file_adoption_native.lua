--- tests/unit/infra/test_personal_file_adoption_native.lua

--- ==============================================================================
--- MODULE: Native Personal Source Adoption Contract
--- DESCRIPTION:
--- Uses owned physical files for identity, hardlink and retained-source controls.
--- Canonical defaults never grant an unadmitted descriptor execution authority.
--- ==============================================================================

local helpers = require("tests.helpers")
local Files = require("hotstrings.personal_files")
local lfs = require("lfs")

--- Owns physical files and the source-classification adapter for one observation.
--- @param body function
local function fixture(body)
	return helpers.with_stub_scope({ "adapters.file_system", "infra.personal_file_adoption" }, function()
		local root = os.tmpname(); os.remove(root)
		assert(lfs.mkdir(root)); assert(lfs.mkdir(root .. "/a"))
		local paths = { root .. "/a__b.toml", root .. "/a/b.toml", root .. "/personal_hotstrings.toml" }
		for index, path in ipairs(paths) do
			local file = assert(io.open(path, "w")); assert(file:write("[probe]\nentry = \"source" .. index .. "\"\n")); assert(file:close())
		end
		package.loaded["adapters.file_system"] = {
			path_status = function(path)
				local attributes = lfs.symlinkattributes(path)
				return attributes and "present" or "absent", attributes
			end,
			read_with_status = function(path)
				local file = io.open(path, "r"); if not file then return nil, "absent" end
				local content = assert(file:read("*a")); assert(file:close()); return content, "ok"
			end,
		}
		local Adoption = require("infra.personal_file_adoption")
		local records = {
			{ source = Files.describe({ "a__b.toml" }), path = paths[1], legacy_name = "personal_ext_a__b" },
			{ source = Files.describe({ "a", "b.toml" }), path = paths[2], legacy_name = "personal_ext_a__b" },
		}
		local ok, detail = pcall(body, Adoption, records, paths, root)
		for _, path in ipairs(paths) do os.remove(path) end
		os.remove(root .. "/a"); os.remove(root)
		if not ok then error(detail, 0) end
	end)
end

helpers.describe("native personal file adoption", function()
	helpers.it("projects only the ambiguous metadata field as unavailable without changing gate admission", function()
		local Metadata = require("hotstrings.personal_metadata")
		local source = '[_meta]\nDelay = 0.4 # case-distinct field\ncolor = "#aabbcc"\n[probe]\n"entry" = "Source"\n'
		local fields = Metadata.readonly_fields(source)
		helpers.assert_eq(fields, { delay = true, color = false, show_tooltip = false, priority = false })
		helpers.assert_nil(Metadata.prepare(source, nil, "delay", 0.2))
		local plan = assert(Metadata.prepare(source, nil, "color", "112233"))
		helpers.assert_true(plan.content:find('Delay = 0.4 # case-distinct field', 1, true) ~= nil)
	end)
	helpers.it("checks published bytes with an original sibling cohort without admitting them to boot controls", function()
		fixture(function(Adoption, records, paths)
			local staged = assert(Adoption.stage(records, {}, paths[3]))
			local selected = staged[1]
			local candidate = '[probe]\nentry = "owned candidate"\n'
			local temporary = paths[1] .. ".candidate"
			local file = assert(io.open(temporary, "w")); assert(file:write(candidate)); assert(file:close())
			assert(os.rename(temporary, paths[1]))
			helpers.assert_eq(Adoption.current(staged, selected), false)
			helpers.assert_eq(Adoption.published_current(staged, selected, candidate), true)
			helpers.assert_eq(selected.content, '[probe]\nentry = "source1"\n')
			local sibling = assert(io.open(paths[2], "w")); assert(sibling:write(candidate)); assert(sibling:close())
			helpers.assert_eq(Adoption.published_current(staged, selected, candidate), false)
		end)
	end)
	for _, alias in ipairs({ 2, 3 }) do
		helpers.it("refuses published-candidate hardlinks to original source " .. alias, function()
			fixture(function(Adoption, records, paths)
				local staged = assert(Adoption.stage(records, {}, paths[3]))
				local file = assert(io.open(paths[alias])); local candidate = assert(file:read("*a")); assert(file:close())
				assert(os.remove(paths[1])); assert(lfs.link(paths[alias], paths[1], false))
				helpers.assert_eq(Adoption.published_current(staged, staged[1], candidate), false)
			end)
		end)
	end
	helpers.it("refuses exact requested metadata header and field case aliases while retaining distinct literal sections", function()
		local Metadata = require("hotstrings.personal_metadata")
		for _, sample in ipairs({
			{ source = '[_META]\ncolor = "aabbcc"\n[probe]\n"entry" = "Source"\n', field = "color", value = "112233" },
			{ source = '[_meta.sections.team]\ndelay = 0.4\n[[Team]]\n"entry" = "Source"\n', section = "Team", field = "delay", value = 0.2 },
			{ source = '[_meta.sections.Team]\nDelay = 0.4\n[[Team]]\n"entry" = "Source"\n', section = "Team", field = "delay", value = 0.2 },
			{ source = '[_meta.section_delays]\nTeam = 0.4\nteam = 0.8\n[[Team]]\n"entry" = "Source"\n', section = "Team", field = "delay", value = 0.2 },
			{ source = '[_meta.sections."team.Équipe"]\ndelay = 0.4\n[[Team.Équipe]]\n"entry" = "Source"\n', section = "Team.Équipe", field = "delay", value = 0.2 },
		}) do
			local prepared, detail = Metadata.prepare(sample.source, sample.section, sample.field, sample.value)
			helpers.assert_nil(prepared); helpers.assert_eq(detail, "ambiguous-metadata-owner")
		end
		local source = '[[Team]]\n"one" = "One"\n[[team]]\n"two" = "Two"\n'
		local plan = assert(Metadata.prepare(source, "Team", "delay", 0.2))
		local decoded = require("toml_codec").decode(plan.content)
		helpers.assert_eq(decoded._meta.sections.Team.delay, 0.2)
		helpers.assert_nil(decoded._meta.sections.team)
		helpers.assert_true(plan.content:find(source, 1, true) ~= nil)
	end)
	helpers.it("reserves the physical target of a primary symlink against a regular additional hardlink", function()
		fixture(function(Adoption, records, paths, root)
			local target = root .. "/primary-target.bin"
			assert(os.rename(paths[3], target)); assert(lfs.link(target, paths[3], true))
			assert(os.remove(paths[2])); assert(lfs.link(target, paths[2], false))
			local native_attributes = hs.fs.attributes
			hs.fs.attributes = lfs.attributes
			local ok, detail = pcall(function()
				local staged = assert(Adoption.stage(records, {}, paths[3]))
				helpers.assert_eq(staged[2].admitted, false)
				helpers.assert_eq(staged[2].reason, "primary-source-alias")
				helpers.assert_eq(staged[1].admitted, true)
				local file = assert(io.open(target)); helpers.assert_eq(file:read("*a"), '[probe]\nentry = "source3"\n'); assert(file:close())
			end)
			hs.fs.attributes = native_attributes
			os.remove(target)
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("keeps explicit canonical true intent bounded to its admitted legacy scalar owner", function()
		local Plan, Writer = require("hotstrings.personal_adoption"), require("toml_codec.writer")
		local id = "personal-file:615f5f622e746f6d6c"
		local record = { owner = id, source = Files.describe({ "a__b.toml" }), admitted = true, legacy_name = "old" }
		local row = Plan.preference_row(record, "dotted.team", true)
		helpers.assert_eq(row.literal_key, true); helpers.assert_eq(Plan.is_preference_intent(row), true)
		local reads = 0
		local adapter = { read_with_status = function() reads = reads + 1; return '', "ok" end }
		for _, invalid in ipairs({
			{ section = "hotstrings.groups", key = id, value = true, personal_choice = false },
			{ section = "hotstrings.groups", key = id, value = true, personal_choice = "true" },
			{ section = "hotstrings.groups", key = "personal-file:00", value = true, personal_choice = true },
			{ section = "hotstrings.groups", key = id, value = false, personal_choice = true },
			{ section = "hotstrings.groups", key = id, delete = true, personal_choice = true },
		}) do
			helpers.assert_eq(Writer.prepare_batch("/virtual/102-prefs.toml", { invalid }, adapter), false)
		end
		helpers.assert_eq(reads, 0, "invalid intent refuses before any source acquisition")
		record.admitted = false
		local accepted, refusal = pcall(Plan.preference_row, record, nil, true)
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(refusal:match("personal legacy preference needs its captured admitted owner"),
			"personal legacy preference needs its captured admitted owner", "refusal comes from source admission")
		record.admitted = true
		helpers.assert_eq(Plan.preference_row(record, nil, true).personal_choice, true,
			"restoring actual admission permits the same canonical Boolean intent")
	end)
	helpers.it("refuses unsupported quoted rule identities without changing the established reader dialect", function()
		fixture(function(Adoption, records, paths)
			local file = assert(io.open(paths[1], "w"))
			assert(file:write('[["quoted.team"]]\n"entry" = "Source"\n')); assert(file:close())
			local staged = assert(Adoption.stage(records, {}, paths[3]))
			helpers.assert_eq(staged[1].admitted, false)
			helpers.assert_eq(staged[1].reason, "unsupported-rule-identity")
			helpers.assert_eq(staged[2].admitted, true)
		end)
	end)
	helpers.it("plans canonical literal section gates while preserving generic dotted refusals", function()
		local Plan = require("hotstrings.personal_adoption")
		local id = "personal-file:615f5f622e746f6d6c"
		local inventory = { [id] = { "dotted.team", "Équipe", 'quote"section' }, personal = { "probe" } }
		local changes = assert(Plan.plan_gates(inventory, { id }, false))
		helpers.assert_eq(changes, { { group = id, enabled = false }, { group = id, section = "dotted.team", enabled = false },
			{ group = id, section = "Équipe", enabled = false }, { group = id, section = 'quote"section', enabled = false } })
		helpers.assert_nil(Plan.plan_gates(inventory, { "personal" }, true))
		helpers.assert_nil(Plan.plan_gates(inventory, { id, id }, true))
		helpers.assert_nil(Plan.plan_gates({ [id] = { "probe", "probe" } }, { id }, true))
		helpers.assert_nil(require("hotstrings.bulk_scope").plan(inventory, { id }, true))
		helpers.assert_eq(#assert(Plan.plan_selection(inventory, { "personal", id }, true)), 6)
	end)
	helpers.it("parses quoted literal metadata identities without changing rule header semantics", function()
		local parsed, committed = require("toml_codec.reader").parse_text([=[
[_meta.sections."dotted.Équipe"]
delay = 0.2
color = "#aabbcc"
show_tooltip = false
priority = 41
[[_meta_alias]]
"retained" = "value"
[[dotted.Équipe]]
"literal" = "output"
]=])
		helpers.assert_eq(committed, true)
		helpers.assert_eq(parsed.meta.sections["dotted.Équipe"], { description = "", delay = 0.2, color = "#aabbcc", show_tooltip = false, priority = 41 })
		helpers.assert_nil(parsed.meta.sections.dotted)
		helpers.assert_not_nil(parsed.sections["dotted.Équipe"])
	end)
	helpers.it("prepares exact literal metadata and retains inherited legacy settings for siblings", function()
		local source = '# owned neighbor\n[_meta]\nfuture = "retained"\n[_meta.section_delays]\n"dotted.team" = 0.4\nother = 0.8\n[[dotted.team]]\ntrigger = "literal"\nreplacement = "output"\n[other]\n"sibling" = "Sibling"\n'
		local Metadata = require("hotstrings.personal_metadata")
		local plan = assert(Metadata.prepare(source, "dotted.team", "delay", 0.2,
			{ delay = 0.9, sections = { ["dotted.team"] = { delay = 0.7 } } }))
		helpers.assert_eq(plan.remove_file, true); helpers.assert_eq(plan.remove_section, true)
		local parsed, committed = require("toml_codec.reader").parse_text(plan.content)
		helpers.assert_eq(committed, true); helpers.assert_eq(parsed.meta.delay, 0.9)
		helpers.assert_eq(parsed.meta.sections["dotted.team"].delay, 0.2)
		helpers.assert_nil(parsed.meta.section_delays["dotted.team"])
		helpers.assert_eq(parsed.meta.section_delays.other, 0.8)
		helpers.assert_true(plan.content:find('future = "retained"', 1, true) ~= nil)
		helpers.assert_nil(Metadata.prepare(source, "missing", "delay", 0.2))
		for _, bad in ipairs({ -1, math.huge, 0/0 }) do helpers.assert_eq(Metadata.valid("delay", bad), false) end
		helpers.assert_eq(Metadata.valid("color", "#aabbcc"), true)
		helpers.assert_eq(Metadata.valid("color", "aabbcc"), true)
		helpers.assert_eq(Metadata.valid("color", "#xyz123"), false)
		for _, supported in ipairs({ "#abc", "#abcd", "#abcde", "#abcdef0", "#abcdef01" }) do
			helpers.assert_eq(Metadata.valid("color", supported), true, "the existing configuration-window palette remains supported")
		end
		for _, bad in ipairs({ "#f", "#ab", "#abcdef012", "#abcg", "#fff\n", "#abcdef01;" }) do
			helpers.assert_eq(Metadata.valid("color", bad), false)
		end
		for _, bad in ipairs({ -1, 101, 1.5 }) do helpers.assert_eq(Metadata.valid("priority", bad), false) end
	end)
	helpers.it("shares exact descriptor neutral defaults without granting forged identities", function()
		local defaults = require("config_defaults").new({ features = {}, scopes = { hotstrings = { dynamic_defaults = {
			{ prefix = "hotstrings.groups", depth = 1, default = false, recommended = true },
			{ prefix = "hotstrings.modules", depth = 2, default = false, recommended = true },
		} } } })
		local owner = "personal-file:615f5f622e746f6d6c"
		helpers.assert_eq(defaults.default_for("hotstrings.groups." .. owner), true)
		helpers.assert_eq(defaults.default_for("hotstrings.groups.personal-file:zz"), false)
		helpers.assert_eq(defaults.default_for("hotstrings.modules." .. owner .. '."dotted.Équipe"'), true)
		local disabled = defaults.operation("hotstrings.groups." .. owner, false)
		helpers.assert_eq(disabled, { section = "hotstrings.groups", key = owner, value = false })
		helpers.assert_eq(defaults.operation("hotstrings.groups." .. owner, true).delete, true)
		local section = defaults.operation("hotstrings.modules." .. owner .. '."dotted.Équipe"', false)
		helpers.assert_eq(section, { section = 'hotstrings.modules."' .. owner .. '"', key = "dotted.Équipe", value = false, literal_key = true })
	end)
	helpers.it("keeps two historically colliding sources independently active without legacy settings", function()
		fixture(function(Adoption, records, paths)
			local inventory = assert(Adoption.stage(records, {}, paths[3]))
			helpers.assert_eq(inventory[1].owner, "personal-file:615f5f622e746f6d6c")
			helpers.assert_eq(inventory[2].owner, "personal-file:61:622e746f6d6c")
			for _, record in ipairs(inventory) do
				helpers.assert_true(record.admitted)
				helpers.assert_true(Adoption.current(inventory, record))
				helpers.assert_eq(Adoption.preferences(record, {}), true)
			end
		end)
	end)
	for _, legacy in ipairs({ true, false }) do
		helpers.it("refuses ambiguous stored legacy choice " .. tostring(legacy) .. " without fanout", function()
			fixture(function(Adoption, records, paths)
				local saved = { hotstrings = { personal_ext_a__b = legacy, unrelated = true } }
				local inventory = assert(Adoption.stage(records, saved, paths[3]))
				for _, record in ipairs(inventory) do
					helpers.assert_eq(record.admitted, false)
					helpers.assert_eq(record.reason, "ambiguous-legacy-owner")
					helpers.assert_eq(Adoption.current(inventory, record), false)
					helpers.assert_eq(Adoption.preferences(record, saved), false)
				end
				helpers.assert_eq(saved, { hotstrings = { personal_ext_a__b = legacy, unrelated = true } })
			end)
		end)
	end
	helpers.it("retains unique explicit disabled legacy choices and gives canonical choices precedence", function()
		fixture(function(Adoption, records, paths)
			records[2].legacy_name = "personal_ext_nested"
			local saved = { hotstrings = { personal_ext_nested = false }, section_states = { personal_ext_nested = { probe = false, future = true } } }
			local inventory = assert(Adoption.stage(records, saved, paths[3]))
			local enabled, sections = Adoption.preferences(inventory[2], saved)
			helpers.assert_eq(enabled, false); helpers.assert_eq(sections, { probe = false, future = true })
			saved.hotstrings[inventory[2].owner] = true
			saved.section_states[inventory[2].owner] = { probe = true }
			enabled, sections = Adoption.preferences(inventory[2], saved)
			helpers.assert_true(enabled); helpers.assert_eq(sections, { probe = true })
			helpers.assert_eq(saved.section_states.personal_ext_nested, { probe = false, future = true })
		end)
	end)
	for _, target in ipairs({ 1, 3 }) do
		helpers.it("refuses actual hardlink alias to " .. (target == 3 and "primary" or "sibling") .. " source", function()
			fixture(function(Adoption, records, paths)
				assert(os.remove(paths[2]))
				assert(lfs.link(paths[target], paths[2], false))
				local inventory = assert(Adoption.stage(records, {}, paths[3]))
				helpers.assert_eq(inventory[2].admitted, false)
				helpers.assert_eq(inventory[2].reason, target == 3 and "primary-source-alias" or "physical-alias")
				if target == 1 then helpers.assert_eq(inventory[1].admitted, false) end
			end)
		end)
	end
	helpers.it("rejects held admission after a physical source edit and admits an explicit fresh cohort", function()
		fixture(function(Adoption, records, paths)
			local inventory = assert(Adoption.stage(records, {}, paths[3]))
			local file = assert(io.open(paths[1], "a")); assert(file:write("# external edit\n")); assert(file:close())
			helpers.assert_eq(Adoption.current(inventory, inventory[1]), false)
			local reopened = assert(Adoption.stage(records, {}, paths[3]))
			helpers.assert_true(Adoption.current(reopened, reopened[1]))
		end)
	end)
end)
