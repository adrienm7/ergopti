-- Word-reset audit: actual input reader/hook, Main closures, policy and context.
local root = assert(arg[1])
local driver = root .. "/static/ergopti_plus/linux"
local shared = root .. "/static/ergopti_plus/_shared/lua"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
require("test.runner_home").isolate()
require("compat.utf8").install()
local helpers = require("tests.helpers")
local Logger = require("logger.shim")
Logger.set_level("trace"); Logger.set_sink(function() end)
local f = assert(io.open(driver .. "/ergopti_hotstrings.lua", "rb"))
local source = assert(f:read("*a")); assert(f:close())
local function section(begin, finish, start)
    local first = assert(source:find(begin, start or 1, true))
    local last = assert(source:find(finish, first, true))
    return source:sub(first, last - 1)
end
local code = "local _undoable; local _last_offered; local on_char; "
    .. section("\tlocal function handle_char(", "\n\ton_char = input_capture_gate.guard(handle_char)")
    .. section("\tlocal function handle_control(", "\n\tlocal on_control = input_capture_gate.guard(handle_control)")
    .. section("\tlocal function on_click()", "\n\t-- A pointer event of a checked kind")
local reset = section("\t\treset_text = function()", "\n\t\tend,\n\t})")
reset = assert(reset:match("reset_text = function%(%)\n(.*)"))
local pause_start = assert(source:find("\tlocal script_actions = ScriptActions.new({", 1, true))
local pause = section("\t\treset = function()", "\n\t\tend,", pause_start)
pause = assert(pause:match("reset = function%(%)\n(.*)"))
local tap_start = assert(source:find("\tTapHold.init({", 1, true))
local tap = section("\t\texecute_action = function(action, binding)", "\n\t\tend,", tap_start)
tap = assert(tap:match("execute_action = function%(action, binding%)\n(.*)"))
code = code .. "\non_char=handle_char; return handle_char,handle_control,on_click,function()\n" .. reset
    .. "\nend,function()\n" .. pause .. "\nend,function(action,binding)\n" .. tap .. "\nend"
local function compile(environment)
    if loadstring then local chunk = assert(loadstring(code)); setfenv(chunk, environment); return chunk() end
    return assert(load(code, "actual Main input and lifecycle closures", "t", environment))()
end
local K = { a = 30, b = 48, c = 46, d = 32, x = 45, z = 44, y = 21, s = 31, v = 47, l = 38,
    enter = 28, tab = 15, backspace = 14, escape = 1, left = 105, right = 106, up = 103, down = 108,
    home = 102, ["end"] = 107, pageup = 104, pagedown = 109, insert = 110, delete = 111,
    lshift = 42, lctrl = 29, lalt = 56, altgr = 100, lmeta = 125, caps = 58 }
