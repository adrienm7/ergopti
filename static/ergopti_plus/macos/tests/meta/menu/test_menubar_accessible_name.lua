--- tests/meta/menu/test_menubar_accessible_name.lua

--- ==============================================================================
--- MODULE: The menu-bar item has an accessible name (a11y-menubar-tooltip)
--- DESCRIPTION:
--- The menu-bar item is an image with an empty title: VoiceOver announced it
--- as an unnamed button, and a pause was told only by the darker logo. Its
--- tooltip, which VoiceOver reads as the item's help, now names it and says the
--- paused state in words. The unit suite never builds the real menu bar, so the
--- icon refresh is pinned here: the tooltip follows the pause and the locale,
--- and is set before the shortcut that skips an unchanged icon, or a pause
--- toggled after a locale change would keep the old words.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Returns source text with every line comment removed.
--- @param src string Source text.
--- @return string code
local function without_comments(src)
	local lines = {}
	for line in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = (line:gsub("%-%-.*$", "")) end
	return table.concat(lines, "\n")
end

helpers.describe("the menu-bar item has an accessible name (a11y-menubar-tooltip)", function()
	helpers.it("names the item and its paused state through translated keys (a11y-menubar-tooltip)", function()
		local unit, err = helpers.read_driver_unit("local function update_icon(custom_text)")
		helpers.assert_true(unit ~= nil, tostring(err))
		local body = without_comments(unit)
		local start = body:find("local function update_icon(custom_text)", 1, true)
		local finish = body:find("local function reset_menubar()", start, true)
		helpers.assert_true(start ~= nil and finish ~= nil, "update_icon must be found whole")
		local fn = body:sub(start, finish)
		local keys_at = fn:find('i18n.get(paused and "accessibility.tray_tip_paused" or "accessibility.tray_tip")', 1, true)
		helpers.assert_true(keys_at ~= nil, "the tooltip must come from the shared tray keys, paused or not")
		local key_at = fn:find('local icon_key = tostring(variant) .. "|" .. tostring(paused) .. "|" .. tostring(tooltip)', 1, true)
		helpers.assert_true(key_at ~= nil, "the tooltip text must be part of the unchanged-icon key")
		local skip_at = fn:find("if custom_text == nil and icon_key == _last_icon_key then return end", 1, true)
		local set_at = fn:find("myMenu:setTooltip(tooltip)", 1, true)
		helpers.assert_true(skip_at ~= nil and set_at ~= nil, "the skip and the tooltip call must both be found")
		helpers.assert_true(keys_at < key_at and key_at < skip_at,
			"the tooltip is computed before the key that decides whether anything changed")
	end)

	helpers.it("ships both keys in every locale (a11y-menubar-tooltip)", function()
		local Json = require("core.text.engine.json")
		for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
			"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
			local file = assert(io.open(helpers.shared("core/i18n/data/locales/" .. locale .. ".json"), "rb"))
			local strings = Json.decode(file:read("*a"))
			file:close()
			for _, key in ipairs({ "accessibility.tray_tip", "accessibility.tray_tip_paused" }) do
				helpers.assert_true(type(strings[key]) == "string" and strings[key] ~= "", locale .. " lacks " .. key)
			end
			helpers.assert_true(strings["accessibility.tray_tip_paused"] ~= strings["accessibility.tray_tip"],
				locale .. " must tell the paused state apart")
		end
	end)
end)
