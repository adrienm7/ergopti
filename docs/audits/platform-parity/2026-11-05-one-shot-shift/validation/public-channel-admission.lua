-- Countercheck public preset reachability without unavailable chord declarations.
local root = assert(arg[1])
local campaign = root .. '/docs/audits/platform-parity/2026-11-05-one-shot-shift'
local input = assert(io.open(campaign .. '/linux/public-probe.lua', 'rb'))
local source = input:read('*a'); input:close()
local boundary = assert(source:find('local observations={}', 1, true))
-- Reuse only the archived recording native layout setup, not its scenarios.
local Capture = assert((loadstring or load)(source:sub(1, boundary - 1) .. '\nreturn Capture', '@qualified-public-native-layout'))()
local Features = require('infra.manifest_reader')
local original_find, original_default = Features.find_entry_by_path, Features.default_for
local declaration_fixture = 'tests.support.key_combination_declaration_fixture'
assert(package.loaded[declaration_fixture] == nil)
package.preload[declaration_fixture] = function() error('Unavailable declaration fixture must never be loaded') end
local Fixture = require('tests.support.input_owner_fixture')
local observations = {}
local function original_declarations()
 assert(package.loaded['infra.manifest_reader'] == Features)
 assert(Features.find_entry_by_path == original_find and Features.default_for == original_default)
 for _,path in ipairs({'mod_combos.simultaneous_threshold_ms', 'mod_combos.symmetric'}) do
  assert(type(original_find(path)) == 'table', 'Actual production declaration must exist: ' .. path)
  assert(original_default(path) ~= nil)
 end
 assert(package.loaded[declaration_fixture] == nil)
end
for _,repeated in ipairs({false, true}) do
 require('logger.shim').set_sink(nil)
 assert(Capture.load('keymap', 'C'))
 original_declarations()
 local chars, errors = {}, {}
 local configured = false
 Fixture.with_manager_session({
  capture = Capture,
  public_chords = true,
  -- The actual Manager reads an empty valid config.toml, with no ordered pair.
  -- Existing fixture's tap_hold.toml explicitly enables the shipped preset.
  before_manager = function(s) original_declarations(); s.bytes = ''; configured = true end,
  on_char = function(ch) chars[#chars + 1] = ch end,
 }, function(s)
  original_declarations()
  assert(configured and s.bytes == '')
  local keys = s.manager.keys()
  assert(keys.right_ctrl.tap_action == 'one_shot_shift')
  assert(keys.right_ctrl.hold_modifier == 'shift')
  assert(s.engine == s.manager.configuration_snapshot().engine)
  assert(s.engine ~= s.base, 'The Manager must replace the fixture-only base Engine')
  require('logger.shim').set_sink(function(line, kind) if kind == 'error' then errors[#errors + 1] = line end end)
  s.edge('a', 97, 1, 1000); s.edge('a', 97, 0, 1100)
  assert(s.engine.one_shot_until ~= nil, 'Actual default RCtrl tap must arm')
  assert(#s.actions == 0, 'No generic action/legacy pair admission may be used')
  s.edge('a', 30, 1, 1200)
  if repeated then s.edge('a', 30, 2, 1210) end
  s.edge('a', 30, 0, 1220); s.edge('a', 30, 1, 1300); s.edge('a', 30, 0, 1310)
  local row = {repeated = repeated, config_toml = s.bytes,
   preset = {right_ctrl_tap = keys.right_ctrl.tap_action, right_ctrl_hold = keys.right_ctrl.hold_modifier},
   original_production_declarations = true, unavailable_declaration_fixture_loaded = package.loaded[declaration_fixture] ~= nil,
   generic_action_calls = #s.actions, chars = chars, wire = s.rows, errors = errors,
   hook_running = s.hook.isRunning(), broker_debt = s.broker.has_debt(),
   output_current = s.writer.output_view(s.output) ~= nil,
   reader_closes = s.source_closes or 0, output_closes = s.output_closes or 0, output_destroys = s.output_destroys or 0}
  if repeated then
   assert(not row.hook_running and row.broker_debt and not row.output_current)
   assert(#chars == 1 and chars[1] == 'A')
   assert(#errors == 1 and errors[1]:find('raw ownership settlement failed (code=30 value=2): refused.', 1, true))
   assert(row.reader_closes == 2 and row.output_closes == 1 and row.output_destroys == 1)
  else
   assert(row.hook_running and not row.broker_debt and row.output_current)
   assert(#chars == 2 and chars[1] == 'A' and chars[2] == 'a' and #errors == 0)
   assert(row.reader_closes == 0 and row.output_closes == 0 and row.output_destroys == 0)
  end
  observations[#observations + 1] = row
 end)
 original_declarations()
 require('logger.shim').set_sink(nil)
end
print('PUBLIC_CHANNEL_ADMISSION=' .. assert(require('json').encode({
 qualification = 'Original production declarations and original Manager with empty valid config.toml, explicitly enabled shipped tap-hold preset and ordinary physical RCtrl tap; no unsupported declaration fixture or generic action. Existing test transport initially creates an unused legacy owner before Manager replacement. Native ports remain recording FFI/syscall/XKB; no real device, libxkb inverse or receiving-app proof. This establishes reachable enabled-preset configuration, not enabled-by-default neutral installation.',
 observations = observations})))
