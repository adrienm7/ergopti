--- tests/unit/modules/keymap/registry/test_registry_field_run_candidates.lua

--- ==============================================================================
--- MODULE: Registry Field Run Hotstring Candidates
--- DESCRIPTION:
--- The field run's hotstring round-trip types the first candidate this list
--- returns, so the list must hold only hotstrings that a plain typed trigger and
--- a Space expand into a known text: enabled, shipped (never a user file),
--- terminator-expanded, a lowercase ASCII trigger no other mapping shares, and
--- a replacement with no token, line break or magic key.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.config_paths", "modules.keymap.registry" }

--- Runs body over a registry holding a shipped group, a user group and a
--- disabled shipped group.
--- @param body function fn(Registry, state).
local function with_registry(body)
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.config_paths"] = { get_config_dir = function() return "/cfg" end }
		package.loaded["modules.keymap.registry"] = nil
		local Registry = helpers.load_with_stubs("modules.keymap.registry")
		local state = {
			magic_key = "\u{2605}", mappings = {}, mappings_lookup = {},
			mappings_by_tail_char = {}, mappings_by_star_tail_char = {},
			groups = {
				shipped = { enabled = true, kind = "toml", path = "/bundle/autocorrection.toml", group_order = 1 },
				user = { enabled = true, kind = "toml", path = "/cfg/mine.toml", group_order = 2 },
				off = { enabled = false, kind = "toml", path = "/bundle/off.toml", group_order = 3 },
			},
			seq_counter = 0, current_group = "shipped", start_is_word_boundary = true,
		}
		Registry.init(state)
		body(Registry, state)
	end)
end

--- The triggers of the candidate list, in order.
--- @param Registry table
--- @return string triggers Comma-joined.
local function triggers(Registry)
	local names = {}
	for _, candidate in ipairs(Registry.field_run_candidates()) do names[#names + 1] = candidate.trigger end
	return table.concat(names, ",")
end

helpers.describe("registry: field run hotstring candidates", function()
	helpers.it("lists a shipped terminator hotstring with its plain expansion", function()
		with_registry(function(Registry)
			Registry.add("axa", "AXA", { is_word = true })
			Registry.sort_mappings()
			local candidates = Registry.field_run_candidates()
			helpers.assert_eq(#candidates, 1)
			helpers.assert_eq(candidates[1].trigger, "axa")
			helpers.assert_eq(candidates[1].expansion, "AXA")
		end)
	end)

	helpers.it("leaves out every hotstring the round-trip could not predict", function()
		with_registry(function(Registry, state)
			Registry.add("axa", "AXA", { is_word = true })
			Registry.add("auto", "AUTO", { auto_expand = true })
			Registry.add("a1b", "AB")
			Registry.add("tok", "{Enter}x")
			Registry.add("brk", "a\nb")
			Registry.add("same", "same")
			Registry.add("sec", "secret", { is_private = true })
			Registry.add("dup", "DUP")
			state.current_group = "user"
			Registry.add("mine", "MINE")
			Registry.add("dup", "OTHER")
			state.current_group = "off"
			Registry.add("off", "OFF")
			Registry.sort_mappings()
			helpers.assert_eq(triggers(Registry), "axa",
				"only the shipped, enabled, plain, unique terminator hotstring may be typed")
		end)
	end)
end)

helpers.describe("registry: field run candidates read each group and section once (field-run-candidates-hold)", function()
	helpers.it("asks a section's state and a group's origin once, not once per mapping", function()
		with_registry(function(Registry)
			for index = 1, 200 do
				local trigger = "w" .. string.char(96 + (index - 1) % 26 + 1) .. string.char(96 + (index - 1) // 26 + 1)
				Registry.add(trigger, trigger:upper(), { is_word = true, section = "common" })
			end
			Registry.sort_mappings()
			local Groups = package.loaded["modules.keymap.registry_groups"]
			local section_reads, origin_reads = 0, 0
			local is_section_enabled, file_origin = Registry.is_section_enabled, Groups.file_origin
			Registry.is_section_enabled = function(...) section_reads = section_reads + 1; return true end
			Groups.file_origin = function(...) origin_reads = origin_reads + 1; return file_origin(...) end
			local ok, candidates = pcall(Registry.field_run_candidates)
			Registry.is_section_enabled, Groups.file_origin = is_section_enabled, file_origin
			helpers.assert_true(ok, tostring(candidates))
			helpers.assert_eq(#candidates, 200)
			-- Per mapping, these reads held the main thread for 1810 ms (field run 2026-10-31).
			helpers.assert_eq(section_reads, 1, "one settings read per section")
			helpers.assert_eq(origin_reads, 1, "one origin read per group")
		end)
	end)
end)
