--- tests/unit/modules/gestures/test_action_catalogue_parity.lua

--- ==============================================================================
--- MODULE: macOS Action Catalogue Parity (action-catalogue-parity)
--- DESCRIPTION:
--- The picker lists exactly what this driver can run, its headings are
--- localized, and a binding naming an id the catalogue does not offer is
--- refused.
---
--- ROOT CAUSES ENCODED:
--- 1. The gate that compared the declarations with the drivers was a literal
---    scan: an id counted as handled whenever it appeared as a quoted string
---    anywhere in the driver tree. This compares the generated catalogue with the
---    live registry, in both directions: a listed id with no handler is a
---    binding that does nothing, a handler the catalogue hides is a feature
---    nobody can bind.
--- 2. The modifier-chord headings were the literal "Raccourcis" in every locale.
--- 3. set_action stored any string, so a stale id was dispatched as a silent
---    no-op while Windows refused it at assignment.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

package.loaded["modules.gestures.engine"] = nil
package.loaded["modules.gestures.actions"] = nil
package.loaded["modules.gestures.conflicts"] = nil
local Assignable = require("actions.assignable")
local original_build = Assignable.build
local build_observations = {}
Assignable.build = function(catalogue, modifiers, platform)
	build_observations[#build_observations + 1] = {
		catalogue = catalogue, modifiers = modifiers, platform = platform,
	}
	return original_build(catalogue, modifiers, platform)
end
local boot_ok, Gestures = xpcall(function()
	return helpers.load_with_stubs("modules.gestures")
end, debug.traceback)
Assignable.build = original_build
if not boot_ok then error(Gestures, 0) end
local Actions = require("modules.gestures.actions")
local Catalogue = require("_generated.action_catalogue")
-- The harness injects an i18n stub that echoes keys, and the actions module
-- captured that very table when it loaded. The locale test below points the
-- same table at the real shared locale core for its duration.
local i18n = package.loaded["infra.i18n"]
local Locale = require("infra.locale")

--- Builds a set from a list.
--- @param list table
--- @return table
local function set_of(list)
	local out = {}
	for _, v in ipairs(list) do out[v] = true end
	return out
end

