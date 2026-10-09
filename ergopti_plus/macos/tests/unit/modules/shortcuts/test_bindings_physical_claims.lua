--- tests/unit/modules/shortcuts/test_bindings_physical_claims.lua

--- ==============================================================================
--- MODULE: Built-in Shortcut Physical Claims
--- DESCRIPTION:
--- Keeps the existing native factories observable independently from the common
--- physical-claim registry. Explicit built-ins reserve a contextual source until
--- their exact native handle has acknowledged release.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcut_bindings_fixture")

helpers.describe("built-in shortcuts: native owners and physical claims", function()
	helpers.it("starts every existing factory including Ctrl+CapsLock without weakening the generic modifier guard", function()
		Fixture.with_recommended_bindings(function(subject, ctx)
			local registrar = require("adapters.hotkey_registrar")
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.is_bound("ctrl_capslock"), true)
			helpers.assert_eq(registrar.key_is_modifier("capslock"), true)
			helpers.assert_nil(registrar.bind("Ctrl+CapsLock", function() end))
			helpers.assert_eq(registrar.physical_claims()[registrar.physical_identity({"ctrl"}, "a")].action,
				"explicit")
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(Fixture.live_count(ctx), 0)
			helpers.assert_nil(next(registrar.physical_claims()))
		end)
	end)

	helpers.it("retains the exact physical claim across refused native deletion and releases it on retry", function()
		Fixture.with_bindings(function(subject, ctx)
			local registrar = require("adapters.hotkey_registrar")
			helpers.assert_eq(subject.enable("ctrl_a"), true)
			local identity = registrar.physical_identity({"ctrl"}, "a")
			local native = assert(next(ctx.live))
			local release = native.delete
			native.delete = function() error("owned native delete refused") end
			helpers.assert_eq(subject.disable("ctrl_a"), false)
			helpers.assert_true(registrar.physical_claims()[identity] ~= nil)
			helpers.assert_nil(registrar.bind_conditional({"ctrl"}, _G.hs.keycodes.map.a, function() end))
			native.delete = release
			helpers.assert_eq(subject.disable("ctrl_a"), true)
			helpers.assert_nil(registrar.physical_claims()[identity])
			helpers.assert_eq(Fixture.live_count(ctx), 0)
		end)
	end)
	helpers.it("reserves before a late native factory and releases its void delete without losing the conditional", function()
		Fixture.with_bindings(function(subject, ctx)
			local registrar = require("adapters.hotkey_registrar")
			local bind = _G.hs.hotkey.bind
			local conditional = {enabled=true}
			conditional.enable = function(self) self.enabled=true; return self end
			conditional.disable = function(self) self.enabled=false; return self end
			conditional.delete = function() end
			_G.hs.hotkey.bind = function() return conditional end
			local token = assert(registrar.bind_conditional({"ctrl"}, _G.hs.keycodes.map.a, function() end))
			local observed_claim, observed_suspension
			_G.hs.hotkey.bind = function(...)
				observed_claim = registrar.physical_claims()[registrar.physical_identity({"ctrl"}, "a")]
				observed_suspension = conditional.enabled
				local native = bind(...)
				local release = native.delete
				native.delete = function() release() end -- Hammerspoon delete is void.
				return native
			end
			helpers.assert_eq(subject.enable("ctrl_a"), true)
			helpers.assert_true(observed_claim ~= nil, "claim is published before native acquisition")
			helpers.assert_eq(observed_suspension, false)
			helpers.assert_eq(subject.disable("ctrl_a"), true)
			helpers.assert_eq(conditional.enabled, true)
			helpers.assert_eq(Fixture.live_count(ctx), 0)
			helpers.assert_eq(registrar.unbind(token), true)
		end)
	end)

	helpers.it("restores the existing conditional and leaves no claim when native acquisition returns nil", function()
		Fixture.with_bindings(function(subject)
			local registrar = require("adapters.hotkey_registrar")
			local conditional = {enabled=true}
			conditional.enable = function(self) self.enabled=true; return self end
			conditional.disable = function(self) self.enabled=false; return self end
			conditional.delete = function() end
			_G.hs.hotkey.bind = function() return conditional end
			local token = assert(registrar.bind_conditional({"ctrl"}, _G.hs.keycodes.map.a, function() end))
			_G.hs.hotkey.bind = function() return nil end
			helpers.assert_eq(subject.enable("ctrl_a"), false)
			helpers.assert_eq(conditional.enabled, true)
			helpers.assert_nil(next(registrar.physical_claims()))
			helpers.assert_eq(registrar.unbind(token), true)
		end)
	end)
	helpers.it("retains failed acquisition compensation as cleanup debt even when no native built-in was returned", function()
		Fixture.with_bindings(function(subject)
			local registrar = require("adapters.hotkey_registrar")
			local conditional = {enabled=true}
			conditional.enable = function() return nil end
			conditional.disable = function(self) self.enabled=false; return self end
			conditional.delete = function() end
			_G.hs.hotkey.bind = function() return conditional end
			local token = assert(registrar.bind_conditional({"ctrl"}, _G.hs.keycodes.map.a, function() end))
			_G.hs.hotkey.bind = function() return nil end
			helpers.assert_eq(subject.enable("ctrl_a"), false)
			helpers.assert_eq(subject.has_pause_debt(), true)
			helpers.assert_eq(subject.stop(), false)
			helpers.assert_true(next(registrar.physical_claims()) ~= nil)
			conditional.enable = function(self) self.enabled=true; return self end
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(subject.has_pause_debt(), false)
			helpers.assert_eq(conditional.enabled, true)
			helpers.assert_nil(next(registrar.physical_claims()))
			helpers.assert_eq(registrar.unbind(token), true)
		end)
	end)
	helpers.it("owns failed claim-reservation compensation until the original conditional can settle", function()
		Fixture.with_bindings(function(subject)
			local registrar = require("adapters.hotkey_registrar")
			local conditional = {enabled=true}
			conditional.enable = function() return nil end
			conditional.disable = function(self) self.enabled=false; return nil end
			conditional.delete = function() end
			_G.hs.hotkey.bind = function() return conditional end
			local token = assert(registrar.bind_conditional({"ctrl"}, _G.hs.keycodes.map.a, function() end))
			helpers.assert_eq(subject.enable("ctrl_a"), false)
			helpers.assert_eq(subject.has_pause_debt(), true)
			helpers.assert_eq(subject.stop(), false)
			conditional.disable = function(self) self.enabled=false; return self end
			conditional.enable = function(self) self.enabled=true; return self end
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(subject.has_pause_debt(), false)
			helpers.assert_eq(conditional.enabled, true)
			helpers.assert_eq(registrar.unbind(token), true)
		end)
	end)
end)

return true
