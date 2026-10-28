--- tests/unit/modules/keystats/context_tracker/test_foreground_refresh_refusal.lua

--- Native foreground refusal revokes the actual public persistence sink on resume.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keystats.context_tracker.foreground_refusal_fixture")

local function assert_sink(runtime, expected)
	local accepted, count = runtime.sink()
	helpers.assert_eq(runtime.engine.may_persist(), expected)
	helpers.assert_eq(accepted, expected)
	helpers.assert_eq(count, expected and 1 or 0)
end

local function assert_clear(runtime)
	helpers.assert_eq(runtime.state.foreground_refresh_pending == true, false)
end

local function resume_in(runtime, name, bundle, fault)
	runtime.pause()
	runtime.foreground(name, bundle)
	runtime.activate()
	helpers.assert_eq(runtime.state.active_app_name, "TextEdit", "Paused callbacks retain their accepted cache")
	runtime.native.fault = fault
	return runtime.resume()
end

local function ordinary(runtime)
	runtime.foreground("Terminal", "com.apple.Terminal")
	runtime.native.fault = nil
end

helpers.describe("Foreground refresh refusal at the real public resume boundary", function()
	helpers.it("revokes persistence before the first native resync lookup", function()
		Fixture.with_runtime(function(runtime)
			local queries = 0
			runtime.native.on_frontmost = function()
				queries = queries + 1
				assert_sink(runtime, false)
				helpers.assert_eq(runtime.state.foreground_refresh_pending, true)
			end
			helpers.assert_true(runtime.engine.resync_context())
			runtime.native.on_frontmost = nil
			helpers.assert_true(queries > 0)
			assert_clear(runtime); assert_sink(runtime, true)
		end)
	end)

	for _, healthy in ipairs({ "ordinary", "vault" }) do
		helpers.it("keeps the healthy " .. healthy .. " resume policy", function()
			Fixture.with_runtime(function(runtime)
				local is_ordinary = healthy == "ordinary"
				resume_in(runtime, is_ordinary and "Terminal" or "1Password",
					is_ordinary and "com.apple.Terminal" or "com.1password.1password")
				assert_clear(runtime)
				assert_sink(runtime, is_ordinary)
			end)
		end)
	end

	for _, fault in ipairs({ "nil-frontmost", "throw-frontmost", "nil-name", "empty-name", "throw-name" }) do
		helpers.it("denies the public sink after " .. fault .. " and recovers through healthy resume", function()
			Fixture.with_runtime(function(runtime)
				resume_in(runtime, "1Password", "com.1password.1password", fault)
				assert_sink(runtime, false)
				helpers.assert_eq(runtime.state.foreground_refresh_pending, true)
				runtime.native.fault = nil
				runtime.pause(); runtime.resume()
				assert_clear(runtime)
				helpers.assert_eq(runtime.state.is_secure_field, true)
				assert_sink(runtime, false)
			end)
		end)
	end

	for _, policy in ipairs({ "secure-off", "all-filters-off", "disabled-app", "system-auth" }) do
		helpers.it("keeps foreground refusal independent of " .. policy, function()
			Fixture.with_runtime(function(runtime)
				runtime.engine.set_secure_field_filter_enabled(false)
				if policy == "all-filters-off" then
					runtime.engine.set_private_filter_enabled(false)
					runtime.engine.set_system_auth_filter_enabled(false)
				elseif policy == "disabled-app" then
					runtime.engine.set_disabled_apps({ { bundleID = "com.1password.1password" } })
				end
				assert_sink(runtime, true)
				local auth = policy == "system-auth"
				resume_in(runtime, auth and "SecurityAgent" or "1Password",
					auth and "com.apple.SecurityAgent" or "com.1password.1password", "nil-frontmost")
				assert_sink(runtime, false)
				helpers.assert_eq(runtime.state.foreground_refresh_pending, true)
				ordinary(runtime); helpers.assert_true(runtime.tracker.capture_frontmost_app())
				assert_clear(runtime); assert_sink(runtime, true)
			end)
		end)
	end

	for _, writer in ipairs({ "capture", "activation" }) do
		helpers.it("recovers ordinary persistence only after an accepted " .. writer, function()
			Fixture.with_runtime(function(runtime)
				resume_in(runtime, "1Password", "com.1password.1password", "nil-frontmost")
				assert_sink(runtime, false)
				ordinary(runtime)
				if writer == "capture" then runtime.tracker.capture_frontmost_app() else runtime.activate() end
				assert_clear(runtime); assert_sink(runtime, true)
			end)
		end)
	end

	helpers.it("does not promote a capture whose application callback is still paused", function()
		Fixture.with_runtime(function(runtime)
			resume_in(runtime, "1Password", "com.1password.1password", "nil-frontmost")
			assert_sink(runtime, false)
			runtime.pause(); ordinary(runtime)
			helpers.assert_true(runtime.tracker.capture_frontmost_app(), "Legacy capture acknowledgement is not recovery evidence")
			helpers.assert_eq(runtime.state.foreground_refresh_pending, true)
			helpers.assert_eq(runtime.state.active_app_name, "TextEdit")
			assert_sink(runtime, false)
			runtime.resume(); assert_sink(runtime, true)
		end)
	end)

	for _, fault in ipairs({ "throw-bundle", "throw-path", "throw-pid", "nil-pid" }) do
		helpers.it("retains refusal after a partial native refresh: " .. fault, function()
			Fixture.with_runtime(function(runtime)
				resume_in(runtime, "Terminal", "com.apple.Terminal", fault)
				assert_sink(runtime, false)
				helpers.assert_eq(runtime.state.foreground_refresh_pending, true)
				ordinary(runtime); runtime.activate()
				assert_clear(runtime); assert_sink(runtime, true)
			end)
		end)
	end

	for _, field in ipairs({ "no_bundle", "no_path" }) do
		helpers.it("accepts successful optional native metadata absence: " .. field, function()
			Fixture.with_runtime(function(runtime)
				runtime.native[field] = true
				resume_in(runtime, "Terminal", "com.apple.Terminal")
				assert_clear(runtime); assert_sink(runtime, true)
			end)
		end)
	end

	for _, result in ipairs({ "false", "throw" }) do
		helpers.it("rearms after delegated refusal following a successful actual refresh: " .. result, function()
			Fixture.with_runtime(function(runtime)
				runtime.native.after_resync = result
				resume_in(runtime, "Terminal", "com.apple.Terminal")
				helpers.assert_eq(runtime.state.active_app_name, "Terminal")
				assert_sink(runtime, false)
				helpers.assert_eq(runtime.state.foreground_refresh_pending, true)
				runtime.native.after_resync = nil
				runtime.pause(); runtime.resume()
				assert_clear(runtime); assert_sink(runtime, true)
			end)
		end)
	end

	for _, writer in ipairs({ "activation", "capture" }) do
		helpers.it("preserves a physical ordinary hold through healthy " .. writer, function()
			Fixture.with_runtime(function(runtime)
				local timestamp = runtime.modifier_press()
				ordinary(runtime)
				if writer == "activation" then runtime.activate() else runtime.tracker.capture_frontmost_app() end
				helpers.assert_eq(runtime.state.modifier_down_at[55], timestamp)
				helpers.assert_eq(runtime.state.modifier_suppressed_releases[55], nil)
				assert_clear(runtime); assert_sink(runtime, true)
			end)
		end)
	end
end)
