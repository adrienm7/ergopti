--- tests/unit/adapters/test_keyboard_geometry_boot_contract.lua

--- ==============================================================================
--- MODULE: Keyboard Geometry Boot and Child Environment Contract
--- DESCRIPTION:
--- Keeps the immutable native map boot-owned and out of helper environments.
--- Initialization must precede configuration-dependent input consumers.
--- ==============================================================================

local helpers = require("tests.helpers")
local KEY = "ERGOPTI_KEYBOARD_GEOMETRY_V1"

helpers.describe("keyboard geometry boot ownership", function()
	helpers.it("initializes exactly once before configuration-dependent consumer requires", function()
		local source, detail = helpers.read_driver_unit("local function finish_boot_after_onboarding()")
		helpers.assert_true(source ~= nil, detail)
		source = source:gsub("%-%-[^\n]*", "")
		local initialize = 'require("adapters.keyboard_geometry").initialize()'
		local position = source:find(initialize, 1, true)
		helpers.assert_true(position ~= nil, "root boot must explicitly initialize keyboard geometry")
		helpers.assert_nil(source:find(initialize, position + #initialize, true),
			"accessibility resume must not initialize a second geometry owner")
		for _, marker in ipairs({ 'require("adapters.file_system")', 'pcall(require, "platform.remap")',
			'require("ui.menu")', "local function finish_boot_after_onboarding()", "shortcuts.start_script_control" }) do
			local consumer = source:find(marker, 1, true)
			helpers.assert_true(consumer ~= nil, "the boot guard must retain consumer coverage: " .. marker)
			helpers.assert_true(position < consumer, "native geometry must precede consumer: " .. marker)
		end
	end)

	helpers.it("reports the boot field and strips it before helper construction", function()
		helpers.with_fresh_modules({ "infra.launcher_environment" }, function()
			local policy = require("infra.launcher_environment")
			local present = policy.presence(function(key) return key == KEY and "native map" or nil end)
			helpers.assert_eq(present, { KEY })
			local sanitized, reason = policy.child_copy({ [KEY] = "native map", PATH = "/usr/bin:/bin" })
			helpers.assert_nil(reason)
			helpers.assert_nil(sanitized[KEY])
			helpers.assert_eq(sanitized.PATH, "/usr/bin:/bin")
			local restored, refusal = policy.child_copy({}, { [KEY] = "borrowed map" })
			helpers.assert_nil(restored)
			helpers.assert_eq(refusal, "explicit child environment contains launcher-only authority: " .. KEY)
			local verified, detail = policy.verify_child_copy({}, { [KEY] = "inherited map" })
			helpers.assert_eq(verified, false)
			helpers.assert_eq(detail, "launcher-only environment key survived native sanitization: " .. KEY)
		end)
	end)
end)
