--- tests/support/adapters/layout/number_row_native_levels_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_number_row_native_levels
--- DESCRIPTION:
--- Prelude shared by the test_number_row_native_levels_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local h = require('tests.helpers')

local Native = require('layout.number_row_native')

local codes = { 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }

local digits = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '0' }

local symbols = { '!', '@', '#', '$', '%', '^', '&', '*', '(', ')' }

local function rows()
 local result = {}
 for _, caps in ipairs({ false, true }) do
  for _, shift in ipairs({ false, true }) do
   for index, code in ipairs(codes) do
    local text = (shift and symbols or digits)[index]
    result[#result + 1] = { code = code, caps = caps, shift = shift,
     text = text, keysym = text:byte(), dead = false }
   end
  end
 end
 return result
end

local function with_native_row_producer(body)
 local prior = package.loaded['adapters.xkb_capture']
 local prior_native_levels = Native.levels
 package.loaded['adapters.xkb_capture'] = nil
 local capture = require('adapters.xkb_capture')
 local request = { 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }
 local state = { source_calls = 0, enumerations = 0, transitions = 0, compose = 0 }
 local backend = {
  create = function() return { identity = 'controlled-number-row-map', groups = 1 } end,
  destroy = function() end,
  source_group = function()
   state.source_calls = state.source_calls + 1
   if state.on_source then state.on_source(state.source_calls) end
   return 0, state.generation or 1, function() return true end
  end,
  number_row_levels = function(_, actual_codes)
   state.enumerations = state.enumerations + 1
   state.actual_codes = actual_codes
   if state.on_enumerate then state.on_enumerate(actual_codes) end
   local result = {}
   for _, caps in ipairs({ false, true }) do
    for _, shift in ipairs({ false, true }) do
     for index, code in ipairs(actual_codes) do
      local dead = shift and index == 6
      local text = dead and '' or (shift and symbols[index] or digits[index])
      result[#result + 1] = { code = code, caps = caps, shift = shift,
       text = text, keysym = dead and 0xfe52 or text:byte(), dead = dead }
     end
    end
   end
   if state.on_rows then state.on_rows(result) end
   return result
  end,
  update_key = function() state.transitions = state.transitions + 1 end,
  compose_feed = function() state.compose = state.compose + 1 end,
  compose_reset = function() state.compose = state.compose + 1 end,
 }
 capture._set_backend(backend)
 local ok, reason = pcall(function()
  h.assert_true(capture.load('controlled-number-row-map'))
  body(capture, backend, request, state)
 end)
 capture._reset_backend()
 Native.levels = prior_native_levels
 package.loaded['adapters.xkb_capture'] = prior
 if not ok then error(reason, 0) end
end

return {
	h = h,
	Native = Native,
	codes = codes,
	digits = digits,
	symbols = symbols,
	rows = rows,
	with_native_row_producer = with_native_row_producer,
}
