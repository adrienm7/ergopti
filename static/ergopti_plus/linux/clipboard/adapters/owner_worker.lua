--- clipboard/adapters/owner_worker.lua

--- ==============================================================================
--- MODULE: Multi-Format Clipboard Owner (Linux)
--- DESCRIPTION:
--- A standalone LuaJIT child that puts a saved clipboard back with every format
--- it held: it takes the X11 CLIPBOARD selection through libX11, or the Wayland
--- selection through the data-control protocol (ext-data-control-v1, else
--- wlr-data-control-unstable-v1) through libwayland-client, and serves each
--- saved target's exact bytes until another client copies.
---
--- WHY A CHILD THAT FORKS:
--- A selection lives as long as its owner answers requests. xclip and wl-copy,
--- the text writers, offer one type each; this owner offers them all, and like
--- them it forks once the selection is taken: the parent's exit status is the
--- receipt the daemon waits for, the detached child serves.
---
--- FEATURES & RATIONALE:
--- 1. Self-contained: only ffi, the snapshot file and the library soname given
---    on the command line, so the child needs no module path of the driver.
--- 2. The snapshot file is removed as soon as it is read: it may hold whatever
---    the user had copied, and nothing else needs it.
--- 3. X11 answers TARGETS and TIMESTAMP, refuses MULTIPLE, and sends a payload
---    larger than one request through ICCCM INCR.
--- 4. Exit codes: 0 selection taken (or probe passed), 64 usage, 65 bad
---    snapshot, 69 no display, library or data-control, 70 ownership refused.
--- ==============================================================================

local M = {}

local MAGIC = "ERGOPTI-CLIPBOARD-1\n"
local EXIT_OK, EXIT_USAGE, EXIT_DATA, EXIT_UNAVAILABLE, EXIT_SOFTWARE = 0, 64, 65, 69, 70

-- X11 constants (X.h, Xatom.h).
local PROPERTY_NOTIFY, SELECTION_CLEAR, SELECTION_REQUEST = 28, 29, 30
local SELECTION_NOTIFY = 31
local PROPERTY_CHANGE_MASK = 4194304 -- 1 << 22
local PROP_MODE_REPLACE, PROP_MODE_APPEND = 0, 2
local PROPERTY_DELETE = 1
local NONE = 0
local XA_ATOM, XA_INTEGER = 4, 19

-- 4-byte words of a ChangeProperty request before its data (X11 protocol).
local CHANGE_PROPERTY_HEADER_WORDS = 6

-- Wayland data-control protocols, newest first; both share one message layout.
local DATA_CONTROL_PROTOCOLS = {
	{ prefix = "ext_data_control", manager = "ext_data_control_manager_v1", version = 1 },
	{ prefix = "zwlr_data_control", manager = "zwlr_data_control_manager_v1", version = 1 },
}




-- ===============================================
-- ===============================================
-- ======= 1/ Snapshot and process ===============
-- ===============================================
-- ===============================================

