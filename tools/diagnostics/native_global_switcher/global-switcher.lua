--- tools/diagnostics/native_global_switcher/global-switcher.lua
-- Isolated actual-Hammerspoon investigation, never a product action provider.
-- No repository init, remapper, TCC grant, application activation fallback, or sleep.
local root = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local path = root .. "/probe-config.json"
local identity = assert(hs.fs.attributes(path))
assert(identity.mode == "file" and type(identity.dev) == "number" and type(identity.ino) == "number")
local file = assert(io.open(path, "rb")); local source = assert(file:read("*a")); assert(file:close())
local after_read = assert(hs.fs.attributes(path))
assert(after_read.dev == identity.dev and after_read.ino == identity.ino)
local config = assert(hs.json.decode(source))
local pid = hs.processInfo.processID
local result = { coverage = "isolated_fixture_only", status = "pending", hs_pid = pid,
    observations = {}, hardware = {}, hardware_sample_count = 0, hardware_truncated = false,
    event_identity = {}, event_identity_truncated = false,
    cleanup_debt = false, tasks_retired = false,
    tap_retired = false, timer_retired = false, session_retired = false, source_current = false }
local owner = { phase = 1, request = 0, observations = {}, tasks = {}, generation = 1 }
_G.globalSwitcherNativeProbe = owner
local types, properties = hs.eventtap.event.types, hs.eventtap.event.properties
local commands = {
    { 0x47534F01, 55, true, types.flagsChanged, true },
    { 0x47534F02, 48, true, types.keyDown, true },
    { 0x47534F03, 48, false, types.keyUp, true },
    { 0x47534F04, 55, false, types.flagsChanged, false },
}
local type_names = { [types.flagsChanged] = "flagsChanged", [types.keyDown] = "keyDown", [types.keyUp] = "keyUp" }
local function digest_bytes(bytes)
    local context = assert(hs.hash.new("SHA256"))
    local appended = assert(context:append(bytes))
    local finished = assert(appended:finish())
    local value = finished:value()
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-fA-F]+$") then return nil end
    return value:lower()
end
local function source_pins_current(required_path)
    if type(config.pins) ~= "table" or #config.pins < 1 or #config.pins > 32 then return false end
    local matched = 0
    for _, pin in ipairs(config.pins) do
        if type(pin) ~= "table" or type(pin.path) ~= "string" or type(pin.dev) ~= "number"
            or type(pin.ino) ~= "number" or type(pin.sha256) ~= "string" or #pin.sha256 ~= 64 then return false end
        if required_path == nil or pin.path == required_path then
            matched = matched + 1
            local before = hs.fs.attributes(pin.path)
            if not before or before.mode ~= "file" or before.dev ~= pin.dev or before.ino ~= pin.ino then return false end
            local input = io.open(pin.path, "rb"); if not input then return false end
            local bytes = input:read(2 * 1024 * 1024 + 1); local closed = input:close()
            if closed ~= true or type(bytes) ~= "string" or #bytes > 2 * 1024 * 1024 then return false end
            local after = hs.fs.attributes(pin.path)
            if not after or after.dev ~= pin.dev or after.ino ~= pin.ino or digest_bytes(bytes) ~= pin.sha256 then return false end
        end
    end
    return required_path == nil or matched == 1
end
local function source_current()
    if hs.fs.attributes(root .. "/cancel") ~= nil then return false end
    local attr = hs.fs.attributes(path)
    if not attr or attr.dev ~= identity.dev or attr.ino ~= identity.ino or attr.mode ~= "file" then return false end
    local input = io.open(path, "rb"); if not input then return false end
    local bytes = input:read("*a"); local closed = input:close()
    return closed == true and bytes == source and source_pins_current()
end
local function front_pid()
    local app = hs.application.frontmostApplication()
    return app and app:pid() or nil
end
local function publish(status)
    result.status = status
    result.cleanup_debt = owner.cmd_debt == true or owner.tab_debt == true or owner.session_debt == true or next(owner.tasks) ~= nil
    result.source_current = source_current()
    result.after_pid = front_pid()
    assert(hs.json.write(result, config.result, true, true))
