--- tests/support/focus_watch_worker_fixture.lua

--- ==============================================================================
--- MODULE: Controlled Resident Focus Worker Callbacks
--- DESCRIPTION:
--- Executes the actual worker's publication, listener and request bodies against
--- controlled native ports. The retained-focus checker remains production code;
--- no native GTK, GLib callback ABI or kernel qualification is claimed here.
--- ==============================================================================

local M = {}
local helpers = require("tests.helpers")
local Focus = require("adapters.atspi_focus")
local Json = require("json")

--- Builds the original worker closures with separately controlled native events.
--- @param source string|nil Worker source; absent selects the actual driver file.
--- @return table state Native observations and callable original worker bodies.
function M.new(source)
	if source == nil then
		local file = assert(io.open(helpers.driver_root() .. "/adapters/atspi_focus_watch_worker.lua", "r"))
		source = file:read("*a"); file:close()
	end
	local emit = assert(source:match('(\tlocal function emit%(kind, snapshot%).-)\n\tlocal handles = nil'), "worker emit body missing")
	local publish = assert(source:match('(\tlocal handles = nil.-)\n\tlocal function abort'), "worker publisher body missing")
	local schedule = assert(source:match('(\tlocal function schedule%(%).-)\n\tlocal ok, error_message'), "worker scheduler body missing")
	local event = assert(source:match('(\t\tevent_callback = ffi%.cast.-)\n\t\tlistener = atspi%.atspi_event_listener_new'), "worker event body missing")
	local control = assert(source:match('(\t\tlocal control_buffer, control_pending.-)\n\t\tcontrol_source = glib%.g_unix_fd_add'), "worker control body missing")
	local state = { now = 1000, messages = {}, current = "A", checks = 0, scans = 0, released = 0, events_freed = 0 }
	local fields = { A = { role = 61 }, B = { role = 40 } }
	local window = {}
	local api
	local backend = {
		clear = function() end,
		focused = function(node) state.checks = state.checks + 1; return node == fields[state.current] end,
		active = function()
			local callback = state.during_check; state.during_check = nil
			if callback then callback() end
			return true
		end,
		role = function(node) return node.role end,
		release = function() state.released = state.released + 1 end,
	}
	local function snapshot(name)
		return { role = fields[name].role, active_scope = true, native_bus_name = ":1.7", native_object_path = "/field/" .. name }
	end
	local function handles(name)
		return { focus = fields[name], window = window, backend = backend, snapshot = snapshot(name) }
	end
	local focus = {
		_check_native_watch_focus = Focus._check_native_watch_focus,
		_release_native_watch_focus = Focus._release_native_watch_focus,
		_get_native_watch_snapshot = function()
			state.scans = state.scans + 1
			local captured = state.current
			local callback = state.during_scan; state.during_scan = nil
			if callback then callback() end
			return snapshot(captured), true, handles(captured)
		end,
	}
	local ffi = { C = {} }
	function ffi.cast(_, value) return value end
	function ffi.string(value, count) return type(value) == "table" and value.data:sub(1, count) or value end
	function ffi.new() return {} end
	function ffi.errno() return 11 end
	function ffi.C.read(_, buffer)
		local value = state.input or ""; state.input = nil; buffer.data = value; return #value
	end
	function ffi.C.write(_, text, count) state.messages[#state.messages + 1] = assert(Json.decode(text)); return count end
	local env = {
		Focus = focus, Json = Json, Monotonic = { now_ms = function() return state.now end }, ffi = ffi,
		glib = { g_idle_add = function() state.scheduled = true; return 1 end },
		gobject = { g_boxed_free = function() state.events_freed = state.events_freed + 1 end },
		atspi = { atspi_event_get_type = function() return 1 end }, state = state,
	}
	setmetatable(env, { __index = _G })
	local chunk = "local sequence,request,dirty=0,0,false\nlocal descriptor,control=1,2\n"
		.. "local idle_source,idle_callback,event_callback,control_callback\n" .. emit .. "\n" .. publish
		.. "\nlocal function abort() state.failed=true end\n" .. schedule .. "\n" .. event .. "\n" .. control
		.. "\nreturn {seed=function(value)handles=value end,publish=publish,focus=event_callback,control=control_callback,emit=emit}\n"
	local compiled, reason
	if setfenv then
		compiled, reason = loadstring(chunk, "actual resident worker bodies"); if compiled then setfenv(compiled, env) end
	else compiled, reason = load(chunk, "actual resident worker bodies", "t", env) end
	assert(compiled, reason); api = compiled(); api.seed(handles("A"))
	function state.publish() api.publish() end
	function state.clear_handles() api.seed(nil) end
	function state.focus(name)
		state.current = name
		api.focus({ type = "object:state-changed:focused", source = fields[name] })
	end
	function state.child_name() api.focus({ type = "object:property-change:accessible-name", source = fields.B }) end
	function state.request(number) state.input = "R" .. number .. "\n"; api.control() end
	function state.ready() api.emit("ready"); api.publish() end
	return state
end

return M
