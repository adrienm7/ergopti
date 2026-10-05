--- tests/unit/ui/test_onboarding_import_transaction.lua

--- ==============================================================================
--- MODULE: Onboarding Existing Configuration Read Transaction
--- DESCRIPTION:
--- Refuses import unless native reading and exact stream closure both commit.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.onboarding_delivery_fixture")

helpers.describe("onboarding configuration import transaction", function()
	for _, route in ipairs({ "ready", "loadExistingConfig" }) do
		helpers.it("(onboarding-import-transaction) " .. route .. " preserves empty maps at the native JSON boundary", function()
			fixture.with_delivery(function(_, state, pending, errors, evaluations)
				-- Native LuaSkin returns NSArray for an empty Lua table. This
				-- independent boundary model is deliberately different from Json.encode.
				state.native_encode = function(value, encode)
					local function native_shape(item)
						if type(item) ~= "table" then return item end
						if next(item) == nil then return require("json").array({}) end
						local result = {}
						for key, child in pairs(item) do result[key] = native_shape(child) end
						return result
					end
					return encode(native_shape(value))
				end
				local inspect = hs.fs.symlinkAttributes
				hs.fs.symlinkAttributes = function(path)
					if path:match("/config%.toml$") then return nil, "PRIVATE_NATIVE_DETAIL" end
					return inspect(path)
				end
				fixture.dispatch(route, state, pending)
				helpers.assert_eq(#evaluations, 1, "a successful absent read publishes exactly once")
				local field = route == "ready" and "current" or "values"
				helpers.assert_eq(next(state.payload[field]), nil, "the actual published map is empty")
				helpers.assert_true(evaluations[1].code:find('"' .. field .. '":{}', 1, true) ~= nil,
					"the actual JavaScript publication preserves an object-shaped empty map")
				helpers.assert_nil(evaluations[1].code:find('"' .. field .. '":[]', 1, true),
					"native empty-array conversion cannot reach the strict page contract")
				helpers.assert_eq(#errors, 0)
			end)
		end)
	end
	helpers.it("(onboarding-import-transaction) new configuration directory restarts the pages from neutral values", function()
		fixture.with_delivery(function(_, state, pending, errors, evaluations)
			local debug_messages = {}
			package.loaded["infra.logger"].debug = function(_, template, ...)
				local message = string.format(template, ...)
				if message:find("existing configuration", 1, true) then
					debug_messages[#debug_messages + 1] = message
				end
			end
			local inspect = hs.fs.symlinkAttributes
			hs.fs.symlinkAttributes = function(path)
				if path:match("/config%.toml$") then return nil, "PRIVATE_NATIVE_DETAIL" end
				return inspect(path)
			end
			local opens = 0
			io.open = function() opens = opens + 1; error("stream must not open") end
			fixture.dispatch("loadExistingConfig", state, pending)
			helpers.assert_eq(opens, 0)
			helpers.assert_eq(#evaluations, 1, "an empty folder answers with no configured value")
			helpers.assert_true(evaluations[1].code:find("window.applyCurrentValues(", 1, true) ~= nil)
			helpers.assert_eq(state.payload.request, 1)
			helpers.assert_eq(next(state.payload.values), nil)
			helpers.assert_eq(#errors, 0)
			helpers.assert_eq(#debug_messages, 1)
			helpers.assert_true(debug_messages[1]:find("neutral values shown", 1, true) ~= nil)
			helpers.assert_nil(debug_messages[1]:find("PRIVATE_NATIVE_DETAIL", 1, true))
		end)
	end)
	for _, mode in ipairs({ "throw", "nil" }) do
		helpers.it("(onboarding-import-transaction) decode " .. mode .. " cannot publish defaults", function()
			fixture.with_delivery(function(_, state, pending, errors, evaluations)
				package.loaded["infra.toml.codec"].decode = function()
					if mode == "throw" then error("PRIVATE_NATIVE_DETAIL") end
				end
				fixture.dispatch("loadExistingConfig", state, pending)
				helpers.assert_eq(#evaluations, 0)
				helpers.assert_eq(#errors, 1)
				helpers.assert_true(errors[1]:find("decode", 1, true) ~= nil)
				helpers.assert_nil(errors[1]:find("PRIVATE_NATIVE_DETAIL", 1, true))
			end)
		end)
	end
	helpers.it("(onboarding-import-transaction) close reentry cannot import into a successor", function()
		fixture.with_delivery(function(_, state, pending, errors, evaluations, open)
			local closes = 0
			io.open = function()
				return { read = function() return "fixture" end, close = function()
					closes = closes + 1
					state.view.options.on_close()
					open()
					return true
				end }
			end
			fixture.dispatch("loadExistingConfig", state, pending)
			helpers.assert_eq(closes, 1)
			helpers.assert_eq(#evaluations, 0)
			helpers.assert_eq(#errors, 0)
		end)
	end)
	for _, mode in ipairs({ "open_nil", "open_throw", "read_nil", "read_throw", "close_nil", "close_throw", "success" }) do
		helpers.it("(onboarding-import-transaction) " .. mode, function()
			fixture.with_delivery(function(_, state, pending, errors, evaluations)
				local reads, closes = 0, 0
				io.open = function(_, access)
					helpers.assert_eq(access, "r")
					if mode == "open_nil" then return nil, "PRIVATE_NATIVE_DETAIL", 13 end
					if mode == "open_throw" then error("PRIVATE_NATIVE_DETAIL") end
					return {
						read = function()
							reads = reads + 1
							if mode == "read_nil" then return nil, "PRIVATE_NATIVE_DETAIL", 5 end
							if mode == "read_throw" then error("PRIVATE_NATIVE_DETAIL") end
							return "fixture"
						end,
						close = function()
							closes = closes + 1
							if mode == "close_nil" then return nil, "PRIVATE_NATIVE_DETAIL", 5 end
							if mode == "close_throw" then error("PRIVATE_NATIVE_DETAIL") end
							return true
						end,
					}
				end
				fixture.dispatch("loadExistingConfig", state, pending)
				local opened = mode ~= "open_nil" and mode ~= "open_throw"
				helpers.assert_eq(reads, opened and 1 or 0)
				helpers.assert_eq(closes, opened and 1 or 0, "every acquired stream gets a close attempt")
				helpers.assert_eq(#evaluations, mode == "success" and 1 or 0)
				helpers.assert_eq(#errors, mode == "success" and 0 or 1)
				for _, message in ipairs(errors) do
					helpers.assert_nil(message:find("PRIVATE_NATIVE_DETAIL", 1, true))
					helpers.assert_nil(message:find("/virtual/", 1, true))
				end
			end)
		end)
	end
end)
