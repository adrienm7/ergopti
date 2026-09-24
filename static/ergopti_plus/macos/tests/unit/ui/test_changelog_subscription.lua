--- tests/unit/ui/test_changelog_subscription.lua

--- ==============================================================================
--- MODULE: Changelog Subscription Through The Channel Owner
--- DESCRIPTION:
--- The Versions window used to take "main" or "dev" from its caller and filter
--- the stable list by GitHub's pre-release flag; the page could not subscribe,
--- and a channel chosen in the menu never reached an open window. The window
--- now accepts registry ids only, opens on the owner's channel, subscribes
--- through the menu session's channel owner, and receives the owner's changes.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

--- A channel owner double with the real owner's shape.
--- @param subscribed string Channel it starts on.
--- @param accept boolean What set() answers.
--- @return table owner, table record
local function owner_double(subscribed, accept)
	local record = { sets = {}, listeners = {}, current = subscribed }
	local owner = {
		get = function() return record.current end,
		set = function(id)
			record.sets[#record.sets + 1] = id
			if not accept then return false end
			record.current = id
			for _, fn in pairs(record.listeners) do fn(id) end
			return true
		end,
		subscribe = function(key, fn) record.listeners[key] = fn end,
	}
	return owner, record
end

--- Returns whether any evaluated script equals the expected one.
local function evaluated(state, script)
	for _, code in ipairs(state.evaluations) do
		if code == script then return true end
	end
	return false
end

helpers.describe("Changelog subscription", function()
	helpers.it("opens on the owner's channel and seeds the subscription", function()
		with_changelog(function(changelog, state)
			local owner = owner_double("dev", true)
			helpers.assert_true(changelog.open({ channel_owner = owner }))
			local html = state.view.options.html_string
			helpers.assert_true(html:find('window.__changelog_channel="dev"', 1, true) ~= nil,
				"the window opens on the subscribed channel")
			helpers.assert_true(html:find('window.__subscribed_channel="dev"', 1, true) ~= nil,
				"the page needs the subscription for its banner")
			helpers.assert_true(html:find("window.__channel_switch_restarts=false", 1, true) ~= nil,
				"a channel change does not restart the macOS app")
		end)
	end)

	helpers.it("refuses to open on a channel outside the registry", function()
		with_changelog(function(changelog, state)
			for _, unknown in ipairs({ "stable", "beta", "Main" }) do
				helpers.assert_eq(changelog.open({ channel = unknown }), false, unknown .. " must be refused")
			end
			helpers.assert_eq(state.creates, 0, "no window may open on an unknown channel")
		end)
	end)

	helpers.it("subscribes through the owner and answers the page", function()
		with_changelog(function(changelog, state, post)
			local owner, record = owner_double("dev", true)
			helpers.assert_true(changelog.open({ channel_owner = owner }))
			post("ready")
			post({ action = "set_channel", channel = "main" })
			helpers.assert_eq(#record.sets, 1, "the owner must be asked once")
			helpers.assert_eq(record.sets[1], "main")
			helpers.assert_true(evaluated(state, 'setSubscribedChannel("main",true)'),
				"the page must learn the new subscription")
		end)
	end)

	helpers.it("refuses ids outside the registry without touching the owner", function()
		with_changelog(function(changelog, state, post)
			local owner, record = owner_double("dev", true)
			helpers.assert_true(changelog.open({ channel_owner = owner }))
			post("ready")
			for _, unknown in ipairs({ "stable", "beta", "Main", 42 }) do
				post({ action = "set_channel", channel = unknown })
			end
			helpers.assert_eq(#record.sets, 0, "no unknown id may reach the owner")
			helpers.assert_true(evaluated(state, 'setSubscribedChannel("dev",false)'),
				"the page must show the refusal and keep the subscription")
		end)
	end)

	helpers.it("reports an owner refusal to the page", function()
		with_changelog(function(changelog, state, post)
			local owner, record = owner_double("dev", false)
			helpers.assert_true(changelog.open({ channel_owner = owner }))
			post("ready")
			post({ action = "set_channel", channel = "main" })
			helpers.assert_eq(#record.sets, 1)
			helpers.assert_true(evaluated(state, 'setSubscribedChannel("dev",false)'),
				"a refused save must reach the page as a failure")
		end)
	end)

	helpers.it("pushes the owner's changes from the menu to the open page", function()
		with_changelog(function(changelog, state, post)
			local owner, record = owner_double("dev", true)
			helpers.assert_true(changelog.open({ channel_owner = owner }))
			post("ready")
			helpers.assert_type(record.listeners.changelog, "function", "the window must follow the owner")
			owner.set("main")
			helpers.assert_true(evaluated(state, 'setSubscribedChannel("main",true)'),
				"a menu change must reach the open page")
			helpers.assert_true(changelog.close())
			local before = #state.evaluations
			helpers.assert_eq(changelog.push_subscribed_channel("dev"), false, "a closed window is not pushed to")
			helpers.assert_eq(#state.evaluations, before)
		end)
	end)

	helpers.it("refuses a fetch for a channel outside the registry", function()
		with_changelog(function(changelog, state, post)
			helpers.assert_true(changelog.open())
			local before = #state.callbacks
			for _, unknown in ipairs({ "stable", "beta", "Main" }) do
				post({ action = "fetch", channel = unknown })
			end
			helpers.assert_eq(#state.callbacks, before, "no request may start for an unknown channel")
		end)
	end)
end)
