--- tests/unit/ui/test_permission_ui_stage_observation.lua
--- Runs the original native fixture with modeled HS endpoints; no native proof.
local helpers = require("tests.helpers")
local Json = require("json")
local PROBE = helpers.driver_root() .. "../../../tools/diagnostics/hs_permission_dialog_native.lua"
local PREFIX = "ERGOPTI_PERMISSION_UI_STAGE_FAILURE "
local MODULES = {
	"infra.logger", "app_dirs", "infra.locale", "infra.i18n", "ui.ui_builder",
	"adapters.timer_scheduler", "ui.permission_dialog", "ui.permission_dialog.login_items_guide",
	"adapters.json_codec", "adapters.webview_result",
}
local CASES = {
	"tap_holds_off_keeps_banner", "accessibility_precedes_login_items", "accessibility_later_native_bridge",
	"login_items_native_dom_and_window", "unknown_status_keeps_steps", "open_settings_native_bridge",
	"later_dismisses_and_spends_offer", "explicit_reopen_creates_new_view", "native_delete_reports_close",
	"observed_ready_auto_closes",
}
local HARNESS = [==[

local function check(value, message) if not value then error(message, 0) end end
local function quote(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    if c == '\\' then return '\\\\' end
    if c == '"' then return '\\"' end
    return string.format('\\u%04x', string.byte(c))
  end) .. '"'
end
local function encode(x)
  if type(x) == 'string' then return quote(x) end
  if type(x) == 'number' or type(x) == 'boolean' then return tostring(x) end
  check(type(x) == 'table', 'model encoder type')
  local parts = {}
  if #x > 0 then
    for i = 1, #x do parts[i] = encode(x[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  local keys = {}; for key in pairs(x) do keys[#keys+1] = key end; table.sort(keys)
  for _, key in ipairs(keys) do parts[#parts+1] = quote(key) .. ':' .. encode(x[key]) end
  return '{' .. table.concat(parts, ',') .. '}'
end
local actual_open = io.open
local actual_stderr = io.stderr
local initial_handle = assert(io.tmpfile())
local actual_file_metatable = getmetatable(initial_handle)
local actual_file_close = actual_file_metatable.__index.close
actual_file_close(initial_handle)
local log_errors, handles, windows, pending = {}, {}, {}, {}
local elapsed, observer, guide, session, view_count = 0, nil, nil, nil, 0
local UI, Dialog, Guide = {}, {}, {}
local function new_view()
  view_count = view_count + 1
  local id = view_count
  local view = assert(io.tmpfile()); handles[#handles+1] = view; windows[id] = view
  local index = {}
  function index:isVisible() return windows[id] ~= nil end
  function index:hswindow() return { id = function() return id end } end
  function index:frame() return { w = mode == 'geometry' and 561 or 560, h = 520 } end
  function index:delete()
    if not (mode == 'late_debt' and id == 3) then windows[id] = nil end
    debug.setmetatable(self, nil)
    if session and session.view == self then
      local closed_kind = session.spec.kind
      session = nil
      if guide and closed_kind == 'login_items' then guide = nil end
    end
  end
  function index:evaluateJavaScript(js, callback)
    if mode == 'busy' then return end
    pending[#pending+1] = function()
      local value = true
      if js:find("querySelector", 1, true) then
        value = { title = 'Title', steps = 3, open = 'Open', later = 'Later', lang = 'en' }
      elseif js:find("getElementById('later').click()", 1, true) then
        Dialog.close()
      elseif js:find("getElementById('open').click()", 1, true) then
        check(session and session.spec.open_settings() == true, 'model settings')
      end
      callback(value, nil)
    end
  end
  debug.setmetatable(view, { __index = index })
  return view
end
function UI.show_webview() return new_view() end
function UI.get_app_geometry() return { width = 560, height = 520 } end
function Dialog.show(spec)
  session = { spec = spec, view = UI.show_webview({ frame = { w = 560, h = 520 } }) }
  return true
end
function Dialog.is_open(kind) return session ~= nil and (kind == nil or session.spec.kind == kind) end
function Dialog.close()
  if session then session.view:delete() end
  return true
end
Guide.POLL_SECONDS, Guide.DEADLINE_SECONDS = 1, 600
if mode == 'early' then Guide.POLL_SECONDS = 2 end
local spent = false
local function present()
  if session == nil then
    Dialog.show({ kind = 'login_items', open_settings = function()
      return guide.remap.open_login_items(function() end)
    end })
  end
end
function Guide.offer(remap)
  if not remap.get_tap_holds_enabled() or spent then return false end
  spent = true; guide = { remap = remap }; present(); return true
end
function Guide.reopen(remap) guide = { remap = remap }; present(); return true end
function Guide.is_active() return guide ~= nil end
local providers = {
  ['infra.logger'] = {
    init_log_path = function() return true end,
    error = function(_, _, error_message) log_errors[#log_errors+1] = error_message end,
  },
  ['app_dirs'] = { files = { unified_prefix = 'ErgoptiPlus_', extension = '.log' } },
  ['infra.locale'] = { set_locale = function() end },
  ['infra.i18n'] = { set_locale_injector = function() end, init = function() end, get_locale = function() return 'en' end },
  ['ui.ui_builder'] = UI,
  ['adapters.timer_scheduler'] = { activeCount = function() return guide and 1 or 0 end },
  ['ui.permission_dialog'] = Dialog,
  ['ui.permission_dialog.login_items_guide'] = Guide,
  ['adapters.json_codec'] = { encode = function(packet)
    if mode == 'encode' then error('PRIVATE_ENCODER/path token=SECRET', 0) end
    return encode(packet), nil
  end },
  ['adapters.webview_result'] = { is_error = function(err) return err ~= nil end },
}
for name, value in pairs(providers) do package.preload[name] = function() return value end end
_G.hs = {
  fs = { mkdir = function() return true end, attributes = function()
    if observer == nil then return { mode = 'file' } end
    return nil
  end },
  processInfo = { processID = 123, version = 'modeled' },
  window = { windowForID = function(id) return windows[id] end },
  timer = {
    absoluteTime = function() return elapsed end,
    new = function(_, callback)
      observer = { callback = callback, live = false }
      function observer:start() self.live = true; return self end
      function observer:stop() self.live = false; return self end
      function observer:running() return self.live end
      return observer
    end,
  },
}
if mode == 'open' then
  io.open = function(path, ...)
    if path:match('/result%.pending$') then return nil, 'PRIVATE_OPEN/path token=SECRET' end
    return actual_open(path, ...)
  end
end
if mode == 'stderr' then
  io.stderr = { write = function() error('PRIVATE_STDERR/path token=SECRET', 0) end }
end
local function alter(function_value, target, replacement, seen)
  seen = seen or {}; if seen[function_value] then return false end; seen[function_value] = true
  for i = 1, math.huge do
    local name, value = debug.getupvalue(function_value, i)
    if not name then break end
    if name == target then debug.setupvalue(function_value, i, replacement); return true end
    if type(value) == 'function' and alter(value, target, replacement, seen) then return true end
  end
  return false
end
assert(dofile(source))({ root = root, nonce = 'modeled', bundle = '/modeled.bundle', stage_failure_observation = flag })
if mode == 'invalid_stage' then check(alter(observer.callback, 'stage', 'SECRET/path'), 'stage model setup') end
if mode == 'invalid_busy' then check(alter(observer.callback, 'busy', 'SECRET/path'), 'busy model setup') end
for step = 1, 80 do
  if not observer.live then break end
  if mode == 'busy' and step > 5 or mode == 'invalid_stage' or mode == 'invalid_busy' or mode == 'stderr' then
    elapsed = 11000000000
  else elapsed = step * 10000000 end
  local callbacks = pending; pending = {}
  for _, fn in ipairs(callbacks) do fn() end
  if guide then
    local state = guide.remap.guardian_state()
    if state == 'ready' then guide = nil; Dialog.close() else present() end
  end
  observer.callback()
end
io.open = actual_open; io.stderr = actual_stderr
local result = { observer_live = observer.live, log_error_count = #log_errors }
local file = actual_open(root .. '/result.json', 'rb')
if file then result.packet = file:read('*a'); file:close() end
io.stdout:write(encode(result) .. '\n')
for _, handle in ipairs(handles) do
  debug.setmetatable(handle, actual_file_metatable); actual_file_close(handle)
end

]==]

local function modeled_probe(mode, flag)
	return helpers.with_fresh_modules(MODULES, function()
		local prior = { hs = _G.hs, open = io.open, stderr = io.stderr, stdout = io.stdout, rename = os.rename }
		local preloads = {}; for _, name in ipairs(MODULES) do preloads[name] = package.preload[name] end
		local files, lines, output = {}, {}, {}
		io.open = function(path, mode)
			if mode == "rb" then
				if files[path] == nil then return nil end
				return { read = function() return files[path] end, close = function() return true end }
			end
			assert(mode == "wb", "Unexpected modeled IO")
			return { write = function(_, bytes) files[path] = (files[path] or "") .. bytes; return true end,
				close = function() return true end }
		end
		os.rename = function(source, destination)
			files[destination], files[source] = files[source], nil; return true
		end
		io.stderr = { write = function(_, line) lines[#lines + 1] = line; return true end }
		io.stdout = { write = function(_, line) output[#output + 1] = line; return true end }
		local outcome = table.pack(xpcall(function()
			local execute = assert(load("return function(mode, source, root, flag)\n" .. HARNESS .. "\nend", "@modeled-stage-harness"))()
			execute(mode, PROBE, "/modeled/private/stage-observation", flag)
			local result = assert(Json.decode(table.concat(output)))
			if result.packet then result.packet = assert(Json.decode(result.packet)) end
			local observations = {}
			for _, line in ipairs(lines) do
				if line:sub(1, #PREFIX) == PREFIX then
					helpers.assert_true(#line <= 512 and line:sub(-1) == "\n")
					helpers.assert_true(line:find("SECRET", 1, true) == nil and line:find("/", 1, true) == nil)
					local value = assert(Json.decode(line:sub(#PREFIX + 1)))
					local count = 0; for _ in pairs(value) do count = count + 1 end
					helpers.assert_eq(count, 9)
					for _, key in ipairs({ "schema", "kind", "authority", "native_verdict", "boundary",
						"stage", "finish_checkpoint", "recorded_case_count", "busy" }) do
						helpers.assert_true(value[key] ~= nil, "Closed witness field " .. key)
					end
					helpers.assert_eq(value.schema, 1)
					helpers.assert_eq(value.kind, "permission_ui_stage_failure_observation")
					helpers.assert_eq(value.authority, false); helpers.assert_eq(value.native_verdict, "unchanged")
					helpers.assert_eq(math.type(value.recorded_case_count), "integer")
					helpers.assert_eq(type(value.busy), "boolean")
					observations[#observations+1] = value
				end
			end
			return { result = result, observations = observations }
		end, debug.traceback))
		_G.hs, io.open, io.stderr, io.stdout, os.rename = prior.hs, prior.open, prior.stderr, prior.stdout, prior.rename
		for _, name in ipairs(MODULES) do package.preload[name] = preloads[name] end
		if not outcome[1] then error(outcome[2], 0) end
		return outcome[2].result, outcome[2].observations
	end)
end

local function first(mode, stage, count, busy, checkpoint)
	local result, observations = modeled_probe(mode, true)
	helpers.assert_true(#observations >= 2, "Failure snapshot is required")
	local value = observations[1]
	helpers.assert_eq(value.boundary, "tick_refused_before_cleanup")
	helpers.assert_eq(value.stage, stage); helpers.assert_eq(value.recorded_case_count, count)
	helpers.assert_eq(value.busy, busy); helpers.assert_eq(value.finish_checkpoint, checkpoint or "not_entered")
	helpers.assert_eq(observations[2].boundary, "failure_finish_entered")
	return result, observations
end

helpers.describe("Permission stage observation with modeled HS endpoints", function()
	helpers.it("preserves ten original healthy cases without a failure witness", function()
		local result, observations = modeled_probe("healthy", true)
		helpers.assert_eq(#observations, 0); helpers.assert_eq(result.observer_live, false)
		helpers.assert_eq(result.packet.status, "ok"); helpers.assert_eq(#result.packet.case_results, 10)
		for i, id in ipairs(CASES) do
			helpers.assert_eq(result.packet.case_results[i].id, id)
			helpers.assert_eq(result.packet.case_results[i].passed, true)
		end
	end)
	helpers.it("observes the original early predicate before cleanup", function()
		local result = first("early", 1, 0, false)
		helpers.assert_eq(result.packet.status, "error")
		helpers.assert_true(result.packet.failure:find("Production guide budgets changed", 1, true) ~= nil)
	end)
	helpers.it("retains the busy stage at the original deadline", function()
		local result = first("busy", 2, 2, true)
		helpers.assert_true(result.packet.failure:find("Actual UI probe deadline exceeded", 1, true) ~= nil)
	end)
	helpers.it("identifies callback-stored geometry failure entering finish", function()
		local result, observed = modeled_probe("geometry", true)
		helpers.assert_true(#observed >= 1)
		helpers.assert_eq(observed[1].boundary, "failure_finish_entered")
		helpers.assert_eq(observed[1].stage, 5); helpers.assert_eq(observed[1].recorded_case_count, 3)
		helpers.assert_eq(observed[1].finish_checkpoint, "entered"); helpers.assert_eq(observed[1].busy, false)
		helpers.assert_true(result.packet.failure:find("Actual view did not consume shared geometry", 1, true) ~= nil)
	end)
	helpers.it("preserves first encoding refusal before repeat factory guard", function()
		local result, observed = first("encode", 10, 10, false, "packet_built")
		helpers.assert_eq(result.packet, nil); helpers.assert_eq(observed[#observed].boundary, "finish_refused")
		helpers.assert_eq(observed[#observed].finish_checkpoint, "entered"); helpers.assert_eq(result.log_error_count, 1)
	end)
	helpers.it("distinguishes original pending-open from encoding refusal", function()
		local result, observed = first("open", 10, 10, false, "packet_encoded")
		helpers.assert_eq(result.packet, nil); helpers.assert_eq(observed[#observed].boundary, "finish_refused")
		helpers.assert_eq(observed[#observed].finish_checkpoint, "entered")
	end)
	helpers.it("retains the original native-delete debt predicate", function()
		local result = first("late_debt", 9, 8, false)
		helpers.assert_true(result.packet.failure:find("Native close left production poll/window debt", 1, true) ~= nil)
	end)
	helpers.it("keeps original failure when diagnostic stderr throws", function()
		local result, observed = modeled_probe("stderr", true)
		helpers.assert_eq(#observed, 0); helpers.assert_eq(result.packet.status, "error")
		helpers.assert_true(result.packet.failure:find("Actual UI probe deadline exceeded", 1, true) ~= nil)
	end)
	for _, mode in ipairs({ "invalid_stage", "invalid_busy" }) do
		helpers.it("declines private nonprimitive saved " .. mode, function()
			local result, observed = modeled_probe(mode, true)
			helpers.assert_eq(#observed, 0)
			helpers.assert_true(result.packet.failure:find("Actual UI probe deadline exceeded", 1, true) ~= nil)
		end)
	end
	for _, flag in ipairs({ false, "PRIVATE opt-in" }) do
		helpers.it("requires the captured exact-true opt-in " .. tostring(flag), function()
			local result, observed = modeled_probe("early", flag)
			helpers.assert_eq(#observed, 0)
			helpers.assert_true(result.packet.failure:find("Production guide budgets changed", 1, true) ~= nil)
		end)
	end
end)
