--- tests/unit/adapters/layout/test_number_row_native_levels_shared_typed_facts.lua

package.loaded["tests.support.adapters.layout.number_row_native_levels_fixture"] = nil
local Fixture = require("tests.support.adapters.layout.number_row_native_levels_fixture")
local h, Native, codes, digits, symbols, rows, with_native_row_producer =
	Fixture.h, Fixture.Native, Fixture.codes, Fixture.digits, Fixture.symbols, Fixture.rows, Fixture.with_native_row_producer




h.describe('shared typed native number-row facts required by source capture', function()
 h.it('imports the actual source adapter and its shared typed dependency', function()
  h.assert_true(type(require('adapters.xkb_capture').chord_sources) == 'function')
  h.assert_true(type(require('adapters.xkb_source_probe').read_input_state) == 'function')
  h.assert_eq(Native.LEVELS, 40)
 end)
 h.it('retains all independent Caps and Shift source rows', function()
  local levels = assert(Native.levels('linux', rows(), codes))
  for _, caps in ipairs({ false, true }) do
   for position = 1, 10 do
    h.assert_eq(Native.select(levels, 'digits', position, caps, false).text, digits[position])
    h.assert_eq(Native.select(levels, 'symbols', position, caps, false).text, symbols[position])
    h.assert_eq(Native.select(levels, 'digits', position, caps, true).text, symbols[position])
   end
  end
 end)
 h.it('preserves empty native dead action parameters instead of text inference', function()
  local source = rows()
  source[16].text, source[16].keysym, source[16].dead = '', 0xfe52, true
  local levels = assert(Native.levels('linux', source, codes))
  local selected = assert(Native.select(levels, 'symbols', 6, false, false))
  h.assert_eq(selected.text, '')
  h.assert_eq(selected.native_action.keysym, 0xfe52)
  h.assert_eq(selected.native_action.dead, true)
 end)
 h.it('refuses missing duplicate malformed and foreign typed native rows', function()
  local sparse = rows(); sparse[4] = nil; h.assert_eq(Native.levels('linux', sparse, codes), nil)
  local foreign = rows(); foreign[1].keysym = -1; h.assert_eq(Native.levels('linux', foreign, codes), nil)
  local caps = rows(); caps[40].caps = false; h.assert_eq(Native.levels('linux', caps, codes), nil)
  h.assert_eq(Native.levels('linux', rows(), { 2, 2, 4, 5, 6, 7, 8, 9, 10, 11 }), nil)
 end)
 h.it('keeps ambiguous direct-digit and empty ordinary-output sources unavailable', function()
  local levels = assert(Native.levels('linux', rows(), codes)); levels[false][2].shift.text = '2'
  h.assert_eq(Native.capable(levels, 'digits'), false)
  local empty = assert(Native.levels('linux', rows(), codes)); empty[true][3].shift.text = ''
  h.assert_eq(Native.capable(empty, 'symbols'), false)
 end)
end)




