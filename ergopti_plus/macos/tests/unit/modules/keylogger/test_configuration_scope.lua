--- tests/unit/modules/keylogger/test_configuration_scope.lua

local helpers = require("tests.helpers")

local function fixture()
	local enabled, available, migrating, conversions = false, true, false, 0
	package.loaded["modules.keylogger.text_cipher"] = {
		set_enabled = function(value) enabled = value end,
		is_enabled = function() return enabled end,
		is_available = function() return available end,
	}
	package.loaded["modules.keylogger.text_migration"] = {
		is_running = function() return migrating end,
		resume_for_posture = function() conversions = conversions + 1 end,
	}
	package.loaded["modules.keylogger.kc_bridge"] = { init = function() return true end }
	local core = helpers.load_with_stubs("modules.keylogger")
	return core, function() return conversions end, function(value) migrating = value end,
		function(value) available = value end
end

helpers.describe("metrics scope native configuration", function()
	helpers.it("captures detached native values and changes future policy without converting existing records", function()
		local core, conversions = fixture()
		core.set_options({ encrypt = false, float = true })
		local prior = conversions()
		core.set_disabled_apps({ { bundleID = "private.app" } })
		local snapshot = core.configuration_snapshot()
		helpers.assert_eq(snapshot.enabled, false)
		snapshot.disabled_apps[1].bundleID = "copy.only"
		helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].bundleID, "private.app")
		local candidate = core.configuration_snapshot()
		candidate.options.encrypt = true
		candidate.cipher_enabled = true
		candidate.private_filter_enabled = false
		helpers.assert_eq(core.apply_configuration(candidate), true)
		helpers.assert_eq(core.configuration_snapshot().options.encrypt, true)
		helpers.assert_eq(core.configuration_snapshot().cipher_enabled, true)
		helpers.assert_eq(core.configuration_snapshot().private_filter_enabled, false)
		helpers.assert_eq(conversions(), prior, "scope cannot launch/resume historical conversion")
	end)
	helpers.it("refuses conversion races and unavailable encryption without publishing native preferences", function()
		local core, _, migration, availability = fixture()
		local candidate = core.configuration_snapshot()
		candidate.options.encrypt = true
		candidate.cipher_enabled = true
		candidate.private_filter_enabled = false
		migration(true)
		helpers.assert_eq(core.apply_configuration(candidate), false)
		helpers.assert_eq(core.configuration_snapshot(), nil, "an active data conversion is outside scope admission")
		migration(false)
		availability(false)
		helpers.assert_eq(core.apply_configuration(candidate), false)
		helpers.assert_eq(core.configuration_snapshot().options.encrypt, false)
		helpers.assert_eq(core.configuration_snapshot().private_filter_enabled, true)
	end)
end)
