--- tests/unit/modules/shortcuts/test_slot_prefix_ordering.lua

--- ==============================================================================
--- MODULE: Ordinary Shortcut Prefix Admission
--- DESCRIPTION:
--- The shared modifier catalogue owns longest-first resolution; display menu
--- ordering is independent. Drive the real consumer with overlapping prefixes
--- so a shorter prefix cannot steal a shifted chord or its visible label.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

helpers.describe("ordinary shortcut prefixes (shortcuts-core-1)", function()
	helpers.it("keeps both actual resolution loops ordered rather than relying on pairs array traversal", function()
		local source = helpers.read_driver_source("local function load_assignments")
		helpers.assert_true(source ~= nil, "ordinary keyboard owner must be locatable")
		for _, name in ipairs({"slot_to_chord", "slot_label"}) do
			local body = source:match("local function " .. name .. "%b()%s*(.-)\nend")
			helpers.assert_true(body ~= nil, "actual resolution function must remain observable")
			helpers.assert_true(body:find("for _, entry in ipairs(slot_mods()) do", 1, true) ~= nil,
				name .. " must preserve longest-first declared iteration")
		end
	end)

	helpers.it("keeps every declared overlapping prefix longest-first", function()
		local file = assert(io.open(helpers.shared("modules/actions/modifier_chords.json"), "rb"))
		local catalogue = Json.decode(file:read("*a")); file:close()
		local groups = catalogue.platforms.macos.shortcut_groups
		helpers.assert_true(type(groups) == "table" and #groups > 0)
		local indices = {}
		for index, group in ipairs(groups) do
			helpers.assert_true(indices[group.prefix] == nil, "one declared owner per prefix")
			indices[group.prefix] = index
			for other_index, other in ipairs(groups) do
				if #group.prefix > #other.prefix and group.prefix:sub(1, #other.prefix) == other.prefix then
					helpers.assert_true(index < other_index, "longer overlapping prefixes resolve first")
				end
			end
		end
		helpers.assert_true(indices.cmd_shift_ < indices.cmd_)
		helpers.assert_true(indices.hs_ctrl_shift_ < indices.hs_ctrl_)
	end)

	helpers.it("binds and labels shifted slots through the real declared prefix consumer", function()
		return helpers.with_stub_scope({
			"adapters.file_system", "adapters.hotkey_registrar", "infra.paths", "infra.config_paths",
			"infra.preferences", "modules.gestures.actions", "modules.shortcuts.keyboard_shortcuts",
		}, function()
			helpers.load_with_stubs("infra.preferences")
			local observed = {}
			package.loaded["infra.paths"] = {shared = helpers.shared}
			package.loaded["adapters.file_system"] = {read = function(path)
				local file = assert(io.open(path, "rb")); local bytes = file:read("*a"); file:close(); return bytes
			end}
			package.loaded["adapters.hotkey_registrar"] = {
				bind = function(chord) observed[chord] = (observed[chord] or 0) + 1; return chord end,
				unbind = function() return true end,
			}
			package.loaded["modules.gestures.actions"] = {
				is_assignable = function(action) return action == "send_text" or action == "none" end,
			}
			require("tests.support.keyboard_config_fixture").install({
				cmd_shift_a="send_text", cmd_a="send_text", hs_ctrl_shift_a="send_text", hs_ctrl_a="send_text",
			})
			package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
			local subject = require("modules.shortcuts.keyboard_shortcuts")
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(observed, { ["Cmd+Shift+A"]=1, ["Cmd+A"]=1, ["Ctrl+Shift+A"]=1, ["Ctrl+A"]=1 })
			helpers.assert_eq(subject.get_slot_label("cmd_shift_a"), "⌘ ⇧ A")
			helpers.assert_eq(subject.get_slot_label("hs_ctrl_shift_a"), "^ ⇧ A")
			helpers.assert_eq(subject.stop(), true)
		end)
	end)
end)

return true
