--- tests/unit/adapters/layout/test_number_row_native_levels.lua

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

-- Controlled behavioral receiving of the actual Hook row-owner builder.
-- No connected/native/physical claim; original native forty facts remain above.
do
 local function genuine_row_owner_builder()
  local name = 'adapters.keyboard_hook'
  local previous = package.loaded[name]
  local called, result = pcall(function()
   local Hook = h.load_module(name)
   assert(type(Hook) == 'table' and type(Hook.start) == 'function', 'whole original Hook/start unavailable')
   local identity = assert(debug.getinfo(Hook.start, 'S')).source
   assert(type(identity) == 'string' and identity:sub(1, 1) == '@', 'original Hook file source unavailable')
   local file = assert(io.open(identity:sub(2), 'rb'))
   local original_read, original_close = file.read, file.close
   local read_ok, source, read_error = pcall(original_read, file, '*a')
   -- Once acquired, close is attempted even if the original read refuses/throws.
   local close_ok, closed, close_error = pcall(original_close, file)
   if not read_ok or type(source) ~= 'string' then
    local failure
    if not read_ok then failure = source
    elseif read_error ~= nil then failure = read_error
    else failure = 'original Hook source read refused' end
    if not close_ok or closed ~= true then
     local cleanup
     if not close_ok then cleanup = closed
     elseif close_error ~= nil then cleanup = close_error
     else cleanup = 'original Hook source close refused' end
     error(tostring(failure) .. '\n' .. tostring(cleanup), 0)
    end
    error(failure, 0)
   end
   if not close_ok then error(closed, 0) end
   assert(closed == true, close_error or 'original Hook source close refused')
   local start_marker = 'local function build_row_owners('
   local end_marker = '\n--- Connected opt-in backend.'
   local first = assert(source:find(start_marker, 1, true), 'actual Hook row-owner builder absent')
   assert(not source:find(start_marker, first + #start_marker, true), 'actual Hook row-owner builder ambiguous')
   local finish = assert(source:find(end_marker, first, true), 'actual Hook row-owner boundary absent')
   assert(not source:find(end_marker, finish + #end_marker, true), 'actual Hook row-owner boundary ambiguous')
   assert(finish > first + #start_marker, 'actual Hook row-owner body empty')
   local body = source:sub(first, finish - 1) .. '\nreturn build_row_owners'
   -- The actual builder uses only these standard globals; missing dependencies
   -- fail while executing its preserved behavioral cases rather than being faked.
   local environment = { pairs = pairs, ipairs = ipairs, type = type, pcall = pcall }
   local chunk
   if loadstring then
    chunk = assert(loadstring(body, identity .. ':row-owner'))
    assert(setfenv)(chunk, environment)
   else
    chunk = assert(load(body, identity .. ':row-owner', 't', environment))
   end
   local builder = chunk()
   assert(type(builder) == 'function', 'actual Hook row-owner builder unavailable')
   return builder
  end)
  package.loaded[name] = previous
  if not called then error(result, 0) end
  return result
 end

 local function with_original_reader_symbols(body)
  local names = { 'ffi', 'adapters.evdev_reader', 'infra.input_event' }
  local saved = {}; for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
  local queues, descriptors, serial = {}, {}, 100
  local allowed = { ['/dev/input/event3'] = true, ['/dev/input/event4'] = true }
  local symbols = {
   open = function(path)
    assert(allowed[path], 'unknown controlled source path')
    serial = serial + 1; descriptors[serial] = path
    queues[path] = queues[path] or {}; return serial
   end,
   ioctl = function(fd, _, argument)
    assert(descriptors[fd], 'unknown controlled descriptor')
    if type(argument) == 'table' then argument.bytes = string.rep('\0', argument.count) end
    return 0
   end,
   read = function(fd, buffer)
    local path = assert(descriptors[fd], 'unknown controlled descriptor')
    local bytes = table.remove(queues[path], 1)
    if not bytes then return -1 end
    buffer.bytes = bytes; return #bytes
   end,
   poll = function(array)
    local path = assert(descriptors[array[0].fd], 'unknown controlled descriptor')
    array[0].revents = #queues[path] > 0 and 1 or 0
    return array[0].revents
   end,
   close = function(fd)
    assert(descriptors[fd], 'duplicate controlled descriptor retirement')
    descriptors[fd] = nil; return 0
   end,
  }
  package.loaded.ffi = {
   cdef = function() end,
   sizeof = function(kind) assert(kind == 'struct input_event'); return 24 end,
   new = function(kind, count)
    if kind == 'struct pollfd[1]' then return { [0] = {} } end
    return { count = count or 0, bytes = string.rep('\0', count or 0) }
   end,
   cast = function(_, value) return value end,
   string = function(buffer, count) return buffer.bytes:sub(1, count) end,
   errno = function() return 11 end, C = symbols,
  }
  local Reader
  local called, result = xpcall(function()
   local Input = h.load_module('infra.input_event')
   Reader = h.load_module('adapters.evdev_reader')
   local function push_bytes(path, bytes)
    assert(allowed[path] and type(bytes) == 'string' and #bytes == 24)
    local queue = assert(queues[path], 'source must be opened by the original Reader')
    queue[#queue + 1] = bytes
   end
   assert(Reader.use_ffi_backend() == true, 'original FFI constructor refused')
   body(Reader, Input, push_bytes)
   assert(next(descriptors) == nil, 'control left an original Reader descriptor unsettled')
  end, debug.traceback)
  local cleaned, cleanup = true, nil
  if Reader then cleaned, cleanup = pcall(Reader._reset_backend) end
  local settled = cleaned and cleanup ~= false and next(descriptors) == nil
  for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
  if not settled then error(tostring(result or '') .. '\noriginal controlled Reader cleanup unresolved', 0) end
  if not called then error(result, 0) end
 end

 h.describe('actual Hook row-owner controlled behavioral regressions', function()
  local factory = function(...) return genuine_row_owner_builder()(...) end
  local Custody = require('input.modifier_custody')
local names, cases = {}, {}
local function case(name, fn) names[#names + 1] = name; cases[name] = fn end
local function fixture(options)
 options = options or {}
 local state = { active = true, event_valid = true, wires = {}, commits = {}, releases = 0, retired = 0 }
 local broker = Custody.new(nil, nil)
 -- Explicit controlled observation ports; real edge/handoff/view/debt remain unchanged.
 broker.output_current = function() return broker.has_debt() == false end
 broker.output_retired = function() return state.channel_retired == true end
 local rows = {}
 rows.desired = function(plan) return plan and { code = 2, shift = plan.shift, physical_shift = plan.physical_shift } end
 rows.observe = function(plan, shift)
  state.observed = shift
  return plan and { code = 2, shift = plan.shift, native_action = { keysym = 0x31, dead = false } }
 end
 rows.retire = function(plan) if plan then state.retired = state.retired + 1 end; return true end
 local emit = function(code, value)
  state.wires[#state.wires + 1] = tostring(code) .. ":" .. tostring(value)
  if state.on_wire then state.on_wire(code, value) end
  return not options.refuse_wire
 end
 local held = options.held or {}
 local owner = factory(rows, broker, emit, function() return state.active end,
  function() return state.event_valid end, function() return held, function() return true end end,
  function(_, _, _, value, emitted)
   state.commits[#state.commits + 1] = { value = value, emitted = emitted }
   if state.on_commit then state.on_commit() end
   return true, emitted and "1" or nil, "1"
  end,
  function() state.releases = state.releases + 1; return true end)
 local function event(key, value, shift, physical)
  return owner.event(key, { code = 2, value = value }, "digits", 1, physical == true,
   value ~= 0 and { shift = shift == true, physical_shift = physical == true } or nil)
 end
 return state, broker, owner, event, emit
end
local function wire(state) return table.concat(state.wires, ",") end
case("down_repeat_up_preserves_exact_row_owner", function()
 local s,b,o,event = fixture()
 local d = event("first", 1); local r = event("first", 2); local u = event("first", 0)
 assert(d and r and u); assert(wire(s) == "2:1,2:2,2:0")
 assert(#s.commits == 2 and s.commits[1].emitted and s.commits[2].emitted)
 assert(s.releases == 1 and next(b.view().owners) == nil and o.retire())
end)
case("temporary_shift_uses_original_broker_and_restores", function()
 local s,b,o,event = fixture()
 local d = event("first", 1, true, false); local u = event("first", 0)
 assert(d and u); assert(wire(s) == "42:1,2:1,42:0,2:0")
 assert(s.releases == 1 and next(b.view().owners) == nil and o.retire())
end)
case("physical_shift_survives_exact_temporary_handoff", function()
 local s,b,o,event,emit = fixture({ held = {42} }); local physical = {}
 local held = b.edge(physical,42,1,emit); s.wires = {}
 local d = event("first",1,false,true); local u = event("first",0)
 assert(held.ok and d and u); assert(wire(s) == "42:0,2:1,42:1,2:0")
 assert(b.view().owners[physical].state == "held" and s.releases == 1)
 local released = b.edge(physical,42,0,emit); assert(released.ok and o.retire())
end)
case("collision_ack_zero_does_not_feed_semantic_compose", function()
 local s,b,o,event,emit = fixture(); local other = {}
 local initial = b.edge(other,2,1,emit); s.wires = {}
 local d,outcome = event("first",1); local u = event("first",0)
 assert(initial.ok and d and u and outcome.native_writes == 0 and outcome.text == nil)
 assert(wire(s) == "" and #s.commits == 1 and s.commits[1].emitted == false and s.releases == 0)
 assert(b.view().owners[other] ~= nil); local released=b.edge(other,2,0,emit); assert(released.ok and o.retire())
end)
case("up_retires_original_owner_after_admission_revocation", function()
 local s,b,o,event = fixture(); local d=event("first",1); s.active=false
 local u=event("first",0); assert(d and u); assert(wire(s) == "2:1,2:0")
 assert(s.releases == 1 and next(b.view().owners) == nil and o.retire())
end)
case("stop_retires_row_once_and_closes_real_broker_roster", function()
 local s,b,o,event = fixture(); local d=event("first",1)
 local stop=o.retire(); local again=o.retire()
 assert(d and stop and again); assert(wire(s) == "2:1,2:0")
 assert(s.releases == 1 and next(b.view().owners) == nil)
end)
case("source_revoked_by_wire_callback_has_no_semantic_success", function()
 local s,b,o,event = fixture(); s.on_wire=function(_,value) if value==1 then s.active=false end end
 local d=event("first",1); local closed=o.retire()
 assert(d == false and closed); assert(wire(s) == "2:1,2:0")
 assert(#s.commits == 0 and next(b.view().owners) == nil)
end)
case("reentrant_stop_queues_exact_up_without_false_closed_roster", function()
 local s,b,o,event = fixture(); local inside
 s.on_wire=function(_,value) if value==1 then s.active=false; inside=o.retire() end end
 local d=event("first",1); local final=o.retire()
 assert(inside == false and d == false and final == true)
 assert(wire(s) == "2:1,2:0" and #s.commits == 0 and next(b.view().owners) == nil)
end)
case("unknown_wire_prefix_keeps_retirement_debt", function()
 local s,b,o,event = fixture({refuse_wire=true}); local d=event("first",1)
 local closed=o.retire(); assert(d==false and closed==false)
 assert(b.has_debt() and #s.commits==0 and #s.wires==1)
end)
case("repeat_without_original_row_down_stays_ordinary", function()
 local s,b,o,event = fixture(); local r,reason=event("first",2)
 assert(r==false and reason=="ordinary"); assert(#s.wires==0 and #s.commits==0 and next(b.view().owners)==nil)
end)
case("missing_physical_shift_lease_refuses_before_output", function()
 local s,b,o,event = fixture(); local d=event("first",1,false,true)
 assert(d==false and #s.wires==0 and #s.commits==0 and next(b.view().owners)==nil and o.retire())
end)
case("forged_event_currency_refuses_before_output", function()
 local s,b,o,event = fixture(); s.event_valid=false; local d=event("first",1)
 assert(d==false and #s.wires==0 and #s.commits==0 and next(b.view().owners)==nil)
end)
case("final_commit_callback_revocation_refuses_semantic_success", function()
 local s,b,o,event = fixture(); s.on_commit=function() s.active=false end
 local d=event("first",1); local closed=o.retire()
 assert(d==false and closed==true); assert(wire(s)=="2:1,2:0")
 assert(#s.commits==1 and next(b.view().owners)==nil)
end)
  assert(#names == 13, 'original row-owner thirteen-case census changed')
  for _, name in ipairs(names) do h.it(name, cases[name]) end
 end)

 local opaque_reader_control = (function()
-- SOURCE ONLY / UNRUN. The future driver binds controlled native FFI symbols
-- before calling this module. It passes the whole original Reader and codec.
-- push_bytes supplies bytes to that FFI read provider; it issues no receipt.
-- A custom Reader backend cannot satisfy these controls. This is software
-- provenance receiving, never kernel/Xorg/uinput or physical evidence.
return function(Reader, Input, push_bytes)
	local capture, current, retire = Reader.capture_source_owner, Reader.source_owner_current, Reader.retire_source
	local row_slot, shift_slot = "keyboard:/dev/input/event3", "keyboard:/dev/input/event4"
	assert(Reader.open("/dev/input/event3", row_slot) == true)
	assert(Reader.grab(row_slot) == true)
	assert(Reader.open("/dev/input/event4", shift_slot) == true)
	assert(Reader.grab(shift_slot) == true)
	local row_lease, row_observer = Reader.capture_source_owner(row_slot)
	local shift_lease, shift_observer = Reader.capture_source_owner(shift_slot)
	assert(row_lease and row_observer and shift_lease and shift_observer)
	assert(Reader.source_owner_current(row_lease, row_observer, capture, current, retire) == true)
	assert(Reader.source_owner_current(shift_lease, shift_observer, capture, current, retire) == true)
	push_bytes("/dev/input/event4", Input.encode(Input.EV_KEY, 42, 1, nil, 1000))
	local shift_down = assert(Reader.read_event(shift_slot))
	local held = assert(Reader.capture_event(shift_down, shift_slot))
	assert(Reader.event_view(held).source == "/dev/input/event4")
	assert(Reader.source_current(held, shift_lease, shift_observer, capture, current, retire) == true)
	assert(Reader.capture_event({ type = Input.EV_KEY, code = 42, value = 1 }, shift_slot) == nil)
	assert(Reader.source_current(held, {}, shift_observer, capture, current, retire) == false)
	assert(Reader.source_current(held, row_lease, row_observer, capture, current, retire) == false)
	assert(Reader.source_current(held, shift_lease, function() return true end, capture, current, retire) == false)
	push_bytes("/dev/input/event4", Input.encode(Input.EV_KEY, 30, 1, nil, 2000))
	assert(Reader.read_event(shift_slot))
	assert(Reader.event_current(held) == false)
	assert(Reader.source_current(held, shift_lease, shift_observer, capture, current, retire) == true)
	push_bytes("/dev/input/event3", Input.encode(Input.EV_KEY, 2, 1, nil, 3000))
	local row_down = assert(Reader.read_event(row_slot))
	local row = assert(Reader.capture_event(row_down, row_slot))
	assert(Reader.event_current(row) == true)
	assert(Reader.source_current(row, row_lease, row_observer, capture, current, retire) == true)
	-- Exact counterexample prerequisite: retiring the OTHER Shift descriptor
	-- leaves the current row receipt untouched; it cannot certify that Shift.
	assert(Reader.ungrab(shift_slot) == true)
	assert(Reader.event_current(row) == true)
	assert(Reader.source_current(row, row_lease, row_observer, capture, current, retire) == true)
	assert(Reader.source_current(held, shift_lease, shift_observer, capture, current, retire) == false)
	assert(Reader.source_owner_current(shift_lease, shift_observer, capture, current, retire) == false)
	assert(Reader.close(shift_slot) == true)
	assert(Reader.open("/dev/input/event4", shift_slot) == true)
	assert(Reader.grab(shift_slot) == true)
	local replacement, replacement_observer = Reader.capture_source_owner(shift_slot)
	assert(replacement and not rawequal(replacement, shift_lease))
	assert(Reader.source_current(held, replacement, replacement_observer, capture, current, retire) == false)
	assert(Reader.source_current(held, shift_lease, shift_observer, capture, current, retire) == false)
	assert(Reader.read_event(row_slot) == nil)
	assert(Reader.event_current(row) == false)
	assert(Reader.source_current(row, row_lease, row_observer, capture, current, retire) == true)
	assert(Reader.close(shift_slot) == true)
	assert(Reader.close(row_slot) == true)
end

 end)()
 local opaque_owner_control = (function()
-- SOURCE ONLY / UNRUN. Independent software composition, no native IO proof.
-- Reader is the unchanged whole original module bound by use_ffi_backend to
-- controlled native symbols; push_bytes feeds that read provider only.
-- build is the EXACT build_row_owners function extracted from the pinned whole
-- Hook; Custody is the unchanged real shared modifier_custody module.
-- Rows are explicitly controlled component observation ports, not input grants.
return function(Reader, Input, push_bytes, build, Custody, selected)
	local capture, current, retire = Reader.capture_source_owner, Reader.source_owner_current, Reader.retire_source
	local row_slot, shift_slot = "keyboard:/dev/input/event3", "keyboard:/dev/input/event4"
	assert(Reader.open("/dev/input/event3", row_slot) and Reader.grab(row_slot))
	assert(Reader.open("/dev/input/event4", shift_slot) and Reader.grab(shift_slot))
	local row_lease, row_observer = Reader.capture_source_owner(row_slot)
	local shift_lease, shift_observer = Reader.capture_source_owner(shift_slot)
	assert(row_lease and row_observer and shift_lease and shift_observer)
	push_bytes("/dev/input/event4", Input.encode(Input.EV_KEY, 42, 1, nil, 1000))
	local down = assert(Reader.read_event(shift_slot))
	local held = assert(Reader.capture_event(down, shift_slot))
	-- This later read expires event currency while retaining original source
	-- currency. The control never substitutes event_current for a held lease.
	push_bytes("/dev/input/event4", Input.encode(Input.EV_KEY, 30, 1, nil, 2000))
	assert(Reader.read_event(shift_slot))
	assert(not Reader.event_current(held))
	assert(Reader.source_current(held, shift_lease, shift_observer, capture, current, retire))
	push_bytes("/dev/input/event3", Input.encode(Input.EV_KEY, 2, 1, nil, 3000))
	local event = assert(Reader.read_event(row_slot))
	local origin = assert(Reader.capture_event(event, row_slot))
	local snapshot, mutated, wires, commits = false, false, {}, 0
	local function revoke()
		if not mutated then assert(Reader.ungrab(shift_slot)); mutated = true end
	end
	local function shift_current()
		return Reader.source_current(held, shift_lease, shift_observer, capture, current, retire) == true
	end
	local broker = Custody.new(nil, nil)
	broker.output_current = function() return broker.has_debt() == false end
	broker.output_retired = function() return false end
	local function emit(code, value)
		wires[#wires + 1] = tostring(code) .. ":" .. tostring(value)
		if selected == "after_suspension" and code == 42 and value == 0 then revoke() end
		if selected == "after_row_write" and code == 2 and value == 1 then revoke() end
		return true
	end
	local physical = {}
	assert(broker.edge(physical, 42, 1, emit).ok)
	wires = {}
	local rows = {
		desired = function() return { code = 2, shift = selected == "after_commit", physical_shift = true } end,
		observe = function() return { native_action = { keysym = 0x31, dead = false } } end,
		retire = function() return true end,
	}
	local owner = build(rows, broker, emit, function() return true end,
		function()
			if snapshot and selected == "before_output" then revoke() end
			return Reader.event_current(origin) == true
				and Reader.source_current(origin, row_lease, row_observer, capture, current, retire) == true
		end,
		function() snapshot = true; return { 42 }, shift_current end,
		function()
			commits = commits + 1
			if selected == "after_commit" then revoke() end
			return true, "1", "1"
		end, function() return true end)
	local accepted, outcome = owner.event("row", event, "digits", 1, true, {})
	assert(Reader.event_current(origin) == true, "the other source must not expire the row event")
	local wire = table.concat(wires, ",")
	if selected == "surviving_shift" then
		assert(accepted and wire == "42:0,2:1,42:1" and commits == 1)
		assert(broker.view().owners[physical].state == "held")
		push_bytes("/dev/input/event3", Input.encode(Input.EV_KEY, 2, 0, nil, 4000))
		event = assert(Reader.read_event(row_slot)); origin = assert(Reader.capture_event(event, row_slot))
		assert(owner.event("row", event, "digits", 1, true))
		assert(table.concat(wires, ",") == "42:0,2:1,42:1,2:0" and owner.retire())
		assert(broker.edge(physical, 42, 0, emit).ok)
	elseif selected == "before_output" then
		assert(accepted == false and wire == "" and commits == 0 and owner.retire() == true)
	elseif selected == "after_suspension" then
		assert(accepted == false and wire == "42:0" and commits == 0 and owner.retire() == false)
		assert(broker.view().owners[physical].state == "suspended")
	elseif selected == "after_row_write" then
		assert(accepted == false and wire == "42:0,2:1,2:0" and commits == 0 and owner.retire() == false)
		assert(broker.view().owners[physical].state == "suspended")
	elseif selected == "after_commit" then
		assert(accepted == false and wire == "2:1,2:0" and commits == 1 and owner.retire() == true)
		assert(type(outcome) ~= "table", "retired Shift cannot yield semantic success")
	else error("unknown literal independent case") end
	-- Suspended-owner cases deliberately remain unresolved. The root's whole
	-- Hook/output fixture later retires the ORIGINAL output owner to settle it.
	assert(Reader.close(shift_slot))
	assert(Reader.close(row_slot))
end

 end)()
 h.describe('original Reader and actual Hook retained-Shift behavioral controls', function()
  h.it('opaque_source_event_lifecycle', function()
   with_original_reader_symbols(opaque_reader_control)
  end)
  for _, selected in ipairs({ 'surviving_shift', 'before_output', 'after_suspension', 'after_row_write', 'after_commit' }) do
   local literal_case = selected
   h.it(literal_case, function()
    -- Read/load the whole original Hook before installing the modeled FFI.
    local builder = genuine_row_owner_builder()
    local Custody = require('input.modifier_custody')
    with_original_reader_symbols(function(Reader, Input, push_bytes)
     opaque_owner_control(Reader, Input, push_bytes, builder, Custody, literal_case)
    end)
   end)
  end
 end)
end

-- Whole Hook controlled lifecycle under explicit intent; no connected rights.
do
 local Fixture = require('tests.support.input_owner_fixture')
 local function intent_options(session, mode)
  local options = {}; for key, value in pairs(session.start_options) do options[key] = value end
  options.numberRowMode = mode
  return options
 end
 h.describe('whole Hook explicit number-row intent without receiving admission', function()
  for _, mode in ipairs({ 'digits', 'symbols' }) do
   local literal_mode = mode
   h.it(literal_mode .. '_intent_preserves_whole_hook_ordinary_forwarding', function()
    Fixture.with_session({}, function(s)
     local slot = 'keyboard:' .. s.paths.a
     local previous = assert(s.reader.capture_source_owner(slot))
     assert(s.hook.stop() ~= false)
     h.assert_eq(s.hook.isRunning(), false)
     h.assert_eq(s.reader.is_open(slot), false)
     -- Original Writer API observes refusal; no replacement issuer is installed.
     h.assert_eq(s.writer.capture_kernel_source(), nil)
     h.assert_eq(s.writer.kernel_source_ports({}), nil)
     h.assert_eq(s.hook.start(intent_options(s, literal_mode)), true)
     h.assert_eq(s.hook.isRunning(), true)
     local fresh = assert(s.reader.capture_source_owner(slot))
     h.assert_true(fresh ~= previous and s.reader.source_owner_current(fresh))
     h.assert_eq(s.reader.source_owner_current(previous), false)
     s.rows, s.captures = {}, {}
     s.edge('a', 2, 1, 10); s.edge('a', 2, 2, 20); s.edge('a', 2, 0, 30)
     h.assert_eq(s.rows, { { 2, 1 }, { 2, 2 }, { 2, 0 } })
     h.assert_eq(s.captures, { { 2, 1 }, { 2, 2 }, { 2, 0 } })
     h.assert_eq(s.writer.capture_kernel_source(), nil)
     h.assert_eq(s.hook.isRunning(), true)
     h.assert_true(s.writer.output_current(s.output))
     assert(s.hook.stop() ~= false)
     h.assert_eq(s.reader.is_open(slot), false)
     h.assert_eq(s.hook.isRunning(), false)
    end)
   end)
  end
  h.it('invalid_number_row_intent_refuses_before_capture_and_recovers', function()
   local resets = 0
   Fixture.with_session({ on_capture_reset = function() resets = resets + 1 end }, function(s)
    assert(s.hook.stop() ~= false)
    local baseline = resets
    s.rows, s.captures = {}, {}
    h.assert_eq(s.hook.start(intent_options(s, 'unsupported-number-row-mode')), false)
    h.assert_eq(s.hook.isRunning(), false)
    h.assert_eq(s.reader.is_open('keyboard:' .. s.paths.a), false)
    h.assert_eq(s.reader.is_open('keyboard:' .. s.paths.b), false)
    h.assert_eq(s.descriptor('a'), nil); h.assert_eq(s.descriptor('b'), nil)
    h.assert_eq(resets, baseline)
    h.assert_eq(s.rows, {}); h.assert_eq(s.captures, {})
    h.assert_true(s.writer.output_current(s.output))
    h.assert_eq(s.hook.start(intent_options(s, 'native')), true)
    h.assert_eq(resets, baseline + 1)
    s.edge('a', 2, 1, 10); s.edge('a', 2, 0, 20)
    h.assert_eq(s.rows, { { 2, 1 }, { 2, 0 } })
    h.assert_eq(s.captures, { { 2, 1 }, { 2, 0 } })
    h.assert_eq(s.hook.isRunning(), true)
   end)
  end)
 end)
end
