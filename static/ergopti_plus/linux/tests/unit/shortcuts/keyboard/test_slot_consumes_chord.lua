--- tests/unit/shortcuts/keyboard/test_slot_consumes_chord.lua

--- ==============================================================================
--- MODULE: A bound keyboard slot swallows its chord (keyboard-slot-consume)
--- DESCRIPTION:
--- Under the grab, the keyboard hook asks its consumption callback about every
--- key press before it forwards the key. A chord bound to a keyboard slot is
--- claimed there: its action runs on the next loop tick and the key never
--- reaches the focused application. An unbound chord, and a chord held back by
--- a pause or by the shortcuts switch, is forwarded untouched.
---
--- ROOT CAUSE ENCODED:
--- Slots were matched in the control-key callback, which the hook calls after
--- it has already forwarded the key, so a bound chord also reached the
--- application (Super+Space still switched the input source, Ctrl+G still ran
--- the browser's find-next). The hook also reports a key by its XKB identity:
--- the space bar as " " and a Shift-held letter in upper case, which the
--- slot suffixes "space" and "p" never matched.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("tests.lua.settings.unused_keys_contract").sandbox

local Fakes = helpers.load_module("tests.fakes")

local held = {}
local config_path = nil

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	package.loaded["shortcuts.engine.keyboard_shortcuts"] = nil
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
	if config_path then os.remove(config_path) os.remove(config_path .. ".tmp") config_path = nil end
end

--- A fresh module over stored assignments, with a recording executor and a
--- queue standing for the next loop tick.
--- @param stored table|nil Stored preference values.
--- @return table shortcuts, table seen
local function fixture(stored)
	local seen = { executed = {}, deferred = {}, chatgpt = 0 }
	replace("core.fs.adapters.storage", Fakes.storage({ initial = stored }))
	config_path = os.tmpname()
	local lines = { "[shortcuts.keyboard]" }
	for key, value in pairs(stored or {}) do
		lines[#lines + 1] = key:match("([^.]+)$") .. " = " .. string.format("%q", value)
	end
	Sandbox.write_bytes(config_path, table.concat(lines, "\n") .. "\n")
	replace("settings.engine.paths", { config = function() return config_path end })
	replace("shortcuts.engine.chatgpt", { open = function() seen.chatgpt = seen.chatgpt + 1 return true end })
	replace("gestures.engine.manager", {
		is_assignable = function(id) return id == "select_line" or id == "script_reload" or id == "open_chatgpt" end,
		execute_action = function(action, binding)
			seen.executed[#seen.executed + 1] = action .. "@" .. binding
		end,
	})
	package.loaded["shortcuts.engine.keyboard_shortcuts"] = nil
	local shortcuts = require("shortcuts.engine.keyboard_shortcuts")
	shortcuts._reset()
	seen.opts = function(only_script)
		return {
			only_script = only_script == true,
			defer = function(fn) seen.deferred[#seen.deferred + 1] = fn return true end,
		}
	end
	seen.tick = function()
		local queue = seen.deferred
		seen.deferred = {}
		for _, fn in ipairs(queue) do fn() end
	end
	return shortcuts, seen
end

--- Runs a body over a fixture and always restores the replaced modules.
--- @param stored table|nil
--- @param body function(shortcuts, seen)
local function with_fixture(stored, body)
	local shortcuts, seen = fixture(stored)
	local ok, err = pcall(body, shortcuts, seen)
	restore()
	if not ok then error(err, 0) end
end

helpers.describe("Linux keyboard slots under the grab (keyboard-slot-consume)", function()
	helpers.it("swallows a bound chord and runs it on the next tick", function()
		with_fixture({ ["shortcuts.keyboard.meta_space"] = "select_line" }, function(shortcuts, seen)
			local consumed, slot = shortcuts.consume({ key = " ", mods = { meta = true } }, seen.opts())
			helpers.assert_eq(consumed, true, "a bound Super+Space must never reach the application")
			helpers.assert_eq(slot, "meta_space", "the hook reports the space bar as ' '")
			helpers.assert_eq(#seen.executed, 0, "the action waits for the next tick")
			seen.tick()
			helpers.assert_eq(seen.executed[1], "select_line@keyboard__meta_space",
				"the action runs under its keyboard binding")
		end)
	end)

	helpers.it("matches a Shift-held letter reported in upper case", function()
		with_fixture({ ["shortcuts.keyboard.primary_shift_p"] = "select_line" }, function(shortcuts, seen)
			local consumed = shortcuts.consume({ key = "P", mods = { ctrl = true, shift = true } }, seen.opts())
			helpers.assert_eq(consumed, true, "Ctrl+Shift+P arrives as 'P' and must match primary_shift_p")
		end)
	end)

	helpers.it("forwards an unbound chord untouched", function()
		with_fixture(nil, function(shortcuts, seen)
			local consumed = shortcuts.consume({ key = "j", mods = { ctrl = true } }, seen.opts())
			helpers.assert_eq(consumed, false, "an unbound chord belongs to the application")
			helpers.assert_eq(#seen.deferred, 0)
		end)
	end)

	-- SCD-1 (decided by the maintainer on 2026-11-11): a keyboard slot bound to
	-- a script action is suspended like every other slot, as on Windows and
	-- macOS; the AltGr script chords are the way back.
	helpers.it("forwards every bound chord a pause holds back, script control included (scd1-slot-paused)", function()
		with_fixture({
			["shortcuts.keyboard.primary_j"] = "select_line",
			["shortcuts.keyboard.primary_r"] = "script_reload",
		}, function(shortcuts, seen)
			helpers.assert_eq(shortcuts.consume({ key = "j", mods = { ctrl = true } }, seen.opts(true)), false,
				"while paused an ordinary binding must not eat the key it no longer runs")
			helpers.assert_eq(shortcuts.consume({ key = "r", mods = { ctrl = true } }, seen.opts(true)), false,
				"a slot bound to script_reload must not run through a pause")
			seen.tick()
			helpers.assert_eq(#seen.executed, 0)
		end)
	end)

	helpers.it("refuses a script-action slot the live admission reads as paused (scd1-slot-paused)", function()
		with_fixture({ ["shortcuts.keyboard.primary_r"] = "script_reload" }, function(shortcuts, seen)
			local opts = seen.opts(false)
			opts.admission = function() return { master = true, paused = true, inhibited = false } end
			helpers.assert_eq(shortcuts.consume({ key = "r", mods = { ctrl = true } }, opts), false,
				"a paused native admission must stop a script-action slot like every other slot")
			seen.tick()
			helpers.assert_eq(#seen.executed, 0)
		end)
	end)

	helpers.it("forwards Ctrl+G while it is unassigned", function()
		with_fixture(nil, function(shortcuts, seen)
			helpers.assert_eq(shortcuts.consume({ key = "g", mods = { ctrl = true } }, seen.opts()), false)
			helpers.assert_eq(#seen.deferred, 0)
			helpers.assert_eq(seen.chatgpt, 0)
		end)
	end)

	helpers.it("queues an explicitly assigned ChatGPT action through the action executor", function()
		with_fixture({ ["shortcuts.keyboard.primary_g"] = "open_chatgpt" }, function(shortcuts, seen)
			helpers.assert_true(shortcuts.consume({ key = "g", mods = { ctrl = true } }, seen.opts()))
			helpers.assert_eq(#seen.executed, 0)
			seen.tick()
			helpers.assert_eq(seen.executed[1], "open_chatgpt@keyboard__primary_g")
			helpers.assert_eq(seen.chatgpt, 0, "the keyboard owner must not bypass the action executor")
		end)
	end)

	helpers.it("forwards the key when the next tick cannot be queued", function()
		with_fixture({ ["shortcuts.keyboard.primary_j"] = "select_line" }, function(shortcuts)
			local consumed = shortcuts.consume({ key = "j", mods = { ctrl = true } }, {
				only_script = false,
				defer = function() return false end,
			})
			helpers.assert_eq(consumed, false, "a key whose action cannot run must still be typed")
		end)
	end)

	helpers.it("matches the same identities in the observe-mode dispatch", function()
		with_fixture({ ["shortcuts.keyboard.meta_space"] = "select_line" }, function(shortcuts, seen)
			local fired, slot = shortcuts.dispatch({ key = " ", mods = { meta = true } })
			helpers.assert_eq(fired, true, "without the grab the chord still runs its binding")
			helpers.assert_eq(slot, "meta_space")
			helpers.assert_eq(seen.executed[1], "select_line@keyboard__meta_space")
		end)
	end)
end)
