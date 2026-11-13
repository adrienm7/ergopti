--- tests/unit/layouts/engine/registry/test_channel.lua

--- ==============================================================================
--- MODULE: Installed Build Channel Registry Tests
--- DESCRIPTION:
--- Catalogue URLs follow the installed build owner rather than the default
--- stable branch. Local-source refresh still avoids HTTP and real HTTP failures
--- remain errors for packaged builds.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local Registry = require("layouts.engine.registry.registry_core")
local Catalogue = require("layouts.engine.composer.catalogue")
local Channels = require("updater.engine.channels")
local root = helpers.driver_root() .. "/../_shared/"
local fh = assert(io.open(root .. "updater/data/channels.json", "rb"))
local channels = assert(Channels.load(Json.decode(fh:read("*a"))))
fh:close()

helpers.describe("layout registry installed channel", function()
	for _, case in ipairs({ { "1.2.3", "main", false }, { "0.0.0-dev.131", "dev", false }, { "local", "dev", true } }) do
		helpers.it("routes " .. case[1] .. " through its installed owner", function()
			local owner = "updater.engine"
			local original = package.loaded[owner]
			local ok, failure = xpcall(function()
				package.loaded[owner] = { installed_channel = function()
					return channels.channel_for_tag(case[1]) or channels.unreleased_build_channel
				end }
				local host = helpers.load_with_stubs("layouts.engine.registry.registry")
				local settings = assert(host.settings())
				helpers.assert_eq(settings.branch, case[2])
				local requests, result = {}, nil
				Catalogue.refresh(settings, {
					clone_registry = case[3], bundled_index = { layouts = {} },
					read_cache = function() return nil end, write_cache = function() error("404 cannot be cached") end,
					decode_json = Json.decode,
					transport = { get = function(url, _, _, callback)
						requests[#requests + 1] = url
						callback(404, "", nil, {})
					end },
				}, function(outcome) result = outcome end)
				if case[3] then
					helpers.assert_eq(#requests, 0)
					helpers.assert_eq(result.error, nil)
				else
					helpers.assert_eq(#requests, 1)
					helpers.assert_eq(requests[1], Registry.raw_url(settings, settings.index_file))
					helpers.assert_true(requests[1]:find("/" .. case[2] .. "/", 1, true) ~= nil)
					helpers.assert_eq(result.error.code, Catalogue.ERROR_HTTP)
					helpers.assert_eq(result.error.detail, "HTTP 404")
				end
			end, debug.traceback)
			package.loaded[owner] = original
			assert(ok, failure)
		end)
	end
end)
