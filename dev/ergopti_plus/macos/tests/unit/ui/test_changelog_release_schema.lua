--- tests/unit/ui/test_changelog_release_schema.lua

--- ==============================================================================
--- MODULE: Changelog HTTP Release Schema
--- DESCRIPTION:
--- Real JSON responses must be validated before native filtering or UI publication.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

-- LuaSkin encodes an empty table as NSArray; the shared encoder chooses an object.
local function native_encode(value)
	if type(value) == "table" and next(value) == nil then return "[]" end
	return json.encode(value)
end

local invalid = {
	{ name = "boolean entry", body = "[true]" },
	{ name = "numeric entry", body = "[42]" },
	{ name = "string entry", body = '["private-release-data"]' },
	{ name = "object envelope", body = '{"message":"private-release-data"}' },
	{ name = "empty object envelope", body = "{}" },
	{ name = "nested array entry", body = '[["private-release-data"]]' },
	{ name = "numeric notes", body = '[{"tag_name":"v1","body":42}]' },
	{ name = "boolean notes", body = '[{"tag_name":"v1","body":true}]' },
	{ name = "string prerelease", body = '[{"tag_name":"v1","prerelease":"false"}]' },
	{ name = "object date", body = '[{"published_at":{"private-release-data":true}}]' },
	{ name = "object tag", body = '[{"tag_name":{"private-release-data":true}}]' },
	{ name = "boolean URL", body = '[{"html_url":true}]' },
}

helpers.describe("changelog release response schema", function()
	helpers.it("accepts nullable fields using the native LuaSkin decoding contract", function()
		with_changelog(function(window, state, post)
			local body = '[{"tag_name":"v1","body":null,"published_at":null,"html_url":null}]'
			hs.json.decode = function(input)
				helpers.assert_eq(input, body)
				-- LuaSkin maps NSNull fields to nil, unlike the shared decoder sentinel.
				return {{ tag_name = "v1" }}
			end
			hs.json.encode = native_encode
			helpers.assert_true(window.open())
			post("ready")
			post({ action = "fetch", channel = "main" })
			state.callbacks[1](200, body, {})
			helpers.assert_eq(#state.evaluations, 1)
			helpers.assert_eq(state.evaluations[1], 'injectReleases([{"tag_name":"v1"}],"main")')
		end)
	end)
	for _, channel in ipairs({ "main", "dev" }) do
		helpers.it("publishes an actual empty JSON array on " .. channel, function()
			with_changelog(function(window, state, post)
				hs.json.decode = json.decode
				hs.json.encode = native_encode
				helpers.assert_true(window.open({ channel = channel }))
				post("ready")
				post({ action = "fetch", channel = channel })
				state.callbacks[1](200, "[]", {})
				helpers.assert_eq(#state.evaluations, 1)
				helpers.assert_eq(state.evaluations[1], 'injectReleases([],"' .. channel .. '")')
			end)
		end)
		for _, sample in ipairs(invalid) do
			helpers.it("(changelog-release-schema) rejects " .. sample.name .. " on " .. channel, function()
				with_changelog(function(window, state, post)
					hs.json.decode = json.decode
					hs.json.encode = native_encode
					local warnings = {}
					package.loaded["infra.logger"].warn = function(_, message, ...)
						warnings[#warnings + 1] = string.format(message, ...)
					end
					helpers.assert_true(window.open({ channel = channel }))
					post("ready")
					post({ action = "fetch", channel = channel })
					helpers.assert_eq(#state.callbacks, 1)
					state.callbacks[1](200, sample.body, {})
					helpers.assert_eq(#state.evaluations, 1)
					helpers.assert_true(state.evaluations[1]:find("injectError(", 1, true) ~= nil)
					helpers.assert_true(state.evaluations[1]:find("changelog_window.error_parse", 1, true) ~= nil)
					helpers.assert_eq(#warnings, 1)
					helpers.assert_eq(warnings[1]:find("private-release-data", 1, true), nil)
				end)
			end)
		end
		helpers.it("publishes optional notes and filters releases on " .. channel, function()
			with_changelog(function(window, state, post)
				hs.json.decode = json.decode
				hs.json.encode = native_encode
				helpers.assert_true(window.open({ channel = channel }))
				post("ready")
				post({ action = "fetch", channel = channel })
				state.callbacks[1](200,
					'[{"tag_name":"stable-v1","prerelease":false},'
						.. '{"tag_name":"preview-v2","prerelease":true,"body":"notes"}]', {})
				helpers.assert_eq(#state.evaluations, 1)
				helpers.assert_true(state.evaluations[1]:find("injectReleases([", 1, true) ~= nil)
				helpers.assert_true(state.evaluations[1]:find("stable-v1", 1, true) ~= nil)
				helpers.assert_eq(state.evaluations[1]:find("preview-v2", 1, true) ~= nil, channel == "dev")
			end)
		end)
	end
end)
