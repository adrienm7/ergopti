--- modules/updater/archive_transfer.lua

--- One immutable updater download transaction. The native branded artifact
--- factory/installer join requires its own composite runtime qualification.
--- No filesystem descriptor/path is opened or treated as authority here.
local M = {}
local Budget = require("updater.transfer_budget")

local function method(object, name)
 return type(object) == "table" and rawget(object, name) or nil
end

--- Captures real owned transport/artifact ports. No default capability exists.
--- Factory methods must accept only their own private raw-identity brands.
function M.new(ports)
 if type(ports) ~= "table" or type(ports.clock) ~= "function" or type(ports.parse_checksum) ~= "function"
  or type(ports.current) ~= "function" or type(ports.defaults) ~= "table" then return nil end
 local get = method(ports.http, "get_owned")
 local download = method(ports.http, "download_output_owned")
 local reserve = method(ports.artifact, "reserve_transfer")
 local bind_checksum = method(ports.artifact, "bind_checksum")
 local adopt = method(ports.artifact, "seal_and_adopt")
 local retire = method(ports.artifact, "cancel_transfer")
 local artifact_settled = method(ports.artifact, "transfer_settled")
 local artifact_observe = method(ports.artifact, "on_transfer_settled")
 local artifact_retry = method(ports.artifact, "retry_transfer_cleanup")
 if type(get) ~= "function" or type(download) ~= "function" or type(reserve) ~= "function"
  or type(bind_checksum) ~= "function" or type(adopt) ~= "function" or type(retire) ~= "function"
  or type(artifact_settled) ~= "function" or type(artifact_observe) ~= "function" then return nil end
 local clock, source, parse = ports.clock, ports.current, ports.parse_checksum
 local owner, max_archive, max_checksum = ports.owner, ports.max_download_bytes, ports.max_checksum_bytes
 local headers = {}
 if type(ports.headers) ~= "table" then return nil end
 for key, value in next, ports.headers do headers[key] = value end
 local factory = {}
 local active -- Retains exact predecessor through unknown native debt.

 function factory:start(release, callback)
  if active or type(release) ~= "table" or type(callback) ~= "function" then return nil end
  local selected = {}
  for _, name in ipairs({ "tag", "download_url", "checksum_url" }) do
   local value = rawget(release, name)
   if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then return nil end
   selected[name] = value
  end
  local txn = { token = {}, phase = nil, cancelled = false, requests = {}, constructing = 0, finished = false, listeners = {} }
  local operation = { started = false }
  active = txn -- Reserve before native clock, source or artifact construction.
  local budget
  local function current()
   if active ~= txn or txn.cancelled or txn.finished then return false end
   local called, accepted = pcall(source, txn.token)
   if not called or accepted ~= true or active ~= txn or txn.cancelled or txn.finished then return false end
   local timed, now = pcall(clock)
   return timed and budget ~= nil and Budget.admit(budget, txn.phase, now)
    and active == txn and not txn.cancelled and not txn.finished
  end
  local function lineage()
   if active ~= txn or txn.cancelled or txn.finished then return false end
   local called, accepted = pcall(source, txn.token)
   return called and accepted == true and active == txn and not txn.cancelled and not txn.finished
  end
  local function physically_settled()
   if txn.constructing ~= 0 or txn.unknown then return false end
   for _, owned in ipairs(txn.requests) do
    if type(owned.is_settled) ~= "function" then return false end
    local called, ack = pcall(owned.is_settled, owned.operation)
    if not called or ack ~= true or txn.constructing ~= 0 or txn.unknown then return false end
   end
   if txn.artifact then
    local called, ack = pcall(artifact_settled, txn.artifact)
    if not called or ack ~= true then return false end
   end
   return txn.constructing == 0 and not txn.unknown
  end
  local function notify()
   local listeners = txn.listeners
   txn.listeners = {}
   for _, listener in ipairs(listeners) do pcall(listener) end
  end
  local settle
  local function revoke()
   txn.cancelled = true
   if budget then Budget.retire(budget) end
   for _, owned in ipairs(txn.requests) do
    if not owned.signalled and type(owned.cancel) == "function" then
     owned.signalled = true; pcall(owned.cancel, owned.operation)
    end
   end
   if txn.artifact and not txn.artifact_signalled then
    txn.artifact_signalled = true; pcall(retire, txn.artifact)
   end
  end
  local function fail(message, stage, receipt)
   if txn.finished or txn.failure then return end
   txn.failure = { message = message, stage = stage, receipt = receipt }
   revoke(); settle()
  end
  settle = function()
   if active ~= txn or txn.finished or txn.settling then return end
   txn.settling = true
   local retired = physically_settled()
   txn.settling = false
   if not retired or active ~= txn or txn.finished then return end
   if txn.failure then
    local failure = txn.failure
    txn.finished = true; active = nil
    pcall(callback, nil, failure.message, failure.stage, failure.receipt)
    notify()
   elseif txn.cancelled then txn.finished = true; active = nil; notify() end
  end
  function operation:is_settled()
   -- finished is set only after captured physical proofs. A later artifact
   -- install/retirement cannot make original transfer ACKs disappear.
   return txn.finished
  end
  function operation:on_settled(listener)
   if type(listener) ~= "function" then return false end
   if txn.finished then pcall(listener)
   else txn.listeners[#txn.listeners + 1] = listener end
   return true
  end
  function operation:retry_cleanup()
   if active ~= txn or txn.finished or txn.constructing ~= 0 or txn.unknown or not txn.cancelled
    or txn.retrying or not txn.artifact or type(artifact_retry) ~= "function" then return false end
   txn.retrying = true
   local brand = txn.artifact
   local checked, accepted = pcall(artifact_retry, brand)
   txn.retrying = false
   if active ~= txn or txn.artifact ~= brand or txn.unknown or txn.constructing ~= 0 then return txn.finished end
   settle() -- Original settlement joins every original transport owner.
   return checked and accepted == true and txn.finished == true
  end
  function operation:request_cancel()
   -- A completed transfer cannot revoke its later separately owned artifact.
   if txn.finished then return true end
   revoke(); settle(); return true
  end
  function operation:cancel() self:request_cancel(); return self:is_settled() end

  local function enter(name)
   if not lineage() then return nil end
   local called, now = pcall(clock)
   if not called then return nil end
   local deadline = Budget.enter(budget, name, now)
   if not deadline or not lineage() then return nil end
   txn.phase = name
   return current() and deadline or nil
  end
  local function dispatch(call, completed, terminal_admit)
   local owned = { operation = nil, received = false, delivered = false }
   txn.requests[#txn.requests + 1] = owned
   txn.constructing = txn.constructing + 1
   local function publish()
    if owned.publishing or owned.delivered or not owned.received or txn.constructing ~= 0 or not owned.operation then return end
    local operation, result, completion = owned.operation, owned.result, owned.completion
    local function intact()
     return active == txn and not txn.finished and not txn.cancelled and txn.constructing == 0 and not owned.delivered
      and rawequal(owned.operation, operation) and rawequal(owned.result, result) and rawequal(owned.completion, completion)
    end
    owned.publishing = true -- Reserve across physical, source and original clock probes.
    local guarded = pcall(function()
     if not intact() then return end
     local called, ack = pcall(owned.is_settled, operation)
     if not called or ack ~= true or not intact() then return end
     -- After artifact handoff, use only fresh lineage plus the original
     -- observational publication deadline, never retired network consent.
     local admitted = terminal_admit or current
     local checked, accepted = pcall(admitted)
     if not intact() then return end
     if not checked or accepted ~= true then revoke(); settle(); return end
     owned.delivered = true -- Callback authority is consumed before any new phase acquisition.
     completed(result, completion)
    end)
    owned.publishing = false
    if not guarded then fail("owned update callback failed", "download") end
   end
   local called, child = pcall(call, function(result, completion)
    if owned.received then return end
    owned.received, owned.result, owned.completion = true, result, completion
    publish()
   end)
   local probe, signal, observe = method(child, "is_settled"), method(child, "request_cancel"), method(child, "on_settled")
   signal = type(signal) == "function" and signal or method(child, "cancel")
   if called and type(probe) == "function" and type(signal) == "function" and type(observe) == "function" then
    owned.operation, owned.is_settled, owned.cancel, owned.observe = child, probe, signal, observe
    local subscribed, ack = pcall(observe, child, function() publish(); settle() end)
    if not subscribed or ack ~= true then txn.unknown = true end
   else txn.unknown = true end
   if txn.cancelled and owned.operation and not owned.signalled then
    owned.signalled = true; pcall(owned.cancel, owned.operation)
   end
   txn.constructing = txn.constructing - 1
   if txn.unknown then fail("owned update transport unavailable", "download")
   elseif rawget(child, "started") ~= true and not owned.received then fail("update request was not dispatched", "download")
   else publish() end
   settle()
   return not txn.unknown and rawget(child, "started") == true
  end

  local timed, now = pcall(clock)
  budget = timed and Budget.capture(ports.defaults, now) or nil
  local checksum_deadline = budget and enter("checksum") or nil
  if not checksum_deadline then txn.unknown = false; fail("update transfer admission refused", "download"); return operation end
  txn.constructing = txn.constructing + 1
  local published_metadata = { tag = selected.tag, download_url = selected.download_url, checksum_url = selected.checksum_url }
  local reserved, artifact, target = pcall(reserve, published_metadata, txn.token, lineage, current, Budget.deadline(budget))
  txn.artifact = reserved and type(artifact) == "table" and artifact or nil
  artifact = txn.artifact
  if not reserved or artifact == nil then txn.unknown = true end
  -- A returned brand with no target is still the exact retained native owner.
  -- Its authentic constructor-refusal debt must be joined, never frozen as unknown solely because target is absent.
  if artifact ~= nil then
   local subscribed, ack = pcall(artifact_observe, artifact, settle)
   if not subscribed or ack ~= true then txn.unknown = true end
  end
  txn.constructing = txn.constructing - 1
  local allocation_current = current()
  if txn.unknown or type(target) ~= "table" or not allocation_current then
   local message = "owned archive allocation unavailable"
   if allocation_current and not txn.unknown and artifact ~= nil and type(target) ~= "table" then
    -- Only the actual captured allocator owner's literal physical ACK permits
    -- the established known temporary-allocation refusal message. No target
    -- or logical cancel result alone acknowledges native constructor cleanup.
    local observed, physical = pcall(artifact_settled, artifact)
    if observed and physical == true and active == txn and not txn.cancelled and not txn.finished
     and not txn.unknown and rawequal(txn.artifact, artifact) and current() then
     operation.closed_allocation_refusal = true -- Fixed producer fact after exact physical ACK and fresh lineage.
     message = "temporary path unavailable"
    end
   end
   fail(message, "download")
   return operation
  end
  local function after_checksum(result)
   if type(result) ~= "table" or result.ok ~= true then
    fail(type(result) == "table" and result.error or "checksum request failed", "download",
     type(result) == "table" and result.failure_receipt or nil); return
   end
   local parsed, expected, error_message = pcall(parse, result.body)
   if not parsed or expected == nil or not current() then fail(error_message or "checksum record refused", "verify"); return end
   local bound, admitted = pcall(bind_checksum, artifact, expected)
   if not bound or admitted ~= true or not current() then fail("authenticated checksum binding refused", "verify"); return end
   local archive_deadline = enter("archive")
   if not archive_deadline then fail("archive deadline expired", "download"); return end
   dispatch(function(done)
    return download(selected.download_url, headers, target, { owner = owner,
     authorized = current, absolute_deadline_ms = archive_deadline,
     timeout_ms = math.max(1, math.floor(archive_deadline - clock())),
     max_download_bytes = max_archive, follow_redirects = true, https_only = true }, done)
   end, function(downloaded, completion)
    if type(downloaded) ~= "table" or downloaded.ok ~= true or type(completion) ~= "table" then
     fail(type(downloaded) == "table" and downloaded.error or "archive request failed", "download",
      type(downloaded) == "table" and downloaded.failure_receipt or nil); return
    end
    local hash_deadline = enter("hash")
    if not hash_deadline then fail("archive hash deadline expired", "verify"); return end
    local function adoption_current()
     if not lineage() then return false end
     local timed, observed = pcall(clock)
     return timed and type(observed) == "number" and observed == observed and observed < hash_deadline
      and active == txn and not txn.cancelled and not txn.finished
    end
    dispatch(function(done)
     return adopt(artifact, completion, expected, hash_deadline, function(path, error_message, receipt)
      local valid_path = type(path) == "string" and path ~= "" and not path:find("\0", 1, true)
       and error_message == nil and receipt == nil
      done({ ok = valid_path, path = valid_path and path or nil, error = error_message, failure_receipt = receipt })
     end)
    end, function(adopted)
     -- Adoption must have physically retired the original transfer owners.
     -- The artifact lives under separate future install consent, not this phase.
     if type(adopted) ~= "table" or adopted.ok ~= true or not physically_settled() or not adoption_current() then
      fail(type(adopted) == "table" and adopted.error or "verified archive adoption refused", "verify",
       type(adopted) == "table" and adopted.failure_receipt or nil); return
     end
     txn.finished = true; active = nil; Budget.retire(budget)
     pcall(callback, adopted.path, nil, nil, nil, artifact)
     notify()
    end, adoption_current)
   end)
  end
  operation.started = dispatch(function(done)
   return get(selected.checksum_url, headers, { owner = owner, authorized = current,
    absolute_deadline_ms = checksum_deadline, timeout_ms = math.max(1, math.floor(checksum_deadline - clock())),
    max_body_bytes = max_checksum, follow_redirects = true, https_only = true }, done)
  end, after_checksum)
  return operation
 end
 return factory
end
return M
