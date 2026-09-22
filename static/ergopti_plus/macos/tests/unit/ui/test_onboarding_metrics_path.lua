--- tests/unit/ui/test_onboarding_metrics_path.lua

--- ==============================================================================
--- MODULE: Onboarding Metrics Path
--- DESCRIPTION:
--- Proves the step-4 consent warning names the metrics store of the folder the
--- user chose, resolved through the keylogger's own path rule. The wizard used
--- to pre-format the warning once, from the config path captured at open (and
--- one level too deep, under hammerspoon/), so a different folder chosen on the
--- config step never reached the text.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.onboarding_delivery_fixture")
local with_delivery = fixture.with_delivery


--- Decodes the single call argument the fixture captured.
--- @param state table Fixture state.
--- @return table payload
local function last_payload(state)
	helpers.assert_type(state.payload, "table")
	return state.payload
end


helpers.describe("onboarding metrics path", function()
	helpers.it("(onboarding-metrics-path) initData names the current folder's metrics store", function()
		with_delivery(function(_, state, pending, errors, evaluations)
			state.receiver({ body = { action = "ready" } })
			pending[#pending]()
			helpers.assert_eq(#errors, 0)
			helpers.assert_true(evaluations[1].code:find("window.initData(", 1, true) ~= nil)
			helpers.assert_eq(last_payload(state).metrics_path, "<metrics of /virtual/current>")
		end)
	end)

	helpers.it("(onboarding-metrics-path) a chosen folder resolves to its own metrics store", function()
		with_delivery(function(_, state, _, errors, evaluations)
			state.receiver({ body = { action = "resolveMetricsPath",
				config_dir = "/Users/me/Ergopti Data/", request = 3 } })
			helpers.assert_eq(#errors, 0)
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_true(evaluations[1].code:find("window.setMetricsPath(", 1, true) ~= nil)
			helpers.assert_eq(last_payload(state), {
				request = 3, path = "<metrics of /Users/me/Ergopti Data/>",
			})
		end)
	end)

	helpers.it("(onboarding-metrics-path) an empty field keeps the current folder", function()
		with_delivery(function(_, state)
			state.receiver({ body = { action = "resolveMetricsPath", config_dir = "", request = 1 } })
			helpers.assert_eq(last_payload(state).path, "<metrics of /virtual/current/>")
		end)
	end)

	helpers.it("(onboarding-metrics-path) going back and choosing again resolves again", function()
		with_delivery(function(_, state, _, _, evaluations)
			state.receiver({ body = { action = "resolveMetricsPath", config_dir = "/a/", request = 1 } })
			state.receiver({ body = { action = "resolveMetricsPath", config_dir = "/b/", request = 2 } })
			helpers.assert_eq(#evaluations, 2)
			helpers.assert_eq(last_payload(state), { request = 2, path = "<metrics of /b/>" })
		end)
	end)

	helpers.it("(onboarding-metrics-path) a request without its number is refused visibly", function()
		with_delivery(function(_, state, _, errors, evaluations)
			state.receiver({ body = { action = "resolveMetricsPath", config_dir = "/a/" } })
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(#errors, 1)
		end)
	end)

	helpers.it("(onboarding-metrics-path) a closed wizard receives no metrics path", function()
		with_delivery(function(_, state, _, _, evaluations)
			local receiver = state.receiver
			state.view.options.on_close()
			receiver({ body = { action = "resolveMetricsPath", config_dir = "/a/", request = 1 } })
			helpers.assert_eq(#evaluations, 0)
		end)
	end)

	for _, route in ipairs({ "ready", "previewLocale" }) do
		helpers.it("(onboarding-metrics-path) " .. route .. " ships the raw warning template", function()
			with_delivery(function(_, state, pending)
				fixture.dispatch(route, state, pending)
				local strings = last_payload(state).strings
				helpers.assert_eq(strings["dialog.metrics.enable_warning"], "dialog.metrics.enable_warning")
				helpers.assert_nil(strings["dialog.metrics.enable_warning_formatted"],
					"a pre-formatted warning freezes the path at open time")
			end)
		end)
	end
end)

helpers.describe("config_paths metrics directory", function()
	local function real_config_paths()
		return helpers.load_with_stubs("infra.config_paths", {})
	end

	helpers.it("(onboarding-metrics-path) the metrics store sits at the folder root", function()
		local ConfigPaths = real_config_paths()
		helpers.assert_eq(ConfigPaths.metrics_dir("/Users/me/data/"), "/Users/me/data/metrics")
		helpers.assert_eq(ConfigPaths.metrics_dir("/Users/me/data"), "/Users/me/data/metrics")
	end)

	helpers.it("(onboarding-metrics-path) an empty folder fails fast", function()
		local ConfigPaths = real_config_paths()
		helpers.assert_eq(pcall(ConfigPaths.metrics_dir, ""), false)
	end)
end)
