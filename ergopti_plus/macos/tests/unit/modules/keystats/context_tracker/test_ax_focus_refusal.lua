--- tests/unit/modules/keystats/context_tracker/test_ax_focus_refusal.lua
--- Native AX refusal at the real public pause/resume boundary.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keystats.context_tracker.ax_focus_refusal_fixture")
local function sink(runtime, expected)
 local accepted, snapshots = runtime.sink()
 helpers.assert_eq(runtime.engine.may_persist(), expected, "Confirmed AX focus refusal must close the public persistence gate")
 helpers.assert_eq(accepted, expected, "The actual synthetic sink must follow the AX focus privacy verdict")
 helpers.assert_eq(snapshots, expected and 1 or 0)
end
local function target(runtime, secure)
 runtime.pause()
 runtime.foreground("Google Chrome", "com.google.Chrome")
 runtime.native.title = "Ordinary fixture page"
 runtime.native.field_subrole = secure and "AXSecureTextField" or nil
 runtime.activate()
 helpers.assert_eq(runtime.state.active_app_name, "TextEdit")
 helpers.assert_eq(runtime.state.is_secure_field, false)
 helpers.assert_eq(runtime.observation.ui_live, 2)
end
local function resumed(runtime)
 local row = runtime.resume()
 helpers.assert_eq(runtime.observation.tracker_receipts[#runtime.observation.tracker_receipts].result, true)
 helpers.assert_eq(row.foreground_refresh_pending, false)
 helpers.assert_eq(row.modifier_context_pending, false)
 helpers.assert_eq(row.auth_modifier_pending, false)
 helpers.assert_eq(row.admission_open, true)
 return row
end
local function healthy(runtime)
 helpers.assert_eq(#runtime.observation.logs, 0, "No native owner/setup failure may conceal the actual privacy verdict")
end
helpers.describe("Confirmed AX focus refusal during public resume", function()
 helpers.it("keeps a healthy ordinary resumed field admitted", function()
  Fixture.with_runtime(function(runtime)
   target(runtime, false); resumed(runtime); sink(runtime, true)
   helpers.assert_eq(runtime.state.is_secure_field, false); healthy(runtime)
  end)
 end)
 helpers.it("keeps a healthy secure resumed field denied", function()
  Fixture.with_runtime(function(runtime)
   target(runtime, true); resumed(runtime); sink(runtime, false)
   helpers.assert_eq(runtime.state.is_secure_field, true); healthy(runtime)
  end)
 end)
 helpers.it("preserves the legitimate nil-only no-focused-element contract", function()
  Fixture.with_runtime(function(runtime)
   target(runtime, false); runtime.native.no_focus = true
   resumed(runtime); sink(runtime, true)
   helpers.assert_eq(runtime.state.is_secure_field, false)
   helpers.assert_eq(runtime.native.absent_focus_reads, 2); healthy(runtime)
  end)
 end)
 for _, site in ipairs({ "both", "refresh", "bootstrap" }) do
  helpers.it("denies confirmed native focus refusal and recovers through a healthy resume: " .. site, function()
   Fixture.with_runtime(function(runtime)
    -- Bootstrap-only starts with an ordinary classification: the second native
    -- read refuses permission; no new secure field is invented between calls.
    target(runtime, site ~= "bootstrap")
    if site ~= "bootstrap" then
     local detector = assert(package.loaded["adapters.secure_field_detector"])
     local secure, detail = detector.inspectFocusedElement(runtime.native.pid)
     helpers.assert_eq(secure, true); helpers.assert_nil(detail)
    end
    if site == "both" then runtime.native.focus_refused = true
    else runtime.native.refused_site = site end
    -- A later nil-only absence does not conclusively classify the refused field.
    -- A healthy returned element would legitimately recover within the same turn.
    if site == "refresh" then runtime.native.absent_site = "bootstrap" end
    resumed(runtime); sink(runtime, false)
    helpers.assert_eq(runtime.state.is_secure_field, true)
    helpers.assert_eq(runtime.native.refused_focus_reads, site == "both" and 2 or 1)
    runtime.native.focus_refused, runtime.native.refused_site, runtime.native.absent_site = false, nil, nil
    runtime.pause(); resumed(runtime)
    sink(runtime, site == "bootstrap")
    helpers.assert_eq(runtime.state.is_secure_field, site ~= "bootstrap")
    healthy(runtime)
   end)
  end)
 end
end)
