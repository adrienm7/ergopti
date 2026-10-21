--- tests/unit/modules/keylogger/context_tracker/test_private_resume_classification.lua

--- Trusted public resume refreshes coarse privacy before persistence admission.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keylogger.context_tracker.private_resume_fixture")
local ORDINARY, PRIVATE = "Ordinary fixture page", "Fixture page - Incognito"

local function assert_sink(runtime, expected)
 local accepted, snapshots = runtime.sink()
 helpers.assert_eq(runtime.engine.may_persist(), expected, "Coarse resume must decide the actual public persistence policy")
 helpers.assert_eq(accepted, expected, "The actual public synthetic sink must follow coarse resume privacy")
 helpers.assert_eq(snapshots, expected and 1 or 0, "The deferred persistence builder count must match actual admission")
end
local function assert_clear(runtime)
 helpers.assert_eq(runtime.state.foreground_refresh_pending, false)
end
local function assert_revoked(runtime)
 helpers.assert_nil(runtime.state.active_win_title, "A prior title must not label the new context")
 helpers.assert_nil(runtime.state.session_document_path, "A prior document must not label the new context")
 helpers.assert_eq(runtime.state.is_fullscreen, false, "Prior fullscreen metadata must be revoked without reading new metadata")
end
local function browser(runtime, title)
 runtime.foreground("Google Chrome", "com.google.Chrome")
 runtime.native.title = title
 runtime.activate()
 helpers.assert_eq(runtime.observation.ui_live, 2)
end
local function paused_browser(runtime, title)
 runtime.pause()
 local reads = runtime.observation.window_reads
 browser(runtime, title)
 helpers.assert_eq(runtime.observation.window_reads, reads, "Ordinary paused activation must not query a title")
 helpers.assert_eq(runtime.state.active_app_name, "TextEdit")
 return reads
