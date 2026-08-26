--- tests/unit/modules/updater/test_update_asset_integrity.lua
---
--- ============================================================================
--- MODULE: Updater Release Asset Integrity Regression Tests
--- DESCRIPTION:
--- Ensures self-update accepts only the exact GitHub release asset for the
--- selected tag and requires a release-provided SHA-256 digest before caching.
--- ============================================================================

local helpers = require("tests.helpers")

local DIGEST = string.rep("a", 64)
local TAG = "v2.0.0"
local VALID_URL = "https://github.com/adrienm7/ergopti/releases/download/"
	.. TAG .. "/ErgoptiPlus.app.zip"


--- Builds one GitHub release response with caller-controlled asset metadata.
--- @param url string Asset download URL.
--- @param digest string|nil Asset digest as returned by GitHub.
--- @param asset_name string|nil Asset filename.
--- @return string body Encoded response body.
local function release_body(url, digest, asset_name)
	local digest_field = digest and string.format(',"digest":"%s"', digest) or ""
	return string.format(
		[[{"tag_name":"%s","body":"notes","assets":[{"name":"%s","browser_download_url":"%s"%s}]}]],
		TAG,
		asset_name or "ErgoptiPlus.app.zip",
		url,
		digest_field
	)
end


--- Loads the real updater with deterministic headless dependencies.
--- @return table updater Fresh updater module.
local function fresh_updater()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.file_system"] = { read = function() return nil end }
	package.loaded["adapters.json_codec"] = nil
	package.loaded["adapters.network_info"] = {
		isInternetReachable = function() return true end,
		hasInternetProbeResult = function() return false end,
	}
	package.loaded["adapters.notifier"] = { send = function() return true end }
	return helpers.load_with_stubs("modules.updater", {
		processInfo = { bundleID = "com.ergopti.app", version = "1.0.0" },
	})
end


--- Loads a packaged updater with controllable background HTTP responses.
--- @return table updater Fresh updater module.
--- @return table requests Captured HTTP requests.
--- @return table observed Notification and menu-update counters.
local function fresh_background_updater()
	local requests = {}
	local observed = { notifications = 0, menu_updates = 0 }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.file_system"] = { read = function() return nil end }
	package.loaded["adapters.json_codec"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.network_info"] = {
		isInternetReachable = function() return true end,
		hasInternetProbeResult = function() return false end,
	}
	package.loaded["adapters.notifier"] = {
		send = function() observed.notifications = observed.notifications + 1 return true end,
	}
	local updater = helpers.load_with_stubs("modules.updater", {
		processInfo = { bundleID = "com.ergopti.app", version = "1.0.0" },
		http = {
			asyncGet = function(url, headers, callback)
				requests[#requests + 1] = { url = url, headers = headers, callback = callback }
			end,
		},
	})
	return updater, requests, observed
end


helpers.describe("updater: release asset integrity", function()
	helpers.it("parses only the exact repository asset and its SHA-256 digest", function()
		local updater = fresh_updater()
		local asset, reason = updater.parse_install_asset(
			release_body(VALID_URL, "sha256:" .. DIGEST),
			TAG
		)

		helpers.assert_true(asset ~= nil, tostring(reason))
		helpers.assert_eq(asset.tag, TAG)
		helpers.assert_eq(asset.zip_url, VALID_URL)
		helpers.assert_eq(asset.sha256, DIGEST)
		helpers.assert_eq(updater.validate_install_asset(asset), true)
	end)

	helpers.it("rejects off-origin, cross-release, and decorated download URLs", function()
		local updater = fresh_updater()
		local invalid_urls = {
			"https://example.test/ErgoptiPlus.app.zip",
			"http://github.com/adrienm7/ergopti/releases/download/" .. TAG .. "/ErgoptiPlus.app.zip",
			"https://user:token@github.com/adrienm7/ergopti/releases/download/" .. TAG
				.. "/ErgoptiPlus.app.zip",
			VALID_URL .. "?token=secret",
			VALID_URL .. "#fragment",
			"https://github.com/adrienm7/other/releases/download/" .. TAG .. "/ErgoptiPlus.app.zip",
			"https://github.com/adrienm7/ergopti/releases/download/v3.0.0/ErgoptiPlus.app.zip",
			"https://github.com/adrienm7/ergopti/releases/download/" .. TAG .. "/Other.app.zip",
		}

		for _, url in ipairs(invalid_urls) do
			local asset = updater.parse_install_asset(
				release_body(url, "sha256:" .. DIGEST),
				TAG
			)
			helpers.assert_eq(asset, nil, "unsafe asset URL must be rejected: " .. url)
		end
	end)

	helpers.it("rejects missing or malformed digests before caching", function()
		local updater = fresh_updater()
		local bodies = {
			release_body(VALID_URL, nil),
			release_body(VALID_URL, "md5:" .. string.rep("a", 32)),
			release_body(VALID_URL, "sha256:abc"),
			release_body(VALID_URL, "sha256:" .. string.rep("g", 64)),
		}

		for _, body in ipairs(bodies) do
			local asset = updater.parse_install_asset(body, TAG)
			helpers.assert_eq(asset, nil, "release without a valid SHA-256 must be rejected")
		end

		helpers.assert_eq(updater.set_cached_release({
			tag = TAG,
			zip_url = "https://example.test/archive.zip",
			sha256 = DIGEST,
		}), false)
		helpers.assert_eq(updater.get_cached_release(), nil)
		helpers.assert_eq(updater.set_cached_release({
			tag = TAG,
			zip_url = VALID_URL,
			sha256 = DIGEST,
		}), true)
		helpers.assert_eq(updater.get_cached_release().sha256, DIGEST)
	end)

	helpers.it("background polling cannot cache or announce an unsafe asset", function()
		local updater, requests, observed = fresh_background_updater()
		helpers.assert_eq(updater.start_background_checks("main", 60, function()
			observed.menu_updates = observed.menu_updates + 1
		end), true)

		local boot_timer
		local recurring_timer
		for _, timer in ipairs(_G.hs.timer.__timers) do
			if timer.delay == updater.BOOT_CHECK_DELAY_SEC then boot_timer = timer end
			if timer.delay == 60 then recurring_timer = timer end
		end
		helpers.assert_true(boot_timer ~= nil, "background boot timer must be owned")
		helpers.assert_true(recurring_timer ~= nil, "background recurring timer must be owned")

		boot_timer:fire()
		helpers.assert_eq(#requests, 1)
		requests[1].callback(200, release_body(
			"https://example.test/ErgoptiPlus.app.zip",
			"sha256:" .. DIGEST
		), {})
		helpers.assert_eq(updater.get_cached_release(), nil)
		helpers.assert_eq(updater.get_update_state(), "idle")
		helpers.assert_eq(observed.notifications, 0)
		helpers.assert_eq(observed.menu_updates, 0)

		recurring_timer:fire()
		helpers.assert_eq(#requests, 2)
		requests[2].callback(200, release_body(VALID_URL, "sha256:" .. DIGEST), {})
		helpers.assert_eq(updater.get_cached_release().zip_url, VALID_URL)
		helpers.assert_eq(observed.notifications, 1)
		helpers.assert_eq(observed.menu_updates, 1)
		helpers.assert_eq(updater.stop_background_checks(), true)
	end)
end)
