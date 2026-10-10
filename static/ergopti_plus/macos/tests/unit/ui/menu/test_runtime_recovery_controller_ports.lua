--- tests/unit/ui/menu/test_runtime_recovery_controller_ports.lua

--- ==============================================================================
--- MODULE: Pure Original Controller Recovery Custody
--- DESCRIPTION:
--- Actual native controller construction supplies private absent-state evidence;
--- ordinary diagnostics and role aliases are not paint-time observations.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.runtime_recovery_fixture")
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'
helpers.describe("Original pure uninitialized controller custody", function()
 helpers.it("native tuple retains operation roles and observes actual absence without status", function()
  fixture.with_source(OWNED, function(_, _, lease)
   local owner, initialized, status, stop, init, current = lease.uninitialized_recovery_ports()
   helpers.assert_eq(owner, lease);helpers.assert_eq(initialized, lease.is_initialized)
   helpers.assert_eq(status, lease.status);helpers.assert_eq(stop, lease.stop);helpers.assert_eq(init, lease.init)
   local entries = 0
   debug.sethook(function(event)
    if event == "call" and debug.getinfo(2,"f").func == status then entries=entries+1 end
   end,"c")
   local called, result = pcall(current)
   debug.sethook()
   helpers.assert_eq(called,true);helpers.assert_eq(result,true);helpers.assert_eq(entries,0)
  end)
 end)
 helpers.it("same-file advertised controller role substitution refuses without invoking that role", function()
  fixture.with_source(OWNED, function(_, _, lease)
   local _, initialized, status, _, _, current = lease.uninitialized_recovery_ports()
   lease.is_initialized = status
   local entries = 0
   debug.sethook(function(event)
    if event == "call" and debug.getinfo(2,"f").func == status then entries=entries+1 end
   end,"c")
   local called, result = pcall(current)
   debug.sethook();lease.is_initialized=initialized
   helpers.assert_eq(called,true);helpers.assert_eq(result,false);helpers.assert_eq(entries,0)
  end)
 end)
 helpers.it("actual native initialization invalidates the original absent-state receipt", function()
  fixture.with_source(OWNED, function(_, _, lease)
   local _, initialized, _, _, init, current = lease.uninitialized_recovery_ports()
   helpers.assert_eq(current(),true)
   init()
   helpers.assert_eq(initialized(),true)
   helpers.assert_eq(current(),false)
  end)
 end)
end)