--- Decodes the snapshot the daemon wrote: MAGIC, then per target a
--- "<name bytes> <data bytes>\n" header, the name and the data.
--- @param blob string
--- @return table|nil targets Ordered { { name, data } }.
function M.decode(blob)
	if type(blob) ~= "string" or blob:sub(1, #MAGIC) ~= MAGIC then return nil end
	local targets, position, seen = {}, #MAGIC + 1, {}
	while position <= #blob do
		local name_len, data_len, header_end = blob:match("^(%d+) (%d+)\n()", position)
		if not name_len then return nil end
		name_len, data_len = tonumber(name_len), tonumber(data_len)
		local name = blob:sub(header_end, header_end + name_len - 1)
		local data = blob:sub(header_end + name_len, header_end + name_len + data_len - 1)
		if name_len == 0 or #name ~= name_len or #data ~= data_len or name:find("[%z\n]") or seen[name] then return nil end
		seen[name] = true
		targets[#targets + 1] = { name = name, data = data }
		position = header_end + name_len + data_len
	end
	if #targets == 0 then return nil end
	return targets
end

--- Encodes targets for decode().
--- @param targets table Ordered { { name, data } }.
--- @return string
function M.encode(targets)
	local parts = { MAGIC }
	for _, target in ipairs(targets) do
		parts[#parts + 1] = string.format("%d %d\n", #target.name, #target.data)
		parts[#parts + 1] = target.name
		parts[#parts + 1] = target.data
	end
	return table.concat(parts)
end

local PROCESS_DECLARATIONS = {
	"int fork(void);",
	"int setsid(void);",
	"void _exit(int status);",
	"int open(const char *path, int flags, ...);",
	"int dup2(int oldfd, int newfd);",
	"int close(int fd);",
	"long write(int fd, const void *buffer, unsigned long count);",
	"typedef void (*ErgoptiSignalHandler)(int);",
	"ErgoptiSignalHandler signal(int signum, ErgoptiSignalHandler handler);",
}

--- Declares the libc calls, tolerating another module's identical declaration.
--- @param ffi table
--- @param declarations table
local function declare(ffi, declarations)
	for _, declaration in ipairs(declarations) do
		local ok, err = pcall(ffi.cdef, declaration)
		if not ok and not tostring(err):find("redefin", 1, true) then error(err, 0) end
	end
end

-- Descriptors above stdio closed in the serving child; the daemon's evdev
-- and uinput handles must not outlive it in a clipboard owner.
local INHERITED_FD_CEILING = 4096

--- Detaches the serving child and returns in it; the parent exits 0, the
--- daemon's receipt that the selection is taken.
--- @param ffi table
--- @param keep_fd integer The display connection the child serves on.
local function detach(ffi, keep_fd)
	local C = ffi.C
	local pid = C.fork()
	if pid < 0 then os.exit(EXIT_SOFTWARE) end
	-- _exit: the parent must not close the display connection the child keeps.
	if pid > 0 then C._exit(EXIT_OK) end
	C.setsid()
	local null = C.open("/dev/null", 2) -- O_RDWR
	if null >= 0 then
		for fd = 0, 2 do C.dup2(null, fd) end
		if null > 2 then C.close(null) end
	end
	for fd = 3, INHERITED_FD_CEILING do
		if fd ~= keep_fd then C.close(fd) end
	end
end

--- Writes every byte to a descriptor a reader may close early.
--- @return boolean
local function write_all(ffi, fd, data)
	local buffer, offset = ffi.cast("const char *", data), 0
	while offset < #data do
		local written = ffi.C.write(fd, buffer + offset, #data - offset)
		if written <= 0 then
			-- EINTR (4) retries; EPIPE and the rest mean the reader left.
			if ffi.errno() ~= 4 then return false end
		else
			offset = offset + tonumber(written)
		end
	end
	return true
end




-- ===============================================
-- ===============================================
-- ======= 2/ X11 owner ==========================
-- ===============================================
-- ===============================================

local X11_DECLARATIONS = {
	"struct _XDisplay *XOpenDisplay(const char *display);",
	"unsigned long XDefaultRootWindow(struct _XDisplay *display);",
	"unsigned long XInternAtom(struct _XDisplay *display, const char *name, int only_if_exists);",
	"unsigned long XCreateSimpleWindow(struct _XDisplay *, unsigned long, int, int, unsigned int,"
		.. " unsigned int, unsigned int, unsigned long, unsigned long);",
	"int XFlush(struct _XDisplay *);",
	"unsigned long XGetSelectionOwner(struct _XDisplay *, unsigned long);",
	"int XSetSelectionOwner(struct _XDisplay *, unsigned long, unsigned long, unsigned long);",
	"int XSelectInput(struct _XDisplay *, unsigned long, long);",
	"int XChangeProperty(struct _XDisplay *, unsigned long, unsigned long, unsigned long, int, int,"
		.. " const unsigned char *, int);",
	"int XSendEvent(struct _XDisplay *, unsigned long, int, long, void *);",
	"long XMaxRequestSize(struct _XDisplay *);",
	"int XConnectionNumber(struct _XDisplay *);",
	"typedef union { int type; long pad[24]; } ErgoptiOwnerEvent;",
	"int XNextEvent(struct _XDisplay *, ErgoptiOwnerEvent *);",
	"typedef struct { int type; unsigned long serial; int send_event; void *display; unsigned long owner,"
		.. " requestor, selection, target, property, time; } ErgoptiOwnerRequest;",
	"typedef struct { int type; unsigned long serial; int send_event; void *display; unsigned long requestor,"
		.. " selection, target, property, time; } ErgoptiOwnerNotify;",
	"typedef struct { int type; unsigned long serial; int send_event; void *display; unsigned long window,"
		.. " selection, time; } ErgoptiOwnerClear;",
	"typedef struct { int type; unsigned long serial; int send_event; void *display; unsigned long window,"
		.. " atom, time; int state; } ErgoptiOwnerProperty;",
	"typedef int (*ErgoptiOwnerErrorHandler)(struct _XDisplay *, void *);",
	"ErgoptiOwnerErrorHandler XSetErrorHandler(ErgoptiOwnerErrorHandler handler);",
}

--- Serves the snapshot as the X11 CLIPBOARD owner until another client copies.
--- @param soname string libX11's soname.
--- @param targets table|nil nil probes the display only.
--- @return integer exit code (only on failure or probe; serving never returns).
local function run_x11(soname, targets)
	local ffi = require("ffi")
	declare(ffi, PROCESS_DECLARATIONS)
	declare(ffi, X11_DECLARATIONS)
	local loaded, x11 = pcall(ffi.load, soname)
	if not loaded then return EXIT_UNAVAILABLE end
	local display = x11.XOpenDisplay(nil)
	if display == nil then return EXIT_UNAVAILABLE end
	if targets == nil then return EXIT_OK end

	-- A requestor that vanishes mid-transfer raises BadWindow; Xlib's default
	-- handler would end the owner and lose the clipboard for everyone else.
	local on_error = ffi.cast("ErgoptiOwnerErrorHandler", function() return 0 end)
	x11.XSetErrorHandler(on_error)

	local function atom(name) return x11.XInternAtom(display, name, 0) end
	local clipboard, atom_targets, atom_timestamp = atom("CLIPBOARD"), atom("TARGETS"), atom("TIMESTAMP")
	local atom_multiple, atom_incr, atom_utf8 = atom("MULTIPLE"), atom("INCR"), atom("UTF8_STRING")
	local atom_text = atom("TEXT")
	local window = x11.XCreateSimpleWindow(display, x11.XDefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0)
	x11.XSelectInput(display, window, PROPERTY_CHANGE_MASK)

	local by_atom, served = {}, {}
	for _, target in ipairs(targets) do
		local id = atom(target.name)
		if id ~= atom_targets and id ~= atom_timestamp and id ~= atom_multiple then
			by_atom[tonumber(id)] = target.data
			served[#served + 1] = id
		end
	end

	-- ICCCM forbids CurrentTime for ownership: a zero-length append to our own
	-- window yields a PropertyNotify carrying the server's time.
	local event = ffi.new("ErgoptiOwnerEvent[1]")
	local stamp_atom = atom("ERGOPTI_OWNER_STAMP")
	x11.XChangeProperty(display, window, stamp_atom, XA_INTEGER, 8, PROP_MODE_APPEND, nil, 0)
	local acquired_at
	repeat
		x11.XNextEvent(display, event)
		if event[0].type == PROPERTY_NOTIFY then
			acquired_at = ffi.cast("ErgoptiOwnerProperty *", event).time
		end
	until acquired_at
	x11.XSetSelectionOwner(display, clipboard, window, acquired_at)
	if x11.XGetSelectionOwner(display, clipboard) ~= window then return EXIT_SOFTWARE end
	x11.XFlush(display)
	detach(ffi, x11.XConnectionNumber(display))

	-- One property change per request: a larger payload goes through INCR in
	-- chunks of what the server accepts (XMaxRequestSize counts 4-byte words).
	local chunk = (tonumber(x11.XMaxRequestSize(display)) - CHANGE_PROPERTY_HEADER_WORDS) * 4
	local transfers = {}
	local notify = ffi.new("ErgoptiOwnerEvent[1]")

	local function answer(request, property)
		local reply = ffi.cast("ErgoptiOwnerNotify *", notify)
		reply.type, reply.send_event, reply.display = SELECTION_NOTIFY, 1, display
		reply.requestor, reply.selection, reply.target = request.requestor, request.selection, request.target
		reply.property, reply.time = property, request.time
		x11.XSendEvent(display, request.requestor, 0, 0, notify)
	end

	local function serve(request)
		local property = request.property ~= NONE and request.property or request.target
		local target = request.target
		if target == atom_targets then
			local list = ffi.new("long[?]", #served + 2)
			list[0], list[1] = atom_targets, atom_timestamp
			for index, id in ipairs(served) do list[index + 1] = id end
			x11.XChangeProperty(display, request.requestor, property, XA_ATOM, 32, PROP_MODE_REPLACE,
				ffi.cast("const unsigned char *", list), #served + 2)
			return answer(request, property)
		end
		if target == atom_timestamp then
			local value = ffi.new("long[1]", acquired_at)
			x11.XChangeProperty(display, request.requestor, property, XA_INTEGER, 32, PROP_MODE_REPLACE,
				ffi.cast("const unsigned char *", value), 1)
			return answer(request, property)
		end
		local data = by_atom[tonumber(target)]
		if data == nil then return answer(request, NONE) end
		-- TEXT names no encoding; the bytes saved under it go out as UTF-8.
		local kind = target == atom_text and atom_utf8 or target
		if #data <= chunk then
			x11.XChangeProperty(display, request.requestor, property, kind, 8, PROP_MODE_REPLACE, data, #data)
			return answer(request, property)
		end
		x11.XSelectInput(display, request.requestor, PROPERTY_CHANGE_MASK)
		local size = ffi.new("long[1]", #data)
		x11.XChangeProperty(display, request.requestor, property, atom_incr, 32, PROP_MODE_REPLACE,
			ffi.cast("const unsigned char *", size), 1)
		transfers[tostring(request.requestor) .. ":" .. tostring(property)] =
			{ requestor = request.requestor, property = property, kind = kind, data = data, offset = 0 }
		return answer(request, property)
	end

	local function continue_transfer(change)
		if change.state ~= PROPERTY_DELETE then return end
		local key = tostring(change.window) .. ":" .. tostring(change.atom)
		local transfer = transfers[key]
		if not transfer then return end
		local piece = transfer.data:sub(transfer.offset + 1, transfer.offset + chunk)
		-- The empty piece after the last one ends the transfer.
		x11.XChangeProperty(display, transfer.requestor, transfer.property, transfer.kind, 8, PROP_MODE_REPLACE,
			piece, #piece)
		transfer.offset = transfer.offset + #piece
		if #piece == 0 then transfers[key] = nil end
	end

	while true do
		x11.XNextEvent(display, event)
		local kind = event[0].type
		if kind == SELECTION_REQUEST then
			serve(ffi.cast("ErgoptiOwnerRequest *", event))
		elseif kind == SELECTION_CLEAR then
			if ffi.cast("ErgoptiOwnerClear *", event).selection == clipboard then break end
		elseif kind == PROPERTY_NOTIFY then
			continue_transfer(ffi.cast("ErgoptiOwnerProperty *", event))
		end
		x11.XFlush(display)
	end
	return EXIT_OK
end




-- ===============================================
-- ===============================================
-- ======= 3/ Wayland owner ======================
-- ===============================================
-- ===============================================

local WAYLAND_DECLARATIONS = {
	"struct wl_interface;",
	"struct wl_message { const char *name; const char *signature; const struct wl_interface **types; };",
	"struct wl_interface { const char *name; int version; int method_count; const struct wl_message *methods;"
		.. " int event_count; const struct wl_message *events; };",
	"union wl_argument { int32_t i; uint32_t u; int32_t f; const char *s; void *o; uint32_t n; void *a; int32_t h; };",
	"void *wl_display_connect(const char *name);",
	"int wl_display_roundtrip(void *display);",
	"int wl_display_dispatch(void *display);",
	"int wl_display_get_fd(void *display);",
	"void *wl_proxy_marshal_array_constructor_versioned(void *proxy, uint32_t opcode, union wl_argument *args,"
		.. " const struct wl_interface *interface, uint32_t version);",
	"void wl_proxy_marshal_array(void *proxy, uint32_t opcode, union wl_argument *args);",
	"int wl_proxy_add_listener(void *proxy, void **implementation, void *data);",
	"uint32_t wl_proxy_get_version(void *proxy);",
}

--- Builds the four data-control interfaces of one protocol family.
--- @param ffi table
--- @param family table One DATA_CONTROL_PROTOCOLS entry.
--- @param seat_interface cdata wl_seat_interface.
--- @param anchor table Keeps every C object alive for the process lifetime.
--- @return table { manager, source, device, offer } interface pointers.
local function build_interfaces(ffi, family, seat_interface, anchor)
	local function str(text)
		local buffer = ffi.new("char[?]", #text + 1, text)
		anchor[#anchor + 1] = buffer
		return buffer
	end
	local names = { "manager", "source", "device", "offer" }
	local interfaces = {}
	for _, name in ipairs(names) do
		interfaces[name] = ffi.new("struct wl_interface[1]")
		anchor[#anchor + 1] = interfaces[name]
	end
	local function types(list)
		local array = ffi.new("const struct wl_interface *[?]", math.max(#list, 1))
		for index, value in ipairs(list) do array[index - 1] = value end
		anchor[#anchor + 1] = array
		return array
	end
	local function messages(list)
		local array = ffi.new("struct wl_message[?]", math.max(#list, 1))
		for index, message in ipairs(list) do
			array[index - 1].name = str(message[1])
			array[index - 1].signature = str(message[2])
			array[index - 1].types = types(message[3] or {})
		end
		anchor[#anchor + 1] = array
		return array, #list
	end
	local null = ffi.cast("const struct wl_interface *", nil)
	local m, s, d, o = interfaces.manager, interfaces.source, interfaces.device, interfaces.offer
	local function fill(target, interface_name, requests, events)
		target[0].name = str(interface_name)
		target[0].version = family.version
		target[0].methods, target[0].method_count = messages(requests)
		target[0].events, target[0].event_count = messages(events)
	end
	fill(m, family.manager,
		{ { "create_data_source", "n", { s } }, { "get_data_device", "no", { d, seat_interface } }, { "destroy", "" } }, {})
	fill(s, family.prefix .. "_source_v1",
		{ { "offer", "s", { null } }, { "destroy", "" } },
		{ { "send", "sh", { null, null } }, { "cancelled", "" } })
	fill(d, family.prefix .. "_device_v1",
		{ { "set_selection", "?o", { s } }, { "destroy", "" }, { "set_primary_selection", "?o", { s } } },
		{ { "data_offer", "n", { o } }, { "selection", "?o", { o } }, { "finished", "" },
			{ "primary_selection", "?o", { o } } })
	fill(o, family.prefix .. "_offer_v1",
		{ { "receive", "sh", { null, null } }, { "destroy", "" } },
		{ { "offer", "s", { null } } })
	local function pointer(array) return ffi.cast("const struct wl_interface *", array) end
	return { manager = pointer(m), source = pointer(s), device = pointer(d), offer = pointer(o) }
end

--- Serves the snapshot as the Wayland selection until another client copies.
--- @param soname string libwayland-client's soname.
--- @param targets table|nil nil probes the display and data-control only.
--- @return integer exit code (only on failure or probe; serving never returns).
local function run_wayland(soname, targets)
	local ffi = require("ffi")
	declare(ffi, PROCESS_DECLARATIONS)
	declare(ffi, WAYLAND_DECLARATIONS)
	local loaded, wl = pcall(ffi.load, soname)
	if not loaded then return EXIT_UNAVAILABLE end
	declare(ffi, { "extern const struct wl_interface wl_registry_interface;",
		"extern const struct wl_interface wl_seat_interface;" })
	local display = wl.wl_display_connect(nil)
	if display == nil then return EXIT_UNAVAILABLE end
	local anchor = {}

	local registry_interface = ffi.cast("const struct wl_interface *", wl.wl_registry_interface)
	local seat_interface = ffi.cast("const struct wl_interface *", wl.wl_seat_interface)
	local registry = wl.wl_proxy_marshal_array_constructor_versioned(display, 1,
		ffi.new("union wl_argument[1]"), registry_interface, wl.wl_proxy_get_version(display))
	if registry == nil then return EXIT_UNAVAILABLE end

	local globals = {}
	local on_global = ffi.cast("void (*)(void *, void *, uint32_t, const char *, uint32_t)",
		function(_, _, name, interface, version)
			local key = ffi.string(interface)
			if not globals[key] then globals[key] = { name = name, version = version } end
		end)
	local on_global_remove = ffi.cast("void (*)(void *, void *, uint32_t)", function() end)
	local registry_listener = ffi.new("void *[2]", { ffi.cast("void *", on_global), ffi.cast("void *", on_global_remove) })
	anchor[#anchor + 1] = { on_global, on_global_remove, registry_listener }
	wl.wl_proxy_add_listener(registry, registry_listener, nil)
	if wl.wl_display_roundtrip(display) < 0 then return EXIT_UNAVAILABLE end

	local family
	for _, candidate in ipairs(DATA_CONTROL_PROTOCOLS) do
		if globals[candidate.manager] then family = candidate; break end
	end
	-- GNOME offers no data-control: the text writer's refusal stays there.
	if not family or not globals.wl_seat then return EXIT_UNAVAILABLE end
	if targets == nil then return EXIT_OK end

	local interfaces = build_interfaces(ffi, family, seat_interface, anchor)
	local function bind(global, interface, version)
		local name = ffi.new("char[?]", #ffi.string(interface.name) + 1, ffi.string(interface.name))
		anchor[#anchor + 1] = name
		local args = ffi.new("union wl_argument[4]")
		args[0].u, args[1].s, args[2].u, args[3].n = global.name, name, version, 0
		return wl.wl_proxy_marshal_array_constructor_versioned(registry, 0, args, interface, version)
	end
	local manager = bind(globals[family.manager], interfaces.manager, family.version)
	local seat = bind(globals.wl_seat, seat_interface, 1)
	if manager == nil or seat == nil then return EXIT_SOFTWARE end

	local create = ffi.new("union wl_argument[1]")
	create[0].n = 0
	local source = wl.wl_proxy_marshal_array_constructor_versioned(manager, 0, create, interfaces.source, family.version)
	local device_args = ffi.new("union wl_argument[2]")
	device_args[0].n, device_args[1].o = 0, seat
	local device = wl.wl_proxy_marshal_array_constructor_versioned(manager, 1, device_args, interfaces.device,
		family.version)
	if source == nil or device == nil then return EXIT_SOFTWARE end

	local by_mime, cancelled = {}, false
	for _, target in ipairs(targets) do
		by_mime[target.name] = target.data
		local mime = ffi.new("char[?]", #target.name + 1, target.name)
		anchor[#anchor + 1] = mime
		local offer = ffi.new("union wl_argument[1]")
		offer[0].s = mime
		wl.wl_proxy_marshal_array(source, 0, offer)
	end
	local on_send = ffi.cast("void (*)(void *, void *, const char *, int32_t)", function(_, _, mime, fd)
		local data = by_mime[ffi.string(mime)]
		if data then write_all(ffi, fd, data) end
		ffi.C.close(fd)
	end)
	local on_cancelled = ffi.cast("void (*)(void *, void *)", function() cancelled = true end)
	local source_listener = ffi.new("void *[2]", { ffi.cast("void *", on_send), ffi.cast("void *", on_cancelled) })
	anchor[#anchor + 1] = { on_send, on_cancelled, source_listener }
	wl.wl_proxy_add_listener(source, source_listener, nil)

	local selection = ffi.new("union wl_argument[1]")
	selection[0].o = source
	wl.wl_proxy_marshal_array(device, 0, selection)
	if wl.wl_display_roundtrip(display) < 0 or cancelled then return EXIT_SOFTWARE end
	detach(ffi, wl.wl_display_get_fd(display))
	while not cancelled do
		if wl.wl_display_dispatch(display) < 0 then break end
	end
	return EXIT_OK
end




-- ===============================================
-- ===============================================
-- ======= 4/ Entry point ========================
-- ===============================================
-- ===============================================

--- Runs the owner.
--- @param argv table { "probe"|"own", "x11"|"wayland", soname, snapshot_path (own only) }.
--- @return integer exit code
function M.run(argv)
	local mode, backend, soname, path = argv[1], argv[2], argv[3], argv[4]
	if (mode ~= "probe" and mode ~= "own") or (backend ~= "x11" and backend ~= "wayland")
		or type(soname) ~= "string" or soname == "" or (mode == "own") ~= (type(path) == "string") then
		return EXIT_USAGE
	end
	local has_ffi, ffi = pcall(require, "ffi")
	if not has_ffi then return EXIT_UNAVAILABLE end
	-- Callbacks run inside C calls made from Lua; a compiled trace cannot host them.
	require("jit").off()
	declare(ffi, PROCESS_DECLARATIONS)
	-- A paste target that closes its pipe early must not end the owner.
	ffi.C.signal(13, ffi.cast("ErgoptiSignalHandler", 1)) -- SIGPIPE, SIG_IGN
	local targets = nil
	if mode == "own" then
		local file = io.open(path, "rb")
		if not file then return EXIT_DATA end
		local blob = file:read("*a")
		file:close()
		os.remove(path)
		targets = M.decode(blob)
		if not targets then return EXIT_DATA end
	end
	if backend == "x11" then return run_x11(soname, targets) end
	return run_wayland(soname, targets)
end

if type(arg) == "table" and type(arg[0]) == "string"
	and arg[0]:gsub("\\", "/"):match("([^/]+)$") == "owner_worker.lua" then
	os.exit(M.run(arg))
end

return M
