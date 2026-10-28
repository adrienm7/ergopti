--- _shared/lua/test/native_presentation_receiver_contract.lua

--- ==============================================================================
--- MODULE: Native Presentation Receiver Contract
--- DESCRIPTION:
--- Pins the shared receiving owner (native_presentation.receiver) on both Lua
--- runners over modelled translation owners: the platform tag selects only
--- that platform's declarations, a receipt is opaque and revoked when a pinned
--- owner is replaced. register_driver() checks that a driver's
--- infra.native_presentation is the shared receiver, not a retyped copy.
--- ==============================================================================

local M = {}
local Shared = require("native_presentation")

local NAMES = { i18n = "tests.virtual.npr_i18n", locale = "tests.virtual.npr_locale",
	core = "tests.virtual.npr_core", receiver = "tests.virtual.npr_receiver" }

--- Runs body with one receiver over modelled owners loaded under virtual names.
--- @param platform string Platform tag.
--- @param body function Receives the receiver and the owners.
local function with_receiver(platform, body)
	local saved = {}
	for key, name in pairs(NAMES) do saved[key] = package.loaded[name] end
	local owners = {
		i18n = { get = function(key) return "Caption for " .. key end },
		locale = { get = function() return nil end, current_locale = function() return "en" end },
		core = { get = function() return nil end, current_locale = function() return "en" end },
	}
	package.loaded[NAMES.i18n], package.loaded[NAMES.locale], package.loaded[NAMES.core] = owners.i18n, owners.locale, owners.core
	local ok, failure = xpcall(function()
		local receiver = Shared.receiver({ platform = platform, name = NAMES.receiver,
			i18n = { name = NAMES.i18n, module = owners.i18n },
			locale = { name = NAMES.locale, module = owners.locale },
			core = { name = NAMES.core, module = owners.core } })
		package.loaded[NAMES.receiver] = receiver
		body(receiver, owners)
	end, debug.traceback)
	for key, name in pairs(NAMES) do package.loaded[name] = saved[key] end
	if not ok then error(failure, 0) end
end

--- Registers the receiver vectors in a driver suite.
--- @param helpers table Driver test API.
function M.register(helpers)
	helpers.describe("shared native presentation receiver (native-presentation-receiver)", function()
		helpers.it("refuses an unknown platform or a missing owner", function()
			local owner = { name = NAMES.i18n, module = {} }
			helpers.assert_eq(pcall(Shared.receiver, { platform = "ahk", name = "x", i18n = owner, locale = owner, core = owner }), false)
			helpers.assert_eq(pcall(Shared.receiver, { platform = "hs", name = "x", i18n = owner, locale = owner }), false)
			helpers.assert_eq(pcall(Shared.receiver, { platform = "hs", name = "", i18n = owner, locale = owner, core = owner }), false)
		end)

		helpers.it("receives only its own platform's declarations", function()
			with_receiver("hs", function(receiver)
				local receipt = receiver.prepare("profile_shortcut_dialog", "dialog")
				helpers.assert_type(receipt, "table")
				helpers.assert_eq(receiver.title(receipt), "Caption for menu.profiles.shortcut_title")
				helpers.assert_nil(receiver.prepare("magic_key_source_notice", "notification"), "a Linux-only notice")
				helpers.assert_nil(receiver.prepare("profile_shortcut_dialog", "notification"), "the wrong kind")
				helpers.assert_nil(receiver.title({}), "a forged receipt")
			end)
			with_receiver("linux", function(receiver)
				local receipt = receiver.prepare("magic_key_source_notice", "notification")
				helpers.assert_eq(receiver.title(receipt), "Caption for dialog.magic_key_source.title")
				helpers.assert_nil(receiver.prepare("profile_shortcut_dialog", "dialog"), "a macOS-only dialog")
			end)
		end)

		helpers.it("revokes a receipt when a pinned owner or locale changes", function()
			with_receiver("hs", function(receiver, owners)
				local receipt = receiver.prepare("profile_shortcut_dialog", "dialog")
				package.loaded[NAMES.i18n] = {}
				helpers.assert_nil(receiver.title(receipt), "a replaced translation owner")
				package.loaded[NAMES.i18n] = owners.i18n
				helpers.assert_type(receiver.title(receipt), "string")
				owners.locale.current_locale = function() return "fr" end
				helpers.assert_nil(receiver.title(receipt), "a replaced locale reader")
			end)
		end)
	end)
end

--- Checks that the driver's receiving owner is the shared receiver.
--- @param helpers table Driver test API.
function M.register_driver(helpers)
	helpers.describe("infra.native_presentation is the shared receiver (native-presentation-receiver)", function()
		helpers.it("prepare and title come from native_presentation.lua", function()
			local receiver = require("infra.native_presentation")
			for _, method in ipairs({ "prepare", "title" }) do
				local source = debug.getinfo(receiver[method], "S").source
				helpers.assert_true(source:find("_shared/lua/native_presentation.lua", 1, true) ~= nil,
					method .. " must come from the shared receiver, not " .. source)
			end
		end)
	end)
end

return M
