-- static/ergopti_plus/macos/tests/unit/ui/test_permission_ui_stage4_observation.lua
--- Stage-4 software observations; every OS endpoint below is explicitly modeled.
local helpers = require("tests.helpers")
local Json = require("json")
local PROBE = helpers.driver_root() .. "../../../tools/diagnostics/hs_permission_dialog_native.lua"
local PREFIX = "ERGOPTI_PERMISSION_UI_STAGE4 "
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

local function upvalue(fn, target, seen)
	seen = seen or {}
	if seen[fn] then return nil end
	seen[fn] = true
	for i = 1, math.huge do
		local name, value = debug.getupvalue(fn, i)
		if name == nil then break end
		if name == target then return fn, i, value end
		if type(value) == "function" then
			local owner, slot, found = upvalue(value, target, seen)
			if owner then return owner, slot, found end
		end
	end
end

local function modeled(mode, flag)
	return helpers.with_fresh_modules(MODULES, function()
		local old = { hs = _G.hs, open = io.open, stderr = io.stderr, stdout = io.stdout, rename = os.rename }
		local old_hook, old_mask, old_count = debug.gethook()
		local preloads = {}
		for _, name in ipairs(MODULES) do preloads[name] = package.preload[name] end
		local files, lines, stdout, trace, first_guard = {}, {}, {}, {}, {}
		local ids, next_id, wrapped, originals, configured = {}, 0, {}, {}, false
		local callback, frame_active, first_frame, changed = nil, false, false, false
		local stage4_publisher, writer_reentered = nil, false
		local function scalar(value)
			if type(value) == "string" or type(value) == "number" or type(value) == "boolean" or value == nil then
				return value == nil and "<nil>" or value
			end
			if not ids[value] then next_id = next_id + 1; ids[value] = next_id end
			return type(value) .. ":" .. ids[value]
		end
		local function slots(values)
			local result = { n = values.n }
			for i = 1, values.n do result[i] = scalar(values[i]) end
			return result
		end
		local wrap
		local function wrap_view(view)
			if type(view) ~= "userdata" then return end
			local index = getmetatable(view).__index
			for _, name in ipairs({ "isVisible", "hswindow", "frame", "delete", "evaluateJavaScript" }) do
				wrap(index, name, "view." .. name)
			end
		end
		wrap = function(object, key, name)
			local original = object[key]
			if type(original) ~= "function" or wrapped[original] then return end
			local forwarding = function(...)
				local args = slots(table.pack(...))
				local values = table.pack(original(...))
				trace[#trace + 1] = { name = name, args = args, returns = slots(values) }
				if frame_active then first_guard[#first_guard + 1] = { name = name, args = args } end
				if name == "UI.show_webview" then wrap_view(values[1]) end
				if name == "view.hswindow" and type(values[1]) == "table" then wrap(values[1], "id", "window.id") end
				return table.unpack(values, 1, values.n)
			end
			wrapped[forwarding] = true; originals[forwarding] = original
			object[key] = forwarding
		end
		local function configure()
			if configured then return end
			configured = true
			for _, pair in ipairs({ { "ui.ui_builder", "UI" }, { "ui.permission_dialog", "Dialog" },
				{ "ui.permission_dialog.login_items_guide", "Guide" }, { "adapters.timer_scheduler", "Scheduler" } }) do
				local _, _, provider = upvalue(package.preload[pair[1]], "value")
				assert(type(provider) == "table")
				for name, value in pairs(provider) do
					if type(value) == "function" then wrap(provider, name, pair[2] .. "." .. name) end
				end
			end
			for name in pairs(hs.window) do wrap(hs.window, name, "hs.window." .. name) end
			for name in pairs(hs.timer) do wrap(hs.timer, name, "hs.timer." .. name) end
			wrap(hs.fs, "mkdir", "hs.fs.mkdir"); wrap(hs.fs, "attributes", "hs.fs.attributes")
		end
		local function change_state(fn)
			local owner, slot, stage = upvalue(fn, "stage")
			if stage ~= 4 then return false end
			local _, _, busy = upvalue(fn, "busy")
			if busy ~= false then return false end
			if changed then return false end
			changed = true
			local _, _, observations = upvalue(fn, "observations")
			if mode == "later_not_observed" then
				owner, slot = upvalue(fn, "later_done"); assert(owner); debug.setupvalue(owner, slot, false)
			elseif mode == "one_view" then
				observations[2] = nil
			elseif mode == "login_closed" then
				local dialog = package.loaded["ui.permission_dialog"]
				local original = originals[dialog.is_open] or dialog.is_open
				dialog.is_open = function(kind) if kind == "login_items" then return false end; return original(kind) end
				wrap(dialog, "is_open", "Dialog.is_open")
			elseif mode == "invisible" or mode == "window_nil" or mode == "invalid_visible" then
				local index = getmetatable(observations[2]).__index
				if mode == "window_nil" then index.hswindow = function() return nil end; wrap(index, "hswindow", "view.hswindow")
				else index.isVisible = function() return mode == "invalid_visible" and "UNKNOWN/path" or false end; wrap(index, "isVisible", "view.isVisible") end
			end
			return true
		end
		io.open = function(path, access)
			if access == "rb" then
				if files[path] == nil then return nil end
				return { read = function() return files[path] end, close = function() return true end }
			end
			assert(access == "wb")
			return { write = function(_, bytes) files[path] = (files[path] or "") .. bytes; return true end, close = function() return true end }
		end
		os.rename = function(a, b) files[b], files[a] = files[a], nil; return true end
		io.stderr = { write = function(_, bytes)
			if bytes:sub(1, #PREFIX) == PREFIX then
				if mode == "writer_throw" then error("PRIVATE_DIAGNOSTIC_WRITER", 0) end
				if mode == "writer_reentry" and not writer_reentered then
					writer_reentered = true
					local owner, slot = upvalue(stage4_publisher, "stage4_pending")
					assert(owner)
					debug.setupvalue(owner, slot, { later = true, views = 2, login_items = true, visible = true, native_window = "non_nil" })
					stage4_publisher()
				end
			end
			lines[#lines + 1] = bytes; return true
		end }
		io.stdout = { write = function(_, bytes) stdout[#stdout + 1] = bytes; return true end }
		local result = table.pack(xpcall(function()
			debug.sethook(function(event)
				local info = debug.getinfo(2, "fS")
				if not info or info.source ~= "@" .. PROBE then return end
				if event == "call" then
					if mode == "invalid_snapshot" then
						local owner, slot, pending = upvalue(info.func, "stage4_pending")
						if owner and type(pending) == "table" then pending.views = -1 end
					end
					configure()
					local _, _, tick = upvalue(info.func, "tick")
					if type(tick) == "function" then
						callback = info.func
						local _, _, actual_publisher = upvalue(info.func, "stage4_observation")
						stage4_publisher = actual_publisher
						if not first_frame and change_state(info.func) then first_frame = true; frame_active = true end
					end
				elseif event == "return" and info.func == callback then frame_active = false end
			end, "cr")
			local run = assert(load("return function(mode, source, root, flag)\n" .. HARNESS .. "\nend", "@frozen-progress-model"))()
			run("healthy", PROBE, "/modeled/private/permission-progress", flag)
			debug.sethook()
			local summary = assert(Json.decode(table.concat(stdout)))
			if summary.packet then summary.packet = assert(Json.decode(summary.packet)) end
			local rows = {}
			for _, bytes in ipairs(lines) do
				if bytes:sub(1, #PREFIX) == PREFIX then
					helpers.assert_true(#bytes <= 512 and bytes:sub(-1) == "\n")
					rows[#rows + 1] = assert(Json.decode(bytes:sub(#PREFIX + 1)))
				end
			end
			return summary, rows, trace, first_guard, lines
		end, debug.traceback))
		debug.sethook(old_hook, old_mask, old_count)
		_G.hs, io.open, io.stderr, io.stdout, os.rename = old.hs, old.open, old.stderr, old.stdout, old.rename
		for _, name in ipairs(MODULES) do package.preload[name] = preloads[name] end
		if not result[1] then error(result[2], 0) end
		return table.unpack(result, 2, result.n)
	end)
end

local function payload(rows, expected)
	helpers.assert_true(#rows > 0 and #rows <= 32)
	local seen = {}
	for i, row in ipairs(rows) do
		local count = 0; for _ in pairs(row) do count = count + 1 end; helpers.assert_eq(count, 13)
		helpers.assert_eq(row.schema, 1); helpers.assert_eq(row.kind, "permission_ui_stage4_branch_observation")
		helpers.assert_eq(row.authority, false); helpers.assert_eq(row.native_verdict, "unchanged")
		helpers.assert_eq(row.pid, 123); helpers.assert_eq(row.nonce, string.rep("1", 32)); helpers.assert_eq(row.version, "1.1.1")
		helpers.assert_eq(row.sequence, i)
		local key = table.concat({ tostring(row.later), tostring(row.views), tostring(row.login_items), tostring(row.visible), row.native_window }, "/")
		helpers.assert_eq(seen[key], nil); seen[key] = true
	end
	local first = rows[1]
	for name, value in pairs(expected) do helpers.assert_eq(first[name], value, "independently declared " .. name) end
end

local function guard_names(guard)
	local names = {}
	for _, row in ipairs(guard) do names[#names + 1] = row.name end
	return table.concat(names, ",")
end

helpers.describe("Stage-4 observations preserve existing software branches", function()
	local cases = {
		{ "later_not_observed", { later = "not_observed", views = "not_read", login_items = "not_read", visible = "not_read", native_window = "not_read" }, "hs.timer.absoluteTime" },
		{ "one_view", { later = "accepted", views = 1, login_items = "not_read", visible = "not_read", native_window = "not_read" }, "hs.timer.absoluteTime" },
		{ "login_closed", { later = "accepted", views = 2, login_items = false, visible = "not_read", native_window = "not_read" }, "hs.timer.absoluteTime,Dialog.is_open" },
		{ "invisible", { later = "accepted", views = 2, login_items = true, visible = false, native_window = "not_read" }, "hs.timer.absoluteTime,Dialog.is_open,Dialog.is_open,hs.window.windowForID,view.isVisible" },
		{ "window_nil", { later = "accepted", views = 2, login_items = true, visible = true, native_window = "nil" }, "hs.timer.absoluteTime,Dialog.is_open,Dialog.is_open,hs.window.windowForID,view.isVisible,view.hswindow" },
		{ "healthy", { later = "accepted", views = 2, login_items = true, visible = true, native_window = "non_nil" }, "hs.timer.absoluteTime,Dialog.is_open,Dialog.is_open,hs.window.windowForID,view.isVisible,view.hswindow,window.id" },
	}
	for _, case in ipairs(cases) do
		helpers.it("records only acquired operands for " .. case[1], function()
			local result, rows, _, guard = modeled(case[1], true)
			payload(rows, case[2]); helpers.assert_eq(guard_names(guard), case[3])
			if case[1] == "healthy" then helpers.assert_eq(result.packet.status, "ok"); helpers.assert_eq(#result.packet.case_results, 10) end
		end)
	end
	helpers.it("adds no output or endpoint calls when progress is false", function()
		local off, rows_off, trace_off = modeled("healthy", false)
		local on, rows_on, trace_on = modeled("healthy", true)
		helpers.assert_eq(#rows_off, 0); helpers.assert_true(#rows_on > 0)
		helpers.assert_eq(Json.encode(off), Json.encode(on)); helpers.assert_eq(Json.encode(trace_off), Json.encode(trace_on))
	end)
	helpers.it("preserves the actual primary outcome when its new writer throws", function()
		local result, rows, trace = modeled("writer_throw", true)
		local healthy, _, healthy_trace = modeled("healthy", true)
		helpers.assert_eq(#rows, 0); helpers.assert_eq(Json.encode(result), Json.encode(healthy))
		helpers.assert_eq(Json.encode(trace), Json.encode(healthy_trace))
	end)
	helpers.it("latches the same held snapshot before diagnostic writer reentry", function()
		local result, rows, trace = modeled("writer_reentry", true)
		local healthy, _, healthy_trace = modeled("healthy", true)
		helpers.assert_eq(#rows, 1); helpers.assert_eq(Json.encode(result), Json.encode(healthy))
		helpers.assert_eq(Json.encode(trace), Json.encode(healthy_trace))
	end)
	helpers.it("suppresses an unknown visibility value without replacing the original return", function()
		local result, rows, _, guard = modeled("invalid_visible", true)
		helpers.assert_eq(#rows, 0); helpers.assert_eq(result.packet, nil); helpers.assert_eq(result.observer_live, true)
		helpers.assert_eq(guard_names(guard), "hs.timer.absoluteTime,Dialog.is_open,Dialog.is_open,hs.window.windowForID,view.isVisible")
	end)
	helpers.it("keeps every diagnostic stream silent when progress is false", function()
		local result, rows, _, _, lines = modeled("healthy", false)
		helpers.assert_eq(#rows, 0); helpers.assert_eq(#lines, 0)
		helpers.assert_eq(result.packet.status, "ok"); helpers.assert_eq(#result.packet.case_results, 10)
	end)
	helpers.it("suppresses an invalid held snapshot without affecting native actions", function()
		local result, rows, trace = modeled("invalid_snapshot", true)
		local healthy, _, healthy_trace = modeled("healthy", true)
		helpers.assert_eq(#rows, 0); helpers.assert_eq(Json.encode(result), Json.encode(healthy))
		helpers.assert_eq(Json.encode(trace), Json.encode(healthy_trace))
	end)
end)

return { modeled = modeled, HARNESS = HARNESS }
