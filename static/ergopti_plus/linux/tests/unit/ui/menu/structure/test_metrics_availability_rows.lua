--- tests/unit/ui/menu/structure/test_metrics_availability_rows.lua

--- ==============================================================================
--- MODULE: Metrics The Session Cannot Measure (Linux)
--- DESCRIPTION:
--- Under Wayland no client reads the cursor position or the current desktop,
--- so pointer distance and desktop changes are not measured. The Metrics
--- submenu names each one with its reason, so an empty dashboard column reads
--- as unmeasured rather than as a zero; on X11 nothing is listed.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the actual Metrics submenu with the given availabilities.
--- @param pointer table Pointer distance availability.
--- @param desktop function Binds the system sampler's desktop source.
--- @return table rows The submenu rows.
local function metrics_rows(pointer, desktop)
	local System = require("modules.keystats.system_metrics")
	System._reset()
	desktop(System)
	local keystats = { is_enabled = function() return true end, get_privacy_state = function() return {} end,
		pointer_distance_availability = function() return pointer end }
	local rows = helpers.load_module("ui.menu.builder").build({ keystats = keystats })
	local i18n = require("infra.i18n")
	for _, row in ipairs(rows) do
		if row.title == i18n.get("menu.metrics.title") then return row.menu end
	end
	error("the tray must carry the Metrics submenu")
end

--- Titles of the inert rows that start with a metric's name.
local function unmeasured(rows, name_key)
	local i18n = require("infra.i18n")
	local prefix = string.format(i18n.get("menu.metrics.not_measured"), i18n.get(name_key), "")
	local found = {}
	for _, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then
			helpers.assert_eq(row.disabled, true, "an availability row is inert")
			helpers.assert_nil(row.fn)
			found[#found + 1] = row.title
		end
	end
	return found
end

helpers.describe("metrics menu: what this session cannot measure", function()
	helpers.it("linux-metrics-availability: names each unmeasured metric with its reason", function()
		local rows = metrics_rows({ measured = false, reason = "platform_reason.pointer_distance_needs_cursor_position" },
			function(System) System.bind_desktop_source(nil, "platform_reason.desktop_changes_need_workspace_interface") end)
		local i18n = require("infra.i18n")
		helpers.assert_eq(unmeasured(rows, "menu.metrics.pointer_distance"), { string.format(i18n.get("menu.metrics.not_measured"),
			i18n.get("menu.metrics.pointer_distance"), i18n.get("platform_reason.pointer_distance_needs_cursor_position")) })
		helpers.assert_eq(unmeasured(rows, "menu.metrics.space_changes"), { string.format(i18n.get("menu.metrics.not_measured"),
			i18n.get("menu.metrics.space_changes"), i18n.get("platform_reason.desktop_changes_need_workspace_interface")) })
	end)

	helpers.it("linux-metrics-availability: lists nothing when both are measured", function()
		local rows = metrics_rows({ measured = true, unit = "px" },
			function(System) System.bind_desktop_source(function() return 0 end) end)
		helpers.assert_eq(unmeasured(rows, "menu.metrics.pointer_distance"), {})
		helpers.assert_eq(unmeasured(rows, "menu.metrics.space_changes"), {})
		require("modules.keystats.system_metrics")._reset()
	end)
end)
