--- tests/unit/ui/test_changelog_document_policy.lua

--- ==============================================================================
--- MODULE: Changelog Document Policy And Terminal Fetch
--- DESCRIPTION:
--- The shared changelog page declares a browser-host CSP ("script-src 'self'")
--- for external same-origin scripts. The macOS driver inlines those scripts, so
--- keeping that policy blocked every one of them: the page never armed its
--- watchdog, never defined injectError, and stayed on its loading spinner
--- whatever the network did. The generated document must therefore let every
--- script it carries run under exactly one policy. Independently, a request
--- whose transport raises or never answers must still end the fetch.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

local FIXTURE_DIR = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]") or ".")
local CHANGELOG_DIR = FIXTURE_DIR .. "/../../../../_shared/ui/changelog/"

--- Reads one file of the shared changelog tree.
--- @param path string
--- @return string
local function read(path)
	local handle = assert(io.open(path, "rb"), "missing shared asset " .. path)
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Builds the document the way ui_builder.build_injected_html does: i18n boot
--- first in <head>, then every local stylesheet and script inlined.
--- @return string
local function inlined_shared_document()
	local html = read(CHANGELOG_DIR .. "index.html")
	html = html:gsub("(<head[^>]*>)", function(tag)
		return tag .. '<script>window.__i18n_base="file:///locales/";window._i18n_locale="fr";</script>'
	end, 1)
	html = html:gsub('<link%s+rel="stylesheet"%s+href="([^"]+)"%s*/>', function(href)
		return "<style>" .. read(CHANGELOG_DIR .. href) .. "</style>"
	end)
	html = html:gsub('<script([^>]*)%s+src="([^"]+)"([^>]*)></script>', function(_, src)
		return "<script>" .. read(CHANGELOG_DIR .. src) .. "</script>"
	end)
	return html
end

--- Returns the source list governing inline scripts in one policy.
--- @param policy string
--- @return string
local function script_sources(policy)
	local sources = (";" .. policy):match(";%s*script%-src%s+([^;]*)")
		or (";" .. policy):match(";%s*default%-src%s+([^;]*)")
	return sources or "*"
end

--- Reports whether one inline <script> tag executes under one policy.
--- @param sources string script-src source list.
--- @param attributes string The tag's attributes.
--- @return boolean
local function inline_allowed(sources, attributes)
	local nonce = attributes:match('nonce="([^"]+)"')
	if nonce and sources:find("'nonce-" .. nonce .. "'", 1, true) then return true end
	-- 'unsafe-inline' is ignored as soon as a nonce or hash source is present.
	if sources:find("'nonce-", 1, true) or sources:find("'sha%d+-") then return false end
	return sources:find("'unsafe-inline'", 1, true) ~= nil or sources == "*"
end

helpers.describe("changelog: document policy and terminal fetch", function()
	helpers.it("every inlined page script runs under exactly one policy (changelog-document-policy)", function()
		with_changelog(function(window, state)
			package.loaded["ui.ui_builder"].build_injected_html = inlined_shared_document
			helpers.assert_true(window.open({ channel = "main" }))
			local html = state.view.options.html_string
			helpers.assert_type(html, "string")

			local policies = {}
			for position, policy in html:gmatch(
				'()<meta%s+http%-equiv="Content%-Security%-Policy"%s+content="([^"]*)"') do
				policies[#policies + 1] = { position = position, text = policy }
			end

			-- A meta policy governs only the scripts parsed after it.
			local scripts, first_script = 0, nil
			for position, attributes in html:gmatch("()<script([^>]*)>") do
				scripts = scripts + 1
				first_script = first_script or position
				for _, policy in ipairs(policies) do
					if policy.position < position then
						helpers.assert_true(inline_allowed(script_sources(policy.text), attributes),
							"inline script #" .. scripts .. " is blocked, so the page never leaves its spinner")
					end
				end
			end
			helpers.assert_eq(#policies, 1, "the generated document must publish exactly one CSP")
			helpers.assert_true(policies[1].position < first_script,
				"the policy must precede every script it governs")
			helpers.assert_true(scripts >= 6, "the config, i18n and every shared page script must be present")
			helpers.assert_true(policies[1].text:find("default-src 'none'", 1, true) ~= nil,
				"the generated policy must deny every unlisted source")
			helpers.assert_eq(policies[1].text:find("https:", 1, true), nil,
				"the page itself must never reach the network")
			helpers.assert_true(html:find("function injectError", 1, true) ~= nil)
			helpers.assert_true(html:find("function parseReleasesAtom", 1, true) ~= nil)
		end)
	end)

	helpers.it("two silent sources end in the network error (changelog-document-policy)", function()
		with_changelog(function(window, state, post)
			hs.json.decode = json.decode
			helpers.assert_true(window.open({ channel = "main" }))
			post("ready")
			post({ action = "fetch", channel = "main" })
			state.deadlines[1].callback()
			helpers.assert_eq(#state.deadlines, 2, "the feed fallback must be bounded")
			state.deadlines[2].callback()
			helpers.assert_eq(#state.evaluations, 1)
			helpers.assert_true(state.evaluations[1]:find('injectError("changelog_window.error_network")', 1, true) ~= nil)
		end)
	end)

	helpers.it("a transport that raises still ends the fetch (changelog-document-policy)", function()
		with_changelog(function(window, state, post)
			hs.json.decode = json.decode
			hs.http.asyncGet = function() error("synthetic NSURLSession refusal") end
			helpers.assert_true(window.open({ channel = "main" }))
			post("ready")
			post({ action = "fetch", channel = "main" })
			helpers.assert_eq(#state.evaluations, 1, "a refused request must publish a terminal state")
			helpers.assert_true(state.evaluations[1]:find('injectError("changelog_window.error_network")', 1, true) ~= nil)
		end)
	end)
end)
