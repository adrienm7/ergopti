--- _shared/lua/test/dynamic_word_boundary_contract.lua

--- Shared registered regressions for builtin dynamic word-start admission.

return function(helpers)
    local Engine = require("dynamic_hotstrings")
    local function with_rules(body)
        local previous = {}
        for index, rule in ipairs(Engine.get_rules()) do
            previous[index] = { suffix = rule.suffix, section = rule.section,
                resolver = rule.resolver, require_word_boundary = rule.require_word_boundary }
        end
        Engine.reset_rules()
        local ok, err = xpcall(body, debug.traceback)
        Engine.reset_rules()
        for _, rule in ipairs(previous) do
            assert(Engine.add_rule(rule.suffix, rule.section, rule.resolver, rule.require_word_boundary))
        end
        if not ok then error(err, 0) end
    end
    helpers.describe("builtin dynamic word-start contract", function()
        helpers.it("never previews or resolves date inside update (dynamic-word-start)", function()
            with_rules(function()
                Engine.register_date_rules("*")
                local calls = 0
                for _, rule in ipairs(Engine.get_rules()) do
                    local original = rule.resolver
                    rule.resolver = function() calls = calls + 1; return original() end
                end
                for _, trigger in ipairs({ "date", "dt", "td" }) do
                    for _, prefix in ipairs({ "up", "x", "1", "_", "é", "@" }) do
                        helpers.assert_nil(Engine.preview(prefix .. trigger, "dynamic", nil, true))
                        helpers.assert_nil(Engine.match_buffer(prefix .. trigger, "dynamic", nil, true))
                    end
                end
                helpers.assert_eq(calls, 0, "rejection must happen before every builtin resolver")
            end)
        end)
        helpers.it("preserves known start and ordinary Unicode-aware boundaries", function()
            with_rules(function()
                Engine.register_date_rules("*")
                for _, trigger in ipairs({ "date", "dt", "td" }) do
                    helpers.assert_not_nil(Engine.preview(trigger, "dynamic", nil, true))
                    helpers.assert_not_nil(Engine.match_buffer(trigger, "dynamic", nil, true))
                    for _, prefix in ipairs({ " ", "\n", "'", ".", "(" }) do
                        helpers.assert_not_nil(Engine.preview(prefix .. trigger, "dynamic", nil, false))
                        helpers.assert_not_nil(Engine.match_buffer(prefix .. trigger, "dynamic", nil, false))
                    end
                    helpers.assert_nil(Engine.preview(trigger, "dynamic", nil, false))
                    helpers.assert_nil(Engine.match_buffer(trigger, "dynamic", nil, nil))
                end
            end)
        end)
        helpers.it("keeps custom in-word and explicit at-command contracts", function()
            with_rules(function()
                helpers.assert_true(Engine.add_rule("été", "custom", function() return "custom" end))
                helpers.assert_true(Engine.add_rule("@p", "personal", function() return "owned-field" end))
                helpers.assert_eq(Engine.match_buffer("zzété", "dynamic", nil, false).result, "custom")
                helpers.assert_eq(Engine.preview("Alice@p", "dynamic", nil, false), "owned-field")
                helpers.assert_eq(Engine.match_buffer("Alice@p", "dynamic", nil, false).result, "owned-field")
                helpers.assert_eq(Engine.add_rule("bad", "date", function() return "bad" end, "yes"), false)
            end)
        end)
    end)
end
