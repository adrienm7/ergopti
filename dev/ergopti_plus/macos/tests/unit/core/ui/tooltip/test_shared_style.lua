--- tests/unit/core/ui/tooltip/test_shared_style.lua

--- ==============================================================================
--- MODULE: Tooltip Shared-Style Contract Tests
--- DESCRIPTION:
--- Guards that the macOS tooltip reads its visual style (corner radius, border
--- ring, separator) from the SINGLE shared source — _shared/core/ui/data/tooltip/constants.toml
--- — rather than hardcoded literals. Both drivers consume that file (HS here, AHK
--- via infra/ui_style.ahk) so the tooltips look identical across platforms.
---
--- ROOT CAUSE ENCODED: the stacked LLM tooltip used to hardcode the AHK-tuned
--- border/separator alpha (0.25) on the macOS canvas and a literal corner radius,
--- diverging from the single tooltip and the shared spec. A re-hardcode would make
--- the two platforms drift again; these assertions fail fast if the wiring breaks.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Read the canonical shared values straight from the TOML so the test is tied to
-- the source of truth, not to a copied literal. The reader wraps named TOML
-- sections under `.sections`, mirroring how config.lua's require_key indexes them.
local function shared_constants()
	local toml_reader = require("core.text.engine.toml.reader")
	local path = helpers.shared("core/ui/data/tooltip/constants.toml")
	local ok, data = pcall(toml_reader.parse, path)
	helpers.assert_true(ok and type(data) == "table" and type(data.sections) == "table",
		"_shared/core/ui/data/tooltip/constants.toml must parse with sections")
	return data.sections
end

helpers.describe("Tooltip: shared-style wiring", function()
	local Config = helpers.load_with_stubs("core.ui.ui.tooltip.config")
	local shared = shared_constants()

	helpers.it("corner radius comes from shared [layout].corner_radius", function()
		helpers.assert_eq(Config.layout.corner_radius, shared.layout.corner_radius)
	end)

	helpers.it("border ring color comes from shared [colors] (HS-tuned alpha)", function()
		helpers.assert_true(type(Config.colors.border) == "table", "Config.colors.border must be populated")
		helpers.assert_eq(Config.colors.border.white, shared.colors.border_white)
		helpers.assert_eq(Config.colors.border.alpha, shared.colors.border_alpha_hs)
	end)

	helpers.it("separator color comes from shared [colors] (HS-tuned alpha)", function()
		helpers.assert_eq(Config.colors.sep.white, shared.colors.sep_white)
		helpers.assert_eq(Config.colors.sep.alpha, shared.colors.sep_alpha_hs)
	end)

	helpers.it("uses the HS border alpha, not the AHK one (the old stacked divergence)", function()
		-- The shared file deliberately carries DIFFERENT per-driver alphas so the
		-- two render the same; macOS must use the _hs value, never _ahk.
		helpers.assert_true(shared.colors.border_alpha_hs ~= shared.colors.border_alpha_ahk,
			"shared file must keep per-driver border alphas distinct")
		helpers.assert_eq(Config.colors.border.alpha, shared.colors.border_alpha_hs)
	end)

	-- TWD-1, decided by the maintainer on 2026-11-16: a preview with no delay hid
	-- only at the next key on macOS; it now hides after the shared safety lifetime,
	-- as on Windows and Linux (twd1-zero-delay-safety).
	helpers.it("(twd1-zero-delay-safety) a duration of 0 takes the shared [timing].safety_timeout_sec", function()
		local saved = Config.settings.timeout_sec
		local ok, err = pcall(function()
			helpers.assert_true(type(shared.timing.safety_timeout_sec) == "number"
				and shared.timing.safety_timeout_sec > 0, "the shared safety lifetime is declared")
			Config.set_timeout(0)
			helpers.assert_eq(Config.settings.timeout_sec, shared.timing.safety_timeout_sec)
			helpers.assert_eq(Config.timing.safety_timeout_sec, shared.timing.safety_timeout_sec)
			Config.set_timeout(2)
			helpers.assert_eq(Config.settings.timeout_sec,
				math.max(shared.timing.timeout_floor_sec, 2 - shared.timing.timeout_decrement_sec),
				"a real delay keeps the shared decrement")
		end)
		Config.settings.timeout_sec = saved
		if not ok then error(err, 0) end
	end)
end)