end
local function revoke(reason)
    owner.cancelled = true
    result.reason = reason
end
local function current_admission()
    return owner.cancelled ~= true and source_current() and hs.accessibilityState(false) == true
end
local function sample()
    if owner.pending then return end
    if not source_pins_current(config.hardware) then
        revoke("hardware_source_revoked"); publish("pending"); return
    end
    -- Exact task/attempt identity, not this bounded nonce alone, owns completion.
    -- One pending task permits safe wrap; long physical holds cannot exhaust cleanup.
    owner.request = (owner.request % 9999) + 1
    local attempt = { request = owner.request, generation = owner.generation }
    owner.pending = attempt
    local task
    local constructed
    constructed, task = pcall(hs.task.new, config.hardware, function(code, stdout, stderr)
        -- Callback capture precedes constructor/start admission; it cannot grant it.
        attempt.completion = { code = code, stdout = stdout, stderr = stderr }
    end, { tostring(attempt.request) })
    attempt.task = task
    if not constructed or task == nil or task == false then
        -- This constructor never starts a native task; no process was acquired.
        owner.pending = nil
        revoke("hardware_constructor_refused")
        return
    end
    owner.tasks[task] = attempt
    if not source_pins_current(config.hardware) then
        attempt.admitted = false
        revoke("hardware_source_revoked"); return
    end
    local ok, receipt = pcall(task.start, task)
    attempt.admitted = ok and receipt == task
    if attempt.admitted ~= true then revoke("hardware_start_refused") end
