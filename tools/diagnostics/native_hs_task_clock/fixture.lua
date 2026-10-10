-- PRIVATE, UNEXECUTED: actual native framework, controlled peer, no lease authority.
local input = hs.json.decode(__INPUT_JSON__)
local source = input.source_root
package.path = source .. "/static/ergopti_plus/macos/?.lua;"
    .. source .. "/static/ergopti_plus/macos/?/init.lua;"
    .. source .. "/static/ergopti_plus/_shared/lua/?.lua;" .. package.path
local logger_refused = false
local function inert_logger() logger_refused = true end
-- Only persistence is modeled; no message/argument is retained.
package.loaded["infra.logger"] = {error=inert_logger, warn=inert_logger,
    debug=function() end, trace=function() end, done=function() end}
local Runner = require("adapters.shell_runner")
local Scheduler = require("adapters.timer_scheduler")
assert(debug.getinfo(hs.task.new, "S").what == "C", "real_task_required")
assert(debug.getinfo(hs.timer.new, "S").what == "C", "real_timer_required")
-- Capture an actual C clock; no TimerScheduler wall-clock fallback is admitted.
local absolute_time = hs.timer.absoluteTime
assert(type(absolute_time) == "function"
    and debug.getinfo(absolute_time, "S").what == "C", "native_absolute_clock_required")
local last_absolute
local function absolute_ns()
    local ok, value = pcall(absolute_time)
    assert(ok and type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge and value >= 0
        and math.floor(value) == value, "native_absolute_sample_refused")
    assert(last_absolute == nil or value >= last_absolute, "native_clock_regression_refused")
    last_absolute = value
    return value
end
local began = absolute_ns()
local events, sequence, admitted = {}, 0, 0
local pending, recurring, acknowledgement, handle
local started, ready, refused, published = false, false, false, false
local buffer, entry_sequence = "", nil
local function mark(boundary, seq)
    local elapsed = absolute_ns() - began
    if type(elapsed) ~= "number" or elapsed < 0 or elapsed > 45000000000
        or #events >= 12 then refused = true; return end
    events[#events + 1] = {seq=seq, boundary=boundary,
        clock="hs-absolute-relative", elapsed_ns=math.floor(elapsed)}
end
local function finalize(code)
    if published then return end
    published = true
    if recurring then Scheduler.cancel(recurring) end
    if acknowledgement then Scheduler.cancel(acknowledgement) end
    local healthy = code == 0 and started and ready and not refused
        and not logger_refused and admitted == 3 and pending == nil and #events == 12
    local packet = {schema=1, contract="hosted-hs-task-five-boundary",
        source_sha=input.source_sha, nonce=input.nonce, pid=hs.processInfo.processID,
        outcome=healthy and "observed-task-boundaries" or "failed", events=events,
        startup_prompt_state="unobserved", native_lease_authority=false}
    local raw = assert(hs.json.encode(packet))
    assert(#raw <= 4096, "receipt_bound_refused")
    local file = assert(io.open(input.receipt .. ".partial", "wb"))
    assert(file:write(raw) ~= nil and file:close() == true, "receipt_write_refused")
    assert(os.rename(input.receipt .. ".partial", input.receipt), "receipt_publish_refused")
    os.exit(healthy and 0 or 1)
end
local function tick()
    if refused or pending ~= nil or sequence >= 3 then refused = true; return end
    sequence = sequence + 1
    pending = sequence
    mark("timer-tick", sequence)
    if handle.set_input("TASK_PING " .. sequence .. "\n") ~= true then
        refused = true; return
    end
    mark("stdin-request-accepted", sequence)
    local held = sequence
    local committed
    acknowledgement, committed = Scheduler.after(3.75, function()
        if pending == held then refused = true end
    end)
    if committed ~= true then refused = true end
end
handle = Runner.spawn(input.python, {input.child, input.child_receipt},
    function(code, stdout, stderr)
        if stdout ~= "" or stderr ~= "" then refused = true end
        Scheduler.after(0, function() finalize(code) end)
    end,
    function(task, stdout, stderr)
        if task == nil or type(stdout) ~= "string" or stderr ~= ""
            or #stdout > 32 or #buffer + #stdout > 32 then refused = true; return false end
        -- Entry timestamp precedes parsing; the sole current request supplies seq.
        if ready and entry_sequence ~= pending then
            mark("lua-stream-entry", pending or 0)
            entry_sequence = pending
        end
        buffer = buffer .. stdout
        local line = buffer:match("^(.-)\n$")
        if not line then return true end
        buffer = ""
        if not ready then
            if line ~= "TASK_READY" then refused = true; return false end
            ready = true
            local committed
            recurring, committed = Scheduler.every(5, tick)
            if committed ~= true then refused = true end
            return true
        end
        if pending == nil or line ~= "TASK_ACK " .. pending then refused = true; return false end
        if acknowledgement == nil or Scheduler.cancel(acknowledgement) ~= true then
            refused = true; return false
        end
        acknowledgement = nil
        mark("matching-sequence-admitted", pending)
        admitted = admitted + 1
        pending = nil
        if admitted == 3 then
            -- set_input admits a queued request, not a completed native write.
            -- Retain stdin until the controlled child has read TASK_DONE and exited.
            if Scheduler.cancel(recurring) ~= true
                or handle.set_input("TASK_DONE\n") ~= true then refused = true end
        end
        return true
    end, nil, true)
assert(handle ~= nil, "native_task_construction_refused")
started = handle.start() == true
assert(started, "native_start_refused")
_G.ERGOPTI_HOSTED_TASK_CLOCK = {handle=handle, scheduler=Scheduler, runner=Runner}
