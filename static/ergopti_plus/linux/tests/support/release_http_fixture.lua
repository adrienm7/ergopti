--- static/ergopti_plus/linux/tests/support/release_http_fixture.lua

--- Explicit portable ownership for the pre-existing scripted release GETs.
--- These synchronous effect producers acquire no native child or descriptor;
--- their named completion/cancel actions supply modeled physical ACKs only.
--- No kernel, native timer, process group or actual HTTP proof is inferred.
local M = {}
function M.attach(port)
 local get, cancel = rawget(port, "get"), rawget(port, "cancel")
 assert(type(get) == "function", "original scripted release get must exist")
 local pending = {}
 local function copy(value)
  if type(value) ~= "table" then return nil end
  local result = {}; for key, field in next, value do result[key] = field end
  return result
 end
 function port.get(url, headers, options, callback)
  local operation = { started = false }
  local closed, receipt, listeners = false, nil, {}
  local function acknowledge(value)
   if closed then return end
   receipt, closed = copy(value), true
   local held = listeners; listeners = {}
   for _, observer in ipairs(held) do observer() end
  end
  function operation:is_settled() return closed end
  function operation:settled_result() return closed and copy(receipt) or nil end
  function operation:on_settled(observer)
   if closed then observer() else listeners[#listeners + 1] = observer end
   return true
  end
  function operation:cancel()
   acknowledge({ ok = false, status = 0, body = "", error = "cancelled" })
   return true
  end
  pending[#pending + 1] = operation
  local admitted = get(url, headers, options, function(result)
   acknowledge(result) -- Explicit scripted completion ACK precedes logical effect.
   callback(result)
  end)
  operation.started = admitted == true
  if admitted ~= true then acknowledge({ ok = false, status = 0, body = "", error = "scripted dispatch refused" }) end
  return admitted, operation
 end
 if type(cancel) == "function" then
  function port.cancel(owner)
   local accepted = cancel(owner)
   if accepted == true then for _, operation in ipairs(pending) do operation:cancel() end end
   return accepted
  end
 end
 return port
end
return M
