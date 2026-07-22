--- tests/unit/ui/menu/menu_llm/test_apple_silicon_single_detector.lua

--- ==============================================================================
--- MODULE: Regression — single Apple-Silicon detector across the LLM menu (F-MED-4)
--- DESCRIPTION:
--- ui/menu/menu_llm/init.lua's DEFAULT_STATE.llm_backend seed used a
--- filesystem-existence heuristic (hs.fs.attributes("/opt/homebrew", "mode")),
--- while ui/menu/menu_llm/backend_panel.lua correctly used `uname -m`. The
--- heuristic is wrong on a fresh arm64 Mac that has not installed Homebrew
--- yet — Homebrew only creates /opt/homebrew once it is itself installed —
--- so a first run on Apple Silicon silently seeded llm_backend as "ollama"
--- instead of "mlx".
---
--- Fix: backend_panel.lua exports its uname-based is_apple_silicon() as
--- M.is_apple_silicon; init.lua now calls BackendPanel.is_apple_silicon()
--- instead of re-declaring its own /opt/homebrew heuristic, so both call
--- sites are guaranteed to agree forever.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src(rel_path)
	local path = helpers.driver_root() .. rel_path
	local fh   = io.open(path, "r")
	helpers.assert_true(fh ~= nil, rel_path .. " must be readable")
	local src = fh:read("*a"); fh:close()
	return src
end





-- =============================================================
-- =============================================================
-- ======= 1/ backend_panel.lua exports is_apple_silicon =======
-- =============================================================
-- =============================================================

helpers.describe("backend_panel.lua: is_apple_silicon is a single exported source of truth (F-MED-4)", function()

	helpers.it("exports M.is_apple_silicon", function()
		local src = read_src("ui/menu/menu_llm/backend_panel.lua")
		helpers.assert_true(
			src:find("M.is_apple_silicon = is_apple_silicon", 1, true) ~= nil,
			"backend_panel.lua must export M.is_apple_silicon (F-MED-4)"
		)
	end)

	helpers.it("uses uname -m, not a /opt/homebrew filesystem heuristic", function()
		-- Scope to the is_apple_silicon FUNCTION BODY only, not the whole file —
		-- the doc comment right above it legitimately mentions the OLD
		-- /opt/homebrew heuristic in prose to explain why this detector exists.
		local src = read_src("ui/menu/menu_llm/backend_panel.lua")
		local fn_start = src:find("local function is_apple_silicon()", 1, true)
		helpers.assert_true(fn_start ~= nil, "backend_panel.lua must define is_apple_silicon()")
		local fn_end  = src:find("\nend", fn_start, true)
		local fn_body = src:sub(fn_start, fn_end)

		helpers.assert_true(
			fn_body:find('hs.execute("uname -m")', 1, true) ~= nil,
			"backend_panel.lua's is_apple_silicon must use uname -m (F-MED-4)"
		)
		helpers.assert_true(
			fn_body:find('hs.fs.attributes("/opt/homebrew"', 1, true) == nil,
			"backend_panel.lua's is_apple_silicon body must not use a /opt/homebrew filesystem heuristic"
		)
	end)
end)





-- =====================================================================
-- =====================================================================
-- ======= 2/ menu_llm/init.lua delegates instead of duplicating =======
-- =====================================================================
-- =====================================================================

helpers.describe("menu_llm/init.lua: delegates Apple-Silicon detection to BackendPanel (F-MED-4)", function()

	helpers.it("does NOT re-declare the /opt/homebrew filesystem heuristic", function()
		local src = read_src("ui/menu/menu_llm/init.lua")
		helpers.assert_true(
			src:find('hs.fs.attributes("/opt/homebrew"', 1, true) == nil,
			"menu_llm/init.lua must not use the /opt/homebrew filesystem heuristic — it is wrong on a fresh arm64 Mac with no Homebrew yet (F-MED-4)"
		)
	end)

	helpers.it("calls BackendPanel.is_apple_silicon() for its is_apple_silicon local", function()
		local src = read_src("ui/menu/menu_llm/init.lua")
		helpers.assert_true(
			src:find("local is_apple_silicon = BackendPanel.is_apple_silicon()", 1, true) ~= nil,
			"menu_llm/init.lua must delegate to BackendPanel.is_apple_silicon() (F-MED-4)"
		)
	end)

	helpers.it("requires ui.menu.menu_llm.backend_panel BEFORE using is_apple_silicon", function()
		local src = read_src("ui/menu/menu_llm/init.lua")
		local require_pos = src:find('require("ui.menu.menu_llm.backend_panel")', 1, true)
		local usage_pos    = src:find("BackendPanel.is_apple_silicon()", 1, true)
		helpers.assert_true(require_pos ~= nil, "menu_llm/init.lua must require ui.menu.menu_llm.backend_panel")
		helpers.assert_true(usage_pos ~= nil, "menu_llm/init.lua must call BackendPanel.is_apple_silicon()")
		helpers.assert_true(require_pos < usage_pos,
			"BackendPanel must be required BEFORE is_apple_silicon() is called (Lua locals resolve at declaration order)")
	end)
end)
