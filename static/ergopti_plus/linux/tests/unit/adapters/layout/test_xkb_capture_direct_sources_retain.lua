--- tests/unit/adapters/layout/test_xkb_capture_direct_sources_retain.lua

--- ==============================================================================
--- MODULE: Live XKB Capture Regression Tests
--- DESCRIPTION:
--- Proves that evdev events are resolved through one stateful XKB session rather
--- than through a static keycode table. The fake backend below is an executable
--- oracle for the state transitions the adapter owns; the production backend is
--- libxkbcommon and has the same narrow contract.
---
--- DEFECTS GUARDED:
--- 1. evdev keycodes need the XKB offset of eight. Omitting it maps every physical
---    key to a different symbol while still returning plausible characters.
--- 2. A key is resolved against the state that existed before its own key-down,
---    then the transition is committed. This is what lets Shift, CapsLock, AltGr
---    and group-switch keys affect the following key without becoming text.
--- 3. Repeats produce text but must not apply a second state transition. Applying
---    CapsLock or a group action twice makes held-key behaviour depend on repeat.
--- 4. Compose is a state machine. A dead key produces nothing, and the completed
---    sequence produces one UTF-8 result instead of two unrelated characters.
--- ==============================================================================

package.loaded["tests.support.adapters.layout.xkb_capture_fixture"] = nil
local Fixture = require("tests.support.adapters.layout.xkb_capture_fixture")
local helpers, with_original_direct_producer =
	Fixture.helpers, Fixture.with_original_direct_producer




