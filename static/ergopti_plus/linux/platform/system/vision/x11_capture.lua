--- platform/system/vision/x11_capture.lua

--- ==============================================================================
--- MODULE: X11 Screen Capture (Linux)
--- DESCRIPTION:
--- Reads the pixels of one window, or of a rectangle of the root window, from
--- the X server through libxcb (GetImage, ZPixmap), in this process, and turns
--- them into the shared grayscale image of the screen vision service
--- (docs/design/screen-vision.md).
---
--- FEATURES & RATIONALE:
--- 1. A window is read from its own drawable, not from the root: an XWayland
---    window (VS Code runs on XWayland by default) answers GetImage under a
---    Wayland session too, where the root shows nothing of native Wayland
---    windows.
--- 2. libxcb, not Xlib, for the reason platform/focus/x11_focus.lua gives: a
---    dead X server makes Xlib exit() the process.
--- 3. The conversion to gray runs on the reply buffer through the FFI, with the
---    shared BT.601 rounding (auto_click_matcher.gray), so a capture scores
---    the same as the corpus scenes.
--- 4. A refusal is returned as a reason of the screen vision vocabulary, never
---    an empty image: a 24- or 32-bit visual is required, anything else is
---    "capture_unsupported_visual".
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "platform.system.vision.x11_capture"

-- X11 protocol: ImageFormat ZPixmap and an all-planes mask.
local Z_PIXMAP = 2
local ALL_PLANES = 0xFFFFFFFF

local _transport = nil
local _connection = nil




-- =========================================
-- =========================================
-- ======= 1/ Transport ====================
-- =========================================
-- =========================================

