--- tools/diagnostics/native_global_switcher/test_probe_owner.lua
-- Executes the actual isolated probe with controlled native ports; no macOS proof.
local base = assert(arg[1])
local cases = {
    "hardware_pin_replaced_after_command", "hardware_pin_replaced_during_constructor", "hardware_pin_restored_after_command", "session_command_stuck_after_up", "session_tab_stuck_after_up", "session_flags_stuck_after_up", "session_stale_after_up", "session_malformed_after_up", "session_release_later", "session_preheld", "healthy", "hardware_constructor_nil", "hardware_constructor_throw", "unadmitted_hardware_still_running", "unadmitted_hardware_query_nil", "unadmitted_hardware_query_throw", "post_return_without_delivery", "post_return_without_delivery_external_effect", "delivery_without_effect", "physical_left_command",
    "physical_right_command", "physical_tab", "wrong_hardware_source", "hardware_start_nil",
    "hardware_start_false", "hardware_start_throw", "hardware_sync_callback_then_refusal",
    "timer_stop_false", "timer_stop_nil", "timer_stop_throw", "tap_stop_false",
    "tap_stop_nil", "tap_stop_throw", "source_revoked_after_command", "source_pin_replaced_after_command", "physical_during_command", "long_physical_hold_wrap",
    "command_post_refused_after_delivery", "accessibility_refused", "foreign_event_pid",
    "identity_prepost_tag", "identity_prepost_pid", "identity_prepost_state",
    "private_state_instance", "private_state_selector_refused", "private_state_session_refused", "foreign_event_state",
}
local function check(value, message) if not value then error(message, 0) end end
local function run(mode)
    local fixture = base .. "/control-" .. mode
    local config = { pins = { { path = fixture .. "/global-switcher.lua", dev = 7, ino = 9, sha256 = string.rep("a", 64) },
        { path = fixture .. "/hardware", dev = 7, ino = 11, sha256 = string.rep("a", 64) } }, hardware = fixture .. "/hardware", result = fixture .. "/result.json",
        fixture_a = 101, fixture_b = 202, bundle_a = "fixture.a", bundle_b = "fixture.b" }
    local input = assert(io.open(base .. "/global-switcher.lua", "rb")); local src = assert(input:read("*a")); assert(input:close())
    -- The test runner prepares these unique directories; it never overwrites product files.
    local out = assert(io.open(fixture .. "/global-switcher.lua", "wb")); assert(out:write(src)); assert(out:close())
    local hardware = assert(io.open(fixture .. "/hardware", "wb")); assert(hardware:write("independent trusted hardware fixture")); assert(hardware:close())
    local source = assert(io.open(fixture .. "/probe-config.json", "wb")); assert(source:write("independent-probe-scope")); assert(source:close())
    local ticks, callbacks, posts, activations, report, current_front = {}, {}, {}, {}, nil, nil
    local physical, revoked, pins_changed, clock = false, false, false, 0
    local release_session_later = false
    local hardware_revoked, constructor_calls, start_calls = false, 0, 0
    local properties = { eventSourceUserData = 1, eventSourceUnixProcessID = 2, eventSourceStateID = 3 }
    local types = { keyDown = 10, keyUp = 11, flagsChanged = 12 }
    local observer, private_command
    local nonce_one_count = 0
    local hs = {
        processInfo = { processID = 303 },
        fs = { attributes = function(path)
            if path:match("/cancel$") then return revoked and {} or nil end
            if path == config.hardware then return { dev = 7, ino = hardware_revoked and 99 or 11, mode = "file" } end
            return { dev = 7, ino = (pins_changed and path:match("/global%-switcher%.lua$") and 99 or 9), mode = "file" }
        end },
        hash = { new = function()
            local context = {}
            function context:append(_) return self end
            function context:finish() return self end
            function context:value() return string.rep("a", 64) end
            return context
        end },
        json = {}, application = {}, task = {}, eventtap = { event = { types = types, properties = properties } },
        timer = { absoluteTime = function() return clock end },
        accessibilityState = function(prompt) check(prompt == false, "TCC prompt forbidden"); return mode ~= "accessibility_refused" end,
    }
    function hs.json.decode(raw)
        if raw == "independent-probe-scope" then return config end
        local request = tonumber(raw:match("^hardware:(%d+)$")); check(request, "unexpected hardware frame")
        local held = {}
        if mode == "physical_left_command" then held = { 55 }
        elseif mode == "physical_right_command" then held = { 54 }
        elseif mode == "physical_tab" then held = { 48 }
        elseif (mode == "physical_during_command" or mode == "long_physical_hold_wrap") and physical then held = { 54 } end
        local session_held = private_command and {55} or {}
        local session_flags = private_command and 0x100000 or 0
        if mode == "session_preheld" then session_held = {55}; session_flags = 0x100000 end
        if #posts >= 4 then
            if mode == "session_command_stuck_after_up" or mode == "session_release_later" and not release_session_later then
                session_held = {55}; session_flags = 0x100000
            elseif mode == "session_tab_stuck_after_up" then session_held = {48}
            elseif mode == "session_flags_stuck_after_up" then session_held = {}; session_flags = 0x100000 end
        end
        local session = { version = 1, request = request, source = "combined_session", held = session_held, flags = session_flags }
        if #posts >= 4 and mode == "session_stale_after_up" then session.request = request - 1 end
        if #posts >= 4 and mode == "session_malformed_after_up" then session.held = false end
        return { version = 1, request = request, session = session, source = mode == "wrong_hardware_source" and "combined_session" or "hid_system",
            held = held, flags = 0, listen_access = true, post_access = true, ax_trusted = true }
    end
    function hs.json.write(value) report = value; return true end
    function hs.application.get(pid)
        return { pid = function() return pid end, bundleID = function() return pid == 101 and "fixture.a" or "fixture.b" end,
            activate = function() activations[#activations + 1] = pid; current_front = pid; return true end }
    end
    function hs.application.frontmostApplication()
        if not current_front then return nil end
        return { pid = function() return current_front end }
    end
    function hs.eventtap.new(_, callback)
        observer = callback
        local tap = { enabled = false }
        function tap:start() self.enabled = true; return self end
        function tap:isEnabled() return self.enabled end
        function tap:stop()
            if mode == "tap_stop_false" then return false end
            if mode == "tap_stop_nil" then return nil end
            if mode == "tap_stop_throw" then error("controlled tap stop refusal") end
            self.enabled = false; return self
        end
        return tap
    end
    function hs.eventtap.event.newKeyEvent(key, down)
        check(type(key) == "number" and type(down) == "boolean", "modifier table shortcut forbidden")
        if key == 55 then private_command = down end
        local source_state = mode == "private_state_selector_refused" and -1
            or mode == "private_state_session_refused" and 0 or 1649760492
        local e = { key = key, down = down, command = private_command == true, prop = { [2] = 303, [3] = source_state } }
        function e:getType() return self.key == 55 and 12 or (self.down and 10 or 11) end
        function e:getFlags() return { cmd = self.command } end
        function e:getKeyCode() return self.key end
        function e:setProperty(key, value)
            self.prop[key] = mode == "identity_prepost_tag" and key == 1 and value + 1 or value
            return self
        end
        function e:getProperty(key)
            if mode == "identity_prepost_pid" and key == 2 then return 999 end
            if mode == "identity_prepost_state" and key == 3 then return 1 end
            return self.prop[key]
        end
        function e:post()
            posts[#posts + 1] = { key = self.key, down = self.down, tag = self.prop[1] }
            if not mode:match("^post_return_without_delivery") then
                if mode == "foreign_event_pid" then self.prop[2] = 999 end
                if mode == "foreign_event_state" then self.prop[3] = 1649760493 end
                observer(self)
            end
            if self.prop[1] == 0x47534F01 then
                if mode == "post_return_without_delivery_external_effect" then current_front = 202 end
                if mode == "source_revoked_after_command" then revoked = true end
                if mode == "source_pin_replaced_after_command" then pins_changed = true end
                if mode == "hardware_pin_replaced_after_command" or mode == "hardware_pin_restored_after_command" then hardware_revoked = true end
                if mode == "physical_during_command" or mode == "long_physical_hold_wrap" then physical = true end
                if mode == "command_post_refused_after_delivery" then return false end
            end
            if self.prop[1] == 0x47534F04 and mode ~= "delivery_without_effect" and mode ~= "post_return_without_delivery" then
                current_front = 202
            end
            return self
        end
        return e
    end
    function hs.task.new(executable, callback, args)
        constructor_calls = constructor_calls + 1
        check(executable == config.hardware and not hardware_revoked, "known foreign hardware cannot be constructed")
        if mode == "hardware_pin_replaced_during_constructor" then hardware_revoked = true end
        if args[1] == "1" then nonce_one_count = nonce_one_count + 1 end
        if mode == "hardware_constructor_nil" then return nil end
        if mode == "hardware_constructor_throw" then error("controlled constructor refusal before any start") end
        local task = { running = false }
        function task:isRunning()
            if mode == "unadmitted_hardware_query_nil" then return nil end
            if mode == "unadmitted_hardware_query_throw" then error("controlled native physical query refusal") end
            return self.running
        end
        function task:start()
            start_calls = start_calls + 1
            check(not hardware_revoked, "known foreign hardware cannot be started")
            if mode == "unadmitted_hardware_still_running" then self.running = true; return false end
            if mode == "unadmitted_hardware_query_nil" or mode == "unadmitted_hardware_query_throw" then return false end
            if mode == "hardware_sync_callback_then_refusal" then callback(0, "hardware:" .. args[1], ""); return false end
            if mode == "hardware_start_nil" then return nil end
            if mode == "hardware_start_false" then return false end
            if mode == "hardware_start_throw" then error("controlled hardware start refusal") end
            self.running = true
            callbacks[#callbacks + 1] = function()
                self.running = false
                local request = tonumber(args[1])
                if not request or request < 1 or request >= 10000 then callback(64, "", "")
                else callback(0, "hardware:" .. args[1], "") end
            end
            return self
        end
        return task
    end
    function hs.timer.doEvery(_, callback)
        local timer = { active = true, callback = callback }
        function timer:running() return self.active end
        function timer:stop()
            if mode == "timer_stop_false" then return false end
            if mode == "timer_stop_nil" then return nil end
            if mode == "timer_stop_throw" then error("controlled timer stop refusal") end
            self.active = false; return self
        end
        ticks[#ticks + 1] = timer
        return timer
    end
    _G.hs = hs
    assert(loadfile(fixture .. "/global-switcher.lua"))()
    local steps = mode == "long_physical_hold_wrap" and 30100 or 160
    for step = 1, steps do
        clock = step * 100000000
        local queued = callbacks; callbacks = {}
        for _, callback in ipairs(queued) do callback() end
        if (mode == "physical_during_command" and step == 35) or (mode == "long_physical_hold_wrap" and step == 30000) then
            check(#posts == 1, "physical Command must prevent Tab and compensating up while held")
            physical = false
        end
        if mode == "hardware_pin_restored_after_command" and step == 35 then
            check(#posts == 1 and constructor_calls == 1 and start_calls == 1, "known revoked hardware must not be reacquired during held Command cleanup")
            hardware_revoked = false
        end
        if mode == "session_release_later" and step == 35 then
            check(#posts == 4 and _G.globalSwitcherNativeProbe.session_debt == true and ticks[1].active == true,
                "local up witness and HID clear cannot release native session debt")
            release_session_later = true
        end
        for _, timer in ipairs(ticks) do if timer.active then timer.callback() end end
    end
    if mode == "private_state_instance" then
        check(report and report.status == "observed" and #report.observations == 4 and #posts == 4,
            "a genuine private table identifier must reach all four original observations")
        check(report.cleanup_debt == false and report.timer_retired == true and report.tap_retired == true
            and report.session_retired == true, "private table identity must preserve complete original retirement")
    end
    if mode == "healthy" or mode == "private_state_instance" then
        check(report and report.status == "observed", "healthy owner must observe real port effect")
        check(#posts == 4 and #report.observations == 4, "healthy owner observes exact four-event chord")
        check(report.before_pid == 101 and report.after_pid == 202, "independent native frontmost effect required")
        check(report.tap_retired and report.timer_retired and report.tasks_retired and not report.cleanup_debt, "physical resource receipts required")
    else
        check(not report or report.status ~= "observed", mode .. " cannot claim native effect success")
    end
    if mode:match("^hardware_constructor") or mode:match("^unadmitted_hardware") or mode:match("^hardware_start") or mode == "hardware_sync_callback_then_refusal" or mode:match("^physical_[lrt]") or mode == "wrong_hardware_source" or mode == "accessibility_refused" then
        check(#posts == 0, mode .. " must fence before any native key post")
    end
    if mode:match("^hardware_constructor") or mode:match("^hardware_start") or mode == "hardware_sync_callback_then_refusal" then
        check(report and report.status == "refused" and report.tasks_retired == true and report.tap_retired == true and report.timer_retired == true and report.cleanup_debt == false,
            mode .. " must retire exact stopped acquisition without admitting its hardware frame")
        check(#report.hardware == 0, mode .. " must discard every unadmitted frame")
    end
    if mode:match("^unadmitted_hardware") then
        check(not report or report.status ~= "observed", mode .. " cannot retire or advance from unknown native state")
        check(next(_G.globalSwitcherNativeProbe.tasks) ~= nil, mode .. " retains exact physical capability")
    end
    if mode == "source_revoked_after_command" or mode == "source_pin_replaced_after_command" or mode == "physical_during_command" or mode == "long_physical_hold_wrap" or mode == "command_post_refused_after_delivery" then
        check(#posts == 2 and posts[1].key == 55 and posts[1].down and posts[2].key == 55 and not posts[2].down,
            mode .. " retires exact Command debt without Tab admission")
    end
    if mode == "long_physical_hold_wrap" then
        check(nonce_one_count >= 2, "long physical cleanup must safely wrap the bounded nonce")
        check(report and report.status == "refused" and report.tasks_retired == true and report.cleanup_debt == false, "long hold must physically retire after release")
        check(#report.hardware == 64 and report.hardware_truncated == true and report.hardware_sample_count > 9999, "long hold receipts must stay bounded and never fake complete evidence")
    end
    if mode == "hardware_pin_replaced_after_command" then
        check(#posts == 1 and constructor_calls == 1 and start_calls == 1, "revoked helper must retain down debt without executing replacement")
        check(_G.globalSwitcherNativeProbe.cmd_debt == true and _G.globalSwitcherNativeProbe.session_debt == true and ticks[1].active == true,
            "held Command and session require exact trusted helper reinstatement")
    elseif mode == "hardware_pin_replaced_during_constructor" then
        check(constructor_calls == 1 and start_calls == 0 and #posts == 0, "constructor boundary revocation must refuse actual start")
        check(report and report.status == "refused" and report.tasks_retired == true and report.cleanup_debt == false,
            "unstarted exact capability can retire without admitting its stale hardware frame")
    elseif mode == "hardware_pin_restored_after_command" then
        check(#posts == 2 and not posts[2].down and report.status == "refused" and report.cleanup_debt == false,
            "original trusted helper permits compensation but never restores cancelled Tab admission")
    end
    if mode:match("^session_.*_after_up$") then
        check(#posts == 4, "counterfactual must witness all four original posts including local up")
        check(report and report.cleanup_debt == true and report.timer_retired == false and ticks[1].active == true,
            "unknown or held terminal session must retain native timer and controller debt")
        check(_G.globalSwitcherNativeProbe.session_debt == true, "native combined session needs an independent clear receipt")
    end
    if mode == "session_release_later" then
        check(report and report.status == "refused" and report.session_retired == true and report.cleanup_debt == false,
            "fresh session clear retires physical debt without restoring revoked success")
        check(#posts == 4, "no synthetic repeat or activation fallback may manufacture session retirement")
    end
    if mode == "session_preheld" then check(#posts == 0 and report.status == "refused", "preexisting combined Command refuses before input") end
    if mode == "private_state_selector_refused" or mode == "private_state_session_refused" then
        check(#posts == 0 and report and report.status == "refused" and report.reason == "native_event_identity_refused",
            "creation selectors and shared session tables cannot become private native identity")
        check(report.cleanup_debt == false and report.tasks_retired and report.tap_retired and report.timer_retired,
            "unadmitted source state must retire without any posted input")
    end
    if mode == "foreign_event_state" then
        check(#posts > 0 and (not report or report.status ~= "observed") and _G.globalSwitcherNativeProbe.phase == 1,
            "observed events from another private table cannot acknowledge the pinned constructor")
        check(_G.globalSwitcherNativeProbe.cmd_debt == true and ticks[1].active == true,
            "unobserved release keeps its original native debt and controller owner")
    end
    if mode:match("^identity_prepost_") then
        check(#posts == 0, "pre-post wrong field must refuse before any event effect")
        check(report and report.status == "refused" and report.reason == "native_event_identity_refused",
            "the unchanged strict identity guard must produce its original refusal")
        check(report.cleanup_debt == false and report.tasks_retired == true and report.tap_retired == true
            and report.timer_retired == true and report.session_retired == true,
            "pre-post refusal must retain original physical retirement assertions")
        check(#report.event_identity == 1 and report.event_identity_truncated == false,
            "the actual refused constructor tuple must be observable exactly once")
        local tuple = report.event_identity[1]
        check(tuple.phase == 1 and tuple.cleanup == false, "first original admission must remain distinct from compensation")
        check(tuple.tag_available == true and tuple.pid_available == true and tuple.state_available == true,
            "actual integer fields must be available without fabricated defaults")
        check(tuple.tag == (mode == "identity_prepost_tag" and 0x47534F02 or 0x47534F01),
            "independent exact pre-post tag must survive diagnostics")
        check(tuple.source_pid == (mode == "identity_prepost_pid" and 999 or 303),
            "independent exact pre-post PID must survive diagnostics")
        check(tuple.source_state == (mode == "identity_prepost_state" and 1 or 1649760492),
            "independent exact pre-post source state must survive diagnostics")
        check(tuple.expected_tag == 0x47534F01 and tuple.expected_pid == 303
            and tuple.private_state_bound == false and tuple.expected_state == nil,
            "unadmitted fields cannot bind or redefine the private table expectation")
    end
    if mode ~= "accessibility_refused" then check(#activations == 2 and activations[1] == 202 and activations[2] == 101, "only original B then A precondition activations allowed") end
    return true
end
local requested = arg[2]
if requested ~= nil then
    local found = false
    for _, mode in ipairs(cases) do if mode == requested then found = true end end
    check(found, "unknown independent control")
    cases = { requested }
end
for _, mode in ipairs(cases) do run(mode); print("PASS " .. mode) end
print("Controlled actual-probe owner: " .. #cases .. " passed, 0 failed; native macOS UNEXECUTED.")
