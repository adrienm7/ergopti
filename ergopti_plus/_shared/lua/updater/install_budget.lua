--- _shared/lua/updater/install_budget.lua

--- One local installation deadline, captured before its first native reader.
--- Accepted execution keeps this bound through listing/extraction/cleanup.
local M = {}
local records = setmetatable({}, { __mode = "k" })
local MAX_TIME = 9007199254740991
local function time(value)
 return type(value) == "number" and value == value and value >= 0 and value <= MAX_TIME
end
function M.capture(defaults, now)
 if type(defaults) ~= "table" or not time(now) then return nil end
 local policy = rawget(defaults, "release_install")
 local cap = type(policy) == "table" and rawget(policy, "install_timeout_ms") or nil
 if not time(cap) or cap == 0 or cap % 1 ~= 0 or now > MAX_TIME - cap then return nil end
 local token = {}
 records[token] = { deadline = now + cap, last = now, retired = false }
 return token
end
function M.admit(token, now)
 local record = records[token]
 if not record or record.retired or not time(now) or now < record.last then return false end
 record.last = now
 return now < record.deadline
end
function M.deadline(token)
 local record = records[token]
 return record and not record.retired and record.deadline or nil
end
function M.retire(token)
 local record = records[token]
 if not record then return false end
 record.retired = true
 return true
end
--- Captures only the canonical listing ceiling, independent of native ports.
--- Names and verbose share it; extraction retains its existing process bound.
--- @param defaults table Decoded canonical updater defaults.
--- @return number|nil bytes Immutable scalar or refusal, with no fallback.
function M.capture_listing(defaults)
 if type(defaults) ~= "table" then return nil end
 local policy = rawget(defaults, "release_install")
 local cap = type(policy) == "table" and rawget(policy, "listing_max_output_bytes") or nil
 if not time(cap) or cap == 0 or cap % 1 ~= 0 then return nil end
 return cap
end
return M