h.describe('native number-row producer retains original positions and callback owners', function()
 h.it('reads all ten typed positions without input or output authority', function()
  with_native_row_producer(function(capture, _, request, state)
   local receipt = assert(capture.number_row_levels(request))
   local view = assert(capture.number_row_view(receipt, request))
   for _, caps in ipairs({ false, true }) do
    for position = 1, 10 do
     h.assert_eq(Native.select(view.levels, 'digits', position, caps, false).text, digits[position])
    end
   end
   local dead = assert(Native.select(view.levels, 'symbols', 6, false, false))
   h.assert_eq(dead.native_action.keysym, 0xfe52)
   h.assert_eq(dead.native_action.dead, true)
   h.assert_eq(capture.capture_chord_output(receipt), nil)
   h.assert_eq(state.transitions, 0)
   h.assert_eq(state.compose, 0)
  end)
 end)
 h.it('passes detached positions to the native enumeration callback', function()
  with_native_row_producer(function(capture, _, request, state)
   h.assert_true(capture.number_row_levels(request) ~= nil)
   h.assert_true(state.actual_codes ~= request)
   h.assert_eq(request[1], 2)
  end)
 end)
 h.it('rejects native callback retargeting without mutating caller positions', function()
  with_native_row_producer(function(capture, _, request, state)
   state.on_enumerate = function(actual) actual[1] = 31 end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(request[1], 2)
  end)
 end)
 h.it('rejects native callback insertion of a foreign request key', function()
  with_native_row_producer(function(capture, _, request, state)
   state.on_enumerate = function(actual) actual.foreign = 31 end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(request.foreign, nil)
  end)
 end)
 h.it('rejects native callback reordering of existing positions', function()
  with_native_row_producer(function(capture, _, request, state)
   state.on_enumerate = function(actual) actual[1], actual[2] = actual[2], actual[1] end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(request[1], 2)
   h.assert_eq(request[2], 3)
  end)
 end)
 h.it('rejects caller mutation during the first source observation', function()
  with_native_row_producer(function(capture, _, request, state)
   state.on_source = function(call) if call == 1 then request[1] = 31 end end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(state.enumerations, 0)
  end)
 end)
 h.it('rejects caller mutation during native enumeration', function()
  with_native_row_producer(function(capture, _, request, state)
   state.on_enumerate = function() request[1] = 31 end
   h.assert_eq(capture.number_row_levels(request), nil)
  end)
 end)
 h.it('rejects caller mutation during the final source observation', function()
  with_native_row_producer(function(capture, _, request, state)
   state.on_source = function(call) if call == 2 then request[1] = 31 end end
   h.assert_eq(capture.number_row_levels(request), nil)
  end)
 end)
 h.it('rejects enumeration owner replacement during first source observation', function()
  with_native_row_producer(function(capture, backend, request, state)
   local original = backend.number_row_levels
   state.on_source = function(call)
    if call == 1 then backend.number_row_levels = function(...) return original(...) end end
   end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(state.enumerations, 0)
  end)
 end)
 h.it('rejects source getter replacement during enumeration', function()
  with_native_row_producer(function(capture, backend, request, state)
   local foreign_calls = 0
   state.on_enumerate = function()
    backend.source_group = function() foreign_calls = foreign_calls + 1; return 0, 1 end
   end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(foreign_calls, 0)
  end)
 end)
 h.it('rejects retained proof after enumeration owner replacement', function()
  with_native_row_producer(function(capture, backend, request)
   local receipt = assert(capture.number_row_levels(request))
   local original = backend.number_row_levels
   backend.number_row_levels = function(...) return original(...) end
   h.assert_eq(capture.number_row_view(receipt, request), nil)
  end)
 end)
 h.it('rejects retained proof after source getter replacement', function()
  with_native_row_producer(function(capture, backend, request)
   local receipt = assert(capture.number_row_levels(request))
   backend.source_group = function() return 0, 1 end
   h.assert_eq(capture.number_row_view(receipt, request), nil)
  end)
 end)
 h.it('rechecks enumeration identity after a retained-proof source callback', function()
  with_native_row_producer(function(capture, backend, request, state)
   local receipt = assert(capture.number_row_levels(request))
   local original = backend.number_row_levels
   state.on_source = function() backend.number_row_levels = function(...) return original(...) end end
   h.assert_eq(capture.number_row_view(receipt, request), nil)
  end)
 end)
 h.it('rejects foreign query keys even when all ten positions still match', function()
  with_native_row_producer(function(capture, _, request)
   local receipt = assert(capture.number_row_levels(request))
   request.foreign = 31
   h.assert_eq(capture.number_row_view(receipt, request), nil)
  end)
 end)
 h.it('rejects a changed source generation observed during typed row validation', function()
  with_native_row_producer(function(capture, _, request, state)
   local previous = assert(capture.number_row_levels(request))
   local touched = false
   state.on_rows = function(result)
    local original_text = result[1].text
    result[1].text = nil
    setmetatable(result[1], { __index = function(_, key)
     if key == 'text' then
      if not touched then
       touched, state.generation = true, 2
       h.assert_eq(capture.number_row_view(previous, request), nil)
      end
      return original_text
     end
    end })
   end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_true(touched)
  end)
 end)
 h.it('rejects metatable requests before reading positions or source callbacks', function()
  with_native_row_producer(function(capture, _, request, state)
   local callbacks = 0
   setmetatable(request, { __len = function() callbacks = callbacks + 1; return 10 end,
    __pairs = function(value) callbacks = callbacks + 1; return next, value, nil end })
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(callbacks, 0)
   h.assert_eq(state.source_calls, 0)
   h.assert_eq(state.enumerations, 0)
  end)
 end)
 h.it('rejects callback-installed request metatables without invoking their readers', function()
  with_native_row_producer(function(capture, _, request, state)
   local callbacks = 0
   state.on_enumerate = function(actual)
    setmetatable(actual, { __pairs = function(value) callbacks = callbacks + 1; return next, value, nil end })
   end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(callbacks, 0)
  end)
 end)
 h.it('rejects metatable view queries before reading a native source', function()
  with_native_row_producer(function(capture, _, request, state)
   local receipt = assert(capture.number_row_levels(request))
   local before = state.source_calls
   local callbacks = 0
   setmetatable(request, { __len = function() callbacks = callbacks + 1; return 10 end,
    __pairs = function(value) callbacks = callbacks + 1; return next, value, nil end })
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   h.assert_eq(callbacks, 0)
   h.assert_eq(state.source_calls, before)
  end)
 end)
 h.it('keeps observed enumeration-owner loss retired after method restoration', function()
  with_native_row_producer(function(capture, backend, request)
   local receipt = assert(capture.number_row_levels(request))
   local original = backend.number_row_levels
   backend.number_row_levels = function(...) return original(...) end
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   backend.number_row_levels = original
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   local fresh = assert(capture.number_row_levels(request))
   h.assert_true(capture.number_row_view(fresh, request) ~= nil)
  end)
 end)
 h.it('keeps observed source-getter loss retired after method restoration', function()
  with_native_row_producer(function(capture, backend, request)
   local receipt = assert(capture.number_row_levels(request))
   local original = backend.source_group
   backend.source_group = function(...) return original(...) end
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   backend.source_group = original
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   local fresh = assert(capture.number_row_levels(request))
   h.assert_true(capture.number_row_view(fresh, request) ~= nil)
  end)
 end)
 h.it('refuses a bad query without retiring a valid native source receipt', function()
  with_native_row_producer(function(capture, _, request)
   local receipt = assert(capture.number_row_levels(request))
   request.foreign = 31
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   request.foreign = nil
   request[1] = 31
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   request[1] = 2
   h.assert_true(capture.number_row_view(receipt, request) ~= nil)
  end)
 end)
 h.it('refuses a source-callback query metatable before invoking its reader', function()
  with_native_row_producer(function(capture, _, request, state)
   local receipt = assert(capture.number_row_levels(request))
   local callbacks = 0
   state.on_source = function()
    setmetatable(request, { __pairs = function(value) callbacks = callbacks + 1; return next, value, nil end })
   end
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   h.assert_eq(callbacks, 0)
   state.on_source = nil
   setmetatable(request, nil)
   h.assert_true(capture.number_row_view(receipt, request) ~= nil)
  end)
 end)
 h.it('rejects validator replacement during the first source observation without calling it', function()
  with_native_row_producer(function(capture, _, request, state)
   local foreign_calls = 0
   state.on_source = function(call)
    if call == 1 then Native.levels = function() foreign_calls = foreign_calls + 1; return {} end end
   end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(foreign_calls, 0)
   h.assert_eq(state.enumerations, 0)
  end)
 end)
 h.it('rejects enumeration callback validator replacement without admitting forged facts', function()
  with_native_row_producer(function(capture, _, request, state)
   local foreign_calls = 0
   state.on_enumerate = function()
    Native.levels = function() foreign_calls = foreign_calls + 1; return {} end
   end
   h.assert_eq(capture.number_row_levels(request), nil)
   h.assert_eq(foreign_calls, 0)
  end)
 end)
 h.it('keeps observed validator-owner loss retired after restoring the exact method', function()
  with_native_row_producer(function(capture, _, request)
   local receipt = assert(capture.number_row_levels(request))
   local original = Native.levels
   Native.levels = function() error('foreign native row validator must not run') end
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   Native.levels = original
   h.assert_eq(capture.number_row_view(receipt, request), nil)
   local fresh = assert(capture.number_row_levels(request))
   h.assert_true(capture.number_row_view(fresh, request) ~= nil)
  end)
 end)
 h.it('contains malformed native row reader errors at the existing refusal boundary', function()
  with_native_row_producer(function(capture, _, request, state)
   state.on_rows = function(result)
    result[1].text = nil
    setmetatable(result[1], { __index = function() error('controlled malformed native row') end })
   end
   local called, receipt, reason = pcall(capture.number_row_levels, request)
   h.assert_true(called)
   h.assert_eq(receipt, nil)
   h.assert_eq(reason, 'number-row-native-levels-refused')
  end)
 end)
 h.it('restores the exact shared validator after a raised controlled scenario', function()
  local original = Native.levels
  local prior_capture = package.loaded['adapters.xkb_capture']
  local called = pcall(function()
   with_native_row_producer(function()
    Native.levels = function() error('foreign validator must be restored') end
    error('controlled scenario failure')
   end)
  end)
  h.assert_eq(called, false)
  h.assert_eq(Native.levels, original)
  h.assert_eq(package.loaded['adapters.xkb_capture'], prior_capture)
 end)
 h.it('returns detached views that cannot rewrite retained native actions', function()
  with_native_row_producer(function(capture, _, request)
   local receipt = assert(capture.number_row_levels(request))
   local view = assert(capture.number_row_view(receipt, request))
   view.codes[1], view.levels[false][6].shift.native_action.keysym = 31, 0
   local unchanged = assert(capture.number_row_view(receipt, request))
   h.assert_eq(unchanged.codes[1], 2)
   h.assert_eq(unchanged.levels[false][6].shift.native_action.keysym, 0xfe52)
  end)
 end)
end)

