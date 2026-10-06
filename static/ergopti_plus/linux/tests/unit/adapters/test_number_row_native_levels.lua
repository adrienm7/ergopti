--- tests/unit/adapters/test_number_row_native_levels.lua

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