--- Binds libxcb for GetImage, or returns nil with a reason.
--- @return table|nil transport { connect, disconnect, healthy, root, geometry, image }
--- @return string|nil reason
local function build_transport()
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi then return nil, "LuaJIT FFI unavailable" end
	local defined, define_error = pcall(ffi.cdef, [[
		typedef struct ergopti_vision_xcb_connection_t ergopti_vision_xcb_connection_t;
		typedef struct { unsigned int sequence; } ergopti_vision_xcb_cookie_t;
		typedef struct { uint32_t root; } ergopti_vision_xcb_screen_t;
		typedef struct { ergopti_vision_xcb_screen_t *data; int rem; int index; } ergopti_vision_xcb_screen_iterator_t;
		typedef struct ergopti_vision_xcb_setup_t ergopti_vision_xcb_setup_t;
		typedef struct { uint8_t response_type, depth; uint16_t sequence; uint32_t length, visual; uint8_t pad0[20]; } ergopti_vision_xcb_get_image_reply_t;
		typedef struct { uint8_t response_type, depth; uint16_t sequence; uint32_t length, root; int16_t x, y; uint16_t width, height, border_width; uint8_t pad0[2]; } ergopti_vision_xcb_get_geometry_reply_t;
		typedef struct { uint8_t response_type, same_screen; uint16_t sequence; uint32_t length, child; int16_t dst_x, dst_y; } ergopti_vision_xcb_translate_reply_t;
		ergopti_vision_xcb_connection_t *xcb_connect(const char *display, int *screen);
		void xcb_disconnect(ergopti_vision_xcb_connection_t *connection);
		int xcb_connection_has_error(ergopti_vision_xcb_connection_t *connection);
		const ergopti_vision_xcb_setup_t *xcb_get_setup(ergopti_vision_xcb_connection_t *connection);
		ergopti_vision_xcb_screen_iterator_t xcb_setup_roots_iterator(const ergopti_vision_xcb_setup_t *setup);
		void xcb_screen_next(ergopti_vision_xcb_screen_iterator_t *iterator);
		ergopti_vision_xcb_cookie_t xcb_get_image(ergopti_vision_xcb_connection_t *connection, uint8_t format, uint32_t drawable, int16_t x, int16_t y, uint16_t width, uint16_t height, uint32_t plane_mask);
		ergopti_vision_xcb_get_image_reply_t *xcb_get_image_reply(ergopti_vision_xcb_connection_t *connection, ergopti_vision_xcb_cookie_t cookie, void **error);
		uint8_t *xcb_get_image_data(const ergopti_vision_xcb_get_image_reply_t *reply);
		int xcb_get_image_data_length(const ergopti_vision_xcb_get_image_reply_t *reply);
		ergopti_vision_xcb_cookie_t xcb_get_geometry(ergopti_vision_xcb_connection_t *connection, uint32_t drawable);
		ergopti_vision_xcb_get_geometry_reply_t *xcb_get_geometry_reply(ergopti_vision_xcb_connection_t *connection, ergopti_vision_xcb_cookie_t cookie, void **error);
		ergopti_vision_xcb_cookie_t xcb_translate_coordinates(ergopti_vision_xcb_connection_t *connection, uint32_t src_window, uint32_t dst_window, int16_t src_x, int16_t src_y);
		ergopti_vision_xcb_translate_reply_t *xcb_translate_coordinates_reply(ergopti_vision_xcb_connection_t *connection, ergopti_vision_xcb_cookie_t cookie, void **error);
		void free(void *pointer);
	]])
	if not defined and not tostring(define_error):find("redefin", 1, true) then
		return nil, "ffi.cdef failed: " .. tostring(define_error)
	end
	local loaded, library = pcall(ffi.load, "xcb")
	if not loaded then
		loaded, library = pcall(ffi.load, "libxcb.so.1")
		if not loaded then return nil, "libxcb is not installed" end
	end

	local connection, root = nil, 0
	local transport = {}

	local function release(error_slot)
		if error_slot[0] ~= nil then ffi.C.free(error_slot[0]) end
	end

	function transport.connect()
		local screen = ffi.new("int[1]")
		local opened = library.xcb_connect(nil, screen)
		if opened == nil or library.xcb_connection_has_error(opened) ~= 0 then
			if opened ~= nil then library.xcb_disconnect(opened) end
			return false, "cannot connect to the X server (is DISPLAY set?)"
		end
		local iterator = library.xcb_setup_roots_iterator(library.xcb_get_setup(opened))
		for _ = 1, screen[0] do
			if iterator.rem <= 1 then break end
			library.xcb_screen_next(iterator)
		end
		if iterator.data == nil then
			library.xcb_disconnect(opened)
			return false, "the X server reported no screen"
		end
		connection, root = opened, iterator.data.root
		return true
	end

	function transport.disconnect()
		if connection ~= nil then library.xcb_disconnect(connection) end
		connection, root = nil, 0
	end

	function transport.healthy()
		return connection ~= nil and library.xcb_connection_has_error(connection) == 0
	end

	function transport.root() return root end

	function transport.geometry(window)
		local error_slot = ffi.new("void*[1]")
		local reply = library.xcb_get_geometry_reply(connection, library.xcb_get_geometry(connection, window), error_slot)
		release(error_slot)
		if reply == nil then return nil end
		local w, h = tonumber(reply.width), tonumber(reply.height)
		ffi.C.free(reply)
		local moved = library.xcb_translate_coordinates_reply(connection,
			library.xcb_translate_coordinates(connection, window, root, 0, 0), error_slot)
		release(error_slot)
		if moved == nil then return nil end
		local x, y = tonumber(moved.dst_x), tonumber(moved.dst_y)
		ffi.C.free(moved)
		return x, y, w, h
	end

	--- Reads a ZPixmap rectangle of a drawable as gray pixels.
	--- @return table|nil pixels, string|nil reason
	function transport.image(drawable, x, y, width, height, gray)
		local error_slot = ffi.new("void*[1]")
		local reply = library.xcb_get_image_reply(connection,
			library.xcb_get_image(connection, Z_PIXMAP, drawable, x, y, width, height, ALL_PLANES), error_slot)
		release(error_slot)
		if reply == nil then return nil, "capture_refused" end
		local depth = tonumber(reply.depth)
		local length = library.xcb_get_image_data_length(reply)
		local data = library.xcb_get_image_data(reply)
		-- 24- and 32-bit visuals are 4 bytes per pixel, blue first, on every
		-- little-endian X server Ergopti runs on.
		if (depth ~= 24 and depth ~= 32) or length < width * height * 4 then
			ffi.C.free(reply)
			return nil, "capture_unsupported_visual"
		end
		local stride = math.floor(length / height)
		local pixels, n = {}, 0
		for row = 0, height - 1 do
			local base = row * stride
			for col = 0, width - 1 do
				local at = base + col * 4
				n = n + 1
				pixels[n] = gray(data[at + 2], data[at + 1], data[at])
			end
		end
		ffi.C.free(reply)
		return pixels
	end

	return transport
