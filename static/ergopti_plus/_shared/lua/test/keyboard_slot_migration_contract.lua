--- _shared/lua/test/keyboard_slot_migration_contract.lua

--- ==============================================================================
--- MODULE: Role-Named Keyboard Slot Migration Contract
--- DESCRIPTION:
--- Replays the shipped v14 -> v15 step through the real Lua migration engine
--- over EVERY retired slot id of the driver (each legacy prefix times each key
--- of the shared key catalogue) and every retired macOS Ctrl-letter switch. The
--- expectations below are written independently of the registry: a prefix map
--- and a switch table, so a wrong or missing op in the registry fails here.
---
--- FEATURES & RATIONALE:
--- 1. A saved slot keeps its action under the role-named id; the old id is gone.
--- 2. A switch left on becomes its catalogue action, a switch left off becomes
---    "none", and an action the user chose for the slot wins over the switch.
--- 3. Replaying the step on its own output changes nothing; a file at the new
---    version is untouched and a newer file is refused.
--- ==============================================================================

local Engine = require("config_migrate")
local Json = require("json")

local M = {}

local PREFIXES = {
	hs = {
		{ "cmd_", "primary_" }, { "cmd_shift_", "primary_shift_" }, { "hs_ctrl_", "secondary_" },
		{ "hs_ctrl_shift_", "secondary_shift_" }, { "hs_option_", "alt_" },
	},
	linux = {
		{ "ctrl_", "primary_" }, { "ctrl_shift_", "primary_shift_" },
		{ "super_", "meta_" }, { "super_shift_", "meta_shift_" },
	},
}

-- Retired macOS switch -> role-named slot and the catalogue action it ran.
local SWITCHES = {
	{ "ctrl_a", "secondary_a", "select_line" }, { "ctrl_d", "secondary_d", "open_downloads" },
	{ "ctrl_e", "secondary_e", "open_file_manager" }, { "ctrl_h", "secondary_h", "screenshot_region_clipboard" },
	{ "ctrl_i", "secondary_i", "open_system_settings" }, { "ctrl_m", "secondary_m", "activity_simulation" },
	{ "ctrl_o", "secondary_o", "surround_parens" }, { "ctrl_p", "secondary_p", "display_mirror_toggle" },
	{ "ctrl_s", "secondary_s", "copy_selected_path" }, { "ctrl_t", "secondary_t", "teleport_mouse" },
	{ "ctrl_u", "secondary_u", "uppercase_selection" }, { "ctrl_w", "secondary_w", "titlecase_selection" },
	{ "ctrl_x", "secondary_x", "pick_color" }, { "ctrl_capslock", "secondary_capslock", "toggle_capslock" },
	{ "ctrl_l", "secondary_l", "lock_screen" }, { "ctrl_period", "secondary_period", "open_emoji_picker" },
	{ "ctrl_quote", "secondary_quote", "spotlight_mouse" }, { "cmd_shift_v", "primary_shift_v", "paste_plain" },
}

local function shared_root()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	return assert(source:match("^(.*)/lua/test/keyboard_slot_migration_contract%.lua$"))
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = file:read("*a")
	assert(file:close())
	return bytes
end