--- Every action id get_sg_names() lists, headings excluded.
--- @return table
local function listed_sg_ids()
	local out = {}
	for _, name in ipairs(Actions.get_sg_names()) do
		if name:sub(1, 1) ~= "#" then out[#out + 1] = name end
	end
	return out
end





-- =====================================================
-- =====================================================
-- ======= 1/ Catalogue <-> registry, both ways ========
-- =====================================================
-- =====================================================

helpers.describe("action catalogue parity (macOS)", function()
	helpers.it("uses the same pure assignability owner as boot migration", function()
		helpers.assert_eq(#build_observations, 1, "the real native action loader consumes the shared owner once")
		local observed = build_observations[1]
		helpers.assert_true(observed.catalogue == Catalogue, "the actual generated action catalogue is injected")
		helpers.assert_eq(observed.platform, "macos")
		helpers.assert_eq(observed.modifiers.keys[40].id, "comma", "the actual complete physical key catalogue is injected")
		helpers.assert_true(Actions.is_assignable("cmd_ctrl_option_shift_comma"), "the real native caller offers the complete modifier matrix")
		helpers.assert_eq(Actions.is_assignable("future_action"), false, "unknown ids remain unassignable")
		helpers.assert_eq(Actions.is_assignable("alt_d"), false, "native aliases remain distinct from ordinary action identities")
	end)

	helpers.it("lists every single action it can run and nothing else (action-catalogue-parity)", function()
		local listed = listed_sg_ids()
		helpers.assert_true(#listed >= 600,
			"the picker lists only " .. #listed .. " action(s) — the catalogue walk collapsed")
		local registered = Actions.registered_action_ids()
		local listed_set, registered_set = set_of(listed), set_of(registered.sg)
		local dead, hidden = {}, {}
		for _, id in ipairs(listed) do
			if not registered_set[id] then dead[#dead + 1] = id end
		end
		for _, id in ipairs(registered.sg) do
			if not listed_set[id] then hidden[#hidden + 1] = id end
		end
		helpers.assert_eq(#dead, 0, "listed but not runnable on macOS: " .. table.concat(dead, ", "))
		helpers.assert_eq(#hidden, 0, "runnable on macOS but never listed: " .. table.concat(hidden, ", "))
	end)

	helpers.it("lists every axis it can run and nothing else (action-catalogue-parity)", function()
		local listed = {}
		for _, name in ipairs(Actions.AX_NAMES) do
			if name ~= "none" then listed[#listed + 1] = name end
		end
		helpers.assert_true(#listed >= 10, "only " .. #listed .. " axis action(s) listed")
		local registered = Actions.registered_action_ids()
		helpers.assert_eq(table.concat(registered.ax, ","), (function()
			table.sort(listed)
			return table.concat(listed, ",")
		end)(), "the axis picker and the axis registry must be the same set")
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 2/ Headings are localized ========
-- ==========================================
-- ==========================================

helpers.describe("action picker headings (macOS)", function()
	helpers.it("builds every heading and label from its locale key, in a non-French locale too", function()
		local previous = Locale.all()["_meta.locale"]
		local stub_get, stub_format = i18n.get, i18n.format
		i18n.get = function(key)
			local s = Locale.get(key)
			if type(s) ~= "string" or s == "" then return key end
			return s
		end
		i18n.format = function(key, ...)
			local text = i18n.get(key)
			local args = table.pack(...)
			for n = 1, args.n do
				text = text:gsub("{" .. n .. "}", (tostring(args[n]):gsub("%%", "%%%%")))
			end
			return text
		end
		local ok, err = pcall(function()
			for _, code in ipairs({ "de", "en" }) do
				Locale.set_locale(code)
				local chords_title = i18n.get("sg_actions.sg_order.header.modifier_chords")
				local ctrl_title = i18n.format("sg_actions.sg_order.header.modifier_chord_group", "Ctrl")
				local found_h1, found_ctrl, headings = false, false, 0
				for _, name in ipairs(Actions.get_sg_names()) do
					if name:sub(1, 1) == "#" then
						headings = headings + 1
						local text = name:gsub("^#+", "")
						helpers.assert_true(not text:find("Raccourcis", 1, true),
							code .. ": a heading is still French: " .. name)
						helpers.assert_true(not text:find("sg_actions.", 1, true),
							code .. ": a heading shows its raw key: " .. name)
						found_h1 = found_h1 or name == "#" .. chords_title
						found_ctrl = found_ctrl or name == "##" .. ctrl_title
					end
				end
				helpers.assert_true(headings >= 20, code .. ": only " .. headings .. " heading(s)")
				local labelled = 0
				for _, id in ipairs(listed_sg_ids()) do
					local meta = Catalogue.actions[id]
					if meta then
						labelled = labelled + 1
						helpers.assert_eq(Actions.get_label(id), Locale.get(meta.label_key),
							code .. ": " .. id .. " must be labelled from " .. meta.label_key)
					end
				end
				helpers.assert_true(labelled >= 100, code .. ": only " .. labelled .. " label(s) checked")
				helpers.assert_true(found_h1, code .. ": the chord H1 must read " .. chords_title)
				helpers.assert_true(found_ctrl, code .. ": the Ctrl group must read " .. ctrl_title)
			end
		end)
		Locale.set_locale(previous)
		i18n.get, i18n.format = stub_get, stub_format
		if not ok then error(err, 0) end
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 3/ Unknown ids are refused =======
-- ==========================================
-- ==========================================

helpers.describe("gesture assignment validation (macOS)", function()
	helpers.it("refuses an id the catalogue does not offer and keeps the binding", function()
		helpers.assert_true(Gestures.set_action("tap_3", "lookup"), "a catalogue id is accepted")
		helpers.assert_eq(Gestures.set_action("tap_3", "no_such_action"), false,
			"an unknown id must be refused, as Windows refuses it")
		helpers.assert_eq(Gestures.get_action("tap_3"), "lookup", "a refused id must not replace the binding")
		helpers.assert_eq(Gestures.set_action("tap_3", "copy"), false,
			"a Windows-only id is not assignable on macOS")
		helpers.assert_true(Gestures.set_action("tap_3", "ctrl_a"), "a modifier chord is assignable")
		helpers.assert_true(Gestures.set_action("swipe_3_horiz", "volume"), "an axis action is assignable")
		helpers.assert_true(Gestures.set_action("tap_3", "none"), "none clears a binding")
	end)
end)
