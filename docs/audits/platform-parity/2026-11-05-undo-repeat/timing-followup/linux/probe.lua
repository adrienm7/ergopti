-- Actual Main repeat timing, real preference/configuration/delay owners.
local root = assert(arg[1])
local driver = root .. "/static/ergopti_plus/linux"
local shared = root .. "/static/ergopti_plus/_shared/lua"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
require("test.runner_home").isolate(); require("compat.utf8").install()
local helpers = require("tests.helpers")
local Logger = require("logger.shim"); Logger.set_level("trace"); Logger.set_sink(function() end)
local Fixture = require("tests.support.text_owner_fixture")
local Preferences = require("infra.hotstring_preferences")
local Config = require("modules.hotstrings.hotstrings_config")
local Repeat = require("modules.hotstrings.repeat_key")
local Word = require("modules.hotstrings.word_reset")
local Magic = require("modules.hotstrings.magic_key")
local ExpansionDelay = require("modules.hotstrings.expansion_delay")
local Timings = require("infra.timings")
local Layout = require("adapters.keyboard_layout")
local Clipboard = require("adapters.clipboard")
local function no_clipboard() error("keyboard-only repeat audit must not access a native clipboard") end
Clipboard.is_available, Clipboard.paste_text, Clipboard.new_paste_stage = no_clipboard, no_clipboard, no_clipboard
package.loaded["adapters.keyboard_hook"] = { held_text_modifier_codes = function() return {} end,
    held_shortcut_modifier_codes = function() return {} end, held_forwarded_keys = function() return {} end,
    emergency_stop = function() error("unexpected native failure") end }
local Injector = require("modules.hotstrings.injector")
local f = assert(io.open(driver .. "/ergopti_hotstrings.lua", "rb"))
local source = assert(f:read("*a")); assert(f:close())
local first = assert(source:find("\tlocal function handle_char(", 1, true))
local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
local code = "local _undoable; local _last_offered; local on_char; " .. source:sub(first, last - 1)
    .. "\non_char=handle_char;return handle_char"
local function compile(environment)
    if loadstring then local chunk = assert(loadstring(code)); setfenv(chunk, environment); return chunk() end
    return assert(load(code, "actual Main repeat callback", "t", environment))()
