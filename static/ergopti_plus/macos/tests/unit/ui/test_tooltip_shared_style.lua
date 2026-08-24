--- tests/unit/ui/test_tooltip_shared_style.lua

--- ==============================================================================
--- MODULE: Tooltip Shared-Style Contract Tests
--- DESCRIPTION:
--- Guards that the macOS tooltip reads its visual style (corner radius, border
--- ring, separator) from the SINGLE shared source — _shared/modules/tooltip/constants.toml
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
	local toml_reader = require("infra.toml.reader")
	local path = helpers.shared("modules/tooltip/constants.toml")
	local ok, data = pcall(toml_reader.parse, path)
	helpers.assert_true(ok and type(data) == "table" and type(data.sections) == "table",
		"_shared/modules/tooltip/constants.toml must parse with sections")
	return data.sections
end

helpers.describe("Tooltip: shared-style wiring", function()
	local Config = helpers.load_with_stubs("ui.tooltip.config")
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
end)
