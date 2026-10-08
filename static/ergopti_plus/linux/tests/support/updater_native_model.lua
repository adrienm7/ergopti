--- static/ergopti_plus/linux/tests/support/updater_native_model.lua

--- Portable unit-only adapter for the original controlled HTTP/hash effects.
--- The real Manager and Transfer remain loaded. Explicit model ACKs do not
--- qualify native FD, OpenSSL, publication, timers, HTTP or installer behavior.
local M = {}
function M.with_fixture(body)
 local original_tmpname = os.tmpname -- Restore even when decoration fails before old inner cleanup.
 local names = { "modules.updater.manager", "infra.archive_output", "infra.monotonic", "infra.installation" }
 local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
 local Fs = require("adapters.file_system")
 local Move = require("infra.no_replace_move")
 local owners, config_path, manager = {}, nil, nil
 local now = 0.25
 local function owned_operation(dispatch)
  local physical, listeners = false, {}
  local operation = { started = false }
  local function ack()
   physical = true
   local pending = listeners; listeners = {}
   for _, listener in ipairs(pending) do listener() end
  end
  function operation:is_settled() return physical end
  function operation:on_settled(listener)
   assert(type(listener) == "function")
   if physical then listener() else listeners[#listeners + 1] = listener end
   return true
  end
  function operation:request_cancel()
   -- Only synchronous controlled effects are dispatched by these old cases.
   -- Their callback ACK, not this logical cancellation, grants settlement.
   return true
  end
  operation.started = dispatch(ack) == true
  return operation
 end
 local function remove_owned(owner)
  if owner.path ~= nil and not Fs.delete(owner.path) then return false end
  owner.path = nil
  return true
 end
 local function factory(asset_name)
  local owner, artifact = nil, {}
  assert(asset_name == manager.LINUX_ASSET_NAME)
  local function exact(brand)
   assert(owner and rawequal(brand, owner.brand), "foreign unit artifact")
   return owner
  end
  function artifact.reserve_transfer(meta, txn, lineage, current, deadline)
   assert(owner == nil and type(txn) == "table" and lineage() == true and current() == true)
   assert(type(meta.tag) == "string" and deadline > now)
   owner = { brand = {}, target = {}, transaction = txn, current = current, lineage = lineage,
    transfer_closed = false, listeners = {} }
   owners[#owners + 1] = owner
   -- The original allocator override is the controlled resource effect. A
   -- thrown override acquired nothing and owns a known settled model refusal.
   local allocated, path = pcall(os.tmpname)
   if not allocated or type(path) ~= "string" or path == "" then
    owner.transfer_closed = true
    return owner.brand, nil
   end
   owner.path = path
   local handle = assert(io.open(path, "wb"))
   assert(handle:close(), "unit output handle must physically close")
   return owner.brand, owner.target
  end
  function artifact.bind_checksum(brand, expected)
   local state = exact(brand)
   assert(state.expected == nil and state.current() == true and type(expected) == "string")
   state.expected = expected
   return true
  end
  function artifact.seal_and_adopt(brand, completion, expected, deadline, done)
   local state = exact(brand)
   assert(rawequal(state.completion, completion) and state.expected == expected)
   assert(state.current() == true and deadline > now and not state.transfer_closed)
   return owned_operation(function(ack)
    return manager._file_digest.sha256(state.path, { owner = "updater" }, function(actual, failure)
     -- Original controlled hash callbacks run after their test write handle
     -- has closed. This is model retirement, not real EVP/read-close proof.
     state.transfer_closed = true
     if actual == expected and failure == nil then
      local destination = state.path .. ".verified"
      local moved, reason = Move.move(state.path, destination)
      if moved ~= true then done(nil, reason or "unit publication refused")
      else state.path, state.adopted = destination, true; done(destination) end
     else done(nil, failure or "checksum mismatch") end
     ack()
    end)
   end)
  end
  function artifact.cancel_transfer(brand)
   local state = exact(brand)
   if not remove_owned(state) then return false end
   state.transfer_closed = true
   local listeners = state.listeners; state.listeners = {}
   for _, listener in ipairs(listeners) do listener() end
   return true
  end
  function artifact.transfer_settled(brand) return exact(brand).transfer_closed end
  function artifact.on_transfer_settled(brand, listener)
   local state = exact(brand)
   assert(type(listener) == "function")
   if state.transfer_closed then listener() else state.listeners[#state.listeners + 1] = listener end
   return true
  end
  function artifact.retire_artifact(brand) return remove_owned(exact(brand)) end
  function artifact.artifact_settled(brand) return exact(brand).path == nil end
  function artifact.on_artifact_settled(brand, listener)
   if artifact.artifact_settled(brand) then listener(); return true end
   return false
  end
  -- These cases never admit installation. Missing native proof is not
  -- substituted by an ordinary pathname or a success-returning installer.
  function artifact.begin_install() error("no install admission in manager download models") end
  function artifact.install_current() return false end
  function artifact.install_feed() error("no native tar in manager download models") end
  function artifact.finish_install() error("no installer owner in manager download models") end
  return artifact
 end
 local function decorate_http()
  local http = manager._http_client
  local get, download = rawget(http, "get"), rawget(http, "download")
  assert(type(get) == "function", "original controlled HTTP get must exist")
  http.get_owned = function(url, headers, opts, done)
   assert(opts.owner == "updater" and opts.authorized() == true and opts.absolute_deadline_ms > now)
   return owned_operation(function(ack)
    return get(url, headers, opts, function(result) done(result); ack() end)
   end)
  end
  http.download_output_owned = function(url, headers, target, opts, done)
   assert(#owners == 1 and rawequal(target, owners[1].target))
   local state = owners[1]
   assert(type(download) == "function" and opts.owner == "updater" and opts.authorized() == true)
   assert(opts.absolute_deadline_ms > now)
   return owned_operation(function(ack)
    return download(url, headers, state.path, opts, function(result)
     state.completion = {}; done(result, state.completion); ack()
    end)
   end)
  end
 end
 local ok, failure = xpcall(function()
  config_path = os.tmpname() -- Reserve before the original allocator override.
  local config = assert(io.open(config_path, "wb")); assert(config:close())
  package.loaded["infra.archive_output"] = { native_artifact = factory }
  package.loaded["infra.monotonic"] = { has_hires = function() return true end,
   backend = function() return "luv.hrtime" end, now_ms = function() return now end }
  package.loaded["modules.updater.manager"] = nil
  manager = require("modules.updater.manager")
  manager._http_client = { cancel = function() return true end }
  manager._file_digest = { cancel = function() return true end }
  package.loaded["infra.installation"] = { is_source_run = function() return true end }
  manager.init({ config_path = config_path, is_paused = function() return false end })
  package.loaded["infra.installation"] = saved["infra.installation"].value
  body(manager, decorate_http)
 end, debug.traceback)
 local cleanup_error
 local function cleanup_one(action)
  local cleaned, detail = xpcall(action, debug.traceback)
  if not cleaned and cleanup_error == nil then cleanup_error = detail end
 end
 -- A refused resource never skips another exact captured owner/config.
 for _, owner in ipairs(owners) do
  cleanup_one(function() assert(remove_owned(owner), "unit resource cleanup refused") end)
 end
 if config_path then cleanup_one(function() assert(Fs.delete(config_path), "unit config cleanup refused") end) end
 os.tmpname = original_tmpname
 for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
 if not ok then error(failure, 0) end -- The original body failure remains primary.
 if cleanup_error ~= nil then error(cleanup_error, 0) end
end
return M
