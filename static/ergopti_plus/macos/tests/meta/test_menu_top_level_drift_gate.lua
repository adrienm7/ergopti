--- tests/meta/test_menu_top_level_drift_gate.lua

--- ==============================================================================
--- MODULE: Menu Top-Level Drift Gate (macOS)
--- DESCRIPTION:
--- Asserts that the menu_manifest.json top_level tail (including the separator
--- before global_actions, filtered for the "hs" platform) matches the canonical ids the
--- dispatch loop in builder.lua's load_top_level_tail() handles.  Prevents
--- silent drift between the shared manifest and the driver.
---
--- The AHK half lives in windows/tests/meta/test_menu_top_level_drift_gate.ahk.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

-- Canonical ids in manifest order — macOS platform (suspend absent, karabiner not in tail)
local CANONICAL_IDS = {
	"---",
	"global_actions",
	"language",
	"config_folder",
	"setup_wizard",
	"about",
	"---",
	"reload",
	"quit",
	"debug",
}

helpers.describe("menu drift gate (macOS): top_level tail matches canonical order", function()

	helpers.it("manifest is readable and has top_level array", function()
		local fh = io.open(DRIVER_ROOT .. "../_shared/modules/menu/menu_manifest.json", "r")
		helpers.assert_true(fh ~= nil, "Cannot open menu_manifest.json")
		local raw = fh:read("*a")
		fh:close()
		local data = hs.json.decode(raw)
		helpers.assert_true(type(data) == "table", "menu_manifest.json must decode to a table")
		helpers.assert_true(type(data.top_level) == "table", "menu_manifest.json must have a top_level array")
	end)

	helpers.it("hs-filtered tail ids match canonical order", function()
		local fh = io.open(DRIVER_ROOT .. "../_shared/modules/menu/menu_manifest.json", "r")
		helpers.assert_true(fh ~= nil, "Cannot open menu_manifest.json")
		local raw = fh:read("*a")
		fh:close()
		local data = hs.json.decode(raw)

		-- Locate global_actions and preserve the manifest-owned leading separator.
		local tail_start = nil
		for i, entry in ipairs(data.top_level) do
			if type(entry) == "table" and entry.id == "global_actions" then
				tail_start = i
				break
			end
		end
		helpers.assert_true(tail_start ~= nil, "top_level must contain a global_actions entry")
		if tail_start > 1 and data.top_level[tail_start - 1].id == "---" then
			tail_start = tail_start - 1
		end

		-- Collect hs-filtered tail
		local hs_tail = {}
		for i = tail_start, #data.top_level do
			local entry = data.top_level[i]
			if type(entry) ~= "table" or type(entry.id) ~= "string" then goto continue end
			if type(entry.platforms) == "table" then
				local for_hs = false
				for _, p in ipairs(entry.platforms) do
					if p == "hs" then for_hs = true; break end
				end
				if not for_hs then goto continue end
			end
			table.insert(hs_tail, entry.id)
			::continue::
		end

		helpers.assert_eq(#hs_tail, #CANONICAL_IDS,
			"hs tail has " .. #hs_tail .. " item(s), expected " .. #CANONICAL_IDS)
		for i, expected in ipairs(CANONICAL_IDS) do
			helpers.assert_eq(hs_tail[i], expected,
				"hs tail[" .. i .. "] = '" .. tostring(hs_tail[i]) .. "', expected '" .. expected .. "'")
		end
	end)

	helpers.it("macOS loader keeps the separator immediately before global_actions", function()
		local fh = io.open(DRIVER_ROOT .. "ui/menu/builder.lua", "r")
		helpers.assert_true(fh ~= nil, "Cannot open builder.lua")
		local source = fh:read("*a")
		fh:close()
		helpers.assert_true(source:find("previous.id == \"---\"", 1, true) ~= nil,
			"load_top_level_tail must inspect the manifest entry before global_actions")
		helpers.assert_true(source:find("tail_start = tail_start - 1", 1, true) ~= nil,
			"load_top_level_tail must include the preceding separator in the rendered tail")
	end)
end)
