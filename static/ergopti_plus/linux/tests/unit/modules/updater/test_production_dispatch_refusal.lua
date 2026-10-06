--- tests/unit/modules/updater/test_production_dispatch_refusal.lua

--- Actual updater manager with literal controlled owned-flow/artifact ports.
--- These are receiving-boundary models, not actual HTTP/C/FD/installer proof.
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function scenario(options, body)
 options = options or {}
 local names = { "modules.updater.manager", "modules.updater.archive_transfer", "infra.archive_output",
  "infra.monotonic", "infra.installation", "modules.updater.installer", "toml_codec.writer" }
 local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
 local h = { paused = false, persistence = 0, dispatches = 0, callbacks = {}, flow_physical = false, observers = {},
  cancellation = 0, artifact_closed = false, artifact_listeners = {}, reads = 0, installs = 0, install_physical = false }
 local ok, err = xpcall(function()
  local actual_installer = options.actual_installer and require("modules.updater.installer") or nil
  local brand, transaction = {}, {}; h.brand = brand
  local artifact = {
   retire_artifact = function(value)
    assert(rawequal(value, brand)); h.retired = true
    if h.retire_probe then h.retire_probe() end
    return h.artifact_closed
   end,
   artifact_settled = function(value) assert(rawequal(value, brand)); return h.artifact_closed end,
   on_artifact_settled = function(value, listener)
    assert(rawequal(value, brand)); h.artifact_listeners[#h.artifact_listeners + 1] = listener; return true
   end,
   begin_install = function(value, txn, _, admission, execution)
    assert(rawequal(value, brand) and rawequal(txn, transaction))
    if admission() ~= true then return nil end
    h.install_current = execution; h.reservation = {}; return h.reservation
   end,
   install_current = function() return options.actual_installer ~= true end,
   install_feed = function() h.reads = h.reads + 1; error("no tar in receiving models") end,
   finish_install = function(token, keep, done)
    assert(options.actual_installer and rawequal(token, h.reservation) and keep == true)
    h.finish_done = done
    local child = {}
    function child:is_settled() return h.cleanup_physical == true end
    function child:request_cancel() return true end
    function child:on_settled(listener) h.cleanup_listener = listener; return true end
    return child
   end,
  }
  package.loaded["infra.archive_output"] = { native_artifact = function()
   if options.component_missing then return nil end
   return artifact
  end }
  package.loaded["infra.monotonic"] = { has_hires = function() return true end,
   backend = function() return "luv.hrtime" end, now_ms = function() return 1.25 end }
  package.loaded["infra.installation"] = { is_source_run = function() return true end }
  package.loaded["modules.updater.archive_transfer"] = { new = function(ports)
   h.source = function() return ports.current(transaction) end
   local flow = {}
   function flow:start(_, terminal)
    h.dispatches = h.dispatches + 1; h.terminal = terminal
    assert(h.source() == true, "owned flow must consult its captured source at admission")
    local operation = { started = true }
    function operation:is_settled() if h.physical_probe then h.physical_probe() end; return h.flow_physical end
    function operation:request_cancel() h.cancellation = h.cancellation + 1; return true end
    function operation:on_settled(listener) h.observers[#h.observers + 1] = listener; return true end
    h.flow_operation = operation
    if options.construct then options.construct(h, terminal, brand) end
    if options.malformed then return {} end
    return operation
   end
   return flow
  end }
  package.loaded["modules.updater.installer"] = {
   resolve = function() return { kind = "standalone", install_root = "/owned/lib", parent = "/owned", wrapper = "/owned/bin" } end,
   install_owned = function(_, done)
    h.installs = h.installs + 1; h.installed_done = done
    local operation = {}
    function operation:is_settled() return h.install_physical end
    function operation:request_cancel() return true end
    function operation:on_settled(listener) h.install_observer = listener; return true end
    return operation
   end,
  }
  if actual_installer then
   package.loaded["modules.updater.installer"].install_owned = actual_installer.install_owned
  end
  package.loaded["toml_codec.writer"] = { batch_write = function() h.persistence = h.persistence + 1; return true end }
  package.loaded["modules.updater.manager"] = nil
  h.manager = require("modules.updater.manager")
  h.manager.init({ is_paused = function() return h.paused end })
  h.release = { tag = "v1.2.3", download_url = "https://release/archive", checksum_url = "https://release/checksum" }
  function h:start(execution)
   return self.manager.download_release(self.release, function(...)
    self.callbacks[#self.callbacks + 1] = { ... }
   end, execution)
  end
  function h:ack()
   self.flow_physical = true
   for _, listener in ipairs(self.observers) do listener() end
  end
  function h:success()
   self.terminal("display-information-only", nil, nil, nil, brand); self:ack()
  end
  function h:dispose()
   self.artifact_closed = true
   for _, listener in ipairs(self.artifact_listeners) do listener() end
  end
  body(h)
 end, debug.traceback)
 for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
 if not ok then error(err, 0) end
end
test("known zero-dispatch terminal refusal waits for original physical ACK and returns false", function()
 scenario({ construct = function(h, terminal)
  h.flow_operation.started = false
  terminal(nil, "temporary path unavailable", "download")
  h.flow_physical = true
 end }, function(h)
  assert(h:start() == false)
  assert(#h.callbacks == 1 and h.callbacks[1][1] == nil and h.callbacks[1][2] == "temporary path unavailable")
  assert(h.manager.get_state() ~= "downloading")
 end)
end)
test("zero-started terminal with pending physical owner stays accepted and busy until ACK", function()
 scenario({ construct = function(h, terminal)
  h.flow_operation.started = false
  terminal(nil, "temporary path unavailable", "download")
 end }, function(h)
  assert(h:start() == true and #h.callbacks == 0 and h.manager.get_state() == "downloading")
  assert(h.manager.download_release(h.release) == false and h.dispatches == 1)
  h:ack(); assert(#h.callbacks == 1 and h.callbacks[1][1] == nil and h.manager.get_state() ~= "downloading")
  h:ack(); assert(#h.callbacks == 1)
 end)
end)
test("malformed owner never turns its early terminal into known zero-dispatch completion", function()
 scenario({ malformed = true, construct = function(h, terminal)
  h.flow_operation.started = false; h.flow_physical = true
  terminal(nil, "temporary path unavailable", "download")
 end }, function(h)
  assert(h:start() == false and #h.callbacks == 0 and h.manager.get_state() == "downloading")
  assert(h.manager.download_release(h.release) == false and h.dispatches == 1)
 end)
end)
test("physical probe cannot change captured original started receipt", function()
 scenario({ construct = function(h, terminal)
  h.flow_operation.started = false; h.flow_physical = true
  terminal(nil, "temporary path unavailable", "download")
  h.physical_probe = function() h.flow_operation.started = true end
 end }, function(h)
  assert(h:start() == false and #h.callbacks == 1 and h.manager.get_state() ~= "downloading")
 end)
end)
test("physical ACK alone without authentic terminal preserves original owned admission", function()
 scenario({ construct = function(h)
  h.flow_operation.started = false; h.flow_physical = true
 end }, function(h)
  assert(h:start() == true and h.dispatches == 1)
 end)
end)
test("captured closed allocator fact preserves the existing available offer despite observer field mutation", function()
 scenario({ construct = function(h, terminal)
  h.flow_operation.started = false; h.flow_operation.closed_allocation_refusal = true; h.flow_physical = true
  terminal(nil, "independent allocator error", "download")
  h.physical_probe = function() h.flow_operation.closed_allocation_refusal = false end
 end }, function(h)
  h.manager._test_set_cached_release(h.release)
  assert(h.manager.get_state() == "available")
  local callbacks = 0
  assert(h.manager.download_update(nil, function(path, message)
   callbacks = callbacks + 1; assert(path == nil and message == "independent allocator error")
  end) == false)
  assert(callbacks == 1 and h.manager.get_state() == "available")
 end)
end)
test("matching historical error text without the fixed allocator fact keeps ordinary failure state", function()
 scenario({ construct = function(h, terminal)
  h.flow_operation.started = false; h.flow_physical = true
  terminal(nil, "temporary path unavailable", "download")
 end }, function(h)
  h.manager._test_set_cached_release(h.release)
  local callbacks = 0
  assert(h.manager.download_update(nil, function(path, message)
   callbacks = callbacks + 1; assert(path == nil and message == "temporary path unavailable")
  end) == false)
  assert(callbacks == 1 and h.manager.get_state() == "idle")
 end)
end)
test("physical-probe source withdrawal prevents restoring an old available offer", function()
 scenario({ construct = function(h, terminal)
  h.flow_operation.started = false; h.flow_operation.closed_allocation_refusal = true; h.flow_physical = true
  terminal(nil, "independent allocator error", "download")
  h.physical_probe = function() h.paused = true end
 end }, function(h)
  h.manager._test_set_cached_release(h.release)
  local callbacks = 0
  assert(h.manager.download_update(nil, function(path) callbacks = callbacks + 1; assert(path == nil) end) == false)
  assert(callbacks == 1 and h.paused == true and h.manager.get_state() == "idle")
 end)
end)
assert(#tests == 8, "actual dispatch receiving floor")
local helpers = require("tests.helpers")
helpers.describe("known zero-dispatch native transaction", function()
 assert(#tests == 8, "Independent case floor changed")
 for _, case in ipairs(tests) do helpers.it(case[1], case[2]) end
end)
return tests
