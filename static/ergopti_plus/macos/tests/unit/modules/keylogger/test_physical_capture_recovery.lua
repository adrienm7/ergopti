--- tests/unit/modules/keylogger/test_physical_capture_recovery.lua

--- Frozen recovery controls authored before implementation.
do
--- Independent before-code subscription hint controls: hints never acknowledge native retirement.
local helpers = require("tests.helpers")
local Lifetime = require("keylogger.physical_subscription_lifetime")
local function source()
 local owner, token = {}, {}
 local life = Lifetime.new(owner, token)
 life.bind_detach(function() life.detach(); return true end)
 return owner, token, life, life.capability()
end
helpers.describe("independent source retirement hint contract", function()
 helpers.it("waits for exact detach and every held frame before one framed hint", function()
  local owner, token, life, cap = source()
  local hints, inside = 0, nil
  local a, b = life.enter(), life.enter()
  helpers.assert_eq(cap.on_retired(owner, token, function(...)
   helpers.assert_eq(select("#", ...), 0)
   hints = hints + 1; inside = cap.retired(owner, token)
  end), true)
  life.revoke(); helpers.assert_eq(hints, 0)
  helpers.assert_eq(cap.detach(owner, token), true); helpers.assert_eq(hints, 0)
  helpers.assert_eq(life.leave(a), true); helpers.assert_eq(hints, 0)
  helpers.assert_eq(life.leave(b), true)
  helpers.assert_eq(hints, 1); helpers.assert_eq(inside, false)
  helpers.assert_eq(cap.retired(owner, token), true)
  helpers.assert_eq(life.leave(b), false); helpers.assert_eq(cap.detach(owner, token), true)
  helpers.assert_eq(hints, 1)
 end)
 helpers.it("refuses foreign identity and repeated registration without consuming the real slot", function()
  local owner, token, life, cap = source()
  local hints = 0
  local callback = function() hints = hints + 1 end
  helpers.assert_eq(cap.on_retired({}, token, callback), false)
  helpers.assert_eq(cap.on_retired(owner, {}, callback), false)
  helpers.assert_eq(cap.on_retired(owner, token, callback), true)
  helpers.assert_eq(cap.on_retired(owner, token, callback), false)
  helpers.assert_eq(cap.detach(owner, token), true)
  helpers.assert_eq(hints, 1); helpers.assert_eq(cap.retired(owner, token), true)
 end)
 helpers.it("never treats an accepted detach port without actual detach as completion", function()
  local owner, token = {}, {}
  local life = Lifetime.new(owner, token); local cap = life.capability()
  local hints = 0
  life.bind_detach(function() return true end)
  helpers.assert_eq(cap.on_retired(owner, token, function() hints = hints + 1 end), true)
  helpers.assert_eq(cap.detach(owner, token), false)
  helpers.assert_eq(hints, 0); helpers.assert_eq(cap.retired(owner, token), false)
  life.detach()
  helpers.assert_eq(hints, 1); helpers.assert_eq(cap.retired(owner, token), true)
 end)
 helpers.it("preserves original writer tuple and error when the terminal hint throws", function()
  local owner, token, life, cap = source()
  local hints, marker = 0, {}
  helpers.assert_eq(cap.on_retired(owner, token, function() hints = hints + 1; error(marker, 0) end), true)
  local a, b, c = life.run(function() life.detach(); return "original", nil, 7 end)
  helpers.assert_eq(a, "original"); helpers.assert_eq(b, nil); helpers.assert_eq(c, 7)
  helpers.assert_eq(hints, 1); helpers.assert_eq(cap.retired(owner, token), true)
  local o, t, l, p = source(); local original = {}
  helpers.assert_eq(p.on_retired(o, t, function() error(marker, 0) end), true)
  local ok, failure = pcall(l.run, function() l.detach(); error(original, 0) end)
  helpers.assert_eq(ok, false); helpers.assert_eq(rawequal(failure, original), true)
  helpers.assert_eq(p.retired(o, t), true)
 end)
 helpers.it("never supplies callback truth as an ACK or recursively emits a second hint", function()
  local owner, token, life, cap = source()
  local hints, inside, duplicate = 0, nil, nil
  helpers.assert_eq(cap.on_retired(owner, token, function()
   hints = hints + 1; inside = cap.retired(owner, token)
   duplicate = cap.on_retired(owner, token, function() error("second hint") end)
   helpers.assert_eq(cap.detach(owner, token), true)
   return true
  end), true)
  helpers.assert_eq(cap.detach(owner, token), true)
  helpers.assert_eq(hints, 1); helpers.assert_eq(inside, false); helpers.assert_eq(duplicate, false)
  helpers.assert_eq(cap.retired(owner, token), true)
 end)
end)

end
do
--- Independent clock delegate control; actual API frames, no domain qualification.
local helpers = require("tests.helpers")
helpers.describe("independent clock retirement hint", function()
 helpers.it("keeps successor acquisition denied through actual getter and terminal hint frames", function()
  helpers.with_fresh_modules({ "adapters.physical_observation_clock" }, function()
   local previous, native = hs, { timer = {} }
   local owner, cap, token, clock = {}, nil, nil, nil
   local hints, during_getter, during_hint, hint_retired, getter_detach = 0, nil, nil, nil, nil
   local getter = function()
    getter_detach = cap.detach(owner, token)
    during_getter = cap.retired(owner, token)
    return 17
   end
   native.timer.absoluteTime = getter; hs = native
   local ok, error_value = pcall(function()
    clock = require("adapters.physical_observation_clock")
    cap = assert(clock.bind_history_scope(owner)); token = cap.identity(owner)
    helpers.assert_eq(cap.on_retired(owner, token, function()
     hints = hints + 1; hint_retired = cap.retired(owner, token)
     during_hint = clock.bind_history_scope({})
    end), true)
    local value, reason = cap.read(owner, token)
    helpers.assert_eq(value, nil); helpers.assert_eq(reason, "clock_subscription_detached")
    helpers.assert_eq(getter_detach, true); helpers.assert_eq(during_getter, false)
    helpers.assert_eq(hints, 1); helpers.assert_eq(hint_retired, false); helpers.assert_eq(during_hint, nil)
    helpers.assert_eq(cap.retired(owner, token), true)
    helpers.assert_eq(rawequal(native.timer.absoluteTime, getter), true)
    local next_owner = {}; local successor = assert(clock.bind_history_scope(next_owner))
    helpers.assert_eq(successor.current(next_owner, successor.identity(next_owner)), true)
    helpers.assert_eq(successor.detach(next_owner, successor.identity(next_owner)), true)
    helpers.assert_eq(hints, 1)
   end)
   hs = previous
   if not ok then error(error_value, 0) end
  end)
 end)
end)

end
do
--- Independently authored from the actual six-field producer loss contract.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
local function loss(reason)
 return { version = 1, kind = "lost", coverage = "complete", incarnation = "production-fixture", lease = "7", reason = reason }
end
local function start(capture, observed, c, active)
 c.frames.lost = loss("overflow")
 c.frames.batch = { version = 1, kind = "batch", coverage = "complete", incarnation = "production-fixture", lease = "7", records = {
  { sequence = "1", device = "41", timestamp = "10", has_page = true, has_usage = true,
   page = 7, usage = 44, value = "1", has_cookie = true, cookie = 44 } } }
 helpers.assert_eq(capture.init(c.dependencies), true); helpers.assert_eq(capture.start(c.options), true)
 c.verified(); c.clocked()
 observed.tasks[3].chunk(nil, active and "opened\npage\nready\n" or "opened\npage\n")
