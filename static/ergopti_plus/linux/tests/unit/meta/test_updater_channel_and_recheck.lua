--- tests/unit/meta/test_updater_channel_and_recheck.lua

--- ==============================================================================
--- MODULE: The Updater Finds A Release And Keeps It Found
--- DESCRIPTION:
--- Measured on an installed v0.0.0-dev.133: its updater asked the "stable"
--- channel, GitHub's /releases/latest (which never lists a prerelease)
--- answered 404, and no update was ever found — every published release is a
--- prerelease. A prerelease build now follows prereleases until the user picks
--- a channel. And a found release is no longer forgotten by the next periodic
--- check answering "unchanged" (304) or failing.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

--- A fresh updater at `version`, on a store holding `stored`.
local function updater(version, stored)
	local saved = {
		version = package.loaded["infra.version"],
		storage = package.loaded["adapters.storage"],
		manager = package.loaded["modules.updater.manager"],
		fs = package.loaded["adapters.file_system"],
	}
	local fs = require("adapters.file_system")
	local config_path = "/virtual/updater-channel-test.toml"
	local configured = stored and stored["updater.channel"]
	package.loaded["adapters.file_system"] = setmetatable({
		read = function(path)
			if path == config_path then
				return configured and ('[updater]\nchannel = "' .. configured .. '"\n') or nil
			end
			return fs.read(path)
		end,
	}, { __index = fs })
	package.loaded["infra.version"] = { VERSION = version }
	package.loaded["adapters.storage"] = Fakes.storage({ initial = stored or {} })
	package.loaded["modules.updater.manager"] = nil
	local M = require("modules.updater.manager")
	local init = M.init
	M.init = function(opts)
		opts = opts or {}
		opts.config_path = config_path
		return init(opts)
	end
	local function restore()
		M.stop_background_checks()
		package.loaded["infra.version"] = saved.version
		package.loaded["adapters.storage"] = saved.storage
		package.loaded["modules.updater.manager"] = saved.manager
		package.loaded["adapters.file_system"] = saved.fs
	end
	return M, restore
end

--- A release response naming `tag` with the canonical bundle and checksum.
local function release_body(M, tag)
	local base = "https://github.com/adrienm7/ergopti/releases/download/" .. tag .. "/"
	return '{"tag_name":"' .. tag .. '","prerelease":true,"body":"notes","published_at":"2026-09-24T00:00:00Z",'
		.. '"assets":[{"name":"' .. M.LINUX_ASSET_NAME .. '","browser_download_url":"' .. base .. M.LINUX_ASSET_NAME .. '"},'
		.. '{"name":"' .. M.LINUX_CHECKSUM_ASSET_NAME .. '","browser_download_url":"' .. base
		.. M.LINUX_CHECKSUM_ASSET_NAME .. '"}]}'
end

local function with_updater(version, stored, body)
	local M, restore = updater(version, stored)
	local ok, err = pcall(body, M)
	restore()
	if not ok then error(err, 0) end
end

helpers.describe("updater: the channel an installation follows", function()

	helpers.it("follows prereleases when it is itself a prerelease", function()
		with_updater("0.0.0-dev.133", nil, function(M)
			M.init({ interval_sec = 0 })
			helpers.assert_eq(M.get_channel(), "dev", "a -dev build on 'stable' can never find an update")
			helpers.assert_true(M.release_api_url(M.get_channel()):find("/releases?per_page=", 1, true) ~= nil)
		end)
	end)

	helpers.it("follows stable releases when it is one", function()
		with_updater("4.2.0", nil, function(M)
			M.init({ interval_sec = 0 })
			helpers.assert_eq(M.get_channel(), M.CHANNELS.resolve("stable"))
		end)
	end)

	helpers.it("keeps the channel the user picked", function()
		with_updater("0.0.0-dev.133", { ["updater.channel"] = "stable" }, function(M)
			M.init({ interval_sec = 0 })
			helpers.assert_eq(M.get_channel(), M.CHANNELS.resolve("stable"))
		end)
	end)

end)

helpers.describe("updater: a found release stays found", function()

	--- Runs one check whose response is delivered by `respond(callback)`.
	local function check(M, respond)
		local real = M._http_client
		local result = nil
		M._http_client = {
			get = function(_url, _headers, _options, callback)
				respond(function(body, status, err)
					callback({ ok = status == 200, body = body or "", status = status, error = err,
					error_body = status == 304 and "" or nil })
				end)
				return true
			end,
		}
		M._http_client = require("tests.support.release_http_fixture").attach(M._http_client)
		M.check_for_updates(nil, function(available, release, err)
			result = { available = available, release = release, err = err }
		end)
		M._http_client = real
		return result
	end

	helpers.it("still offers the release when the next check answers 304", function()
		with_updater("0.0.0-dev.133", nil, function(M)
			M.init({ interval_sec = 0 })
			local first = check(M, function(cb) cb("[" .. release_body(M, "v0.0.0-dev.134") .. "]", 200, nil) end)
			helpers.assert_true(first.available)
			local second = check(M, function(cb) cb(nil, 304, nil) end)
			helpers.assert_true(second.available, "unchanged is not gone")
			helpers.assert_eq(second.release.tag, "v0.0.0-dev.134")
			helpers.assert_nil(second.err)
			helpers.assert_eq(M.get_state(), "available", "the menu keeps its install row")
		end)
	end)

	helpers.it("still offers the release when the next check fails", function()
		with_updater("0.0.0-dev.133", nil, function(M)
			M.init({ interval_sec = 0 })
			check(M, function(cb) cb("[" .. release_body(M, "v0.0.0-dev.134") .. "]", 200, nil) end)
			local offline = check(M, function(cb) cb(nil, 0, "offline") end)
			helpers.assert_true(offline.available)
			helpers.assert_eq(offline.err, "offline", "the failure is still reported")
			helpers.assert_eq(M.get_cached_release().tag, "v0.0.0-dev.134")
		end)
	end)

	helpers.it("forgets it when a fresh answer says the installation is current", function()
		with_updater("0.0.0-dev.134", nil, function(M)
			M.init({ interval_sec = 0 })
			local current = check(M, function(cb) cb("[" .. release_body(M, "v0.0.0-dev.134") .. "]", 200, nil) end)
			helpers.assert_true(not current.available)
			helpers.assert_eq(M.get_state(), "idle")
		end)
	end)

end)