end




-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- Binds a transport (the production one, or a test double).
--- @param transport table|nil nil binds libxcb.
--- @return boolean bound, string|nil reason
function M.bind(transport)
	if _transport and _connection then pcall(_transport.disconnect) end
	_connection = nil
	if transport then
		_transport = transport
		return true
	end
	local built, reason = build_transport()
	if not built then return false, reason end
	_transport = built
	return true
end

--- Whether a transport is bound.
--- @return boolean
function M.has_transport()
	return _transport ~= nil
end

--- Closes the connection; the next capture reconnects.
function M.close()
	if _transport and _connection then
		pcall(_transport.disconnect)
		Logger.info(LOG, "Screen capture X connection closed.")
	end
	_connection = nil
end

local function ensure_connected()
	if _connection and _transport.healthy() then return true end
	if _connection then pcall(_transport.disconnect) end
	_connection = nil
	local ok, reason = _transport.connect()
	if not ok then return false, reason end
	_connection = true
	Logger.success(LOG, "Connected to the X server for screen capture.")
	return true
end

--- Captures a window, or a rectangle of the root window.
--- @param target table { window = id }, { root = true } (the whole screen) or
---   { rect = { x, y, width, height } } in root coordinates.
--- @param gray function (r, g, b) -> integer, the shared rounding.
--- @return table|nil image The screen vision image; nil with a reason.
--- @return string|nil reason
function M.capture(target, gray)
	assert(type(target) == "table", "a capture needs a window or a rectangle")
	assert(type(gray) == "function", "a capture needs the shared gray rounding")
	if not _transport then return nil, "capture_unavailable" end
	local connected = ensure_connected()
	if not connected then return nil, "capture_unavailable" end
	local drawable, x, y, width, height, frame
	if target.window then
		local id = tonumber(target.window)
		if not id or id == 0 then return nil, "no_foreground_window" end
		local fx, fy, fw, fh = _transport.geometry(id)
		if not fx then return nil, "no_foreground_window" end
		drawable, x, y, width, height = id, 0, 0, fw, fh
		frame = { x = fx, y = fy, width = fw, height = fh }
	elseif target.root then
		local root = _transport.root()
		local _, _, fw, fh = _transport.geometry(root)
		if not fw then return nil, "capture_unavailable" end
		drawable, x, y, width, height = root, 0, 0, fw, fh
		frame = { x = 0, y = 0, width = fw, height = fh }
	else
		local r = target.rect
		assert(type(r) == "table", "a capture needs a window or a rectangle")
		drawable, x, y, width, height = _transport.root(), r.x, r.y, r.width, r.height
		frame = { x = r.x, y = r.y, width = r.width, height = r.height }
	end
	if width < 1 or height < 1 then return nil, "capture_empty" end
	local pixels, reason = _transport.image(drawable, x, y, width, height, gray)
	if not pixels then return nil, reason end
	return { width = width, height = height, pixels = pixels, scale = 1, frame = frame }
end

return M