end
local function healthy(runtime)
 helpers.assert_eq(#runtime.observation.logs, 0, "A healthy lifecycle must not conceal setup or native refusal")
end
local function recover_ordinary(runtime)
 runtime.native.title_fault, runtime.native.window_fault, runtime.native.fault = nil, nil, nil
 runtime.native.refuse_rich_metadata = false
 runtime.native.title = ORDINARY
 runtime.activate()
 assert_clear(runtime); helpers.assert_eq(runtime.state.is_private_window, false)
 assert_sink(runtime, true)
end
local function assert_refused(runtime)
 helpers.assert_eq(runtime.state.foreground_refresh_pending, true, "Unclassified trusted resume must retain its foreground refusal")
 assert_revoked(runtime)
 assert_sink(runtime, false)
end

helpers.describe("Private classification at the trusted public resume boundary", function()
 helpers.it("keeps an ordinary live browser accepted", function()
  Fixture.with_runtime(function(runtime)
   browser(runtime, ORDINARY)
   helpers.assert_eq(runtime.state.is_private_window, false); assert_clear(runtime)
   assert_sink(runtime, true); healthy(runtime)
  end)
 end)

 helpers.it("keeps an unpaused private browser denied", function()
  Fixture.with_runtime(function(runtime)
   browser(runtime, PRIVATE)
   helpers.assert_eq(runtime.state.is_private_window, true); assert_clear(runtime)
   assert_sink(runtime, false); healthy(runtime)
  end)
 end)

 helpers.it("resumes ordinary policy using coarse classification without new rich metadata", function()
  Fixture.with_runtime(function(runtime)
   local reads = paused_browser(runtime, ORDINARY)
   local full, document, rows = runtime.observation.fullscreen_reads, runtime.observation.document_reads, #runtime.observation.context_rows
   runtime.native.refuse_rich_metadata = true
   runtime.resume()
   helpers.assert_eq(runtime.state.is_private_window, false); assert_clear(runtime)
   helpers.assert_eq(runtime.observation.window_reads, reads + 1)
   helpers.assert_eq(runtime.observation.fullscreen_reads, full)
   helpers.assert_eq(runtime.observation.document_reads, document)
   helpers.assert_eq(#runtime.observation.context_rows, rows)
   assert_revoked(runtime); assert_sink(runtime, true); healthy(runtime)
  end)
 end)

 helpers.it("denies a private browser reached during pause after a truly successful public resync", function()
  Fixture.with_runtime(function(runtime)
   local reads = paused_browser(runtime, PRIVATE)
   runtime.native.refuse_rich_metadata = true
   runtime.resume()
   local receipt = runtime.observation.tracker_receipts[1]
   helpers.assert_true(receipt.call_ok and receipt.result == true)
   helpers.assert_eq(runtime.observation.window_reads, reads + 1)
   helpers.assert_eq(runtime.state.is_private_window, true, "Trusted resume must replace the old nonprivate cache")
   assert_clear(runtime); assert_revoked(runtime); assert_sink(runtime, false); healthy(runtime)
  end)
 end)

 helpers.it("releases a stale private denial after resuming in an ordinary browser window", function()
  Fixture.with_runtime(function(runtime)
   browser(runtime, PRIVATE); assert_sink(runtime, false)
   runtime.pause(); runtime.native.title = ORDINARY
   runtime.title_event(ORDINARY)
   helpers.assert_eq(runtime.state.is_private_window, true, "Paused title callbacks must preserve the accepted cache")
   runtime.native.refuse_rich_metadata = true
   runtime.resume()
   helpers.assert_eq(runtime.state.is_private_window, false, "Trusted resume must clear the former private classification")
   assert_clear(runtime); assert_revoked(runtime); assert_sink(runtime, true); healthy(runtime)
  end)
 end)

 helpers.it("keeps ordinary paused title callbacks silent while trusted same-browser resume classifies", function()
  Fixture.with_runtime(function(runtime)
   browser(runtime, ORDINARY); runtime.pause()
   local reads, full, document = runtime.observation.window_reads, runtime.observation.fullscreen_reads, runtime.observation.document_reads
   runtime.title_event(PRIVATE)
   runtime.tracker.update_private_status()
   helpers.assert_eq(runtime.observation.window_reads, reads)
   helpers.assert_eq(runtime.observation.fullscreen_reads, full)
   helpers.assert_eq(runtime.observation.document_reads, document)
   helpers.assert_eq(runtime.state.is_private_window, false)
   assert_sink(runtime, false)
   runtime.resume()
   helpers.assert_eq(runtime.observation.window_reads, reads + 1)
   helpers.assert_eq(runtime.state.is_private_window, true)
   assert_clear(runtime); assert_sink(runtime, false); healthy(runtime)
  end)
 end)

 helpers.it("preserves the legitimate no-focused-window resume contract", function()
  Fixture.with_runtime(function(runtime)
   runtime.pause(); runtime.native.no_window = true
   runtime.foreground("Terminal", "com.apple.Terminal"); runtime.activate()
   runtime.resume()
   helpers.assert_eq(runtime.state.is_private_window, false)
   assert_clear(runtime); assert_revoked(runtime); assert_sink(runtime, true); healthy(runtime)
  end)
 end)

 for _, fault in ipairs({ "nil", "number", "throw" }) do
  helpers.it("denies an unreadable coarse title and recovers through a healthy public activation: " .. fault, function()
   Fixture.with_runtime(function(runtime)
    paused_browser(runtime, PRIVATE)
    runtime.native.title_fault = fault
    runtime.resume()
    helpers.assert_eq(runtime.state.is_private_window, false, "Failed classification must preserve the previously accepted bool")
    assert_refused(runtime)
    helpers.assert_eq(#runtime.observation.tracker_receipts, 1)
    local receipt = runtime.observation.tracker_receipts[1]
    helpers.assert_eq(receipt.call_ok, fault ~= "throw")
    if fault ~= "throw" then helpers.assert_eq(receipt.result, false) end
    recover_ordinary(runtime)
   end)
  end)
 end

 helpers.it("denies a refused focused-window lookup and recovers through a healthy activation", function()
  Fixture.with_runtime(function(runtime)
   paused_browser(runtime, PRIVATE); runtime.native.window_fault = "throw"
   runtime.resume()
   helpers.assert_eq(runtime.state.is_private_window, false)
   assert_refused(runtime); recover_ordinary(runtime)
  end)
 end)

 helpers.it("keeps the configured private-filter-off policy after a successful coarse classification", function()
  Fixture.with_runtime(function(runtime)
   runtime.engine.set_private_filter_enabled(false)
   paused_browser(runtime, PRIVATE); runtime.resume()
   helpers.assert_eq(runtime.state.is_private_window, true, "Preference OFF must not suppress the native classification itself")
   assert_clear(runtime); assert_revoked(runtime); assert_sink(runtime, true); healthy(runtime)
  end)
 end)

 helpers.it("revokes old rich metadata before the first refused foreground lookup", function()
  Fixture.with_runtime(function(runtime)
   helpers.assert_eq(runtime.state.active_win_title, "Ordinary fixture document")
   helpers.assert_eq(runtime.state.session_document_path, "/tmp/fixture-original-document.txt")
   helpers.assert_eq(runtime.state.is_fullscreen, true)
   runtime.pause()
   runtime.native.on_frontmost = function() assert_revoked(runtime); assert_sink(runtime, false) end
   runtime.native.fault = "nil-frontmost"
   runtime.resume()
   runtime.native.on_frontmost = nil
   assert_refused(runtime); recover_ordinary(runtime)
  end)
 end)

 helpers.it("preserves a former private bool when the trusted replacement classification refuses", function()
  Fixture.with_runtime(function(runtime)
   browser(runtime, PRIVATE); assert_sink(runtime, false)
   runtime.pause(); runtime.native.title = ORDINARY; runtime.native.title_fault = "nil"
   runtime.resume()
   helpers.assert_eq(runtime.state.is_private_window, true, "A refused classifier cannot turn an accepted private bool into permission")
   assert_refused(runtime); recover_ordinary(runtime)
  end)
 end)
end)