end
helpers.describe("independent physical producer loss verdicts", function()
 helpers.it("classifies only genuine baseline and active loss after denying all further delivery", function()
  for _, active in ipairs({ false, true }) do for _, reason in ipairs({ "overflow", "sequence_exhausted", "interrupted" }) do
   with_capture(function(capture, observed, c)
    local verdicts, source_at_callback = {}, nil
    c.dependencies.on_verdict = function(record)
     verdicts[#verdicts + 1] = record; source_at_callback = c.mode.credit_source(); return true
    end
    start(capture, observed, c, active); c.frames.lost = loss(reason)
    observed.tasks[3].chunk(nil, "lost\nbatch\n")
    helpers.assert_eq(#verdicts, 1)
    helpers.assert_eq(verdicts[1].state, reason == "interrupted" and "interrupted" or "lost")
    helpers.assert_eq(verdicts[1].reason, reason); helpers.assert_eq(verdicts[1].retryable, true)
    helpers.assert_eq(type(verdicts[1].lease_token), "table")
    helpers.assert_eq(source_at_callback, "gap"); helpers.assert_eq(c.mode.legacy_credits(), false)
    helpers.assert_eq(#observed.credits, 0)
    local writes = #observed.writes
    observed.tasks[3].chunk(nil, "lost\nbatch\n"); observed.tasks[3].done(1)
    helpers.assert_eq(#verdicts, 1); helpers.assert_eq(#observed.writes, writes)
    helpers.assert_eq(#observed.credits, 0); helpers.assert_eq(#observed.spawns, 3)
   end)
  end end
 end)
 helpers.it("refuses malformed producer identities and fields rather than minting retry permission", function()
  local changes = {
   function(r) r.version = 2 end, function(r) r.version = "1" end,
   function(r) r.coverage = "fixture_only" end, function(r) r.coverage = nil end,
   function(r) r.incarnation = "other-producer" end, function(r) r.lease = "8" end,
   function(r) r.reason = "unknown" end, function(r) r.reason = nil end,
   function(r) r.extra = true end, function(r) r.kind = "unavailable" end,
  }
  for _, change in ipairs(changes) do with_capture(function(capture, observed, c)
   local verdicts = {}
   c.dependencies.on_verdict = function(record) verdicts[#verdicts + 1] = record; return true end
   start(capture, observed, c, true); c.frames.lost = loss("overflow"); change(c.frames.lost)
   observed.tasks[3].chunk(nil, "lost\nbatch\n")
   helpers.assert_eq(#verdicts, 1); helpers.assert_eq(verdicts[1].retryable, false)
   helpers.assert_eq(#observed.credits, 0); helpers.assert_eq(#observed.spawns, 3)
   helpers.assert_eq(c.mode.legacy_credits(), false)
  end) end
 end)
 helpers.it("never accepts loss before a valid opening or from error text", function()
  for _, line in ipairs({ "lost", "plaintext" }) do with_capture(function(capture, observed, c)
   local verdicts = {}
   c.dependencies.on_verdict = function(record) verdicts[#verdicts + 1] = record; return true end
   c.frames.lost = loss("overflow")
   helpers.assert_eq(capture.init(c.dependencies), true); helpers.assert_eq(capture.start(c.options), true)
   c.verified(); c.clocked(); observed.tasks[3].chunk(nil, line .. "\n")
   helpers.assert_eq(#verdicts, 1); helpers.assert_eq(verdicts[1].retryable, false)
   helpers.assert_eq(c.mode.credit_source(), "gap"); helpers.assert_eq(#observed.credits, 0)
   helpers.assert_eq(#observed.spawns, 3)
  end) end
 end)
 helpers.it("requires literal verdict ACK and preserves native debt after observer refusal", function()
  for _, outcome in ipairs({ "false", "truthy", "throw" }) do with_capture(function(capture, observed, c)
   local calls = 0
   c.dependencies.on_verdict = function()
    calls = calls + 1
    if outcome == "throw" then error("observer refusal") end
    return outcome == "truthy" and "accepted" or false
   end
   start(capture, observed, c, true); observed.tasks[3].chunk(nil, "lost\nbatch\n")
   helpers.assert_eq(calls, 1); helpers.assert_eq(capture.status().reason, "verdict_refused")
   helpers.assert_eq(c.mode.credit_source(), "gap"); helpers.assert_eq(capture.start(c.options), false)
   observed.tasks[3].chunk(nil, "lost\n"); helpers.assert_eq(calls, 1)
   helpers.assert_eq(capture.stop(), false); helpers.assert_eq(c.mode.legacy_credits(), false)
   observed.tasks[3].settle(); helpers.assert_eq(capture.stop(), true)
   helpers.assert_eq(c.mode.credit_source(), "legacy"); helpers.assert_eq(#observed.credits, 0)
  end) end
 end)
 helpers.it("retains actual Accounting interruption debt despite native child settlement", function()
  with_capture(function(capture, observed, c)
   local allow, calls = true, 0
   helpers.assert_eq(c.mode.bind_settlement({}, function() return allow end), true)
   c.dependencies.on_verdict = function() calls = calls + 1; return true end
   start(capture, observed, c, true)
   local admitted = c.mode.admitted_capture(); allow = false
   observed.tasks[3].chunk(nil, "lost\nbatch\n")
   helpers.assert_eq(calls, 1); helpers.assert_eq(#observed.credits, 0)
   helpers.assert_eq(c.mode.admitted_capture(), admitted); helpers.assert_eq(c.mode.legacy_credits(), false)
   helpers.assert_eq(capture.stop(), false); observed.tasks[3].settle()
   helpers.assert_eq(capture.stop(), false); helpers.assert_eq(c.mode.admitted_capture(), admitted)
   helpers.assert_eq(capture.start(c.options), false); helpers.assert_eq(c.mode.legacy_credits(), false)
   allow = true; helpers.assert_eq(capture.stop(), true)
   helpers.assert_eq(c.mode.admitted_capture(), nil); helpers.assert_eq(c.mode.credit_source(), "legacy")
  end)
 end)
end)

end
do
--- Independent managed source controls over actual Accounting/Capture/Transport.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
local function bind(capture, c)
 helpers.assert_eq(capture.init(c.dependencies), true)
 local owner = {}; local cap = assert(capture.bind_managed_source(owner))
 local token = cap.identity(owner)
 helpers.assert_eq(type(token), "table")
 return owner, token, cap
end
local function active(capture, observed, c, owner, token, cap)
 local accepted, lease = cap.start(owner, token, c.options)
 helpers.assert_eq(accepted, true); helpers.assert_eq(type(lease), "table")
 c.verified(); c.open()
 helpers.assert_eq(c.mode.credit_source(), "stream")
 return lease
end
helpers.describe("independent managed physical source accounting", function()
 helpers.it("binds once without acquiring tasks or changing the legacy source", function()
  with_capture(function(capture, observed, c)
   local owner, token, cap = bind(capture, c)
   helpers.assert_eq(#observed.spawns, 0); helpers.assert_eq(c.mode.credit_source(), "legacy")
   helpers.assert_eq(rawequal(cap.identity(owner), token), true); helpers.assert_eq(cap.identity({}), nil)
   helpers.assert_eq(capture.bind_managed_source({}), nil)
   helpers.assert_eq(cap.start({}, token, c.options), false)
   helpers.assert_eq(cap.start(owner, {}, c.options), false)
   helpers.assert_eq(#observed.spawns, 0); helpers.assert_eq(c.mode.credit_source(), "legacy")
  end)
 end)
 helpers.it("keeps a selected gap across exact per-lease retirement and a fresh native lease", function()
  with_capture(function(capture, observed, c)
   local settlements = 0
   helpers.assert_eq(c.mode.bind_settlement({}, function() settlements = settlements + 1; return true end), true)
   local owner, token, cap = bind(capture, c)
   local lease = active(capture, observed, c, owner, token, cap)
   helpers.assert_eq(rawequal(cap.lease_identity(owner, token), lease), true)
   local stopped = {}
   helpers.assert_eq(cap.stop_lease(owner, token, function(value) stopped[#stopped + 1] = value end), false)
   helpers.assert_eq(c.mode.credit_source(), "gap"); helpers.assert_eq(c.mode.legacy_credits(), false)
   helpers.assert_eq(cap.start(owner, token, c.options), false)
   helpers.assert_eq(#stopped, 0); observed.tasks[3].settle()
   helpers.assert_eq(stopped, { true }); helpers.assert_eq(c.mode.credit_source(), "gap")
   helpers.assert_eq(cap.current(owner, token), true)
   local before = settlements; local accepted, successor = cap.start(owner, token, c.options)
   helpers.assert_eq(accepted, true); helpers.assert_eq(type(successor), "table")
   helpers.assert_eq(rawequal(successor, lease), false)
   helpers.assert_eq(settlements, before, "Fresh lease must not release/reselect the accounting source")
   helpers.assert_eq(c.mode.credit_source(), "gap"); helpers.assert_eq(c.mode.legacy_credits(), false)
   helpers.assert_eq(#observed.spawns, 4)
  end)
 end)
 helpers.it("requires release of the exact actual history scope before replacement or final shutdown", function()
  with_capture(function(capture, observed, c)
   local adapter_owner, scope = {}, nil
   local original = c.dependencies.clock_ready
   c.dependencies.clock_ready = function(...)
    local accepted = original(...)
    local ok, retained = capture.bind_history_scope(adapter_owner)
    if ok then scope = retained end
    return accepted
   end
   local owner, token, cap = bind(capture, c)
   active(capture, observed, c, owner, token, cap)
   helpers.assert_eq(type(scope), "table"); local scope_token = scope.identity()
   helpers.assert_eq(cap.stop_lease(owner, token), false); observed.tasks[3].settle()
   helpers.assert_eq(scope.settled(scope_token), true)
   helpers.assert_eq(cap.start(owner, token, c.options), false)
   local final = {}
   helpers.assert_eq(cap.shutdown(owner, token, function(value) final[#final + 1] = value end), false)
   helpers.assert_eq(c.mode.credit_source(), "gap"); helpers.assert_eq(#final, 0)
   helpers.assert_eq(scope.release({}, scope_token), false)
   helpers.assert_eq(scope.release(adapter_owner, {}), false)
   helpers.assert_eq(scope.release(adapter_owner, scope_token), true)
   helpers.assert_eq(cap.shutdown(owner, token), true)
   helpers.assert_eq(final, { true }); helpers.assert_eq(c.mode.credit_source(), "legacy")
   helpers.assert_eq(cap.retired(owner, token), true)
   helpers.assert_eq(cap.start(owner, token, c.options), false)
  end)
 end)
 helpers.it("holds refused actual admission interruption after native retirement until exact retry", function()
  with_capture(function(capture, observed, c)
   local allow = true
   helpers.assert_eq(c.mode.bind_settlement({}, function() return allow end), true)
   local owner, token, cap = bind(capture, c)
   active(capture, observed, c, owner, token, cap)
   local admitted = c.mode.admitted_capture(); allow = false; local stopped = {}
   helpers.assert_eq(cap.stop_lease(owner, token, function(value) stopped[#stopped + 1] = value end), false)
   helpers.assert_eq(c.mode.admitted_capture(), admitted); observed.tasks[3].settle()
   helpers.assert_eq(cap.stop_lease(owner, token), false)
   helpers.assert_eq(c.mode.admitted_capture(), admitted); helpers.assert_eq(#stopped, 0)
   helpers.assert_eq(cap.start(owner, token, c.options), false)
   helpers.assert_eq(c.mode.legacy_credits(), false)
   allow = true; helpers.assert_eq(cap.stop_lease(owner, token), true)
   helpers.assert_eq(stopped, { true }); helpers.assert_eq(c.mode.credit_source(), "gap")
   helpers.assert_eq(c.mode.admitted_capture(), nil); helpers.assert_eq(c.mode.legacy_credits(), false)
   helpers.assert_eq(cap.shutdown(owner, token), true); helpers.assert_eq(c.mode.credit_source(), "legacy")
  end)
 end)
 helpers.it("requires final actual release settlement and never signals shutdown from diagnostics", function()
  with_capture(function(capture, observed, c)
   local allow = true
   helpers.assert_eq(c.mode.bind_settlement({}, function() return allow end), true)
   local owner, token, cap = bind(capture, c)
   active(capture, observed, c, owner, token, cap)
   helpers.assert_eq(cap.stop_lease(owner, token), false); observed.tasks[3].settle()
   helpers.assert_eq(c.mode.credit_source(), "gap"); allow = false; local final = {}
   helpers.assert_eq(cap.shutdown(owner, token, function(value) final[#final + 1] = value end), false)
   helpers.assert_eq(cap.retired(owner, token), false); helpers.assert_eq(#final, 0)
   helpers.assert_eq(c.mode.credit_source(), "gap"); helpers.assert_eq(cap.start(owner, token, c.options), false)
   allow = true; helpers.assert_eq(cap.shutdown(owner, token), true)
   helpers.assert_eq(final, { true }); helpers.assert_eq(cap.retired(owner, token), true)
   helpers.assert_eq(c.mode.credit_source(), "legacy")
   helpers.assert_eq(cap.shutdown(owner, token), true); helpers.assert_eq(final, { true })
  end)
 end)
end)

end
do
local helpers = require("tests.helpers")
helpers.describe("bounded physical lease policy", function()
 local function fixture()
  local Policy = require("keylogger.physical_lease_policy")
  local owner, native = {}, {}
  local facts = { current = true, retired = false, queries = 0, native = native }
  local p = Policy.new(owner, {
   current = function() facts.queries = facts.queries + 1; return facts.current end,
   lease_identity = function() return facts.native end,
   retired = function() return facts.retired end,
  })
  return p, owner, facts
 end
 local function opened(p, owner, facts)
  local request = assert(p.begin(owner))
  helpers.assert_eq(p.captured(owner, request, facts.native), true)
  return request
 end
 helpers.it("freezes exactly three retry delays without an admission budget reset", function()
  local p, owner, facts = fixture()
  helpers.assert_eq(facts.queries, 0)
  for index, delay in ipairs({ 1, 2, 4 }) do
   local request = opened(p, owner, facts)
   helpers.assert_eq(p.admitted(owner, request, facts.native), { action = "arm_rotation", delay = 600 })
   helpers.assert_eq(p.verdict(owner, request, { state = "lost", reason = "overflow", retryable = true,
    lease_token = facts.native }), { action = "retire", retryable = true })
   helpers.assert_eq(p.continue(owner, request), nil)
   facts.retired = true
   helpers.assert_eq(p.continue(owner, request), { action = "retry", delay = delay })
   helpers.assert_eq(p.begin(owner), nil)
   helpers.assert_eq(p.retry_ready(owner, request), { action = "start" })
   facts.native, facts.retired = {}, false
   helpers.assert_eq(p.status().retries, index)
  end
  local request = opened(p, owner, facts)
  helpers.assert_eq(p.verdict(owner, request, { state = "interrupted", reason = "interrupted",
   retryable = true, lease_token = facts.native }), { action = "retire", retryable = false })
  facts.retired = true
  helpers.assert_eq(p.continue(owner, request), { action = "deny" })
  helpers.assert_eq(p.begin(owner), nil)
 end)
 helpers.it("rotates only an admitted lease and never resets or spends retry budget", function()
  local p, owner, facts = fixture(); local request = opened(p, owner, facts)
  helpers.assert_eq(p.rotate(owner, request), nil)
  helpers.assert_eq(p.admitted(owner, request, facts.native), { action = "arm_rotation", delay = 600 })
  helpers.assert_eq(p.rotate(owner, request), { action = "retire", retryable = false, rotation = true })
  facts.retired = true; helpers.assert_eq(p.continue(owner, request), { action = "start" })
  helpers.assert_eq(p.status().retries, 0)
  local before = facts.queries; helpers.assert_eq(p.captured(owner, request, facts.native), false)
  helpers.assert_eq(facts.queries, before)
  facts.native, facts.retired = {}, false
  local successor = opened(p, owner, facts); helpers.assert_eq(rawequal(successor, request), false)
 end)
 helpers.it("never lets mutable public authority restore a stopped policy", function()
  local p, owner, facts = fixture(); local request = opened(p, owner, facts)
  local public = p.subscription(); public.current = function() return true end
  helpers.assert_eq(p.stop(owner), true)
  local before = facts.queries
  helpers.assert_eq(p.verdict(owner, request, { state = "lost", reason = "overflow", retryable = true,
   lease_token = facts.native }), nil)
  helpers.assert_eq(p.begin(owner), nil); helpers.assert_eq(facts.queries, before)
 end)
 helpers.it("denies foreign identity and source revocation during actual retirement callback", function()
  local Policy = require("keylogger.physical_lease_policy")
  local owner, native, current, calls, p = {}, {}, true, 0, nil
  p = Policy.new(owner, { current = function() return current end,
   lease_identity = function() return native end,
   retired = function() calls = calls + 1; current = false; return true end })
  local request = assert(p.begin(owner)); helpers.assert_eq(p.captured(owner, request, native), true)
  helpers.assert_eq(p.verdict(owner, request, { state = "lost", reason = "overflow", retryable = true,
   lease_token = native }), { action = "retire", retryable = true })
  helpers.assert_eq(p.continue({}, request), nil); helpers.assert_eq(calls, 0)
  helpers.assert_eq(p.continue(owner, request), nil); helpers.assert_eq(calls, 1)
  helpers.assert_eq(p.begin(owner), nil)
 end)
end)
end

do
--- Independent bounded normalization policy; explicit software ports, no native authority.
local helpers = require("tests.helpers")
local function fixture()
 local Policy = require("keylogger.physical_lease_policy")
 local owner = {}; local c = { current_value = true, native = {}, retired_value = true,
  calls = { current = 0, identity = 0, retired = 0 } }
 local ports = {
  current = function() c.calls.current = c.calls.current + 1; return c.current_value end,
  lease_identity = function() c.calls.identity = c.calls.identity + 1; return c.native end,
  retired = function(request)
   c.calls.retired = c.calls.retired + 1; c.last_request = request
   if c.retire_hook then return c.retire_hook(request) end
   return c.retired_value
  end,
 }
 c.ports = ports; c.policy = Policy.new(owner, ports); c.owner = owner
 function c.begin()
  c.native = {}; local request = assert(c.policy.begin(owner))
  helpers.assert_eq(c.policy.captured(owner, request, c.native), true)
  return request, c.native
 end
 function c.loss(request, token, reason)
  return c.policy.verdict(owner, request, { state = reason == "interrupted" and "interrupted" or "lost",
   reason = reason or "overflow", retryable = true, lease_token = token })
 end
 return c
end
helpers.describe("independent bounded physical lease policy", function()
 helpers.it("captures constructor ports without any source query or caller table alias", function()
  local c = fixture(); helpers.assert_eq(c.calls, { current = 0, identity = 0, retired = 0 })
  c.ports.current = function() error("mutated public current") end
  c.ports.lease_identity = function() error("mutated public identity") end
  c.ports.retired = function() error("mutated public retirement") end
  local request, token = c.begin()
  helpers.assert_eq(c.policy.admitted(c.owner, request, token), { action = "arm_rotation", delay = 600 })
  helpers.assert_eq(c.loss(request, token), { action = "retire", retryable = true })
  helpers.assert_eq(c.policy.continue(c.owner, request), { action = "retry", delay = 1 })
 end)
 helpers.it("reserves exactly three lifetime retries without resetting on successful admissions", function()
  local c = fixture()
  for index, delay in ipairs({ 1, 2, 4 }) do
   local request, token = c.begin()
   helpers.assert_eq(c.policy.admitted(c.owner, request, token), { action = "arm_rotation", delay = 600 })
   helpers.assert_eq(c.loss(request, token), { action = "retire", retryable = true })
   helpers.assert_eq(c.policy.continue(c.owner, request), { action = "retry", delay = delay })
   helpers.assert_eq(c.policy.retry_ready(c.owner, request), { action = "start" })
   helpers.assert_eq(c.policy.status().retries, index)
  end
  local request, token = c.begin()
  helpers.assert_eq(c.policy.admitted(c.owner, request, token), { action = "arm_rotation", delay = 600 })
  helpers.assert_eq(c.loss(request, token), { action = "retire", retryable = false })
  helpers.assert_eq(c.policy.continue(c.owner, request), { action = "deny" })
  helpers.assert_eq(c.policy.status().retries, 3)
  local next_request, reason = c.policy.begin(c.owner)
  helpers.assert_eq(next_request, nil); helpers.assert_eq(reason, "policy_not_prepared")
 end)
 helpers.it("rotates admitted leases without consuming or resetting the lifetime retry budget", function()
  local c = fixture(); local request, token = c.begin()
  helpers.assert_eq(c.loss(request, token), { action = "retire", retryable = true })
  helpers.assert_eq(c.policy.continue(c.owner, request), { action = "retry", delay = 1 })
  helpers.assert_eq(c.policy.retry_ready(c.owner, request), { action = "start" })
  request, token = c.begin()
  helpers.assert_eq(c.policy.admitted(c.owner, request, token), { action = "arm_rotation", delay = 600 })
  helpers.assert_eq(c.policy.rotate(c.owner, request), { action = "retire", retryable = false, rotation = true })
  helpers.assert_eq(c.policy.continue(c.owner, request), { action = "start" })
  helpers.assert_eq(c.policy.status().retries, 1)
  request, token = c.begin()
  helpers.assert_eq(c.loss(request, token, "sequence_exhausted"), { action = "retire", retryable = true })
  helpers.assert_eq(c.policy.continue(c.owner, request), { action = "retry", delay = 2 })
 end)
 helpers.it("does not start or arm a retry from pending retirement or an uncommitted timer event", function()
  local c = fixture(); local request, token = c.begin()
  helpers.assert_eq(c.loss(request, token), { action = "retire", retryable = true })
  for _, value in ipairs({ false, "true" }) do
   c.retired_value = value
   local action, reason = c.policy.continue(c.owner, request)
   helpers.assert_eq(action, nil); helpers.assert_eq(reason, "policy_retirement_pending")
   helpers.assert_eq(c.policy.retry_ready(c.owner, request), nil)
   helpers.assert_eq(c.policy.begin(c.owner), nil)
  end
  c.retired_value = true
  local action = c.policy.continue(c.owner, request)
  helpers.assert_eq(action, { action = "retry", delay = 1 })
  action.action, action.delay = "start", 0
  helpers.assert_eq(c.policy.begin(c.owner), nil)
  helpers.assert_eq(c.policy.retry_ready(c.owner, request), { action = "start" })
 end)
 helpers.it("refuses source revocation during the actual retirement callback", function()
  local c = fixture(); local request, token = c.begin()
  helpers.assert_eq(c.loss(request, token), { action = "retire", retryable = true })
  c.retire_hook = function() c.current_value = false; return true end
  local action, reason = c.policy.continue(c.owner, request)
  helpers.assert_eq(action, nil); helpers.assert_eq(reason, "policy_source_refused")
  helpers.assert_eq(c.policy.retry_ready(c.owner, request), nil)
  helpers.assert_eq(c.policy.begin(c.owner), nil)
 end)
 helpers.it("refuses a thrown retirement callback without creating a timer or start action", function()
  local c = fixture(); local request, token = c.begin()
  helpers.assert_eq(c.loss(request, token), { action = "retire", retryable = true })
  c.retire_hook = function() error("real retained source refusal") end
  local action, reason = c.policy.continue(c.owner, request)
  helpers.assert_eq(action, nil); helpers.assert_eq(reason, "policy_source_refused")
  helpers.assert_eq(c.policy.retry_ready(c.owner, request), nil)
 end)
 helpers.it("holds its own actual frame against retirement callback reentry", function()
  local c = fixture(); local request, token = c.begin()
  helpers.assert_eq(c.loss(request, token), { action = "retire", retryable = true })
  local nested, nested_reason
  c.retire_hook = function()
   nested, nested_reason = c.policy.continue(c.owner, request); return true
  end
  local action, reason = c.policy.continue(c.owner, request)
  helpers.assert_eq(nested, nil); helpers.assert_eq(nested_reason, "policy_source_refused")
  helpers.assert_eq(action, nil); helpers.assert_eq(reason, "policy_source_refused")
 end)
 helpers.it("refuses stale requests and raw foreign owners without additional foreign queries", function()
  local c = fixture(); local request, token = c.begin()
  local before = { current = c.calls.current, identity = c.calls.identity, retired = c.calls.retired }
  local action, reason = c.policy.continue({}, request)
  helpers.assert_eq(action, nil); helpers.assert_eq(reason, "policy_identity_refused")
  helpers.assert_eq(c.policy.captured(c.owner, {}, token), false)
  helpers.assert_eq(c.policy.verdict(c.owner, {}, { state = "lost", reason = "overflow", retryable = true, lease_token = token }), nil)
  helpers.assert_eq(c.policy.retry_ready(c.owner, {}), nil)
  helpers.assert_eq(c.calls, before)
 end)
 helpers.it("does not turn malformed or invented verdict fields into a recognized loss", function()
  for _, change in ipairs({
   function(v) v.reason = "incomplete_coverage" end,
   function(v) v.state = "unavailable" end,
   function(v) v.retryable = "true" end,
   function(v) v.retryable = nil end,
   function(v) v.lease_token = {} end,
   function(v) v.extra = true end,
  }) do
   local c = fixture(); local request, token = c.begin()
   local verdict = { state = "lost", reason = "overflow", retryable = true, lease_token = token }; change(verdict)
   local action, reason = c.policy.verdict(c.owner, request, verdict)
   helpers.assert_eq(action, nil); helpers.assert_eq(reason, "policy_event_refused")
   helpers.assert_eq(c.policy.status().retries, 0)
   helpers.assert_eq(c.policy.continue(c.owner, request), nil)
  end
 end)
 helpers.it("retains permanent terminal denial despite returned status or action mutations", function()
  local c = fixture(); local request, token = c.begin()
  local action = c.policy.verdict(c.owner, request, { state = "unavailable", reason = "incomplete_coverage", retryable = false, lease_token = token })
  helpers.assert_eq(action, { action = "retire", retryable = false })
  action.retryable = true
  helpers.assert_eq(c.policy.continue(c.owner, request), { action = "deny" })
  local status = c.policy.status(); status.state, status.retries = "prepared", 0
  helpers.assert_eq(c.policy.begin(c.owner), nil)
  helpers.assert_eq(c.policy.retry_ready(c.owner, request), nil)
  helpers.assert_eq(c.policy.status().retries, 0)
 end)
end)

end

do
--- Independent actual canonical policy frame, not a native retirement acknowledgment.
local helpers = require("tests.helpers")
helpers.describe("independent policy retirement frame", function()
 helpers.it("retains its real retirement query frame through detach and terminal hint", function()
  local Policy = require("keylogger.physical_lease_policy")
  local owner, native = {}, {}
  local policy, cap, token, hints, inside_query, inside_hint, detached = nil, nil, nil, 0, nil, nil, nil
  policy = Policy.new(owner, {
   current = function() return true end,
   lease_identity = function() return native end,
   retired = function()
    detached = cap.detach(owner, token)
    inside_query = cap.retired(owner, token)
    return true
   end,
  })
  cap = policy.subscription(); token = cap.identity(owner)
  helpers.assert_eq(cap.on_retired(owner, token, function()
   hints = hints + 1; inside_hint = cap.retired(owner, token)
  end), true)
  local request = assert(policy.begin(owner))
  helpers.assert_eq(policy.captured(owner, request, native), true)
  helpers.assert_eq(policy.verdict(owner, request, { state = "lost", reason = "overflow", retryable = true, lease_token = native }),
   { action = "retire", retryable = true })
  local action, reason = policy.continue(owner, request)
  helpers.assert_eq(action, nil); helpers.assert_eq(reason, "policy_source_refused")
  helpers.assert_eq(detached, true); helpers.assert_eq(inside_query, false)
  helpers.assert_eq(hints, 1); helpers.assert_eq(inside_hint, false)
  helpers.assert_eq(cap.retired(owner, token), true)
  helpers.assert_eq(policy.retry_ready(owner, request), nil)
 end)
end)

end

do
--- Healthy actual unbound path; optional recovery ports must not query caller metatables.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
helpers.describe("independent unbound recovery compatibility", function()
 helpers.it("preserves the actual unbound capture path without resolving optional metatable ports", function()
  with_capture(function(capture, observed, c)
   local queries = 0
   setmetatable(c.dependencies, { __index = function(_, name)
    if name == "on_verdict" or name == "baseline_ready" then queries = queries + 1; error("optional port lookup") end
   end })
   helpers.assert_eq(capture.init(c.dependencies), true)
   helpers.assert_eq(queries, 0); helpers.assert_eq(#observed.spawns, 0)
   helpers.assert_eq(c.mode.credit_source(), "legacy")
   c.frames.batch = { version = 1, kind = "batch", coverage = "complete", incarnation = "production-fixture", lease = "7", records = {
    { sequence = "1", device = "41", timestamp = "10", has_page = true, has_usage = true,
     page = 7, usage = 44, value = "1", has_cookie = true, cookie = 44 } } }
   helpers.assert_eq(capture.start(c.options), true); c.verified(); c.open()
   observed.tasks[3].chunk(nil, "batch\n")
   helpers.assert_eq(#observed.credits, 1); helpers.assert_eq(observed.credits[1].capture, "production-fixture/7")
   helpers.assert_eq(queries, 0); helpers.assert_eq(#observed.spawns, 3)
   helpers.assert_eq(capture.stop(), false); observed.tasks[3].settle()
   helpers.assert_eq(capture.stop(), true); helpers.assert_eq(c.mode.credit_source(), "legacy")
  end)
 end)
end)

end

do
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
helpers.describe("actual managed notification frame boundaries", function()
 helpers.it("never reopens a selected source after a refused verdict receipt", function()
  with_capture(function(capture, observed, c)
   c.dependencies.on_verdict = function() return false end
   helpers.assert_eq(capture.init(c.dependencies), true)
   local owner = {}; local cap = assert(capture.bind_managed_source(owner)); local token = cap.identity(owner)
   helpers.assert_eq(cap.start(owner, token, c.options), true); c.verified(); c.open()
   c.frames.lost = { version = 1, kind = "lost", coverage = "complete", incarnation = "production-fixture", lease = "7", reason = "overflow" }
   observed.tasks[3].chunk(nil, "lost\n")
   helpers.assert_eq(cap.stop_lease(owner, token), false); observed.tasks[3].settle()
   helpers.assert_eq(cap.current(owner, token), false)
   helpers.assert_eq(cap.start(owner, token, c.options), false)
   helpers.assert_eq(#observed.spawns, 3); helpers.assert_eq(c.mode.credit_source(), "gap")
   helpers.assert_eq(cap.shutdown(owner, token), true); helpers.assert_eq(c.mode.credit_source(), "legacy")
  end)
 end)
 helpers.it("does not acknowledge global shutdown or successor binding inside its actual final callback", function()
  with_capture(function(capture, observed, c)
   helpers.assert_eq(capture.init(c.dependencies), true)
   local owner = {}; local cap = assert(capture.bind_managed_source(owner)); local token = cap.identity(owner)
   helpers.assert_eq(cap.start(owner, token, c.options), true); c.verified(); c.open()
   helpers.assert_eq(cap.stop_lease(owner, token), false); observed.tasks[3].settle()
   local nested, retired, successor, calls
   calls = 0
   helpers.assert_eq(cap.shutdown(owner, token, function()
    calls = calls + 1; retired = cap.retired(owner, token)
    nested = cap.shutdown(owner, token); successor = capture.bind_managed_source({})
   end), true)
   helpers.assert_eq(calls, 1); helpers.assert_eq(retired, false); helpers.assert_eq(nested, false)
   helpers.assert_eq(successor, nil); helpers.assert_eq(cap.retired(owner, token), true)
   local replacement = assert(capture.bind_managed_source({}))
   helpers.assert_eq(cap.start(owner, token, c.options), false)
   helpers.assert_eq(c.mode.credit_source(), "legacy")
  end)
 end)
 helpers.it("retains the genuine candidate token through a synchronous startup verdict and latched shutdown", function()
  with_capture(function(capture, observed, c)
   local owner, cap, token, callback_token, inside_retired, nested, calls = {}, nil, nil, nil, nil, nil, 0
   c.dependencies.on_verdict = function(record)
    calls = calls + 1; callback_token = cap.lease_identity(owner, token)
    helpers.assert_eq(rawequal(record.lease_token, callback_token), true)
    nested = cap.shutdown(owner, token); inside_retired = cap.retired(owner, token)
    return true
   end
   c.on_spawn = function(task) task.state = "settled" end
   helpers.assert_eq(capture.init(c.dependencies), true); cap = assert(capture.bind_managed_source(owner)); token = cap.identity(owner)
   local accepted, native_token = cap.start(owner, token, c.options)
   helpers.assert_eq(accepted, false); helpers.assert_eq(calls, 1)
   helpers.assert_eq(rawequal(native_token, callback_token), true)
   helpers.assert_eq(nested, false); helpers.assert_eq(inside_retired, false)
   helpers.assert_eq(cap.retired(owner, token), true); helpers.assert_eq(c.mode.credit_source(), "legacy")
  end)
 end)
end)
end

do
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
helpers.describe("actual managed acquisition refusal", function()
 helpers.it("never publishes an old candidate identity when a replacement was not acquired", function()
  with_capture(function(capture, observed, c)
   helpers.assert_eq(capture.init(c.dependencies), true)
   local owner = {}; local cap = assert(capture.bind_managed_source(owner)); local token = cap.identity(owner)
   local accepted, first = cap.start(owner, token, c.options)
   helpers.assert_eq(accepted, true); helpers.assert_eq(type(first), "table")
   local blocked, replacement = cap.start(owner, token, c.options)
   helpers.assert_eq(blocked, false); helpers.assert_eq(replacement, nil)
   helpers.assert_eq(rawequal(cap.lease_identity(owner, token), first), true)
   helpers.assert_eq(#observed.spawns, 1); helpers.assert_eq(c.mode.credit_source(), "gap")
  end)
 end)
 helpers.it("retires an unselected candidate after real selection refusal without inventing release debt", function()
  with_capture(function(capture, observed, c)
   helpers.assert_eq(c.mode.bind_settlement({}, function() return false end), true)
   helpers.assert_eq(capture.init(c.dependencies), true)
   local owner = {}; local cap = assert(capture.bind_managed_source(owner)); local token = cap.identity(owner)
   local accepted, candidate = cap.start(owner, token, c.options)
   helpers.assert_eq(accepted, false); helpers.assert_eq(type(candidate), "table")
   helpers.assert_eq(#observed.spawns, 0); helpers.assert_eq(c.mode.credit_source(), "legacy")
   helpers.assert_eq(cap.shutdown(owner, token), true)
   helpers.assert_eq(cap.retired(owner, token), true); helpers.assert_eq(c.mode.credit_source(), "legacy")
  end)
 end)
end)
end

do
--- Actual Capture/Transport callback debt; native task settlement is explicitly modeled.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
helpers.describe("independent actual transport callback retirement", function()
 helpers.it("cannot replace a native lease while its real emission callback remains in flight", function()
  with_capture(function(capture, observed, c)
   local owner, source, token = {}, nil, nil
   local original, calls = c.dependencies.emit, 0
   local inside_started, inside_token, native_ack = nil, nil, nil
   c.dependencies.emit = function(press)
    local accepted = original(press); calls = calls + 1
    if calls == 2 then
     source.stop_lease(owner, token)
     observed.tasks[3].settle()
     native_ack = observed.tasks[3].state
     inside_started, inside_token = source.start(owner, token, c.options)
    end
    return accepted
   end
   helpers.assert_eq(capture.init(c.dependencies), true)
   source = assert(capture.bind_managed_source(owner)); token = source.identity(owner)
   helpers.assert_eq(source.start(owner, token, c.options), true)
   c.verified(); c.open()
   local function batch(sequence, usage)
    return { version = 1, kind = "batch", coverage = "complete", incarnation = "production-fixture", lease = "7", records = {
     { sequence = tostring(sequence), device = "41", timestamp = tostring(sequence * 10), has_page = true, has_usage = true,
      page = 7, usage = usage, value = "1", has_cookie = true, cookie = usage } } }
   end
   c.frames.first, c.frames.second = batch(1, 44), batch(2, 41)
   observed.tasks[3].chunk(nil, "first\n")
   helpers.assert_eq(calls, 1); helpers.assert_eq(#observed.credits, 1)
   helpers.assert_eq(c.mode.credit_source(), "stream")
   observed.tasks[3].chunk(nil, "second\n")
   helpers.assert_eq(calls, 2); helpers.assert_eq(#observed.credits, 2)
   helpers.assert_eq(native_ack, "settled")
   helpers.assert_eq(inside_started, false, "Native settlement must not erase the actual Transport emission frame")
   helpers.assert_eq(inside_token, nil); helpers.assert_eq(#observed.spawns, 3)
   helpers.assert_eq(c.mode.credit_source(), "gap"); helpers.assert_eq(c.mode.legacy_credits(), false)
   helpers.assert_eq(source.stop_lease(owner, token), true)
   local after, fresh = source.start(owner, token, c.options)
   helpers.assert_eq(after, true); helpers.assert_eq(type(fresh), "table")
   helpers.assert_eq(#observed.spawns, 4); helpers.assert_eq(c.mode.credit_source(), "gap")
  end)
 end)
end)

end

do
--- Actual CaptureScope and stop receipt must retain the actual Transport callback frame.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
helpers.describe("independent actual transport scope retirement", function()
 helpers.it("does not publish native scope settlement or stop ACK until its emission frame unwinds", function()
  with_capture(function(capture, observed, c)
   local owner, source, token, adapter, scope = {}, nil, nil, {}, nil
   local original_clock = c.dependencies.clock_ready
   c.dependencies.clock_ready = function(...)
    local accepted = original_clock(...)
    local bound, actual_scope = capture.bind_history_scope(adapter)
    if bound then scope = actual_scope end
    return accepted
   end
   local original_emit, acknowledgements = c.dependencies.emit, {}
   local inside_settled, inside_count, initial_stop = nil, nil, nil
   c.dependencies.emit = function(press)
    local accepted = original_emit(press)
    initial_stop = source.stop_lease(owner, token, function(value) acknowledgements[#acknowledgements + 1] = value end)
    observed.tasks[3].settle()
    inside_settled, inside_count = scope.settled(scope.identity()), #acknowledgements
    return accepted
   end
   helpers.assert_eq(capture.init(c.dependencies), true)
   source = assert(capture.bind_managed_source(owner)); token = source.identity(owner)
   helpers.assert_eq(source.start(owner, token, c.options), true); c.verified(); c.open()
   helpers.assert_eq(type(scope), "table"); helpers.assert_eq(scope.admitted(scope.identity()), "production-fixture/7")
   c.frames.batch = { version = 1, kind = "batch", coverage = "complete", incarnation = "production-fixture", lease = "7", records = {
    { sequence = "1", device = "41", timestamp = "10", has_page = true, has_usage = true,
     page = 7, usage = 44, value = "1", has_cookie = true, cookie = 44 } } }
   observed.tasks[3].chunk(nil, "batch\n")
   helpers.assert_eq(#observed.credits, 1); helpers.assert_eq(initial_stop, false)
   helpers.assert_eq(inside_settled, false, "Actual Scope settlement cannot omit the real Transport callback")
   helpers.assert_eq(inside_count, 0, "A native stop ACK must wait for its actual callback frame")
   helpers.assert_eq(acknowledgements, { true })
   helpers.assert_eq(scope.settled(scope.identity()), true)
   helpers.assert_eq(source.start(owner, token, c.options), false)
   helpers.assert_eq(scope.release(adapter, scope.identity()), true)
   helpers.assert_eq(source.start(owner, token, c.options), true)
   helpers.assert_eq(c.mode.credit_source(), "gap"); helpers.assert_eq(c.mode.legacy_credits(), false)
  end)
 end)
end)

end

do
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
helpers.describe("actual dispatch debt retry and error conservation", function()
 helpers.it("cannot settle a repeated explicit lease stop inside the same native-completed writer", function()
  with_capture(function(capture, observed, c)
   local owner, source, token, repeated, started, ack_inside = {}, nil, nil, nil, nil, nil
   local receipts = 0; local original = c.dependencies.emit
   c.dependencies.emit = function(press)
    local accepted = original(press)
    source.stop_lease(owner, token, function() receipts = receipts + 1 end)
    observed.tasks[3].settle()
    repeated = source.stop_lease(owner, token); ack_inside = receipts
    started = source.start(owner, token, c.options)
    return accepted
   end
   helpers.assert_eq(capture.init(c.dependencies), true); source = assert(capture.bind_managed_source(owner)); token = source.identity(owner)
   helpers.assert_eq(source.start(owner, token, c.options), true); c.verified(); c.open()
   c.frames.batch = { version = 1, kind = "batch", coverage = "complete", incarnation = "production-fixture", lease = "7", records = {
    { sequence = "1", device = "41", timestamp = "10", has_page = true, has_usage = true, page = 7, usage = 44, value = "1", has_cookie = true, cookie = 44 } } }
   observed.tasks[3].chunk(nil, "batch\n")
   helpers.assert_eq(repeated, false); helpers.assert_eq(started, false); helpers.assert_eq(ack_inside, 0)
   helpers.assert_eq(receipts, 1); helpers.assert_eq(c.mode.credit_source(), "gap"); helpers.assert_eq(#observed.spawns, 3)
   helpers.assert_eq(source.stop_lease(owner, token), true)
  end)
 end)
 helpers.it("retains direct Transport stop debt and completion when its error observer raises", function()
  local Transport = require("modules.keylogger.physical_transport")
  local transport, settled_callback, native_chunk, inside_stop, inside_reason, inside_settled, inside_receipts
  local active, writer_active, receipts, after_writer = true, false, 0, nil
  local inside_error_settled, inside_error_stop
  local marker = {}; local native = {}
  function native.onSettled(callback) settled_callback = callback; return true end
  function native.start() return true end
  function native.set_input() return true end
  function native.terminate() settled_callback(); return true, "settled" end
  local receiver = {
   open = function() end,
   active = function() return active end,
   stop = function() active = false end,
   deliver = function()
    writer_active = true; transport.stop()
    inside_stop, inside_reason = transport.stop()
    inside_settled, inside_receipts = transport.isSettled(), receipts
    writer_active = false; return "1"
   end,
  }
  transport = Transport.new({ receiver = receiver, frame_limit = 32,
   spawn = function(_, _, _, chunk) native_chunk = chunk; return native end,
   decode = function(line) return { kind = line == "opened" and "opened" or "batch", incarnation = "original", lease = "1", coverage = "complete" } end,
   encode = function() return "receipt" end,
   on_error = function()
    inside_error_settled = transport.isSettled(); inside_error_stop = transport.stop()
    error(marker, 0)
   end,
   on_settled = function() receipts = receipts + 1; after_writer = not writer_active end,
  })
  helpers.assert_eq(transport.start("/owned", {}), true)
  native_chunk(nil, "opened\n")
  local ok, failure = pcall(native_chunk, nil, "batch\n")
  helpers.assert_eq(ok, false); helpers.assert_eq(rawequal(failure, marker), true)
  helpers.assert_eq(inside_stop, false); helpers.assert_eq(inside_reason, "pending")
  helpers.assert_eq(inside_settled, false); helpers.assert_eq(inside_receipts, 0)
  helpers.assert_eq(inside_error_settled, false); helpers.assert_eq(inside_error_stop, false)
  helpers.assert_eq(receipts, 1); helpers.assert_eq(after_writer, true)
  helpers.assert_eq(transport.isSettled(), true); helpers.assert_eq(transport.stop(), true)
  settled_callback(); helpers.assert_eq(receipts, 1)
 end)
end)
end

do
--- Actual Transport/Delivery stop ACK must retain a synchronously settled emission frame.
local helpers = require("tests.helpers")
local Transport = require("modules.keylogger.physical_transport")
local Delivery = require("modules.keylogger.physical_delivery")
local Frames = require("tests.support.physical_stream_frames")
helpers.describe("independent synchronous native stop acknowledgement", function()
 helpers.it("does not ACK settled transport when native terminate settles inside the real emit frame", function()
  local frames = Frames.new("sync-native-fixture", "7", { "41" })
  local native_settle, chunk, transport = nil, nil, nil
  local emitted, notifications, writes = 0, 0, 0
  local inside_ok, inside_status, inside_retired = nil, nil, nil
  local receiver = Delivery.new({ batch_limit = 8, keycode = Frames.keycode,
   admit = function() return "explicit-software-fixture" end,
   context = function() return { allowed = true, app = "Fixture", timestamp = "2026-10-05 12:00:00.000" } end,
   emit = function()
    emitted = emitted + 1
    inside_ok, inside_status = transport.stop()
    inside_retired = transport.isSettled()
    return true
   end,
  })
  transport = Transport.new({ receiver = receiver, frame_limit = 32,
   decode = function(line) return frames[line] end,
   encode = function(record) return record.baseline_ack or record.ack end,
   on_error = function() end,
   on_settled = function() notifications = notifications + 1 end,
   spawn = function(_, _, _, stream)
    chunk = stream
    return { start = function() return true end,
     onSettled = function(observer) native_settle = observer; return true end,
     terminate = function() native_settle(); return true, "settled" end,
     set_input = function() writes = writes + 1; return true end }
   end,
  })
  helpers.assert_eq(transport.start("/owned/software/fixture", {}), true)
  chunk(nil, "opened\npage\nready\n")
  helpers.assert_eq(receiver.ready(), true); helpers.assert_eq(writes, 2)
  helpers.assert_eq(transport.isSettled(), false); helpers.assert_eq(notifications, 0)
  frames.batch = { version = 1, kind = "batch", coverage = "fixture_only", incarnation = "sync-native-fixture", lease = "7", records = {
   { sequence = "1", device = "41", timestamp = "10", has_page = true, has_usage = true,
    page = 7, usage = 44, value = "1", has_cookie = true, cookie = 44 } } }
  chunk(nil, "batch\n")
  helpers.assert_eq(emitted, 1); helpers.assert_eq(inside_retired, false)
  helpers.assert_eq(inside_ok, false, "Synchronous native task close cannot ACK the actual held Transport frame")
  helpers.assert_eq(inside_status, "pending")
  helpers.assert_eq(notifications, 1); helpers.assert_eq(transport.isSettled(), true)
  local after_ok, after_status = transport.stop()
  helpers.assert_eq(after_ok, true); helpers.assert_eq(after_status, "settled")
 end)
end)

end

do
local helpers = require("tests.helpers")
helpers.it("retains the actual native-exit error observer before one settlement event", function()
--- Independent direct native-exit error-observer frame control.
local Transport = require("modules.keylogger.physical_transport")
for _, throwing in ipairs({ false, true }) do
	local completed, emitted, native_settled = nil, 0, nil
	local inside, inside_stop, inside_status, inside_publications
	local marker = {}
	local transport, receiver = nil, { enabled = true }
	function receiver.stop() receiver.enabled = false end
	function receiver.active() return receiver.enabled end
	transport = Transport.new({ receiver = receiver, frame_limit = 32,
		decode = function() return {} end, encode = function() return "0" end,
		spawn = function(_, _, done)
			completed = done
			return {
				start = function() return true end,
				onSettled = function(callback) native_settled = callback; return true end,
				terminate = function() native_settled(); return true, "settled" end,
			}
		end,
		on_settled = function() emitted = emitted + 1 end,
		on_error = function()
			inside = transport.isSettled()
			inside_stop, inside_status = transport.stop()
			inside_publications = emitted
			if throwing then error(marker, 0) end
		end,
	})
	assert(transport.start("/fixture/native", {}) == true, "Healthy actual direct transport starts")
	local ok, failure = pcall(completed, 1)
	assert(ok == not throwing, "Actual error callback outcome must be preserved")
	if throwing then assert(rawequal(failure, marker), "Original raised object must be preserved") end
	assert(inside == false, "Native exit error observer remains actual retirement debt")
	assert(inside_stop == false and inside_status == "pending", "Stop inside actual error observer is not settlement ACK")
	assert(inside_publications == 0, "Native completion publication waits for actual error-observer unwind")
	assert(transport.isSettled() == true and emitted == 1, "Actual completed observer publishes settlement once")
end

end)
end

do
local helpers = require("tests.helpers")
helpers.it("preserves the complete ordinary native termination tuple and original error object", function()
 local Transport = require("modules.keylogger.physical_transport")
 local marker, native_settle, throwing = {}, nil, false
 local receiver = { stop = function() end, active = function() return false end }
 local transport = Transport.new({ receiver = receiver, frame_limit = 32,
  decode = function() return {} end, encode = function() return "receipt" end,
  on_error = function() end, on_settled = function() end,
  spawn = function()
   return { start = function() return true end,
    onSettled = function(callback) native_settle = callback; return true end,
    terminate = function()
     if throwing then error(marker, 0) end
     return true, "pending", nil, marker, 7
    end }
  end,
 })
 helpers.assert_eq(transport.start("/owned/fixture", {}), true)
 local function pack(...) return { n = select("#", ...), ... } end
 local result = pack(transport.stop())
 helpers.assert_eq(result.n, 5); helpers.assert_eq(result[1], true); helpers.assert_eq(result[2], "pending")
 helpers.assert_eq(result[3], nil); helpers.assert_eq(rawequal(result[4], marker), true); helpers.assert_eq(result[5], 7)
 helpers.assert_eq(transport.isSettled(), false)
 throwing = true; local ok, failure = pcall(transport.stop)
 helpers.assert_eq(ok, false); helpers.assert_eq(rawequal(failure, marker), true)
 native_settle(); helpers.assert_eq(transport.isSettled(), true)
end)
end
