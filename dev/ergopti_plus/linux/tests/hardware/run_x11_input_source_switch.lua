--- tests/hardware/run_x11_input_source_switch.lua
--- Real Xvfb regression: a successful switch must activate the selected group.
package.path = "./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;" .. package.path
local helpers = require("tests.helpers")
package.loaded["core.logger.engine.shim"] = helpers.make_logger_stub()
local uv, ffi = require("luv"), require("ffi")
assert(require("core.fs.engine.paths").driver_root():find("[;?]"), "test driver must retain its literal delimiter")
ffi.cdef[[
struct _XDisplay;
struct _XDisplay *XOpenDisplay(const char *);
int XCloseDisplay(struct _XDisplay *);
int XSync(struct _XDisplay *, int);
int XkbLockGroup(struct _XDisplay *, unsigned int, unsigned int);
int XkbLatchGroup(struct _XDisplay *, unsigned int, unsigned int);
typedef struct {
 unsigned char group, locked_group;
 unsigned short base_group, latched_group;
 unsigned char mods, base_mods, latched_mods, locked_mods, compat_state;
 unsigned char grab_mods, compat_grab_mods, lookup_mods, compat_lookup_mods;
 unsigned short ptr_buttons;
} TestXkbState;
int XkbGetState(struct _XDisplay *, unsigned int, TestXkbState *);
]]
local x = ffi.load("libX11.so.6")
local display = assert(x.XOpenDisplay(nil), "private Xvfb unavailable")
local function state()
	local out = ffi.new("TestXkbState[1]")
	assert(x.XkbGetState(display, 0x100, out) == 0)
	return tonumber(out[0].group), tonumber(out[0].latched_group)
end
local function wait_for(done)
	local deadline = uv.hrtime() + 10000000000
	while not done() and uv.hrtime() < deadline do uv.run("once") end
	assert(done(), "owned switch did not settle before its deadline")
end
local ok, err = xpcall(function()
	local executed = os.execute("setxkbmap -layout us,fr -variant ,oss -option ctrl:nocaps"); assert(executed == true or executed == 0)
	assert(x.XkbLockGroup(display, 0x100, 1) ~= 0)
	x.XSync(display, 0)
	assert(state() == 1, "precondition requires the second group")
	local Switch = require("adapters.input_source_switch")
	local port = Switch.native_port()
	port.backend = function() return Switch.X11 end
	local switcher = Switch.new(port)
	local completed, accepted, reason = false, nil, nil
	switcher.select("fr(oss)", function(success, detail) completed, accepted, reason = true, success, detail end)
	wait_for(function() return completed end)
	assert(accepted == true, tostring(reason))
	assert(state() == 0, "successful switch left a different group active")
	local query = assert(io.popen("setxkbmap -query", "r"))
	local listing = query:read("*a"); assert(query:close())
	local parsed = assert(Switch.parse_setxkbmap_query(listing))
	assert(parsed.layouts[1] == "fr" and parsed.layouts[2] == "us", "other layouts were lost")
	assert(parsed.variants[1] == "oss" and parsed.variants[2] == "", "layout variants lost alignment")
	assert(listing:match("\noptions:%s*ctrl:nocaps"), "the existing XKB option was lost")

	-- A latched group can make the effective state nonzero even after a
	-- successful XkbLockGroup(0). The actual worker must refuse that state.
	assert(x.XkbLatchGroup(display, 0x100, 1) ~= 0)
	x.XSync(display, 0)
	local group, latched = state()
	assert(group == 1 and latched == 1, "latched-group precondition not established")
	local done, result = false, nil
	local operation = require("core.process.adapters.owned_process").start(uv.exepath(), {
		"./adapters/input_source_group_worker.lua", tostring(uv.os_getpid()), require("_generated.native_runtime").x11,
	}, { owner = "xkb-latched-regression", timeout_ms = 3000 }, function(value) done, result = true, value end)
	assert(type(operation) == "table", "worker dispatch refused without an owner")
	wait_for(function() return done end)
	assert(type(result) == "table" and result.ok == false, "latched nonzero group was acknowledged")
	assert(state() == 1, "the test requires the effective group to remain nonzero")
	done, result = false, nil
	operation = require("core.process.adapters.owned_process").start(uv.exepath(), {
		"./adapters/input_source_group_worker.lua", tostring(uv.os_getpid()), "../unexpected.so",
	}, { owner = "xkb-invalid-soname-regression", timeout_ms = 3000 }, function(value) done, result = true, value end)
	assert(type(operation) == "table", "invalid-soname worker dispatch refused without an owner")
	wait_for(function() return done end)
	assert(type(result) == "table" and result.ok == false, "invalid X11 soname was accepted")
end, debug.traceback)
x.XCloseDisplay(display)
if not ok then error(err, 0) end
print("real X11 input source group regression passed")
