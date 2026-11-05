-- Cross-driver policy controls using actual shared and Linux owners.
local root = assert(arg[1], "repository root required")
local driver = root .. "/static/ergopti_plus/linux"
local shared = root .. "/static/ergopti_plus/_shared/lua"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
require("compat.utf8").install()
-- Only the logging output port is replaced. No matcher, context, policy or
-- settings owner is stubbed; no user configuration is read or written.
local log_calls = {}
local logger = {}
for _, name in ipairs({ "trace", "debug", "info", "warn", "error", "start", "success", "done", "evidence" }) do
    logger[name] = function(...) log_calls[#log_calls + 1] = { kind = name, args = { ... } } end
end
package.loaded["logger.shim"] = logger
local Core = require("hotstring_engine")
local Engine = require("modules.hotstrings.engine")
local Word = require("modules.hotstrings.word_reset")
local Context = require("modules.llm.context")
local Settings = require("modules.llm.settings")
local JSON = require("json")
local checks, scenarios = 0, 0
local function eq(actual, expected, label)
    checks = checks + 1
    assert(actual == expected, label .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local f = assert(io.open(root .. "/static/ergopti_plus/_shared/tests/corpus/hotstrings/idle_reset_vectors.json", "rb"))
local corpus = assert(JSON.decode(f:read("*a"))); f:close()
for _, vector in ipairs(corpus.vectors) do
    local previous = type(vector.last_ms) == "number" and vector.last_ms or nil
    eq(Core.idle_resets_word(previous, vector.now_ms, vector.idle_seconds, 0), vector.resets, vector.id)
end
for _, v in ipairs({ -1, math.huge, -math.huge, 0 / 0, "3", false, {} }) do
    eq(Core.valid_idle_reset_seconds(v), false, "invalid idle input")
end
for _, v in ipairs({ 0, 0.0001, 0.5, 3, 1000000 }) do
    eq(Core.valid_idle_reset_seconds(v), true, "valid idle input")
end
eq(Core.idle_resets_word(1000, 3999, 2, 1000), false, "coarse clock below qualified deadline")
eq(Core.idle_resets_word(1000, 4000, 2, 1000), true, "coarse clock at qualified deadline")
eq(Word.adopt_configuration({}), true, "adopt defaults without disk IO")
local defaults = Word.snapshot()
eq(defaults.idle_seconds, 3, "canonical idle default")
eq(defaults.arrow_resets_word, true, "canonical arrow default")
eq(defaults.shortcut_resets_word, true, "canonical shortcut default")
eq(defaults.tap_hold_resets_word, true, "canonical tap-hold default")
local function instance(nav)
    -- The real settings owner restores an explicitly populated valid cache;
    -- this is a controlled config fixture, not a replacement implementation.
    local snapshot = Settings.configuration_snapshot()
    eq(Settings.restore_configuration({ values = { reset_on_nav = nav }, shipped = snapshot.shipped }), true, "restore controlled settings cache")
    local engine = Engine.new()
    local context = Context.new({ is_active = function() return true end })
    engine:attach_ai_context(context)
    engine:reset(false)
    engine:on_char("a"); engine:on_char("b")
    return engine, context
end
local events = {
    { key = "left", detail = { mods = {} }, owner = "arrow" },
    { key = "up", detail = { mods = { ctrl = true }, tap_hold = true }, owner = "arrow" },
    { key = "shortcut", detail = { key = "v", mods = { ctrl = true } }, owner = "shortcut" },
    { key = "shortcut", detail = { key = "v", mods = { ctrl = true }, tap_hold = true }, owner = "tap_hold" },
    { key = "escape", detail = { mods = { ctrl = true } }, owner = "shortcut" },
    { key = "enter", detail = { mods = { alt = true } }, owner = "shortcut" },
    { key = "f5", detail = { mods = { meta = true } }, owner = "shortcut" },
}
for _, arrow in ipairs({ false, true }) do
    for _, shortcut in ipairs({ false, true }) do
        for _, tap in ipairs({ false, true }) do
            eq(Word.adopt_configuration({ hotstrings = { arrow_resets_word = arrow, shortcut_resets_word = shortcut, tap_hold_resets_word = tap } }), true, "adopt policy cross-product")
            local options = { arrow = arrow, shortcut = shortcut, tap_hold = tap }
            for _, nav in ipairs({ false, true }) do
                for _, event in ipairs(events) do
                    local engine, context = instance(nav)
                    eq(Word.control_owner(event.key, event.detail), event.owner, "event's governing option")
                    local reset = options[event.owner]
                    eq(Word.apply_control(engine, event.key, event.detail, "editor"), reset and "word_start" or "kept", "word option effect")
                    eq(engine:current_buffer(), reset and "" or "ab", "word buffer independent of AI option")
                    eq(engine:buffer_starts_at_word_boundary(), reset, "word boundary independent of AI option")
                    eq(context:text(), nav and "" or "ab", "AI navigation policy independent of word option")
                    engine:on_char("z")
                    eq(engine:current_buffer(), reset and "z" or "abz", "next-key word continuity")
                    eq(context:text(), nav and "z" or "abz", "next-key AI continuity")
                    scenarios = scenarios + 1
                end
                for _, event in ipairs({ { "escape", {}, true, "navigation" }, { "home", { ctrl = true }, false, "navigation" }, { "delete", {}, false, "navigation" }, { "backspace", { ctrl = true }, true, "edit" }, { "backspace", { alt = true }, false, "edit" } }) do
                    local engine, context = instance(nav)
                    Word.apply_control(engine, event[1], { mods = event[2] }, "editor")
                    eq(engine:current_buffer(), "", "unconditional control reset")
                    eq(engine:buffer_starts_at_word_boundary(), event[3], "unconditional boundary")
                    eq(context:text(), (event[4] == "edit" or nav) and "" or "ab", "navigation versus unknown edit AI policy")
                    scenarios = scenarios + 1
                end
                local engine, context = instance(nav)
                eq(Word.apply_tap_action(engine, "tap_hold__space"), tap and "word_start" or "kept", "tap action policy")
                eq(engine:current_buffer(), tap and "" or "ab", "tap action word buffer")
                eq(context:text(), nav and "" or "ab", "tap action AI context")
                scenarios = scenarios + 1
            end
        end
    end
end
for _, nav in ipairs({ false, true }) do
    local engine, context = instance(nav)
    eq(Word.apply_typed_newline(engine, "\n", "org.gnome.Terminal"), true, "terminal newline recognized")
    eq(engine:current_buffer(), "", "terminal submission clears hotstring word")
    eq(context:text(), nav and "" or "ab", "terminal submission AI policy")
    engine:backspace()
    eq(engine:buffer_starts_at_word_boundary(), true, "empty terminal line Backspace retains boundary")
    engine, context = instance(nav)
    eq(engine:reset_after_pause(), true, "pause resets nonempty word")
    eq(context:text(), "", "pause always forgets AI context")
    engine:reset(true, true)
    eq(engine:reset_after_pause(), false, "pause preserves empty-line promise")
    engine:backspace()
    eq(engine:buffer_starts_at_word_boundary(), true, "empty-line promise survives idle pause")
    engine:reset(false)
    engine:on_char("é"); engine:backspace()
    eq(engine:buffer_starts_at_word_boundary(), true, "erase last Unicode scalar returns word start")
    engine:backspace()
    eq(engine:buffer_starts_at_word_boundary(), false, "Backspace beyond known text revokes boundary")
end
local ContextBuffer = require("llm.context_buffer")
local context_file = assert(io.open(root .. "/static/ergopti_plus/_shared/tests/corpus/llm/context_buffer_vectors.json", "rb"))
local contexts = assert(JSON.decode(context_file:read("*a"))); context_file:close()
eq(ContextBuffer.CAPACITY_CODEPOINTS, contexts.capacity, "shared context capacity")
for _, vector in ipairs(contexts.cases) do
    local buffer = ContextBuffer.new()
    local cleared = {}
    for _, step in ipairs(vector.ops) do
        if step.op == "append" then
            for _ = 1, step["repeat"] or 1 do buffer:append(step.text) end
        elseif step.op == "backspace" then buffer:backspace()
        elseif step.op == "replace_tail" then buffer:replace_tail(step.deletes, step.text)
        elseif step.op == "set" then buffer:set(step.text)
        elseif step.op == "clear" then buffer:clear()
        elseif step.op == "navigated" then cleared[#cleared + 1] = buffer:navigated(step.reset_on_nav)
        else error("unknown actual corpus operation") end
    end
    eq(buffer:text(), vector.expect.text, vector.id .. " actual shared context text")
    eq(buffer:length(), vector.expect.length, vector.id .. " actual shared context length")
    if vector.cleared then
        eq(#cleared, #vector.cleared, "navigation receipt count")
        for i, value in ipairs(vector.cleared) do eq(cleared[i], value, "navigation receipt value") end
    end
end
for _, vector in ipairs(contexts.private_mirror.cases) do
    local text, mark = ContextBuffer.after_private(vector.text, vector.mark)
    eq(text, vector.expect.visible, vector.id .. " visible text")
    eq(mark, vector.expect.mark, vector.id .. " private mark")
end
local errors = 0
for _, call in ipairs(log_calls) do if call.kind == "error" then errors = errors + 1 end end
eq(errors, 0, "no unexpected error logs")
print(JSON.encode({ checks = checks, policy_scenarios = scenarios, idle_vectors = #corpus.vectors, context_vectors = #contexts.cases, private_vectors = #contexts.private_mirror.cases, native_receiving = false, result = "pass", scope = "actual shared Engine, Linux WordReset/Engine/AIContext/Settings cache restore; logger port only" }))
