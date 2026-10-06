--- tests/unit/modules/updater/test_production_manager_owners.lua

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
test("missing native component refuses without pathname fallback", function()
 scenario({ component_missing = true }, function(h)
  assert(h:start() == false and h.dispatches == 0)
  assert(#h.callbacks == 1 and h.callbacks[1][1] == nil and h.manager.get_state() ~= "downloading")
 end)
end)
test("logical cancellation remains busy until captured physical flow ACK", function()
 scenario({}, function(h)
  assert(h:start()); assert(h.manager.cancel_update() and h.cancellation == 1)
  assert(h.manager.get_state() == "downloading" and #h.callbacks == 0)
  assert(h.manager.download_release(h.release) == false and h.dispatches == 1)
  h:ack(); assert(h.manager.get_state() ~= "downloading" and #h.callbacks == 1 and h.callbacks[1][1] == nil)
 end)
end)
test("exact captured flow method survives public method replacement", function()
 scenario({}, function(h)
  assert(h:start()); h.flow_operation.is_settled = function() return true end
  h.terminal(nil, "failed", "download")
  assert(#h.callbacks == 0 and h.manager.get_state() == "downloading")
  h:ack(); assert(#h.callbacks == 1)
 end)
end)
test("malformed returned owner retains unknown debt and refuses new acquisition", function()
 scenario({ malformed = true }, function(h)
  assert(h:start() == false and #h.callbacks == 0 and h.manager.get_state() == "downloading")
  assert(h.manager.download_release(h.release) == false and h.dispatches == 1)
 end)
end)
test("default tray source requires actual fresh pause observation", function()
 scenario({}, function(h)
  assert(h:start()); assert(h.source())
  h.paused = true; assert(h.source() == false)
 end)
end)
test("selected release mutation cannot authorize another native route", function()
 scenario({}, function(h)
  assert(h:start()); assert(h.source())
  h.release.download_url = "https://foreign.invalid/archive"
  assert(h.source() == false)
 end)
end)
test("accepted Versions execution remains explicit rather than generic pause bypass", function()
 scenario({}, function(h)
  local accepted = true
  assert(h:start(function() return accepted end)); h.paused = true; assert(h.source())
  accepted = false; assert(h.source() == false)
 end)
end)
test("native display path cannot enter original pathname installer", function()
 scenario({}, function(h)
  assert(h:start()); h:success()
  assert(h.manager.install_release_archive("display-information-only", "v1.2.3") == false)
  assert(h.installs == 0)
 end)
end)
test("cancelled artifact cleanup listener cannot publish the terminal twice", function()
 scenario({}, function(h)
  assert(h:start()); h.terminal("display-information-only", nil, nil, nil, h.brand)
  assert(h.manager.cancel_update()); h:ack()
  assert(#h.callbacks == 0)
  h.artifact_closed = true
  h.retire_probe = function()
   h.retire_probe = nil
   for _, listener in ipairs(h.artifact_listeners) do listener() end
  end
  h.observers[1]()
  assert(#h.callbacks == 1 and h.callbacks[1][1] == nil)
  h.observers[1](); assert(#h.callbacks == 1)
 end)
end)
test("physical acknowledgement source withdrawal cannot grant install authority", function()
 scenario({}, function(h)
  local active = true
  h.physical_probe = function() if h.flow_physical then active = false end end -- Installed before method capture.
  assert(h:start(function() return active end))
  h.artifact_closed = true; h:success()
  assert(#h.callbacks == 1 and h.callbacks[1][1] == nil and h.retired == true)
  assert(h.manager.install_release_archive_async("display-information-only", "v1.2.3", function() error("success") end,
   function() return true end) == false and h.installs == 0)
 end)
end)
test("physical acknowledgement pause withdrawal refuses default tray publication", function()
 scenario({}, function(h)
  h.physical_probe = function() if h.flow_physical then h.paused = true end end
  assert(h:start()); h.artifact_closed = true; h:success()
  assert(#h.callbacks == 1 and h.callbacks[1][1] == nil and h.retired == true and h.installs == 0)
 end)
end)
test("physical acknowledgement selected URL mutation refuses archive publication", function()
 scenario({}, function(h)
  h.physical_probe = function() if h.flow_physical then h.release.download_url = "https://foreign.invalid/archive" end end
  assert(h:start()); h.artifact_closed = true; h:success()
  assert(#h.callbacks == 1 and h.callbacks[1][1] == nil and h.retired == true)
 end)
end)
for _, options in ipairs({ { name = "false", source = function() return false end },
 { name = "throwing", source = function() error("withdrawn original intent") end }, { name = "invalid", source = "true" } }) do
 test(options.name .. " initial source preserves previous verified artifact", function()
  scenario({}, function(h)
   assert(h:start()); h:success(); assert(#h.callbacks == 1 and h.callbacks[1][1] ~= nil)
   h.artifact_closed = true
   assert(h:start(options.source) == false)
   assert(h.retired ~= true and h.dispatches == 1)
   assert(h.manager.install_release_archive_async("display-information-only", "v1.2.3", function() end,
    function() return true end) == true and h.installs == 1)
  end)
 end)
end
test("channel cleanup refusal preserves channel and cache before persistence", function()
 scenario({}, function(h)
  assert(h:start()); h:success(); h.manager._test_set_cached_release(h.release)
  local previous = h.manager.get_channel()
  local wanted = previous == "dev" and "main" or "dev"
  assert(h.manager.set_channel(wanted) == false)
  assert(h.manager.get_channel() == previous and h.persistence == 0 and h.manager.get_cached_release() == h.release)
  h:dispose() -- Exact private cleanup ACK; no automatic commit of a refused synchronous call.
  assert(h.manager.get_channel() == previous and h.persistence == 0)
  assert(h.manager.set_channel(wanted) == true)
  assert(h.manager.get_channel() == wanted and h.persistence == 1 and h.manager.get_cached_release() == nil)
 end)
end)
test("channel cleanup reentry cannot borrow or persist a successor choice", function()
 scenario({}, function(h)
  assert(h:start()); h:success(); h.manager._test_set_cached_release(h.release); h.artifact_closed = true
  local previous = h.manager.get_channel()
  local wanted = previous == "dev" and "main" or "dev"
  h.retire_probe = function()
   h.retire_probe = nil
   assert(h.manager.set_channel(previous) == false)
   assert(h.manager.clear_cached_release() == false)
   assert(h.manager.install_release_archive_async("display-information-only", "v1.2.3", function() error("success") end,
    function() return true end) == false and h.installs == 0)
  end
  assert(h.manager.set_channel(wanted) == true)
  assert(h.manager.get_channel() == wanted and h.persistence == 1 and h.manager.get_cached_release() == nil)
 end)
end)
test("actual installer pre-reader deadline refusal releases manager only after authentic cleanup ACK", function()
 scenario({ actual_installer = true }, function(h)
  assert(h:start()); h:success()
  local outcomes = {}
  assert(h.manager.install_release_archive_async("display-information-only", "v1.2.3", function(...)
   outcomes[#outcomes + 1] = { ... }
  end, function() return true end) == true)
  assert(h.manager.get_state() == "installing" and h.reads == 0 and #outcomes == 0)
  h.finish_done({ ok = true })
  assert(h.manager.get_state() == "installing" and #outcomes == 0)
  h.cleanup_physical = true; h.cleanup_listener()
  assert(h.manager.get_state() == "available" and #outcomes == 1 and outcomes[1][1] == false and h.reads == 0)
  h.cleanup_listener(); assert(#outcomes == 1)
  assert(h.manager.install_release_archive_async("display-information-only", "v1.2.3", function() end,
   function() return true end) == true) -- A fresh explicit attempt may reuse its still-owned verified artifact.
  h.finish_done({ ok = true }); h.cleanup_listener()
 end)
end)
assert(#tests == 18, "actual manager owner receiving-model floor")

-- Genuine normal registration retains every independent body and oracle.
local helpers = require("tests.helpers")
helpers.describe("Native Updater Publication", function()
	assert(#tests == 18, "Independent case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function", "Independent registration refused")
		helpers.it(case[1], case[2])
	end
end)
return tests
