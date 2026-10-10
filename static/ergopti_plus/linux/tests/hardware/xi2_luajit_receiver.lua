--- tests/hardware/xi2_luajit_receiver.lua
--- Private native diagnostic; no input injection or installed-runtime admission.
local ffi = require("ffi")
local candidate, logger_source, runtime_source, witness_path, xi_path,
    x11_path, bridge_path, xkb_path, xkb11_path, server_pid, uid, nonce = unpack(arg)
server_pid, uid = assert(tonumber(server_pid)), assert(tonumber(uid))
assert(nonce and nonce:match("^[a-f0-9]+$") and #nonce == 32)
local original_runtime = assert(loadfile(runtime_source))()
assert(original_runtime.xi == nil, "canonical runtime must still be undeclared")
local runtime = {}
for key, value in pairs(original_runtime) do runtime[key] = value end
runtime.xi = xi_path -- Explicit CONTROLLED diagnostic projection; no global/generated write.
package.loaded["_generated.native_runtime"] = runtime
local driver = assert(runtime_source:match("^(.*)/_generated/native_runtime%.lua$"))
local shared = assert(logger_source:match("^(.*)/logger/shim%.lua$"))
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
    .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
-- Load the real driver logger shim, including its normal LuaJIT core fallback.
-- Count and suppress this private diagnostic's log output before its closed fact.
local output_print, log_bytes = print, 0
print = function(...)
    local parts = {...}
    for _, value in ipairs(parts) do log_bytes = log_bytes + #tostring(value) end
    assert(log_bytes <= 32768, "diagnostic logger bound")
end
package.loaded["logger.shim"] = assert(loadfile(logger_source))()
local Probe = assert(loadfile(candidate))()
ffi.cdef([[
    struct _XDisplay; struct xcb_connection_t; struct xkb_context; struct xkb_keymap;
    struct _XDisplay *XOpenDisplay(const char *);
    int XCloseDisplay(struct _XDisplay *); int XSync(struct _XDisplay *, int);
    struct xcb_connection_t *XGetXCBConnection(struct _XDisplay *);
    int xkb_x11_setup_xkb_extension(struct xcb_connection_t *, unsigned short, unsigned short,
        int, unsigned short *, unsigned short *, unsigned char *, unsigned char *);
    int xkb_x11_get_core_keyboard_device_id(struct xcb_connection_t *);
    struct xkb_context *xkb_context_new(int); void xkb_context_unref(struct xkb_context *);
    struct xkb_keymap *xkb_x11_keymap_new_from_device(struct xkb_context *, struct xcb_connection_t *, int, int);
    struct xkb_keymap *xkb_keymap_new_from_string(struct xkb_context *, const char *, int, int);
    char *xkb_keymap_get_as_string(struct xkb_keymap *, int);
    unsigned int xkb_keymap_num_layouts(struct xkb_keymap *);
    void xkb_keymap_unref(struct xkb_keymap *); void free(void *);
    unsigned long XInternAtom(struct _XDisplay *, const char *, int);
    void XIChangeProperty(struct _XDisplay *, int, unsigned long, unsigned long, int, int,
        const unsigned char *, int);
    void XIDeleteProperty(struct _XDisplay *, int, unsigned long);
    int XIGetProperty(struct _XDisplay *, int, unsigned long, long, long, int, unsigned long,
        unsigned long *, int *, unsigned long *, unsigned long *, unsigned char **);
    int XFree(void *);
    unsigned long ep_xi_type(unsigned int, unsigned int);
    unsigned long ep_xi_field(unsigned int, unsigned int, unsigned int);
    int ep_property_what(unsigned int); int ep_symbol_matches(void *, const char *);
    int ep_xvfb_peers(int, unsigned int); int usleep(unsigned int);
]])
local W = ffi.load(witness_path)
local X = ffi.load(runtime.x11)
local B, K, K11 = ffi.load(runtime.x11_xcb), ffi.load(runtime.xkbcommon), ffi.load(runtime.xkbcommon_x11)
local Xi = ffi.load(runtime.xi)
for _, row in ipairs({{X.XOpenDisplay, x11_path}, {B.XGetXCBConnection, bridge_path},
    {K.xkb_context_new, xkb_path}, {K11.xkb_x11_setup_xkb_extension, xkb11_path},
    {Xi.XIChangeProperty, xi_path}}) do
    assert(type(row[1]) == "cdata" and W.ep_symbol_matches(ffi.cast("void *", row[1]), row[2]) == 1)
end
local control, context, keymap, bytes, property, device, identity, groups
local comparisons, cases, stage, cleanup_ok = 0, 0, 0, true
local observed = {}
local function readback(expected)
    local kind, format = ffi.new("unsigned long[1]"), ffi.new("int[1]")
    local count, left, data = ffi.new("unsigned long[1]"), ffi.new("unsigned long[1]"), ffi.new("unsigned char *[1]")
    local result = Xi.XIGetProperty(control, device, property, 0, 64, 0, 0,
        kind, format, count, left, data)
    local valid = result == 0 and tonumber(left[0]) == 0
    if expected then
        valid = valid and tonumber(kind[0]) == 31 and tonumber(format[0]) == 8
            and tonumber(count[0]) == #expected and data[0] ~= nil
            and ffi.string(data[0], count[0]) == expected
    else valid = valid and tonumber(kind[0]) == 0 and tonumber(count[0]) == 0 end
    if data[0] ~= nil then valid = X.XFree(data[0]) == 1 and valid end
    return valid
end
local passed = pcall(function()
    stage = 1
    assert(W.ep_xvfb_peers(server_pid, uid) == 0)
    control = X.XOpenDisplay(os.getenv("DISPLAY")); assert(control ~= nil)
    assert(W.ep_xvfb_peers(server_pid, uid) == 1)
    local xcb = B.XGetXCBConnection(control); assert(xcb ~= nil)
    assert(K11.xkb_x11_setup_xkb_extension(xcb, 1, 0, 0, nil, nil, nil, nil) ~= 0)
    device = K11.xkb_x11_get_core_keyboard_device_id(xcb); assert(device >= 0)
    context = K.xkb_context_new(0); assert(context ~= nil)
    keymap = K11.xkb_x11_keymap_new_from_device(context, xcb, device, 0); assert(keymap ~= nil)
    bytes = K.xkb_keymap_get_as_string(keymap, 1); assert(bytes ~= nil)
    local serialized = ffi.string(bytes)
    ffi.C.free(bytes); bytes = nil
    K.xkb_keymap_unref(keymap); keymap = nil
    keymap = K.xkb_keymap_new_from_string(context, serialized, 1, 0); assert(keymap ~= nil)
    bytes = K.xkb_keymap_get_as_string(keymap, 1); assert(bytes ~= nil)
    identity, groups = ffi.string(bytes), tonumber(K.xkb_keymap_num_layouts(keymap))
    ffi.C.free(bytes); bytes = nil
    K.xkb_keymap_unref(keymap); keymap = nil
    assert(K.xkb_context_unref(context) == nil); context = nil
    stage = 2
    assert(Probe.read(identity, groups)) -- Candidate owns its separate Display and event queue.
    assert(W.ep_xvfb_peers(server_pid, uid) == 2)
    local types = {
        {"ErgoptiXIPropertyCookieV2", {"type", "serial", "send_event", "display", "extension", "evtype", "cookie", "data"}},
        {"ErgoptiXIPropertyEventV2", {"type", "serial", "send_event", "display", "extension", "evtype", "time", "deviceid", "property", "what"}},
        {"ErgoptiXIPropertyMaskV2", {"deviceid", "mask_len", "mask"}}
    }
    for kind, row in ipairs(types) do
        assert(ffi.sizeof(row[1]) == tonumber(W.ep_xi_type(kind - 1, 0))); comparisons = comparisons + 1
        assert(ffi.alignof(row[1]) == tonumber(W.ep_xi_type(kind - 1, 1))); comparisons = comparisons + 1
        for index, field in ipairs(row[2]) do
            assert(ffi.offsetof(row[1], field) == tonumber(W.ep_xi_field(kind - 1, index - 1, 0))); comparisons = comparisons + 1
        end
    end
    assert(comparisons == 27)
    assert(ffi.sizeof("ErgoptiXkbEvent") == tonumber(W.ep_xi_type(3, 0))); comparisons = comparisons + 1
    assert(ffi.alignof("ErgoptiXkbEvent") == tonumber(W.ep_xi_type(3, 1))); comparisons = comparisons + 1
    assert(type(X.XGetEventData) == "cdata" and type(X.XFreeEventData) == "cdata")
    stage = 3
    property = X.XInternAtom(control, "ergopti_luajit_" .. nonce, 0); assert(property ~= 0)
    assert(readback(nil))
    for phase = 0, 2 do
        if phase == 2 then Xi.XIDeleteProperty(control, device, property)
        else
            local text = phase == 0 and "owned-one" or "owned-two"
            Xi.XIChangeProperty(control, device, property, 31, 8, 0, text, #text)
        end
        assert(X.XSync(control, 0) == 0)
        local expected
        if phase < 2 then expected = phase == 0 and "owned-one" or "owned-two" end
        assert(readback(expected))
        local view
        for _ = 1, 100 do
            assert(Probe.read(identity, groups))
            view = Probe.property_invalidation_view()
            if view.status == "observed" and view.fields.property == tonumber(property)
                and view.fields.deviceid == device and view.fields.what == W.ep_property_what(phase) then break end
            ffi.C.usleep(10000)
        end
        assert(view.status == "observed" and view.fields.property == tonumber(property)
            and view.fields.deviceid == device and view.fields.what == W.ep_property_what(phase))
        for _, field in pairs(view.fields) do assert(type(field) == "number") end
        local original_property = view.fields.property
        view.fields.property = -1
        assert(Probe.property_invalidation_view().fields.property == original_property)
        cases = cases + 1
        observed[#observed + 1] = string.format('{"phase":%d,"deviceid":%d,"property":%.0f,"what":%d}',
            phase, device, original_property, W.ep_property_what(phase))
    end
    stage = 4
end)
-- Every acquired emitter resource has an unconditional owner inverse; no GC ACK.
if bytes ~= nil then cleanup_ok = pcall(ffi.C.free, bytes) and cleanup_ok end
if keymap ~= nil then cleanup_ok = pcall(K.xkb_keymap_unref, keymap) and cleanup_ok end
if context ~= nil then local ok, value = pcall(K.xkb_context_unref, context); cleanup_ok = ok and value == nil and cleanup_ok end
if control ~= nil and property ~= nil and device then
    local ok = pcall(function() Xi.XIDeleteProperty(control, device, property); assert(X.XSync(control, 0) == 0); assert(readback(nil)) end)
    cleanup_ok = ok and cleanup_ok
end
local close_called = pcall(Probe.close)
local view_called, final_view = pcall(Probe.property_invalidation_view)
cleanup_ok = close_called and view_called and final_view.status == "unavailable"
    and final_view.reason == "native-property-connection-retired" and cleanup_ok
if control ~= nil then
    cleanup_ok = W.ep_xvfb_peers(server_pid, uid) == 1 and cleanup_ok
    local ok, status = pcall(X.XCloseDisplay, control); cleanup_ok = ok and status == 0 and cleanup_ok
end
cleanup_ok = W.ep_xvfb_peers(server_pid, uid) == 0 and cleanup_ok
local qualified = passed and cleanup_ok and comparisons == 29 and cases == 3
output_print(string.format('{"qualified":%s,"stage":%d,"abi_comparisons":%d,"native_cases":%d,"cleanup":%s,"input_injections":0,"native_epoch_claim":false,"runtime_projection":"CONTROLLED","cases":[%s]}',
    tostring(qualified), stage, comparisons, cases, tostring(cleanup_ok), table.concat(observed, ",")))
os.exit(qualified and 0 or 1)
