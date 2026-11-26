--- tests/unit/core/ui/test_system_accessibility.lua

--- ==============================================================================
--- MODULE: System accessibility settings and VoiceOver announcements
--- DESCRIPTION:
--- hs.canvas previews are invisible to VoiceOver and drawn translucent whatever
--- the system's Reduce transparency or Increase contrast says. These cases pin
--- the reading of those settings, the opaque panel they ask for, and the
--- announcement: spoken through VoiceOver only while it runs, once per text,
--- never the struck-through alternatives (a11y-macos-announce).
--- ==============================================================================

local helpers = require("tests.helpers")

local restore_loaded = helpers.keep_loaded and helpers.keep_loaded({ "core.process.adapters.shell_runner" }) or nil

--- Loads the adapter over a controlled system.
--- @param system table { settings = table|nil|error, voiceover = boolean, script_ok = boolean }
--- @return table module, table log
local function load_adapter(system)
	local log = { scripts = {}, reads = 0 }
	local saved_runner = package.loaded["core.process.adapters.shell_runner"]
	package.loaded["core.process.adapters.shell_runner"] = {
		applescript = function(script, on_done)
			log.scripts[#log.scripts + 1] = script
			on_done(system.script_ok ~= false, "")
			return true
		end,
	}
	local module = helpers.load_with_stubs("core.ui.adapters.system_accessibility", {
		screen = {
			accessibilitySettings = function()
				log.reads = log.reads + 1
				if system.settings == "error" then error("unavailable") end
				return system.settings
			end,
		},
		application = {
			applicationsForBundleID = function(bundle)
				log.bundle = bundle
				return system.voiceover and { {} } or {}
			end,
		},
	})
	package.loaded["core.process.adapters.shell_runner"] = saved_runner
	return module, log
end

helpers.describe("macOS display accessibility settings (a11y-macos-settings)", function()
	helpers.it("reads Reduce transparency and Increase contrast as a wish for an opaque panel", function()
		local module = load_adapter({ settings = { ReduceTransparency = true } })
		helpers.assert_eq(module.display_settings(100).reduce_transparency, true)
		helpers.assert_eq(module.wants_opaque(100), true)
		module = load_adapter({ settings = { IncreaseContrast = true, ReduceMotion = true } })
		helpers.assert_eq(module.display_settings(100), {
			reduce_motion = true, reduce_transparency = false, increase_contrast = true })
		helpers.assert_eq(module.wants_opaque(100), true)
		module = load_adapter({ settings = {} })
		helpers.assert_eq(module.wants_opaque(100), false, "a translucent panel by default")
	end)

	helpers.it("reads the system at most once a second", function()
		local module, log = load_adapter({ settings = {} })
		module.display_settings(100)
		module.display_settings(100)
		helpers.assert_eq(log.reads, 1, "a preview drawn per keystroke must not query NSWorkspace each time")
		module.display_settings(101)
		helpers.assert_eq(log.reads, 2)
	end)

	helpers.it("draws as if all were off when the settings cannot be read", function()
		local module = load_adapter({ settings = "error" })
		helpers.assert_eq(module.wants_opaque(100), false)
	end)
end)

helpers.describe("VoiceOver announcements (a11y-macos-announce)", function()
	helpers.it("says nothing while VoiceOver does not run", function()
		local module, log = load_adapter({ voiceover = false })
		helpers.assert_eq(module.announce("bonjour"), false)
		helpers.assert_eq(#log.scripts, 0, "no speech without a screen reader: the decision of 2026-11-17")
		helpers.assert_eq(log.bundle, "com.apple.VoiceOver")
	end)

	helpers.it("speaks through VoiceOver once per text, again after a hide", function()
		local module, log = load_adapter({ voiceover = true })
		helpers.assert_eq(module.announce("bonjour"), true)
		helpers.assert_eq(module.announce("bonjour"), false, "a redraw with the same text is not repeated")
		helpers.assert_eq(#log.scripts, 1)
		helpers.assert_eq(log.scripts[1], 'tell application "VoiceOver" to output "bonjour"')
		module.forget_announcement()
		helpers.assert_eq(module.announce("bonjour"), true)
		helpers.assert_eq(#log.scripts, 2)
	end)

	helpers.it("escapes the text into one AppleScript string", function()
		local module = load_adapter({})
		helpers.assert_eq(module.voiceover_script('a "b" \\ c\nd'),
			'tell application "VoiceOver" to output "a \\"b\\" \\\\ c d"')
	end)

	helpers.it("(a11y-macos-event) says each event again, without touching the preview's last text", function()
		local module, log = load_adapter({ voiceover = true })
		helpers.assert_eq(module.announce("bonjour"), true)
		helpers.assert_eq(module.announce_event("Mouse pointer highlighted"), true)
		helpers.assert_eq(module.announce_event("Mouse pointer highlighted"), true,
			"a second spotlight is a second event")
		helpers.assert_eq(module.announce("bonjour"), false, "the preview is still not repeated")
		helpers.assert_eq(#log.scripts, 3)
		helpers.assert_eq(module.announce_event(""), false)
		module = load_adapter({ voiceover = false })
		helpers.assert_eq(module.announce_event("Mouse pointer highlighted"), false,
			"nothing is said while VoiceOver does not run")
	end)

	helpers.it("ignores an empty text", function()
		local module, log = load_adapter({ voiceover = true })
		helpers.assert_eq(module.announce(""), false)
		helpers.assert_eq(module.announce(nil), false)
		helpers.assert_eq(#log.scripts, 0)
	end)
end)

helpers.describe("tooltip announcement text (a11y-macos-announce)", function()
	helpers.it("names the rows that will be sent, with their trigger, never the struck-through ones", function()
		local renderer = helpers.load_with_stubs("core.ui.ui.tooltip.renderer", {})
		helpers.assert_eq(renderer.announcement_for_stacked({
			{ text = "bonjour", trigger_label = "★" },
			{ text = "bonsoir", dimmed = true },
			{ text = "salut" },
		}), "bonjour ★; salut")
		helpers.assert_eq(renderer.announcement_for_stacked({ { text = "x", dimmed = true } }), nil)
		helpers.assert_eq(renderer.announcement_for_blocks({ preds = "prédiction" }), "prédiction")
		helpers.assert_eq(renderer.announcement_for_blocks({ preds = { getString = function() return "styled" end } }),
			"styled")
	end)
end)

if restore_loaded then restore_loaded() end