local letters = {}; for char, codepoint in pairs(K) do if #char == 1 then letters[codepoint] = char end end
local rows = {}
local function run(name, options)
    local Hook = helpers.load_module("adapters.keyboard_hook")
    local Word = helpers.load_module("modules.hotstrings.word_reset")
    local Preferences = require("tests.support.llm_preferences_fixture").new({ initial = {
        ["llm.generation.reset_on_nav"] = options.nav ~= false,
    } })
    package.loaded["infra.llm_preferences"] = Preferences
    package.loaded["modules.llm.settings"] = nil; package.loaded["modules.llm.context"] = nil
    local engine = require("modules.hotstrings.engine").new()
    assert(engine:load_mappings({}))
    local context = require("modules.llm.context").new({ is_active = function() return options.ai ~= false end })
    engine:attach_ai_context(context)
    assert(Word.adopt_configuration({ hotstrings = { idle_reset_seconds = options.idle or 0,
        arrow_resets_word = options.word ~= false, shortcut_resets_word = options.word ~= false,
        tap_hold_resets_word = options.tap_word ~= false, click_resets_word = options.click_word ~= false } }))
    Word.forget_last_key()
    local state = { now = 1000, path = "/field/original", bus = ":1.21", role = 61, semantic = 0 }
    local result = { name = name, events = {}, snapshots = {}, predictions = {}, actions = {}, forwarded = {} }
    local function snapshot(label)
        result.snapshots[#result.snapshots + 1] = { label = label, word = engine:current_buffer(),
            context = context:text(), boundary = engine:buffer_starts_at_word_boundary() }
    end
    local function clock()
        state.semantic = state.semantic + 1
        state.now = options.times and options.times[state.semantic] or state.now + 10
        assert(state.now, "every semantic event needs a clock value")
    end
    local Shortcut = require("modules.shortcuts.keyboard_shortcuts")
    local environment = setmetatable({ Logger = Logger, LOG = assert(source:match('local LOG = "([^"]+)"')),
        engine = engine, WordReset = Word, keyboard_hook = Hook,
        script_actions = { is_paused = function() return false end }, opts = { dry_run = false },
        Monotonic = { now_ms = function() return state.now end, resolution_ms = function() return 1 end },
        _cached_app_id = options.app or "owned-editor", RepeatKey = { is_enabled = function() return false end },
        terminators_mod = require("keymap.terminators"),
        injector = { _is_injecting = function() return false end },
        keyboard_shortcuts = setmetatable({ dispatch = function() return false end }, { __index = Shortcut }),
        prediction_engine = { on_char = function(ch, text)
                result.predictions[#result.predictions + 1] = { ch = ch, context = text }
            end, withdraw = function() end, drop_tone = function() end },
        wrap_on_type = { on_pointer_down = function() end },
        action_catalogue = { execute_action = function(action, binding)
            result.actions[#result.actions + 1] = { action = action, binding = binding }
        end },
        keystats = { is_unrecorded_app = function() return false end, suppress = function() end,
            unsuppress = function() end, on_keydown = function() end, record_correction = function() end,
            record_shortcut = function() end, cancel_hold_intervals = function() end },
    }, { __index = _G })
    local char, control, click, reset_text, pause_reset, tap_action = compile(environment)
    local action_manager, writer
    if options.action or options.real_tap_action then
        writer = require("tests.fakes").uinput_writer()
        assert(writer.open())
        package.loaded["adapters.uinput_writer"] = writer
        assert(require("adapters.modifier_broker").attach(writer))
        helpers.load_module("modules.gestures.combo_emitter")
        action_manager = helpers.load_module("modules.gestures.manager")
        if options.real_tap_action then
            local declared = false
            for _, action in ipairs(action_manager.get_executable_action_names()) do
                if action == options.real_tap_action then declared = true end
            end
            assert(declared, "the tap action must be present in the production executable catalogue")
            environment.action_catalogue = action_manager
        end
    end
    local policy = require("modules.keystats.keystats")
    local configuration = assert(policy.configuration_snapshot()); configuration.private_filter_enabled = false
    assert(policy.apply_configuration(configuration))
    local detector = helpers.load_module("adapters.secure_field_detector")
    local listener
    local watch = { on_change = function(fn) listener = fn end, pump = function() end }
    watch.snapshot = function() return state.receipt end
    watch.invalidate = function() state.receipt = nil; listener(nil) end
    watch.barrier = function()
        state.receipt = { bus = state.bus, path = state.path, role = state.role }; listener(state.receipt); return state.receipt
    end
    local guard = helpers.load_module("modules.keystats.focus_guard").new({ watch = watch, detector = detector,
        keystats = policy, now_ms = function() return state.now end, reset_text = reset_text,
        capture_context = function() return { app_id = options.app or "owned-editor", title = "Audit", native_identity = "audit-window" } end,
        publish_context = function(info) return true, policy.is_context_protected(info.app_id, info.title) end })
    environment.secure_focus_guard = guard
    assert(guard.prime())
    local shift = false
    local events = {}
    local function press(code)
        events[#events + 1] = { type = 1, code = code, value = 1 }
        events[#events + 1] = { type = 1, code = code, value = 0 }
    end
    for _, token in ipairs(options.tokens) do
        if type(token) == "string" then press(assert(K[token]))
        else
            for _, mod in ipairs(token.mods or {}) do events[#events + 1] = { type = 1, code = assert(K[mod]), value = 1 } end
            press(assert(K[token.key]))
            for i = #(token.mods or {}), 1, -1 do events[#events + 1] = { type = 1, code = K[token.mods[i]], value = 0 } end
        end
    end
    if options.tap then
        Hook.set_remapper(require("platform.remap.tap_hold_engine").new({
            keys = { caps_lock = { tap_action = options.real_tap_action or "paste", hold_modifier = "ctrl", time_activation_seconds = 10 } },
            tap_min_ms = 0, lone_tap_max_ms = 0, one_shot_timeout_ms = 2000,
        }), tap_action)
    end
    result.drained = Hook._test_drive(events, {
        captureEvent = function(codepoint, value)
            if codepoint == K.lshift then shift = value ~= 0; return nil end
            local letter = letters[codepoint]
            if value == 0 or not letter then return nil end
            return shift and letter:upper() or letter, letter, nil
        end,
        onEmitRaw = function(codepoint, value)
            result.forwarded[#result.forwarded + 1] = { code = codepoint, value = value }; return true
        end,
        onChar = function(ch, scancode)
            clock(); result.events[#result.events + 1] = { kind = "text", ch = ch }
            char(ch, scancode); snapshot("text")
            if options.action and ch == "b" then
                assert(action_manager.execute_action(options.action, "audit-action-binding"))
                snapshot("action")
            end
        end,
        onKey = function(key, detail)
            clock(); result.events[#result.events + 1] = { kind = "control", key = key, detail = detail }
            control(key, detail); snapshot("control")
        end,
    }, true)
    assert(result.drained == #events, "the actual reader must drain every encoded event")
    if options.click then click(); snapshot("pointer-reset") end
    if options.pause then pause_reset(); snapshot("pause-reset") end
    if options.focus then state.path = "/field/successor"; guard.invalidate(); snapshot("focus-reset") end
    result.word, result.context = engine:current_buffer(), context:text()
    if writer then
        result.action_output = writer.events
        assert(writer.close()); require("adapters.modifier_broker").detach(writer)
        package.loaded["adapters.uinput_writer"] = nil
    end
    Hook.set_remapper(nil); guard.stop()
    rows[#rows + 1] = result
end
run("arrow_nav_off_word_on_next_key", { nav = false, tokens = { "a", "b", "left", "c" } })
run("arrow_nav_on_word_off_next_key", { word = false, tokens = { "a", "b", "left", "c" } })
run("ctrl_z_forgets_unknown_edit", { nav = false, word = false, tokens = { "a", "b", { key = "z", mods = { "lctrl" } }, "c" } })
run("ctrl_y_forgets_unknown_edit", { nav = false, word = false, tokens = { "a", "b", { key = "y", mods = { "lctrl" } }, "c" } })
run("ctrl_shift_z_forgets_unknown_edit", { nav = false, word = false, tokens = { "a", "b", { key = "z", mods = { "lctrl", "lshift" } }, "c" } })
run("ctrl_s_keeps_explicitly_retained_context", { nav = false, word = false, tokens = { "a", "b", { key = "s", mods = { "lctrl" } }, "c" } })
run("gui_enter_nav_on", { tokens = { "a", "b", "enter", "c" } })
run("terminal_enter_nav_on", { app = "org.gnome.Terminal", tokens = { "a", "b", "enter", "c" } })
run("gui_enter_nav_off", { nav = false, tokens = { "a", "b", "enter", "c" } })
run("terminal_enter_nav_off", { nav = false, app = "org.gnome.Terminal", tokens = { "a", "b", "enter", "c" } })
run("terminal_shift_enter_known_modifier_gap", { app = "org.gnome.Terminal", tokens = { "a", "b", { key = "enter", mods = { "lshift" } }, "c" } })
run("ctrl_enter_control_path", { nav = false, word = false, tokens = { "a", "b", { key = "enter", mods = { "lctrl" } }, "c" } })
run("escape_retains_ai_context", { nav = false, tokens = { "a", "b", "escape", "c" } })
run("ctrl_a_editor_then_empty_backspace", { tokens = { "a", "b", { key = "a", mods = { "lctrl" } }, "backspace" } })
run("ctrl_a_terminal_then_empty_backspace", { app = "org.gnome.Terminal", tokens = { "a", "b", { key = "a", mods = { "lctrl" } }, "backspace" } })
run("ctrl_l_browser_then_empty_backspace", { app = "firefox", tokens = { "a", "b", { key = "l", mods = { "lctrl" } }, "backspace" } })
run("bare_backspace_after_idle_keeps_previous_word", { idle = 3, times = { 1000, 1010, 6000, 6010 }, tokens = { "a", "b", "backspace", "c" } })
run("ordinary_key_after_idle_forgets_context", { idle = 3, times = { 1000, 1010, 6000 }, tokens = { "a", "b", "c" } })
run("ctrl_backspace_forgets_context", { nav = false, tokens = { "a", "b", { key = "backspace", mods = { "lctrl" } }, "c" } })
run("alt_backspace_forgets_context", { nav = false, tokens = { "a", "b", { key = "backspace", mods = { "lalt" } }, "c" } })
run("direct_paste_forgets_context", { nav = false, word = false, tokens = { "a", "b", { key = "v", mods = { "lctrl" } }, "c" } })
run("tap_paste_navigation_policy", { nav = false, tap = true, tokens = { "a", "b", "caps", "c" } })
run("click_privacy_reset_dominates_nav_off", { nav = false, tokens = { "a", "b" }, click = true })
run("pause_forgets_ai_context", { nav = false, tokens = { "a", "b" }, pause = true })
run("focus_forgets_ai_context", { nav = false, tokens = { "a", "b" }, focus = true })
run("ai_disabled_retains_nothing", { ai = false, tokens = { "a", "b", "left", "c" } })
run("catalogue_arrow_does_not_reset", { action = "arrow_left", tokens = { "a", "b", "c" } })
run("tap_arrow_off_tap_reset_on", { nav = false, word = false, tap_word = true, tap = true,
    real_tap_action = "arrow_left", tokens = { "a", "b", "caps", "c" } })
run("tap_arrow_on_tap_reset_off", { nav = true, word = true, tap_word = false, tap = true,
    real_tap_action = "arrow_left", tokens = { "a", "b", "caps", "c" } })
for _, key in ipairs({ "right", "up", "down" }) do
    run("arrow_" .. key .. "_retains_ai_through_next_key", { nav = false, tokens = { "a", "b", key, "c" } })
end
for _, key in ipairs({ "home", "end", "pageup", "pagedown", "insert", "delete" }) do
    run("unconditional_" .. key .. "_word_navigation", { nav = false, word = false, tokens = { "a", "b", key, "c" } })
end
run("terminal_alt_b_conservative_edit", { nav = false, app = "org.gnome.Terminal", tokens = { "a", "b", { key = "b", mods = { "lalt" } }, "c" } })
run("gui_alt_b_preserves_navigation_context", { nav = false, tokens = { "a", "b", { key = "b", mods = { "lalt" } }, "c" } })
run("tap_held_ctrl_shortcut_owns_word_setting", { nav = false, tap = true, tap_word = false,
    tokens = { "a", "b", { key = "s", mods = { "caps" } }, "c" } })
run("click_word_off_keeps_unknown_boundary", { nav = false, click_word = false, tokens = { "a", "b" }, click = true })
run("tab_invalidates_original_context", { nav = false, tokens = { "a", "b", "tab" } })
local by = {}; for _, row in ipairs(rows) do by[row.name] = row end
assert(by.arrow_nav_off_word_on_next_key.word == "c" and by.arrow_nav_off_word_on_next_key.context == "abc")
assert(by.arrow_nav_off_word_on_next_key.predictions[#by.arrow_nav_off_word_on_next_key.predictions].context == "abc")
assert(by.arrow_nav_on_word_off_next_key.word == "abc" and by.arrow_nav_on_word_off_next_key.context == "c")
for _, name in ipairs({ "ctrl_z_forgets_unknown_edit", "ctrl_y_forgets_unknown_edit", "ctrl_shift_z_forgets_unknown_edit", "direct_paste_forgets_context", "ctrl_backspace_forgets_context", "alt_backspace_forgets_context" }) do assert(by[name].context == "c", name) end
assert(by.ctrl_s_keeps_explicitly_retained_context.context == "abc")
assert(by.gui_enter_nav_on.context == "ab\nc")
assert(by.terminal_enter_nav_on.context == "c")
assert(by.gui_enter_nav_off.context == "ab\nc" and by.terminal_enter_nav_off.context == "ab\nc")
assert(by.terminal_shift_enter_known_modifier_gap.context == "c")
assert(by.ctrl_enter_control_path.context == "abc")
assert(by.escape_retains_ai_context.context == "abc")
assert(by.ctrl_a_editor_then_empty_backspace.snapshots[4].boundary == true)
assert(by.ctrl_a_terminal_then_empty_backspace.snapshots[4].boundary == false)
assert(by.ctrl_l_browser_then_empty_backspace.snapshots[4].boundary == true)
assert(by.bare_backspace_after_idle_keeps_previous_word.word == "ac" and by.bare_backspace_after_idle_keeps_previous_word.context == "ac")
assert(by.ordinary_key_after_idle_forgets_context.word == "c" and by.ordinary_key_after_idle_forgets_context.context == "c")
assert(by.tap_paste_navigation_policy.context == "abc" and #by.tap_paste_navigation_policy.actions == 1)
assert(by.click_privacy_reset_dominates_nav_off.context == "")
assert(by.pause_forgets_ai_context.context == "" and by.focus_forgets_ai_context.context == "")
assert(by.ai_disabled_retains_nothing.context == "")
assert(by.catalogue_arrow_does_not_reset.word == "abc" and by.catalogue_arrow_does_not_reset.context == "abc")
assert(#by.catalogue_arrow_does_not_reset.action_output == 2)
assert(by.catalogue_arrow_does_not_reset.action_output[1].code == K.left and by.catalogue_arrow_does_not_reset.action_output[1].value == 1)
assert(by.catalogue_arrow_does_not_reset.action_output[2].code == K.left and by.catalogue_arrow_does_not_reset.action_output[2].value == 0)
assert(by.tap_arrow_off_tap_reset_on.word == "c" and by.tap_arrow_off_tap_reset_on.context == "abc")
assert(by.tap_arrow_on_tap_reset_off.word == "abc" and by.tap_arrow_on_tap_reset_off.context == "c")
for _, name in ipairs({ "tap_arrow_off_tap_reset_on", "tap_arrow_on_tap_reset_off" }) do
    assert(#by[name].action_output == 2)
    assert(by[name].action_output[1].code == K.left and by[name].action_output[1].value == 1)
end
for _, key in ipairs({ "right", "up", "down" }) do
    assert(by["arrow_" .. key .. "_retains_ai_through_next_key"].word == "c")
    assert(by["arrow_" .. key .. "_retains_ai_through_next_key"].context == "abc")
end
for _, key in ipairs({ "home", "end", "pageup", "pagedown", "insert", "delete" }) do
    assert(by["unconditional_" .. key .. "_word_navigation"].word == "c")
    assert(by["unconditional_" .. key .. "_word_navigation"].context == "abc")
end
assert(by.terminal_alt_b_conservative_edit.context == "c")
assert(by.gui_alt_b_preserves_navigation_context.context == "abc")
assert(by.tap_held_ctrl_shortcut_owns_word_setting.word == "abc")
assert(by.tap_held_ctrl_shortcut_owns_word_setting.events[3].detail.tap_hold == true)
assert(by.click_word_off_keeps_unknown_boundary.snapshots[3].boundary == false)
assert(by.tab_invalidates_original_context.context == "")
print(assert(require("json").encode({ basis = "Actual production reader/hook, Main callbacks, WordReset, engine and context; controlled native and preference/prediction/action receiver ports; no native editor receiving", cases = rows })))
