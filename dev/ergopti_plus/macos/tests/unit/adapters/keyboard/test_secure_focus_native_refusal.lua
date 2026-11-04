--- tests/unit/adapters/keyboard/test_secure_focus_native_refusal.lua
--- Preserve public adapter contracts while retaining confirmed native AX refusal.
local helpers = require("tests.helpers")
local function with_detector(callback)
 return helpers.with_stub_scope({ "adapters.secure_field_detector", "infra.logger", "hs", "tests.stubs.hs" }, function()
  package.loaded["infra.logger"] = { debug = function() end }
  local control = { mode = "ordinary", queries = {} }
  local focused = { attributeValue = function(_, key)
   control.queries[#control.queries + 1] = key
   if key == "AXRole" then return "AXTextField" end
   if key == "AXSubrole" and control.mode == "secure" then return "AXSecureTextField" end
  end }
  local app = { pid = function() control.queries[#control.queries + 1] = "pid"; return 4242 end }
  local detector = helpers.load_with_stubs("adapters.secure_field_detector", {
   application = { frontmostApplication = function() control.queries[#control.queries + 1] = "frontmost"; return app end },
   axuielement = { applicationElementForPID = function()
    control.queries[#control.queries + 1] = "ax_app"
    if control.mode == "no_app_element" then return nil end
    return { attributeValue = function(_, key)
     control.queries[#control.queries + 1] = key
     if control.mode == "refused" then return nil, "Messaging failed" end
     if control.mode == "no_focus" then return nil end
     return focused
    end }
   end },
  })
  return callback(detector, control)
 end)
end
helpers.describe("Native AXFocusedUIElement error return", function()
 helpers.it("keeps exactly two public unknown returns and does not fabricate observed completeness", function()
  with_detector(function(detector, control)
   control.mode = "refused"; local observed = 0
   local values = table.pack(detector.inspectFocusedElement(4242, function() observed = observed + 1 end))
   helpers.assert_eq(values.n, 2); helpers.assert_nil(values[1])
   helpers.assert_eq(values[2], "focused Accessibility element is unavailable")
   helpers.assert_eq(observed, 0)
  end)
 end)
 helpers.it("fails closed on nil plus native error without extra reads or a refresh return change", function()
  with_detector(function(detector, control)
   control.mode = "refused"; local complete, pid
   local values = table.pack(detector.refresh(function(known, inspected) complete, pid = known, inspected end))
   helpers.assert_eq(detector.isSecureField(), true, "Confirmed native focus refusal must suppress capture")
   helpers.assert_eq(values.n, 0); helpers.assert_eq(complete, false); helpers.assert_nil(pid)
   helpers.assert_eq(control.queries, { "frontmost", "pid", "ax_app", "AXFocusedUIElement" })
  end)
 end)
 helpers.it("keeps nil-only absence nonsecure and incomplete", function()
  with_detector(function(detector, control)
   control.mode = "no_focus"; local complete
   helpers.assert_nil(detector.refresh(function(known) complete = known end))
   helpers.assert_eq(detector.isSecureField(), false); helpers.assert_eq(complete, false)
  end)
 end)
 helpers.it("recovers the refused cache only when a healthy ordinary classification is read", function()
  with_detector(function(detector, control)
   control.mode = "refused"; detector.refresh()
   helpers.assert_eq(detector.isSecureField(), true, "Confirmed native focus refusal must suppress capture")
   control.mode = "ordinary"; local complete, pid
   detector.refresh(function(known, inspected) complete, pid = known, inspected end)
   helpers.assert_eq(detector.isSecureField(), false); helpers.assert_eq(complete, true); helpers.assert_eq(pid, 4242)
  end)
 end)
 helpers.it("keeps healthy secure subrole classification complete", function()
  with_detector(function(detector, control)
   control.mode = "secure"; local complete, pid
   detector.refresh(function(known, inspected) complete, pid = known, inspected end)
   helpers.assert_eq(detector.isSecureField(), true); helpers.assert_eq(complete, true); helpers.assert_eq(pid, 4242)
  end)
 end)
 helpers.it("preserves the existing absent AX application contract", function()
  with_detector(function(detector, control)
   control.mode = "no_app_element"; local complete
   detector.refresh(function(known) complete = known end)
   helpers.assert_eq(detector.isSecureField(), false); helpers.assert_eq(complete, false)
  end)
 end)
end)