end
local function take_sample()
    local attempt = owner.pending
    if not attempt then return nil end
    if attempt.generation ~= owner.generation then revoke("stale_hardware_attempt") end
    if attempt.admitted ~= true then
        -- Exact physical retirement is independent of hardware admission. A refused
        -- start may already have launched: retain it until this same cap is stopped.
        local stopped_ok, running = pcall(attempt.task.isRunning, attempt.task)
        if stopped_ok and running == false then
            owner.tasks[attempt.task] = nil
            owner.pending = nil
        end
        revoke("unadmitted_hardware_attempt")
        return nil
    end
    if not attempt.completion then return nil end
    local running_ok, running = pcall(attempt.task.isRunning, attempt.task)
    if not running_ok or running ~= false then revoke("hardware_not_retired"); return nil end
    owner.tasks[attempt.task] = nil; owner.pending = nil
    local raw = attempt.completion
    if raw.code ~= 0 or raw.stderr ~= "" or type(raw.stdout) ~= "string" or #raw.stdout > 512 then
        revoke("hardware_receipt_refused"); return nil
    end
    local ok, frame = pcall(hs.json.decode, raw.stdout)
    if not ok or type(frame) ~= "table" or frame.version ~= 1 or frame.request ~= attempt.request
        or frame.source ~= "hid_system" or type(frame.held) ~= "table" or type(frame.flags) ~= "number"
        or frame.listen_access ~= true or frame.post_access ~= true then
        revoke("hardware_receipt_refused"); return nil
    end
    local session = frame.session
    if type(session) ~= "table" or session.version ~= 1 or session.request ~= attempt.request
        or session.source ~= "combined_session" or type(session.held) ~= "table"
        or math.type(session.flags) ~= "integer" or session.flags < 0 then
        revoke("session_receipt_refused"); return nil
    end
    local count = 0
    for key, value in pairs(session) do
        if key ~= "version" and key ~= "request" and key ~= "source" and key ~= "held" and key ~= "flags" then
            revoke("session_receipt_refused"); return nil
        end
        count = count + 1
    end
    if count ~= 5 then revoke("session_receipt_refused"); return nil end
    local held_count = 0
    for key, value in pairs(session.held) do
        if math.type(key) ~= "integer" or key < 1 or key > #session.held or math.type(value) ~= "integer" then
            revoke("session_receipt_refused"); return nil
        end
        held_count = held_count + 1
    end
    if held_count ~= #session.held then revoke("session_receipt_refused"); return nil end
    owner.session_clear = held_count == 0 and (session.flags & 0x9E0000) == 0
    if not owner.cmd_debt and not owner.tab_debt and owner.session_debt then
        if owner.session_clear then owner.session_debt = false else revoke("session_release_unobserved") end
    elseif owner.phase == 1 and not owner.session_debt and not owner.session_clear then
        revoke("session_precondition_held")
    end
    result.hardware_sample_count = math.min(result.hardware_sample_count + 1, 9007199254740991)
    if #result.hardware < 64 then
        result.hardware[#result.hardware + 1] = frame
    else result.hardware_truncated = true end
    -- HID-only keys include both sides of Command and Tab; never use NS flags as hardware proof.
    local clear = next(frame.held) == nil and (frame.flags & 0x9E0000) == 0
    if not clear then revoke("physical_modifier_or_tab_held") end
    return clear
end
-- Diagnostic values are bounded metadata, not authority for post or cleanup.
local function identity_scalar(value)
    local available = type(value) == "number" and value % 1 == 0
        and value >= -9007199254740991 and value <= 9007199254740991
    return available and value or nil, available
end
local function record_event_identity(event, command, cleanup)
    if #result.event_identity >= 8 then
        result.event_identity_truncated = true
        return
    end
    local diagnostic_tag, tag_available = identity_scalar(event:getProperty(properties.eventSourceUserData))
    local diagnostic_pid, pid_available = identity_scalar(event:getProperty(properties.eventSourceUnixProcessID))
    local diagnostic_state, state_available = identity_scalar(event:getProperty(properties.eventSourceStateID))
    result.event_identity[#result.event_identity + 1] = {
        phase = owner.phase, cleanup = cleanup == true,
        tag = diagnostic_tag, source_pid = diagnostic_pid, source_state = diagnostic_state,
        tag_available = tag_available, pid_available = pid_available, state_available = state_available,
        expected_tag = command[1], expected_pid = pid, expected_state = -1,
    }
end
local function post(command, cleanup)
    if not cleanup and not current_admission() then revoke("source_revoked"); return false end
    local event = hs.eventtap.event.newKeyEvent(command[2], command[3])
    if not event or event:getType() ~= command[4]
        or (event:getFlags().cmd == true) ~= command[5] then
        revoke("explicit_modifier_constructor_refused"); return false
    end
    event:setProperty(properties.eventSourceUserData, command[1])
    record_event_identity(event, command, cleanup)
    if event:getProperty(properties.eventSourceUserData) ~= command[1]
        or event:getProperty(properties.eventSourceUnixProcessID) ~= pid
        or event:getProperty(properties.eventSourceStateID) ~= -1 then
        revoke("native_event_identity_refused"); return false
    end
    if command[2] == 55 and command[3] then owner.cmd_debt = true; owner.session_debt = true end
    if command[2] == 48 and command[3] then owner.tab_debt = true; owner.session_debt = true end
    owner.awaiting = { command = command, admitted = false, cleanup = cleanup }
    local ok, receipt = pcall(event.post, event)
    owner.awaiting.admitted = ok and receipt == event
    if not owner.awaiting.admitted then revoke("native_post_refused") end
    -- post returning self only admits observation waiting. It cannot acknowledge delivery/effect.
    return owner.awaiting.admitted
end
local function observed(event)
    local tag = event:getProperty(properties.eventSourceUserData)
    local waiting = owner.awaiting
    if not waiting or tag ~= waiting.command[1] then return false end
    local command = waiting.command
    if event:getProperty(properties.eventSourceUnixProcessID) ~= pid
        or event:getProperty(properties.eventSourceStateID) ~= -1
        or event:getKeyCode() ~= command[2] or event:getType() ~= command[4]
        or (event:getFlags().cmd == true) ~= command[5] or waiting.observed then
        revoke("native_observation_refused"); return false
    end
    waiting.observed = true
    return false -- Pass every observed event to the OS; never consume the fixture chord.
end
local function acknowledge()
    local waiting = owner.awaiting
    if not waiting or not waiting.observed or waiting.admitted ~= true then return false end
    local command = waiting.command
    if command[2] == 55 and not command[3] then owner.cmd_debt = false end
    if command[2] == 48 and not command[3] then owner.tab_debt = false end
    if waiting.cleanup ~= true then
        result.observations[#result.observations + 1] = {
            tag = command[1], key = command[2], type = type_names[command[4]], cmd = command[5],
        }
        owner.phase = owner.phase + 1
    end
    owner.awaiting = nil
    return true
end
local function retire(status)
    if owner.cmd_debt or owner.tab_debt or owner.session_debt or next(owner.tasks) ~= nil then publish("pending"); return false end
    if owner.tap then
        local ok, receipt = pcall(owner.tap.stop, owner.tap)
        result.tap_retired = ok and receipt == owner.tap and owner.tap:isEnabled() == false
    else result.tap_retired = true end
    if result.tap_retired ~= true then publish("pending"); return false end
    local ok, receipt = pcall(owner.timer.stop, owner.timer)
    result.timer_retired = ok and receipt == owner.timer and owner.timer:running() == false
    result.tasks_retired = next(owner.tasks) == nil
    result.session_retired = owner.session_debt ~= true
    if result.timer_retired ~= true then publish("pending"); return false end
    owner.retired = true; owner.generation = owner.generation + 1
    publish(status)
    return true
end
local function tick()
    if owner.retired then return end
    if not source_current() then revoke("source_revoked") end
    if hs.timer.absoluteTime() >= owner.deadline then revoke("observation_deadline") end
    if owner.awaiting then
        if acknowledge() then return end
        if not owner.cancelled then return end
        -- Ambiguous post still retains down debt. Compensating ups require fresh HID state.
        owner.awaiting = nil
    end
    if owner.pending then
        local clear = take_sample()
        if clear == nil then if owner.cancelled then publish("pending") end; return end
        if clear == false then publish("pending"); return end
        if owner.cancelled then
            if owner.tab_debt then post({ 0x47534F80, 48, false, types.keyUp, owner.cmd_debt == true }, true)
            elseif owner.cmd_debt then post({ 0x47534F81, 55, false, types.flagsChanged, false }, true)
            else retire("refused") end
            return
        end
        if owner.phase <= 4 then post(commands[owner.phase], false); return end
        if front_pid() == config.fixture_b then retire("observed") end
        return
    end
    if owner.cancelled and not owner.cmd_debt and not owner.tab_debt and not owner.session_debt and next(owner.tasks) == nil then
        retire("refused")
        return
    end
    sample()
end
local function run()
    result.ax_trusted = hs.accessibilityState(false) == true
    if not result.ax_trusted then
        result.tap_retired, result.timer_retired, result.tasks_retired, result.session_retired = true, true, true, true
        publish("blocked_accessibility"); return
    end
    assert(config.fixture_a ~= config.fixture_b and config.fixture_a > 0 and config.fixture_b > 0)
    -- Precondition only: establish native MRU once, B then A. No activation after these two calls.
    local b, a = assert(hs.application.get(config.fixture_b)), assert(hs.application.get(config.fixture_a))
    assert(b:bundleID() == config.bundle_b and a:bundleID() == config.bundle_a)
    assert(b:activate(true) == true)
    owner.precondition = "b"
    owner.deadline = hs.timer.absoluteTime() + 8 * 1000000000
    owner.tap = assert(hs.eventtap.new({ types.flagsChanged, types.keyDown, types.keyUp }, observed))
    assert(owner.tap:start() == owner.tap and owner.tap:isEnabled() == true)
    owner.timer = assert(hs.timer.doEvery(0.02, function()
        local ok = pcall(function()
            if owner.precondition == "b" then
                if front_pid() == config.fixture_b then
                    assert(a:activate(true) == true); owner.precondition = "a"
                elseif hs.timer.absoluteTime() >= owner.deadline then revoke("fixture_b_precondition_refused"); owner.precondition = nil end
                return
            elseif owner.precondition == "a" then
                if front_pid() == config.fixture_a then
                    result.before_pid = config.fixture_a; owner.precondition = nil
                elseif hs.timer.absoluteTime() >= owner.deadline then revoke("fixture_a_precondition_refused"); owner.precondition = nil end
                return
            end
            tick()
        end)
        if not ok then revoke("native_probe_boundary_refused"); publish("pending") end
    end))
end
local ok = pcall(run)
if not ok then revoke("native_probe_constructor_refused"); publish("pending") end