helpers.describe('xkb_capture: direct sources retain original native callback owners', function()
 helpers.it('retains duplicate readonly facts and detaches the original validated request', function()
  with_original_direct_producer(function(capture, state)
   local requested = { 36, 40 }
   local rows = assert(capture.direct_sources(requested))
   helpers.assert_eq(#rows, 2)
   helpers.assert_eq(rows[1].code, 36)
   helpers.assert_eq(rows[2].code, 40)
   helpers.assert_eq(rows[1].text, ';')
   helpers.assert_eq(rows[2].text, ';')
   helpers.assert_true(state.requested ~= requested)
   helpers.assert_eq(state.updates, 0)
   helpers.assert_nil(capture.capture_chord_output(rows))
  end)
 end)
 helpers.it('preserves validated intent when a source callback changes the caller array', function()
  with_original_direct_producer(function(capture, state)
   local requested = { 36 }
   state.on_source = function() requested[1] = 40 end
   local rows = assert(capture.direct_sources(requested))
   helpers.assert_eq(rows[1].code, 36)
   helpers.assert_eq(requested[1], 40)
  end)
 end)
 helpers.it('refuses a foreign enumerator installed by the first native observation', function()
  with_original_direct_producer(function(capture, state, backend)
   local foreign_calls = 0
   state.on_source = function(call)
    if call == 1 then backend.direct_sources = function(_, requested)
     foreign_calls = foreign_calls + 1
     return { { code = requested[1], text = ';', mods = {}, plain = true, direct = true, dead = false } }
    end end
   end
   local rows = capture.direct_sources({ 36 })
   helpers.assert_nil(rows, 'foreign direct issuer calls=' .. foreign_calls)
   helpers.assert_eq(foreign_calls, 0)
   helpers.assert_eq(state.enumerations, 0)
  end)
 end)
 helpers.it('refuses a foreign fact issuer even while original source currency remains current', function()
  with_original_direct_producer(function(capture, state, backend)
   local generation, _, original_current = capture.source_generation()
   helpers.assert_true(type(original_current) == 'function')
   local foreign_calls = 0
   state.on_source = function(call)
    if call == 2 then backend.direct_sources = function(_, requested)
     foreign_calls = foreign_calls + 1
     return { { code = requested[1], text = ';', mods = {}, plain = true, direct = true, dead = false } }
    end end
   end
   local rows = capture.direct_sources({ 36 })
   helpers.assert_eq(capture.source_generation(), generation)
   helpers.assert_true(original_current())
   helpers.assert_nil(rows, 'foreign facts survive genuine source currency; issuer calls=' .. foreign_calls)
   helpers.assert_eq(foreign_calls, 0)
  end)
 end)
 helpers.it('refuses original enumerator loss within its own callback', function()
  with_original_direct_producer(function(capture, state, backend)
   local original = backend.direct_sources
   state.on_rows = function() backend.direct_sources = function(...) return original(...) end end
   helpers.assert_nil(capture.direct_sources({ 36 }))
  end)
 end)
 helpers.it('refuses original enumerator loss during the final native observation', function()
  with_original_direct_producer(function(capture, state, backend)
   local original = backend.direct_sources
   state.on_rows = function()
    state.on_source = function() backend.direct_sources = function(...) return original(...) end end
   end
   helpers.assert_nil(capture.direct_sources({ 36 }))
  end)
 end)
 helpers.it('refuses a replaced native getter before invoking it after enumeration', function()
  with_original_direct_producer(function(capture, state, backend)
   local foreign_calls = 0
   state.on_rows = function() backend.source_group = function()
    foreign_calls = foreign_calls + 1; return 0, 7
   end end
   helpers.assert_nil(capture.direct_sources({ 36 }))
   helpers.assert_eq(foreign_calls, 0)
  end)
 end)
 helpers.it('refuses getter replacement within the initial native observation', function()
  with_original_direct_producer(function(capture, state, backend)
   local foreign_calls = 0
   state.on_source = function(call)
    if call == 1 then backend.source_group = function() foreign_calls = foreign_calls + 1; return 0, 7 end end
   end
   helpers.assert_nil(capture.direct_sources({ 36 }))
   helpers.assert_eq(foreign_calls, 0)
   helpers.assert_eq(state.enumerations, 0)
  end)
 end)
 helpers.it('refuses source identity changed by the initial native observation', function()
  with_original_direct_producer(function(capture, state, _, session)
   state.on_source = function(call) if call == 1 then session.identity = 'foreign-map' end end
   helpers.assert_nil(capture.direct_sources({ 36 }))
   helpers.assert_eq(state.enumerations, 0)
  end)
 end)
 helpers.it('refuses native group-count changes even when the observed group stays equal', function()
  with_original_direct_producer(function(capture, state, _, session)
   state.on_rows = function() session.groups = 3 end
   helpers.assert_nil(capture.direct_sources({ 36 }))
  end)
 end)
 helpers.it('refuses metatable requests before position or native callbacks', function()
  with_original_direct_producer(function(capture, state)
   local callbacks = 0
   local requested = setmetatable({ 36 }, {
    __len = function() callbacks = callbacks + 1; return 1 end,
    __pairs = function(value) callbacks = callbacks + 1; return next, value, nil end,
   })
   helpers.assert_nil(capture.direct_sources(requested))
   helpers.assert_eq(callbacks, 0)
   helpers.assert_eq(state.calls, 0)
   helpers.assert_eq(state.enumerations, 0)
  end)
 end)
 helpers.it('refuses backend-installed request metatables without calling foreign readers', function()
  with_original_direct_producer(function(capture, state)
   local callbacks = 0
   state.on_rows = function(requested)
    setmetatable(requested, { __pairs = function(value) callbacks = callbacks + 1; return next, value, nil end })
   end
   helpers.assert_nil(capture.direct_sources({ 36 }))
   helpers.assert_eq(callbacks, 0)
  end)
 end)
 helpers.it('refuses request mutation during the final native observation', function()
  with_original_direct_producer(function(capture, state)
   state.on_rows = function(requested)
    state.on_source = function() requested[1] = 40 end
   end
   helpers.assert_nil(capture.direct_sources({ 36 }))
  end)
 end)
 helpers.it('retains native exceptions and refused rows as existing closed failures', function()
  with_original_direct_producer(function(capture, _, backend)
   backend.direct_sources = function() error('controlled native enumeration failure') end
   local rows, reason = capture.direct_sources({ 36 })
   helpers.assert_nil(rows)
   helpers.assert_true(reason:find('controlled native enumeration failure', 1, true) ~= nil)
   backend.direct_sources = function() return nil, 'controlled source unavailable' end
   rows, reason = capture.direct_sources({ 36 })
   helpers.assert_nil(rows)
   helpers.assert_eq(reason, 'controlled source unavailable')
  end)
 end)
 helpers.it('restores the prior module identity after a raised controlled scenario', function()
  local prior = package.loaded['adapters.xkb_capture']
  local called = pcall(function() with_original_direct_producer(function() error('controlled fixture failure') end) end)
  helpers.assert_eq(called, false)
  helpers.assert_eq(package.loaded['adapters.xkb_capture'], prior)
 end)
end)

