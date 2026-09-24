--- tests/unit/modules/updater/test_update_channel_owner.lua

--- ==============================================================================
--- MODULE: Update Channel Owner (macOS)
--- DESCRIPTION:
--- macOS had no channel owner: the channel came from the launcher version and
--- nothing read or wrote config.toml [updater] channel. The owner persists the
--- subscription through the menu's preferences transaction, resolves the
--- persisted value through the shared registry, tells the packaged launcher
--- which Sparkle feed to read, and publishes a change to its subscribers only
--- after the save committed.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh owner module over the real registry and a recording launcher.
--- @param packaged boolean Whether the process runs inside the packaged app.
--- @return table Owner module, table launcher calls
local function load_owner(packaged)
	local launcher_calls = {}
	local previous_launcher = package.loaded["adapters.update_launcher"]
	package.loaded["adapters.update_launcher"] = {
		select_channel = function(id) launcher_calls[#launcher_calls + 1] = id return true end,
	}
	package.loaded["modules.updater"] = nil
	package.loaded["modules.updater.channel"] = nil
	helpers.load_with_stubs("modules.updater", {
		processInfo = { bundleID = packaged and "com.ergoptiplus.app.hammerspoon" or "org.hammerspoon.Hammerspoon" },
	})
	local Owner = require("modules.updater.channel")
	package.loaded["adapters.update_launcher"] = previous_launcher
	return Owner, launcher_calls
end

--- A transactional save double: commits (or refuses) and records what it saw.
local function recording_save(state, result)
	local saves = {}
	return function()
		saves[#saves + 1] = state.update_channel
		if result == "raise" then error("synthetic save failure") end
		return result
	end, saves
end

helpers.describe("updater channel owner (macOS)", function()
	helpers.it("follows the installed build until config.toml names a channel", function()
		local Owner = load_owner(false)
		local Updater = require("modules.updater")
		local state = {}
		local owner = Owner.new({ state = state, save = recording_save(state, true) })
		helpers.assert_eq(owner.get(), Updater.installed_channel())
		state.update_channel = "stable"
		helpers.assert_eq(owner.get(), "main", "a hand-written alias reads as its channel")
		state.update_channel = "dev"
		helpers.assert_eq(owner.get(), "dev")
		state.update_channel = "beta"
		helpers.assert_eq(owner.get(), Updater.installed_channel(),
			"an unknown value follows the installed build's channel")
	end)

	helpers.it("persists through the transaction, then tells the launcher and the subscribers", function()
		local Owner, launcher_calls = load_owner(true)
		local state = {}
		local save, saves = recording_save(state, true)
		local owner = Owner.new({ state = state, save = save })
		local heard = {}
		owner.subscribe("menu", function(id) heard[#heard + 1] = "menu:" .. id end)
		owner.subscribe("page", function(id) heard[#heard + 1] = "page:" .. id end)

		helpers.assert_eq(owner.set("dev"), true)
		helpers.assert_eq(saves, { "dev" }, "the save must see the new channel in the state")
		helpers.assert_eq(state.update_channel, "dev", "config.toml [updater] channel is update_channel")
		helpers.assert_eq(launcher_calls, { "dev" }, "Sparkle's scheduled checks must follow the menu")
		helpers.assert_eq(heard, { "menu:dev", "page:dev" }, "subscribers hear the change in order")
		helpers.assert_eq(owner.set("dev"), true, "choosing the current channel again is accepted")
		helpers.assert_eq(#saves, 1, "an unchanged channel is not saved again")
	end)

	helpers.it("a source run has no launcher to tell", function()
		local Owner, launcher_calls = load_owner(false)
		local state = {}
		local owner = Owner.new({ state = state, save = recording_save(state, true) })
		helpers.assert_eq(owner.set("main"), true)
		helpers.assert_eq(#launcher_calls, 0)
	end)

	for _, outcome in ipairs({ false, "raise" }) do
		helpers.it("keeps the previous channel when the save does not commit (" .. tostring(outcome) .. ")", function()
			local Owner, launcher_calls = load_owner(true)
			local state = { update_channel = "main" }
			local owner = Owner.new({ state = state, save = recording_save(state, outcome) })
			local heard = 0
			owner.subscribe("menu", function() heard = heard + 1 end)
			helpers.assert_eq(owner.set("dev"), false)
			helpers.assert_eq(state.update_channel, "main", "an uncommitted channel never stays live")
			helpers.assert_eq(owner.get(), "main")
			helpers.assert_eq(heard, 0, "nobody hears of a change that did not happen")
			helpers.assert_eq(#launcher_calls, 0, "Sparkle keeps its feed")
		end)
	end

	helpers.it("refuses aliases and unknown ids before saving", function()
		local Owner = load_owner(true)
		local state = {}
		local save, saves = recording_save(state, true)
		local owner = Owner.new({ state = state, save = save })
		for _, value in ipairs({ "stable", "beta", "Main", 42 }) do
			helpers.assert_eq(owner.set(value), false, tostring(value) .. " must be refused")
		end
		helpers.assert_eq(#saves, 0)
		helpers.assert_eq(state.update_channel, nil)
	end)
end)
