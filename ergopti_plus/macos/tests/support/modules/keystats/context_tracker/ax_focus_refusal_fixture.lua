--- tests/support/modules/keystats/context_tracker/ax_focus_refusal_fixture.lua
--- Tests borrow the qualified private-resume lifecycle and replace only native AX reads.
local Base = require("tests.support.modules.keystats.context_tracker.private_resume_fixture")
local M = {}
function M.with_runtime(callback)
 return Base.with_runtime(function(runtime)
  local native, ax = runtime.native, runtime.hs.axuielement
  local original_app, original_pid = ax.applicationElement, ax.applicationElementForPID
  native.field_role, native.field_subrole = "AXTextField", nil
  native.focus_reads, native.refused_focus_reads, native.absent_focus_reads = 0, 0, 0
  local field = { attributeValue = function(_, key)
   if key == "AXRole" then return native.field_role end
   if key == "AXSubrole" then return native.field_subrole end
   if key == "AXValue" then return "" end
  end }
  local function application_element(site)
   return { attributeValue = function(_, key)
    if key == "AXRole" then return "AXApplication" end
    if key ~= "AXFocusedUIElement" then return nil end
    native.focus_reads = native.focus_reads + 1
    if native.focus_refused or native.refused_site == site then
     native.refused_focus_reads = native.refused_focus_reads + 1
     return nil, "Messaging failed"
    end
    if native.no_focus or native.absent_site == site then
     native.absent_focus_reads = native.absent_focus_reads + 1
     return nil
    end
    return field
   end }
  end
  ax.applicationElement = function() return application_element("bootstrap") end
  ax.applicationElementForPID = function() return application_element("refresh") end
  -- This boundary starts after the original fixture has proved a healthy bootstrap.
  -- Restore both exact native functions before its existing finally retires owners.
  local values = table.pack(xpcall(function() return callback(runtime) end, debug.traceback))
  ax.applicationElement, ax.applicationElementForPID = original_app, original_pid
  if not values[1] then error(values[2], 0) end
  return table.unpack(values, 2, values.n)
 end)
end
return M
