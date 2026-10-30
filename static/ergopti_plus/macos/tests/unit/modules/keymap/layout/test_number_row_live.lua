--- tests/unit/modules/keymap/layout/test_number_row_live.lua

--- ==============================================================================
--- MODULE: Number Row Options, Live (macOS)
--- DESCRIPTION:
--- Which layout the number-row options apply to on macOS: an installed layout of
--- ours selected now, or the build typing for one; anything else has no source
--- and the stored choice stays inert. The application itself runs the live
--- build of layout_rows_build.lua (number-row-live-macos).
--- ==============================================================================

local helpers = require("tests.helpers")
local Live = require("modules.keymap.number_row_live")
local Build = require("modules.keymap.layout_rows_build")
local FakeMac = require("tests.support.layout_rows_fake_mac")

local REGISTRY_DIR = helpers.driver_root() .. "/../../layouts/registry/"

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local ERGOL = read(REGISTRY_DIR .. "ergol/ergol.keylayout")

--- A registry with Ergo-L installed, and the active layout `active`.
local function registry(active)
	return {
		snapshot = function()
			return { active = active, installed = { ergol = { id = "ergol", keyboard_name = "Ergo-L",
				keycode_convention = "ansi" } } }
		end,
		read_local_copy = function(id)
			if id == "ergol" then return ERGOL end
			return nil, "unreadable"
		end,
	}
end

helpers.describe("number row live on macOS: the layout the options apply to (number-row-live-macos)", function()
	helpers.it("applies to the selected installed layout, then to the build typing for it", function()
		Build._reset()
		local mac, build_deps = FakeMac.new()
		local deps = { registry = registry("ergol"), build_deps = build_deps, active_sources = function() return {} end }
		helpers.assert_eq((Live.available(deps)), true)
		local answer
		Live.apply({ order = "symbols", edges = false }, function(...) answer = { ... } end, deps)
		helpers.assert_eq(answer[1], true, tostring(answer[2]))
		helpers.assert_eq(mac.selected, "Ergo-L 1")
		-- The build types now: the registry no longer sees Ergo-L selected.
		deps.registry = registry("")
		deps.active_sources = function()
			return { { id = "org.unknown.keylayout.Ergo-L 1", name = "Ergo-L 1", selected = true } }
		end
		local source = assert(Live.source(deps))
		helpers.assert_eq(source.id, "ergol")
		Live.apply({ order = "digits", edges = false }, function(...) answer = { ... } end, deps)
		helpers.assert_eq(answer[1], true, tostring(answer[2]))
		helpers.assert_eq(mac.selected, "Ergo-L", "the plain layout types again for a choice it already has")
	end)

	helpers.it("has no source while another input source types, and applies nothing", function()
		Build._reset()
		local mac, build_deps = FakeMac.new()
		local deps = { registry = registry(""), build_deps = build_deps,
			active_sources = function() return { { id = "com.apple.keylayout.ABC", name = "ABC", selected = true } } end }
		local available, reason = Live.available(deps)
		helpers.assert_eq(available, false)
		helpers.assert_eq(reason, Live.REASON_NO_SOURCE)
		local answer
		Live.apply({ order = "symbols", edges = false }, function(...) answer = { ... } end, deps)
		helpers.assert_eq(answer[1], false)
		helpers.assert_eq(answer[2], Live.REASON_NO_SOURCE)
		helpers.assert_eq(#mac.calls, 0, "a choice with no source must not touch the input sources")
	end)
end)
