--- tests/unit/ui/test_permission_ui_progress_observation.lua
--- Runs the unchanged native producer over modeled ports; no native authority.
local helpers = require("tests.helpers")
local Json = require("json")
local PROBE = helpers.driver_root() .. "../../../tools/diagnostics/hs_permission_dialog_native.lua"
local PREFIX = "ERGOPTI_PERMISSION_UI_PROGRESS "
local MODULES = {
	"infra.logger", "app_dirs", "infra.locale", "infra.i18n", "ui.ui_builder", "adapters.timer_scheduler",
	"ui.permission_dialog", "ui.permission_dialog.login_items_guide", "adapters.json_codec", "adapters.webview_result",
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
    if mode == 'encode_mutation' then
      check(alter(observer.callback, 'stage', 'PRIVATE_SECRET'), 'frozen encoder stage hook')
      check(alter(observer.callback, 'results', {{ id = 'PRIVATE_SECRET', passed = false }}), 'frozen encoder prefix hook')
      error('PRIVATE_ENCODER/path token=SECRET', 0)
    end
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
  processInfo = { processID = 123, version = '1.1.1' },
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
if mode == 'writer_reentry' then
  local sink, reentered = io.stderr, false
  io.stderr = { write = function(_, bytes)
    sink:write(bytes)
    if not reentered and bytes:sub(1, #'ERGOPTI_PERMISSION_UI_PROGRESS ') == 'ERGOPTI_PERMISSION_UI_PROGRESS ' then
      reentered = true
      observer.callback()
    end
    return true
  end }
end
if mode == 'stderr' then
  io.stderr = { write = function() error('PRIVATE_STDERR/path token=SECRET', 0) end }
end

assert(dofile(source))({ root = root, nonce = string.rep('1', 32), bundle = '/modeled.bundle', progress_observation = flag })
if mode == 'invalid_prefix' then check(alter(observer.callback, 'results', {{ id = 'accessibility_precedes_login_items', passed = true }}), 'frozen misordered prefix hook') end
if mode == 'invalid_ack' then check(alter(observer.callback, 'results', {{ id = 'tap_holds_off_keeps_banner', passed = 1 }}), 'frozen nonliteral prefix hook') end
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
local function modeled(mode, flag)
	return helpers.with_fresh_modules(MODULES, function()
		local old = { hs = _G.hs, open = io.open, stderr = io.stderr, stdout = io.stdout, rename = os.rename }
		local preloads = {}; for _, name in ipairs(MODULES) do preloads[name] = package.preload[name] end
		local files, lines, stdout = {}, {}, {}
		io.open = function(path, mode)
			if mode == "rb" then
				if files[path] == nil then return nil end
				return { read = function() return files[path] end, close = function() return true end }
			end
			assert(mode == "wb")
			return { write = function(_, b) files[path] = (files[path] or "") .. b; return true end, close = function() return true end }
		end
		os.rename = function(a, b) files[b], files[a] = files[a], nil; return true end
		io.stderr = { write = function(_, b) lines[#lines + 1] = b; return true end }
		io.stdout = { write = function(_, b) stdout[#stdout + 1] = b; return true end }
		local result = table.pack(xpcall(function()
			local run = assert(load("return function(mode, source, root, flag)\n" .. HARNESS .. "\nend", "@frozen-progress-model"))()
			run(mode, PROBE, "/modeled/private/permission-progress", flag)
			local summary = assert(Json.decode(table.concat(stdout)))
			if summary.packet then summary.packet = assert(Json.decode(summary.packet)) end
			local observations = {}
			for _, bytes in ipairs(lines) do
				if bytes:sub(1, #PREFIX) == PREFIX then
					helpers.assert_true(#bytes <= 512 and bytes:sub(-1) == "\n")
					helpers.assert_true(bytes:find("PRIVATE", 1, true) == nil and bytes:find("SECRET", 1, true) == nil)
					observations[#observations + 1] = assert(Json.decode(bytes:sub(#PREFIX + 1)))
				end
			end
			return summary, observations
		end, debug.traceback))
		_G.hs, io.open, io.stderr, io.stdout, os.rename = old.hs, old.open, old.stderr, old.stdout, old.rename
		for _, name in ipairs(MODULES) do package.preload[name] = preloads[name] end
		if not result[1] then error(result[2], 0) end
		return table.unpack(result, 2, result.n)
	end)
end
local function contract(rows)
	helpers.assert_true(#rows > 0 and #rows <= 30, "finite first-seen actual producer observations are required")
	local seen = {}
	for i, row in ipairs(rows) do
		local keys = 0; for _ in pairs(row) do keys = keys + 1 end; helpers.assert_eq(keys, 11)
		helpers.assert_eq(row.schema, 1); helpers.assert_eq(row.kind, "permission_ui_first_seen_progress")
		helpers.assert_eq(row.authority, false); helpers.assert_eq(row.native_verdict, "unchanged")
		helpers.assert_eq(row.pid, 123); helpers.assert_eq(row.nonce, string.rep("1", 32)); helpers.assert_eq(row.version, "1.1.1")
		helpers.assert_eq(row.sequence, i); helpers.assert_eq(type(row.busy), "boolean")
		helpers.assert_eq(math.type(row.recorded_case_count), "integer")
		local key = tostring(row.stage) .. "/" .. tostring(row.busy) .. "/" .. row.recorded_case_count
		helpers.assert_eq(seen[key], nil, "each tuple is latched before foreign publication")
		seen[key] = true
	end
end
local function contains(rows, stage, busy, count)
	for _, row in ipairs(rows) do
		if row.stage == stage and row.busy == busy and row.recorded_case_count == count then return true end
	end
	return false
end
helpers.describe("First-seen permission progress over modeled OS endpoints", function()
	helpers.it("keeps opt-out healthy result and all ten original cases", function()
		local result, rows = modeled("healthy", false)
		helpers.assert_eq(#rows, 0); helpers.assert_eq(result.packet.status, "ok")
		helpers.assert_eq(#result.packet.case_results, 10); helpers.assert_eq(result.observer_live, false)
	end)
	helpers.it("records strict prefix zero before the first healthy tick", function()
		local result, rows = modeled("healthy", true); contract(rows)
		helpers.assert_eq(rows[1].stage, 1); helpers.assert_eq(rows[1].busy, false); helpers.assert_eq(rows[1].recorded_case_count, 0)
		helpers.assert_eq(result.packet.status, "ok"); helpers.assert_eq(#result.packet.case_results, 10)
	end)
	helpers.it("retains the real ten-case prefix before successful encoding", function()
		local result, rows = modeled("healthy", true); contract(rows)
		helpers.assert_true(contains(rows, 10, false, 10)); helpers.assert_eq(result.packet.status, "ok")
	end)
	helpers.it("observes the initial refused predicate without recording a case", function()
		local result, rows = modeled("early", true); contract(rows)
		helpers.assert_true(contains(rows, 1, false, 0)); helpers.assert_eq(#result.packet.case_results, 0)
		helpers.assert_eq(result.packet.status, "error")
	end)
	helpers.it("records existing pending WebKit busy with actual prefix two", function()
		local result, rows = modeled("busy", true); contract(rows)
		helpers.assert_true(contains(rows, 2, true, 2)); helpers.assert_eq(#result.packet.case_results, 2)
		helpers.assert_true(result.packet.failure:find("Actual UI probe deadline exceeded", 1, true) ~= nil)
	end)
	helpers.it("observes original geometry refusal at stage five prefix three", function()
		local result, rows = modeled("geometry", true); contract(rows)
		helpers.assert_true(contains(rows, 5, false, 3)); helpers.assert_eq(#result.packet.case_results, 3)
		helpers.assert_true(result.packet.failure:find("Actual view did not consume shared geometry", 1, true) ~= nil)
	end)
	helpers.it("observes real modeled close debt at stage nine prefix eight", function()
		local result, rows = modeled("late_debt", true); contract(rows)
		helpers.assert_true(contains(rows, 9, false, 8)); helpers.assert_eq(#result.packet.case_results, 8)
	end)
	helpers.it("retains actual final prefix before a foreign encoder throws", function()
		local result, rows = modeled("encode", true); contract(rows)
		helpers.assert_true(contains(rows, 10, false, 10)); helpers.assert_eq(result.packet, nil)
	end)
	helpers.it("does not serialize an unknown stage", function()
		local _, rows = modeled("invalid_stage", true); helpers.assert_eq(#rows, 0)
	end)
	helpers.it("does not serialize an invalid busy value", function()
		local _, rows = modeled("invalid_busy", true); helpers.assert_eq(#rows, 0)
	end)
	helpers.it("keeps the original primary refusal when diagnostic stderr throws", function()
		local result, rows = modeled("stderr", true); helpers.assert_eq(#rows, 0)
		helpers.assert_eq(result.packet.status, "error")
	end)
end)

helpers.describe("First-seen progress callback custody", function()
	helpers.it("records the final strict prefix before a foreign encoder changes producer state", function()
		local result, rows = modeled("encode_mutation", true); contract(rows)
		helpers.assert_true(contains(rows, 10, false, 10)); helpers.assert_eq(result.packet, nil)
	end)
	helpers.it("latches tuple ownership before a foreign writer reenters the original timer callback", function()
		local result, rows = modeled("writer_reentry", true); contract(rows)
		helpers.assert_eq(result.packet.status, "ok"); helpers.assert_eq(#result.packet.case_results, 10)
	end)
	for _, mode in ipairs({ "invalid_prefix", "invalid_ack" }) do
		helpers.it("refuses first-seen data from " .. mode .. " in the actual result table", function()
			local _, rows = modeled(mode, true); helpers.assert_eq(#rows, 0)
		end)
	end
	helpers.it("keeps a nonliteral opt-in disabled", function()
		local result, rows = modeled("healthy", "true"); helpers.assert_eq(#rows, 0)
		helpers.assert_eq(result.packet.status, "ok"); helpers.assert_eq(#result.packet.case_results, 10)
	end)
end)
