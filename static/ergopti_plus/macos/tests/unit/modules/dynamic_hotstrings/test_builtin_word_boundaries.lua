--- tests/unit/modules/dynamic_hotstrings/test_builtin_word_boundaries.lua

--- Registered builtin boundary checks; all native ports are closed recording fixtures.

local helpers = require("tests.helpers")
require("test.dynamic_word_boundary_contract")(helpers)

local MAGIC = "★"
local function with_rules_engine(body, personal)
    helpers.with_stub_scope({ "modules.dynamic_hotstrings.rules_engine", "dynamic_hotstrings",
        "modules.dynamic_hotstrings.user_code", "modules.keylogger", "modules.keylogger.init" }, function()
        local closed_keylogger = {}
        package.loaded["modules.keylogger"] = closed_keylogger
        package.loaded["modules.keylogger.init"] = closed_keylogger
        local Rules = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")
        package.loaded["modules.dynamic_hotstrings.user_code"] = {
            preview = function() return nil end,
            request = function() return false end,
        }
        local fixture = { mappings = {}, calls = 0, emissions = 0 }
        local keymap = {
            is_group_enabled = function() return true end,
            is_section_enabled = function() return true end,
            register_lua_group = function() end,
            set_post_load_hook = function() end,
            register_interceptor = function(fn) fixture.interceptor = fn end,
            register_preview_provider = function(fn) fixture.provider = fn end,
            registry_transaction = function(_, mutation) return mutation() == true end,
            invalidate_hotstring_preview = function() return true end,
            owns_visible_magic_action = function(token, buffer)
                return token == fixture.token and buffer == fixture.buffer
            end,
            inject_dynamic = function()
                fixture.emissions = fixture.emissions + 1
                return true
            end,
            add = function(trigger, replacement, options)
                fixture.mappings[#fixture.mappings + 1] = { trigger = trigger,
                    replacement = replacement, options = options }
            end,
            set_group_context = function() end,
            sort_mappings = function() end,
        }
        if personal then helpers.assert_true(Rules.inject_data(personal, MAGIC)) end
        helpers.assert_true(Rules.start(keymap))
        local event = { getFlags = function() return {} end,
            getCharacters = function() return MAGIC end }
        local ok, err = xpcall(function() body(Rules, fixture, event) end, debug.traceback)
        helpers.assert_true(Rules.stop(), "exact fixture owner must retire")
        if not ok then error(err, 0) end
    end)
end

helpers.describe("Mac builtin dynamic boundary owners", function()
    helpers.it("the actual keymap event frame preserves the existing start authority", function()
        local source = assert(helpers.read_driver_source("local _interceptor_ctx ="))
        local expression = assert(source:match("local _interceptor_ctx = (%b{})"))
        local actor = assert(load("return function(CoreState, keyCode, flags, chars) return " .. expression .. " end"))()
        for _, boundary in ipairs({ false, true }) do
            local flags = {}
            local frame = actor({ start_is_word_boundary = boundary }, 1, flags, MAGIC)
            helpers.assert_eq(frame.start_is_word_boundary, boundary)
            helpers.assert_eq(frame.flags, flags)
            helpers.assert_eq(frame.chars, MAGIC)
        end
    end)
    helpers.it("the actual preview parent forwards authority with the existing result tuple", function()
        local source = assert(helpers.read_driver_source("for provider_index, provider in ipairs(_state.preview_providers) do"))
        local call = assert(source:match("local ok, res, provider_action_token = (pcall%([^\n]+)"))
        local actor = assert(load("return function(_state, provider, buf) return " .. call .. " end"))()
        for _, boundary in ipairs({ false, true }) do
            local token, observed = {}, nil
            local ok, result, returned = actor({ start_is_word_boundary = boundary }, function(buffer, start)
                helpers.assert_eq(buffer, "date")
                observed = start
                return "owned", token
            end, "date")
            helpers.assert_eq(observed, boundary)
            helpers.assert_eq(ok, true)
            helpers.assert_eq(result, "owned")
            helpers.assert_eq(returned, token)
        end
    end)
    helpers.it("refuses update in both actual provider and interceptor before resolution", function()
        with_rules_engine(function(_, fixture, event)
            local Engine = require("dynamic_hotstrings")
            for _, rule in ipairs(Engine.get_rules()) do
                local resolver = rule.resolver
                rule.resolver = function() fixture.calls = fixture.calls + 1; return resolver() end
            end
            helpers.assert_nil(fixture.provider("update", true))
            helpers.assert_nil(fixture.interceptor(event, "update", {
                chars = MAGIC, flags = {}, start_is_word_boundary = true }))
            helpers.assert_eq(fixture.calls, 0)
            helpers.assert_eq(fixture.emissions, 0)
        end)
    end)
    helpers.it("revokes a committed date snapshot when the same buffer loses start authority", function()
        with_rules_engine(function(_, fixture, event)
            fixture.buffer = "date"
            local shown
            shown, fixture.token = fixture.provider(fixture.buffer, true)
            helpers.assert_not_nil(shown)
            helpers.assert_type(fixture.token, "table")
            helpers.assert_nil(fixture.interceptor(event, fixture.buffer, {
                chars = MAGIC, flags = {}, start_is_word_boundary = false }))
            helpers.assert_eq(fixture.emissions, 0, "a retained token cannot recreate revoked boundary authority")
            helpers.assert_nil(fixture.provider(fixture.buffer, false))
        end)
    end)
    helpers.it("preserves a custom in-word committed action without resolving twice", function()
        with_rules_engine(function(Rules, fixture, event)
            helpers.assert_true(Rules.add_rule("été", "custom", function()
                fixture.calls = fixture.calls + 1
                return "owned-custom"
            end))
            fixture.buffer = "zzété"
            local shown
            shown, fixture.token = fixture.provider(fixture.buffer, false)
            helpers.assert_eq(shown, "owned-custom")
            helpers.assert_eq(fixture.interceptor(event, fixture.buffer, {
                chars = MAGIC, flags = {}, start_is_word_boundary = false }), "consume")
            helpers.assert_eq(fixture.calls, 1)
            helpers.assert_eq(fixture.emissions, 1)
        end)
    end)
    helpers.it("registers every personal prefix through the actual ordinary word gate", function()
        with_rules_engine(function(_, fixture)
            local Core = require("hotstring_engine")
            helpers.assert_eq(#fixture.mappings, 10)
            for _, entry in ipairs(fixture.mappings) do
                helpers.assert_true(entry.options.is_word == true)
                local mapping = { trigger = entry.trigger, match_mode = "exact",
                    is_word = entry.options.is_word }
                helpers.assert_not_nil(Core.decide(mapping, "owned-result", entry.trigger, nil, true))
                helpers.assert_nil(Core.decide(mapping, "owned-result", entry.trigger, nil, false))
                for _, previous in ipairs({ "x", "1", "_", "é" }) do
                    helpers.assert_nil(Core.decide(mapping, "owned-result", entry.trigger, previous, true))
                end
            end
        end, { phone_number = "0612345678", phone_number_clean = "06 12 34 56 78",
            social_security_number = "1 99 99 99 999 999 99", iban = "FR00 0000 0000 0000" })
    end)
end)
