-- Linux undo/repeat audit: actual Main callbacks, engine, repeat owner and injector.
-- Only the native keyboard channel/layout and ambient app/telemetry ports are recorded.
local root = assert(arg[1], "repository root required")
local driver = root .. "/static/ergopti_plus/linux"
local shared = root .. "/static/ergopti_plus/_shared/lua"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
require("test.runner_home").isolate()
require("compat.utf8").install()
local helpers = require("tests.helpers")
local Logger = require("logger.shim")
Logger.set_level("trace")
local logs = {}
Logger.set_sink(function(line) logs[#logs + 1] = line end)
local Fixture = require("tests.support.text_owner_fixture")
local Engine = require("modules.hotstrings.engine")
local Repeat = require("modules.hotstrings.repeat_key")
local WordReset = require("modules.hotstrings.word_reset")
local Magic = require("modules.hotstrings.magic_key")
local Terminators = require("keymap.terminators")
local Layout = require("adapters.keyboard_layout")
local Clipboard = require("adapters.clipboard")
local function reject_clipboard() error("this keyboard-only audit must never access a native clipboard", 0) end
Clipboard.is_available = reject_clipboard
Clipboard.paste_text = reject_clipboard
Clipboard.new_paste_stage = reject_clipboard
local native_hook = { stops = 0 }
package.loaded["adapters.keyboard_hook"] = {
    held_text_modifier_codes = function() return {} end,
    held_shortcut_modifier_codes = function() return {} end,
    held_forwarded_keys = function() return {} end,
    emergency_stop = function() native_hook.stops = native_hook.stops + 1 end,
}
local Injector = require("modules.hotstrings.injector")
local ExpansionDelay = require("modules.hotstrings.expansion_delay")
local JSON = require("json")
local f = assert(io.open(driver .. "/ergopti_hotstrings.lua", "rb"))
local source = assert(f:read("*a")); assert(f:close())
local first = assert(source:find("\tlocal function handle_char(", 1, true))
local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
local callbacks = "local _undoable; local _last_offered; local on_char; " .. source:sub(first, last - 1)
first = assert(source:find("\tlocal function handle_control(", 1, true))
last = assert(source:find("\n\tlocal on_control = input_capture_gate.guard(handle_control)", first, true))
callbacks = callbacks .. source:sub(first, last - 1)
    .. "\non_char=handle_char; return handle_char,handle_control,function() return _undoable end"
local function compile(environment)
    if loadstring then local chunk = assert(loadstring(callbacks)); setfenv(chunk, environment); return chunk() end
    return assert(load(callbacks, "actual Main callbacks", "t", environment))()
end
local function drop_last(text)
    local at = utf8.offset(text, -1)
    return at and text:sub(1, at - 1) or ""
end
local cases = {}
local function run(name, options)
    Fixture.with(function(guard, state)
        logs = {}
        local engine = Engine.new()
        local mappings = options.mappings or {}
        if options.private_prefix then
            mappings = require("modules.dynamic_hotstrings.prefix_rules").build({ social_security_number = "123456789012349" },
                function(_, section) return section == "ssnprefixes" end)
            assert(#mappings == 1 and mappings[1].trigger == "12345")
            assert(mappings[1].is_private == true and mappings[1].final_result == false)
        end
        if options.shipped then
            mappings = require("modules.hotstrings.loader").load({ {
                path = root .. "/static/layouts/registry/ergopti/hotstrings/repeatcorrections.toml",
                category = "magickey", only_sections = { "repeat_corrections" },
            } })
            assert(#mappings == 14, "the shipped correction source must load in full")
        end
        assert(engine:load_mappings(mappings))
        assert(Repeat.adopt_configuration({ hotstrings = { repeat_key_enabled = options.repeat_on ~= false } }))
        assert(WordReset.adopt_configuration({ hotstrings = {
            idle_reset_seconds = 0, cascade_max_arrows = 1,
            arrow_resets_word = false, shortcut_resets_word = false,
        } }))
        local keychars = { [30] = "a", [46] = "c", [24] = "o", [25] = "p", [22] = "u", [18] = "ê",
            [21] = "y", [45] = "x", [48] = "b", [44] = "z", [57] = " ", [28] = "\n", [50] = "Ω",
            [31] = "s", [32] = "d", [33] = "f", [34] = "g", [35] = "h", [36] = "j", [37] = "k",
            [38] = "l", [49] = "n", [23] = "i", [20] = "t", [19] = "r", [47] = "v", [17] = "w",
            [16] = "q", [15] = "\t", [51] = ",", [52] = ".", [53] = "/", [40] = "'", [12] = "-",
            [11] = "0", [2] = "1", [3] = "2", [4] = "3", [5] = "4", [6] = "5", [7] = "6", [8] = "7",
            [9] = "8", [10] = "9", [43] = "★", [41] = "☃", [39] = "é", [27] = "😀", [26] = "́", [54] = "e", [55] = "m" }
        local layout = {}
        for code, char in pairs(keychars) do layout[char] = { keycode = code, mods = {} } end
        Layout._set_table_for_test(layout)
        local result = { name = name, outputs = {}, telemetry = {}, snapshots = {}, wire = {}, screen = options.prefix or "" }
        local original_stops = native_hook.stops
        Injector._set_uinput({ is_open = function() return true end, emit = function(code, value)
            result.wire[#result.wire + 1] = { code = code, value = value }
            if options.fail_down and value == 1 then return false end
            if value == 1 then
                if code == 14 then result.screen = drop_last(result.screen)
                elseif keychars[code] then result.screen = result.screen .. keychars[code] end
            end
            return true
        end })
        Injector._set_nanosleep_for_test(function() end)
        local recorded_injector = setmetatable({ inject = function(...)
            local n, text, private, tail = ...
            local receipt = Injector.inject(...)
            result.outputs[#result.outputs + 1] = { count = n, text = text, private = private == true, tail = tail, ok = receipt.ok,
                error = receipt.error, cleanup_ok = receipt.cleanup_ok }
            return receipt
        end }, { __index = Injector })
        local environment = setmetatable({
            secure_focus_guard = guard, script_actions = { is_paused = function() return options.paused == true end },
            keyboard_hook = { held_modifiers = function() return {} end },
            Monotonic = { now_ms = function() return state.now end, resolution_ms = function() return 1 end },
            _cached_app_id = "owned-editor", LOG = assert(source:match('local LOG = "([^"]+)"')),
            WordReset = WordReset, terminators_mod = Terminators, RepeatKey = Repeat,
            MagicKey = Magic, ExpansionDelay = ExpansionDelay, opts = { dry_run = false },
            hotstrings_config = { resolve = function() return { delay = 2 } end },
            keystats = { is_unrecorded_app = function() return false end, suppress = function() end, unsuppress = function() end,
                on_keydown = function() end, record_correction = function() end,
                record_hotstring = function(_, trigger, text, _, group, count, private)
                    result.telemetry[#result.telemetry + 1] = { trigger = trigger, text = text, group = group, count = count, private = private == true }
                end }, engine = engine, Logger = Logger, injector = recorded_injector,
        }, { __index = _G })
        local char, control, undo = compile(environment)
        for _, token in ipairs(options.tokens or {}) do
            state.now = state.now + 10
            if type(token) == "string" then
                result.screen = result.screen .. token; char(token, 30)
            elseif token.key == "backspace" then
                result.screen = drop_last(result.screen); control("backspace", { mods = token.mods or {} })
            elseif token.key == "focus" then
                state.path = "/field/successor"; guard.invalidate()
            else control(token.key, token.detail or {}) end
            result.snapshots[#result.snapshots + 1] = { buffer = engine:current_buffer(), screen = result.screen,
                undo = undo() ~= nil, boundary = engine:buffer_starts_at_word_boundary() }
        end
        result.logs = logs
        result.stops = native_hook.stops - original_stops
        cases[#cases + 1] = result
        Injector._set_uinput(nil); Injector._set_nanosleep_for_test(nil)
    end)
end
run("repeat_then_repeat", { tokens = { "p", "o", "★", "★" } })
run("shipped_after_repeat", { shipped = true, tokens = { "a", "c", "★", "ê" } })
run("shipped_manual_positive", { shipped = true, tokens = { "a", "c", "c", "ê" } })
run("repeat_immediate_backspace", { tokens = { "p", "o", "★", { key = "backspace" } } })
run("repeat_off", { repeat_on = false, tokens = { "p", "o", "★" } })
run("repeat_private_ancestry", { private_prefix = true, tokens = { "1", "2", "3", "4", "5", "★" } })
run("empty_replacement_undo", { prefix = "PRE", repeat_on = false, mappings = {
    { trigger = "xy", replacement = "", auto_expand = true, is_case_sensitive_strict = true } },
    tokens = { "x", "y", { key = "backspace" } } })
run("terminator_undo", { mappings = { { trigger = "adn", replacement = "adnΩ", is_case_sensitive_strict = true } },
    tokens = { "a", "d", "n", " ", { key = "backspace" } } })
run("empty_replacement_with_tail_undo", { prefix = "PRE", repeat_on = false, mappings = {
    { trigger = "xy", replacement = "", auto_expand = false, is_case_sensitive_strict = true } },
    tokens = { "x", "y", " ", { key = "backspace" } } })
run("repeat_then_typed_char_retires_undo", { tokens = { "p", "o", "★", "x", { key = "backspace" } } })
run("repeat_then_arrow_retires_undo", { tokens = { "p", "o", "★", { key = "left" }, { key = "backspace" } } })
run("repeat_then_ctrl_backspace_no_undo", { tokens = { "p", "o", "★", { key = "backspace", mods = { ctrl = true } } } })
run("repeat_failure_no_undo_or_telemetry", { fail_down = true, tokens = { "p", "o", "★" } })
run("repeat_paused", { paused = true, tokens = { "p", "o", "★" } })
run("repeat_non_bmp", { tokens = { "a", "😀", "★" } })
run("repeat_combining_scalar", { tokens = { "a", "́", "★" } })
run("registered_mapping_wins", { mappings = { { trigger = "po★", replacement = "winner", auto_expand = true,
    is_case_sensitive_strict = true } }, tokens = { "p", "o", "★" } })
run("private_undo", { private_prefix = true, tokens = { "1", "2", "3", "4", "5", { key = "backspace" } } })
run("repeat_forges_word_start", { mappings = { { trigger = "x", replacement = "z", auto_expand = true,
    is_word = true, is_case_sensitive_strict = true } }, tokens = { "p", "o", "★", "x" } })
run("manual_doubling_keeps_word_start_guard", { mappings = { { trigger = "x", replacement = "z", auto_expand = true,
    is_word = true, is_case_sensitive_strict = true } }, tokens = { "p", "o", "o", "x" } })
local index = {}; for _, case in ipairs(cases) do index[case.name] = case end
assert(index.repeat_then_repeat.screen == "poo★")
assert(index.repeat_then_repeat.snapshots[3].buffer == "")
assert(index.shipped_after_repeat.screen == "accê")
assert(index.shipped_manual_positive.screen == "accu")
assert(index.repeat_immediate_backspace.screen == "po★")
assert(index.repeat_off.screen == "po★")
assert(index.repeat_private_ancestry.outputs[1].private == true)
assert(index.repeat_private_ancestry.outputs[2].private == false)
assert(index.repeat_private_ancestry.outputs[2].text == "9")
assert(index.empty_replacement_undo.screen == "PR")
assert(index.terminator_undo.screen == "adn")
assert(index.empty_replacement_with_tail_undo.screen == "PRExy")
assert(#index.repeat_then_typed_char_retires_undo.outputs == 1)
assert(#index.repeat_then_arrow_retires_undo.outputs == 1)
assert(#index.repeat_then_ctrl_backspace_no_undo.outputs == 1)
assert(#index.repeat_failure_no_undo_or_telemetry.outputs == 1)
assert(index.repeat_failure_no_undo_or_telemetry.outputs[1].ok == false)
assert(#index.repeat_failure_no_undo_or_telemetry.telemetry == 0)
assert(index.repeat_failure_no_undo_or_telemetry.snapshots[3].undo == false)
assert(index.repeat_failure_no_undo_or_telemetry.stops == 1)
assert(#index.repeat_paused.outputs == 0)
assert(index.repeat_non_bmp.screen == "a😀😀")
assert(index.repeat_combining_scalar.screen == "á́")
assert(index.registered_mapping_wins.screen == "winner")
assert(index.private_undo.screen == "12345")
assert(index.private_undo.outputs[2].private == true)
assert(index.repeat_forges_word_start.screen == "pooz")
assert(index.manual_doubling_keeps_word_start_guard.screen == "poox")
print(assert(JSON.encode({ basis = "actual Lua Main callbacks, production engine/repeat/loader/injector/focus guard; recording native channel scalar model", cases = cases })))
