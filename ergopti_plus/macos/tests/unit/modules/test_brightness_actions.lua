--- tests/unit/modules/test_brightness_actions.lua

--- ==============================================================================
--- MODULE: Shared Screen Brightness Contract
--- DESCRIPTION:
--- Replays independent endpoint and native refusal vectors, without treating a
--- media event or a provider exit code as observed physical screen brightness.
--- ==============================================================================

local h = require("tests.helpers")
local Brightness = require("brightness_actions")
local Json = require("json")
local Files = require("keymap.layer_editor")
local shared = h.driver_root() .. "/../_shared"
local data = Brightness.load()
local corpus = Json.decode(Files.read_shipped(shared .. "/tests/corpus/brightness_actions.json"))

h.describe("shared screen brightness receipts", function()
	for _, vector in ipairs(corpus.cases) do
		h.it(vector.name, function()
			h.assert_eq(Brightness.target(data, vector.action, vector.before), vector.target)
			h.assert_eq(Brightness.acknowledged(data, vector.action, vector.receipt), vector.acknowledged)
		end)
	end
	h.it("retains independent native owner data", function()
		local first, second = Brightness.load(), Brightness.load()
		first.actions.brightness_up.direction = -1
		first.step_percent = 20
		h.assert_eq(second.actions.brightness_up.direction, 1)
		h.assert_eq(second.step_percent, 5)
	end)

	h.it("keeps media encodings native and screen-only", function()
		h.assert_eq(Brightness.linux_command(data, "brightness_up"), "brightnessctl --class=backlight set +5%")
		h.assert_eq(Brightness.linux_command(data, "brightness_down"), "brightnessctl --class=backlight set 5%-")
		h.assert_eq(data.actions.brightness_up.macos_system, "BRIGHTNESS_UP")
		h.assert_eq(data.actions.brightness_down.karabiner_consumer, "display_brightness_decrement")
		h.assert_eq(Brightness.acknowledged(data, "brightness_up", true), false)
		local changed = Json.decode(Json.encode(data))
		changed.step_percent = 10
		h.assert_eq(Brightness.linux_command(changed, "brightness_up"), "brightnessctl --class=backlight set +10%")
		h.assert_eq(Brightness.target(changed, "brightness_up", 40), 50)
	end)
end)
