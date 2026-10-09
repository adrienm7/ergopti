--- tests/unit/ui/menu/menu_llm/test_menu_llm_load_failed_red.lua

--- ==============================================================================
--- MODULE: menu_llm — load-failure paints the status dot RED
--- DESCRIPTION:
--- Locks down the menu side of the "no eternal orange dot" fix. api_mlx exposes
--- is_load_failed(); the menu MUST consult it (via llm_mod.is_backend_load_failed)
--- and paint the dot RED when a model was given up on, BEFORE falling through to
--- the orange "still loading" branch. Without this branch a broken model whose
--- HTTP server stays up would keep _llm_health_status true and the dot stuck
--- orange forever — the exact symptom the user reported ("rond orange, ne print
--- plus d'erreur").
---
--- This is a source assertion (same style as the updateMenu early-call guard):
--- the colour decision lives inside update_menu(), an integration-tier closure not
--- exercised by the unit harness, so we assert on the source text.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_menu_llm_source()
	local path = package.searchpath("ui.menu.menu_llm.init", package.path)
	helpers.assert_true(type(path) == "string" and path ~= "",
		"could not resolve ui.menu.menu_llm.init on package.path")
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "could not open menu_llm/init.lua")
	local src = fh:read("*a")
	fh:close()
	return src
end




-- ======================================================
-- ======================================================
-- ======= 1/ load_failed → red, before orange ==========
-- ======================================================
-- ======================================================

helpers.describe("menu_llm — load-failure status dot", function()
	helpers.it("consults is_backend_load_failed for the status colour", function()
		local src = read_menu_llm_source()
		helpers.assert_true(
			src:find("is_backend_load_failed", 1, true) ~= nil,
			"the status indicator must consult llm_mod.is_backend_load_failed"
		)
	end)

	helpers.it("has an `elseif load_failed` branch ahead of the orange branch", function()
		local src = read_menu_llm_source()
		local failed_pos = src:find("elseif load_failed then", 1, true)
		local orange_pos = src:find("_llm_health_status == true", 1, true)
		helpers.assert_true(failed_pos ~= nil, "expected an `elseif load_failed then` branch")
		helpers.assert_true(orange_pos ~= nil, "expected the orange `_llm_health_status == true` branch")
		helpers.assert_true(failed_pos < orange_pos,
			"the load_failed (red) branch must be evaluated BEFORE the orange branch, " ..
			"or a broken model would still resolve to orange")
	end)
end)
