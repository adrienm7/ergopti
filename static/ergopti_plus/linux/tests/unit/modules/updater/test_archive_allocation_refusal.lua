--- tests/unit/modules/updater/test_archive_allocation_refusal.lua

--- Literal allocation receiving controls for the actual Transfer module.
--- Explicit modeled allocator ACKs do not qualify real FD/native cleanup.
local Helpers = require("tests.helpers")
local Transfer = require("modules.updater.archive_transfer")
local function fixture(mode)
 local h = { active = true, physical = mode == "settled", probes = 0, requests = 0,
  cancelled = 0, callbacks = {}, listeners = {}, now = 0.25 }
 local brand = {}
 local factory = assert(Transfer.new({
  clock = function() return h.now end,
  current = function() return h.active end,
  defaults = { archive_transfer = { schema_version = 1,
   phase_timeout_ms = { checksum = 15000, archive = 300000, hash = 15000 } } },
  headers = {}, owner = "updater", parse_checksum = function() error("no checksum dispatch admitted") end,
  http = {
   get_owned = function() h.requests = h.requests + 1; error("no allocation means no HTTP") end,
   download_output_owned = function() h.requests = h.requests + 1; error("no allocation means no archive") end,
  },
  artifact = {
   reserve_transfer = function(_, txn, lineage, phase_current, deadline)
    assert(type(txn) == "table" and lineage() == true and phase_current() == true and deadline == 330000.25)
    if mode == "unknown" then return nil, nil end
    return brand, nil
   end,
   bind_checksum = function() error("no checksum bound") end,
   seal_and_adopt = function() error("no artifact adopted") end,
   cancel_transfer = function(actual) assert(rawequal(actual, brand)); h.cancelled = h.cancelled + 1; return true end,
   transfer_settled = function(actual)
    assert(rawequal(actual, brand)); h.probes = h.probes + 1
    if mode == "withdraw" and h.probes == 1 then h.active = false; h.physical = true end
    if mode == "throw" and h.probes == 1 then error("literal physical ACK refusal") end
    if mode == "reentrant" and h.probes == 1 then
     h.physical = true
     for _, listener in ipairs(h.listeners) do listener() end
    end
    return h.physical
   end,
   on_transfer_settled = function(actual, listener)
    assert(rawequal(actual, brand)); h.listeners[#h.listeners + 1] = listener; return true
   end,
  },
 }))
 h.operation = assert(factory:start({ tag = "v4.0.0", download_url = "https://release.invalid/archive",
  checksum_url = "https://release.invalid/checksum" }, function(path, message, stage)
  h.callbacks[#h.callbacks + 1] = { path = path, message = message, stage = stage }
 end))
 assert(h.operation.started == false and h.requests == 0)
 function h:ack()
  self.physical = true
  for _, listener in ipairs(self.listeners) do listener() end
 end
 return h
end
local function terminal(h, message)
 assert(h.operation:is_settled() == true and #h.callbacks == 1)
 assert(h.callbacks[1].path == nil and h.callbacks[1].message == message and h.callbacks[1].stage == "download")
 assert(h.requests == 0 and h.cancelled == 1)
end
Helpers.describe("exact allocator refusal receiving boundary", function()
 Helpers.it("known physically settled allocation refusal preserves established callback message", function()
  local h = fixture("settled"); terminal(h, "temporary path unavailable")
  h:ack(); assert(#h.callbacks == 1)
 end)
 Helpers.it("no target with unsettled allocator retains generic message and actual debt", function()
  local h = fixture("unsettled")
  assert(not h.operation:is_settled() and #h.callbacks == 0 and h.cancelled == 1)
  h:ack(); terminal(h, "owned archive allocation unavailable")
 end)
 Helpers.it("unknown allocator acquisition cannot borrow no-target cleanup authority", function()
  local h = fixture("unknown")
  assert(not h.operation:is_settled() and #h.callbacks == 0 and h.probes == 0 and h.cancelled == 0)
 end)
 Helpers.it("source withdrawal inside actual physical probe preserves generic refusal", function()
  local h = fixture("withdraw"); terminal(h, "owned archive allocation unavailable")
  assert(h.active == false)
 end)
 Helpers.it("throwing physical probe cannot select settled-allocation message", function()
  local h = fixture("throw")
  assert(not h.operation:is_settled() and #h.callbacks == 0)
  h:ack(); terminal(h, "owned archive allocation unavailable")
 end)
 Helpers.it("physical ACK listener reentry cannot duplicate allocation callback", function()
  local h = fixture("reentrant"); terminal(h, "temporary path unavailable")
  h:ack(); assert(#h.callbacks == 1)
 end)
end)

-- Additional fixed producer-fact controls; all six original bodies stay exact.
Helpers.describe("known allocation refusal producer fact", function()
 Helpers.it("only actual closed allocator admission supplies the fixed receiving fact", function()
  local h = fixture("settled")
  assert(rawget(h.operation, "closed_allocation_refusal") == true and h.operation.started == false)
  terminal(h, "temporary path unavailable")
 end)
 Helpers.it("withdrawn source cannot supply the closed allocator receiving fact", function()
  local h = fixture("withdraw")
  assert(rawget(h.operation, "closed_allocation_refusal") == nil and h.active == false)
  terminal(h, "owned archive allocation unavailable")
 end)
end)