end
local rows = {}
local function run(name, options)
    Fixture.with(function(guard, state)
        local path = os.tmpname()
        local file = assert(io.open(path, "wb"))
        local canonical = '[hotstrings]\nidle_reset_seconds = 0\nrepeat_key_enabled = true\n'
        assert(file:write(canonical)); assert(file:close())
        assert(Preferences._set_file_for_test(path)); assert(Preferences.refresh())
        if options.base ~= nil then assert(Config.set_base_delay(options.base)) end
        if options.magic then assert(Magic.set(options.magic)) end
        file = assert(io.open(path, "rb")); canonical = assert(file:read("*a")); assert(file:close())
        local document = assert(require("toml_codec").decode(canonical))
        assert(Word.adopt_configuration(document)); assert(Word.idle_seconds() == 0)
        assert(Repeat.adopt_configuration(document)); assert(Repeat.is_enabled())
        Word.forget_last_key()
        local engine = require("modules.hotstrings.engine").new()
        local mappings = options.mapping and { { trigger = "po" .. Magic.get(), replacement = "z",
            group = "repeat-timing", auto_expand = true, is_case_sensitive_strict = true } } or {}
        assert(engine:load_mappings(mappings))
        Layout._set_table_for_test({ o = { keycode = 24, mods = {} }, z = { keycode = 44, mods = {} } })
        local row = { name = name, gap_ms = options.gap, config = canonical, magic = Magic.get(),
            base_delay = Config.get_base_delay(), repeat_resolved = Config.resolve("repeat_key"),
            mapping_resolved = Config.resolve("repeat-timing"), idle_seconds = Word.idle_seconds(),
            complex_multiplier = Timings.count("hotstrings", "complex_key_delay_multiplier"),
            complex_carry_ms = Timings.ms("hotstrings", "complex_key_carry_ms"), outputs = {}, wire = {} }
        Injector._set_uinput({ is_open = function() return true end, emit = function(key, value)
            row.wire[#row.wire + 1] = { code = key, value = value }; return true
        end })
        Injector._set_nanosleep_for_test(function() end)
        local hooked = setmetatable({ inject = function(count, text, ...)
            local receipt = Injector.inject(count, text, ...)
            row.outputs[#row.outputs + 1] = { backspaces = count, text = text, ok = receipt.ok }
            return receipt
        end }, { __index = Injector })
        local current = 0
        local env = setmetatable({ secure_focus_guard = guard, script_actions = { is_paused = function() return false end },
            keyboard_hook = { held_modifiers = function() return { shift = options.complex == true and current == 3 } end },
            Monotonic = { now_ms = function() return state.now end, resolution_ms = function() return 0 end },
            _cached_app_id = "owned-editor", LOG = assert(source:match('local LOG = "([^"]+)"')),
            WordReset = Word, RepeatKey = Repeat, MagicKey = Magic, ExpansionDelay = ExpansionDelay,
            terminators_mod = require("keymap.terminators"), hotstrings_config = Config,
            opts = { dry_run = false }, Logger = Logger, engine = engine, injector = hooked,
            keystats = { is_unrecorded_app = function() return false end, suppress = function() end,
                unsuppress = function() end, on_keydown = function() end, record_hotstring = function() end },
        }, { __index = _G })
        local char = compile(env)
        local input = { "p", "o", options.literal or Magic.get() }
        for i, ch in ipairs(input) do
            current = i; state.now = state.now + (i == 3 and options.gap or 10); char(ch, 30)
        end
        row.buffer = engine:current_buffer()
        row.config_acknowledged = Repeat.is_enabled() == true and Word.idle_seconds() == 0
            and document.hotstrings.repeat_key_enabled == true and document.hotstrings.idle_reset_seconds == 0
        assert(row.config_acknowledged)
        for _, output in ipairs(row.outputs) do assert(output.ok == true) end
        Injector._set_uinput(nil); Injector._set_nanosleep_for_test(nil)
        assert(Preferences._set_file_for_test(nil)); assert(os.remove(path))
        rows[#rows + 1] = row
    end)
end
run("repeat_after_1s_default", { gap = 1000 })
run("repeat_after_2s_default", { gap = 2000 })
run("expired_mapping_falls_back_to_repeat", { gap = 1000, mapping = true })
run("admitted_mapping_wins", { gap = 200, mapping = true })
run("complex_expander_widens_mapping_gate", { gap = 1000, mapping = true, complex = true })
run("custom_magic_after_2s", { gap = 2000, magic = "§" })
run("old_magic_is_literal_after_change", { gap = 2000, magic = "§", literal = "★" })
run("repeat_ignores_acknowledged_shorter_base", { gap = 1000, base = 0.1 })
run("unlimited_mapping_wins_after_2s", { gap = 2000, base = 0, mapping = true })
local by = {}; for _, row in ipairs(rows) do by[row.name] = row end
for _, name in ipairs({ "repeat_after_1s_default", "repeat_after_2s_default", "expired_mapping_falls_back_to_repeat",
    "custom_magic_after_2s", "repeat_ignores_acknowledged_shorter_base" }) do
    assert(#by[name].outputs == 1 and by[name].outputs[1].text == "o", name)
end
for _, name in ipairs({ "admitted_mapping_wins", "complex_expander_widens_mapping_gate", "unlimited_mapping_wins_after_2s" }) do
    assert(#by[name].outputs == 1 and by[name].outputs[1].text == "z", name)
end
assert(#by.old_magic_is_literal_after_change.outputs == 0)
assert(by.repeat_after_1s_default.base_delay == 0.75 and by.repeat_after_2s_default.repeat_resolved.delay == 0.75)
assert(by.repeat_ignores_acknowledged_shorter_base.base_delay == 0.1)
assert(by.unlimited_mapping_wins_after_2s.mapping_resolved.delay == 0)
print(assert(require("json").encode({ basis = "Actual Main callback, preference/configuration and delay owners, engine and injector; controlled native ports and clock; no desktop receiving", cases = rows })))