--- @param h table Driver test helpers.
--- @param opts table { driver = "hs"|"linux" }.
function M.register(h, opts)
	local driver = assert(PREFIXES[opts.driver] and opts.driver, "keyboard slot migration: unknown driver")
	local root = shared_root()
	local registry = assert(Engine.load_registry(root .. "/" .. Engine.REGISTRY_PATH))
	local keys = {}
	for _, key in ipairs(Json.decode(read(root .. "/modules/actions/modifier_chords.json")).keys) do
		keys[#keys + 1] = key.id
	end
	local catalogue = dofile(root .. "/../macos/_generated/action_catalogue.lua")
	local context = assert(Engine.load_context(root .. "/modules/actions/modifier_chords.json", catalogue))

	--- Runs the shipped chain from version 14 over a source and returns the plain model.
	local function migrate(source)
		local plan = Engine.plan("[_meta]\nschema_version = 14\n" .. source, registry, driver, context)
		return plan
	end

	h.describe("role-named keyboard slot migration (" .. driver .. ")", function()
		h.it("(slot-migration) every retired slot id keeps its action under the role-named id", function()
			local lines, expected, count = { "[shortcuts.keyboard]" }, {}, 0
			for _, pair in ipairs(PREFIXES[driver]) do
				for _, key in ipairs(keys) do
					local value = "action_" .. pair[1] .. key
					lines[#lines + 1] = pair[1] .. key .. ' = "' .. value .. '"'
					expected[pair[2] .. key] = value
					count = count + 1
				end
			end
			h.assert_true(count >= 160, "the replay must cover every legacy prefix times every key")
			local plan = migrate(table.concat(lines, "\n") .. "\n")
			h.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
			h.assert_eq(Engine.plain(Engine.model_from_source(plan.candidate))["shortcuts.keyboard"], expected)
			local replay = Engine.apply_steps(Engine.model_from_source(plan.candidate), registry, driver, 14, context)
			h.assert_eq(Engine.plain(replay)["shortcuts.keyboard"], expected, "a replay must change nothing")
		end)

		h.it("(slot-migration) an already role-named slot and a physical slot stay", function()
			local source = '[shortcuts.keyboard]\nprimary_a = "copy"\nalt_x = "undo"\nphysical_none_KeyJ = "mute"\nmagic_editor = "none"\n'
			local plan = migrate(source)
			h.assert_eq(Engine.plain(Engine.model_from_source(plan.candidate))["shortcuts.keyboard"], {
				primary_a = "copy", alt_x = "undo", physical_none_KeyJ = "mute", magic_editor = "none" })
		end)

		h.it("(slot-migration) a file at the new version is untouched and a newer one is refused", function()
			local current = Engine.plan("[_meta]\nschema_version = 15\n[shortcuts.keyboard]\ncmd_a = \"copy\"\n", registry, driver, context)
			h.assert_eq(current.outcome, "current")
			h.assert_nil(current.candidate)
			local newer = Engine.plan("[_meta]\nschema_version = 16\n[shortcuts.keyboard]\ncmd_a = \"copy\"\n", registry, driver, context)
			h.assert_eq(newer.outcome, "newer")
			h.assert_nil(newer.candidate)
		end)

		if driver == "hs" then
			h.it("(slot-migration) every retired switch becomes its slot and action, or none when off", function()
				for _, state in ipairs({ true, false }) do
					local lines, expected = { "[shortcuts.keys]" }, {}
					for _, row in ipairs(SWITCHES) do
						lines[#lines + 1] = row[1] .. " = " .. tostring(state)
						expected[row[2]] = state and row[3] or "none"
					end
					lines[#lines + 1] = "ctrl_g = true\ncmd_star = true\nwrap_text_if_selected = false"
					local plan = migrate(table.concat(lines, "\n") .. "\n")
					h.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
					local model = Engine.plain(Engine.model_from_source(plan.candidate))
					h.assert_eq(model["shortcuts.keyboard"], expected)
					h.assert_eq(model["shortcuts.keys"], { ctrl_g = true, cmd_star = true, wrap_text_if_selected = false },
						"only the switches without a catalogue action stay")
				end
			end)

			h.it("(slot-migration) an action the user chose beats the switch of the same chord", function()
				local source = '[shortcuts.keyboard]\nhs_ctrl_a = "send_text"\nhs_ctrl_d = "none"\n'
					.. "[shortcuts.keys]\nctrl_a = true\nctrl_d = true\nctrl_e = true\n"
				local model = Engine.plain(Engine.model_from_source(migrate(source).candidate))
				h.assert_eq(model["shortcuts.keyboard"], {
					secondary_a = "send_text", secondary_d = "none", secondary_e = "open_file_manager" })
			end)
		end
	end)
end

return M
