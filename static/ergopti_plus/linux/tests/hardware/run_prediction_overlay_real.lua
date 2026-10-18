--- tests/hardware/run_prediction_overlay_real.lua

--- ==============================================================================
--- MODULE: Native GTK Prediction Overlay (Linux X11)
--- DESCRIPTION:
--- Exercises the real tooltip config, prediction overlay, renderer, Pango and
--- Cairo against an X11 display. Two French candidates must map as a painted,
--- focus-free GTK surface, follow selection and wrapping, then hide and release
--- their owned native window. No prediction provider or input injector runs.
---
--- Run from the Linux driver root with its source and shared Lua paths, retaining
--- any installed LGI paths in LUA_PATH:
---   XDG_CONFIG_HOME=/tmp/ergopti-overlay-config GDK_BACKEND=x11 xvfb-run -a \
---     luajit tests/hardware/run_prediction_overlay_real.lua
--- ERGOPTI_NATIVE_PROOF_ROOT optionally names an existing directory for two PNGs.
--- Exit 0 = assertions passed; 1 = regression; 2 = missing GTK/LGI/X11 environment.
--- ==============================================================================

require("compat.utf8").install()

--- Refuses an environment that cannot exercise the native surface.
--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

if not os.getenv("DISPLAY") or os.getenv("DISPLAY") == "" then abort("an X11 display is required; run under xvfb-run.") end
local ok, native = pcall(function()
	local lgi = require("lgi")
	local Gtk = lgi.require("Gtk", "3.0")
	local Gdk = lgi.require("Gdk", "3.0")
	local GdkX11 = lgi.require("GdkX11", "3.0")
	assert(Gtk.init_check(), "GTK could not open the display")
	assert(GdkX11.X11Display:is_type_of(Gdk.Display.get_default()), "GTK must use the actual X11 backend")
	return { Gtk = Gtk, Gdk = Gdk, GLib = lgi.GLib }
end)
if not ok then abort("GTK 3, LGI and a usable X11 display are required: " .. tostring(native)) end

local Gtk, Gdk, GLib = native.Gtk, native.Gdk, native.GLib
local Overlay, owned_window
local checks = 0

--- Records a native or logical assertion.
--- @param condition boolean
--- @param message string
local function check(condition, message)
	assert(condition, message)
	checks = checks + 1
	print("  ok   " .. message)
end

--- Lets GTK process mapping and drawing without entering an unbounded main loop.
local function pump()
	local deadline = GLib.get_monotonic_time() + 200000
	repeat
		while Gtk.events_pending() and GLib.get_monotonic_time() < deadline do Gtk.main_iteration_do(false) end
		GLib.usleep(5000)
	until GLib.get_monotonic_time() >= deadline
end

--- Verifies the mapped GTK window and reads its actual X11 pixels.
--- @param name string Optional screenshot suffix.
local function capture(name)
	pump()
	local windows = Gtk.Window.list_toplevels()
	check(#windows == 1, "exactly one owned GTK tooltip window exists")
	local window = windows[1]
	if owned_window then check(window == owned_window, "selection reuses the owned GTK surface") end
	owned_window = window
	check(window:get_visible() and window:get_mapped(), "the native tooltip is visible and mapped")
	check(window:get_accept_focus() == false and window:get_focus_on_map() == false, "the native tooltip cannot claim keyboard focus")
	local width, height = window:get_size()
	check(width > 40 and height > 10, "real Pango measurement gives the candidate rows a size")
	local pixels = assert(Gdk.pixbuf_get_from_window(window:get_window(), 0, 0, width, height), "the native surface must be readable")
	local bytes, channels, stride = pixels:get_pixels(), pixels:get_n_channels(), pixels:get_rowstride()
	check(type(bytes) == "string" and channels >= 3 and #bytes >= (height - 1) * stride + width * channels, "the native surface has complete RGB pixel data")
	local first, varied
	for y = 8, height - 9 do
		for x = 16, width - 17 do
			local offset = y * stride + x * channels + 1
			local rgb = bytes:sub(offset, offset + 2)
			first = first or rgb
			if rgb ~= first then varied = true; break end
		end
		if varied then break end
	end
	check(varied == true, "the panel interior contains painted pixels rather than a uniform blank surface")
	local proof_root = os.getenv("ERGOPTI_NATIVE_PROOF_ROOT")
	if proof_root and proof_root ~= "" then
		check(pixels:savev(proof_root .. "/prediction-overlay-" .. name .. ".png", "png", {}, {}) == true, "the optional native screenshot is saved")
	end
	print(string.format("NATIVE_OVERLAY_MAPPED %dx%d", width, height))
end

local passed, failure = xpcall(function()
	local Renderer = require("adapters.graphics_renderer")
	local Config = require("ui.tooltip.config")
	Overlay = require("ui.tooltip.llm")
	check(#Gtk.Window.list_toplevels() == 0, "the process starts without a foreign GTK window")
	check(Renderer.is_available(), "the real GTK renderer is available")
	check(Overlay.init({ style = Config.load(), screen_provider = function() return { x = 0, y = 0, w = 1024, h = 768 } end }), "the real tooltip configuration initializes the overlay")
	check(Overlay.show({
		{ to_type = " Bonjour à toutes et à tous" },
		{ to_type = " La réunion est prévue jeudi" },
	}, { model = "native fixture", profile = "French", validation_modifiers = { "alt" } }), "two French candidates are shown")
	check(Overlay.is_showing() and Overlay.active_index() == 1, "the first candidate owns the initial logical selection")
	capture("first")
	check(Overlay.is_visible(), "the overlay reports its mapped renderer")
	check(Overlay.select(2) and Overlay.active_index() == 2, "the second candidate can be selected")
	capture("selected")
	check(Overlay.move(1) and Overlay.active_index() == 1, "forward movement wraps to the first candidate")
	check(Overlay.move(-1) and Overlay.active_index() == 2, "backward movement wraps to the last candidate")
	check(Overlay.hide() == true, "the renderer acknowledges hiding")
	pump()
	check(not Overlay.is_showing() and not Overlay.is_visible() and not Renderer.is_visible(), "hiding clears logical and native visibility")
	check(not Overlay.select(1) and not Overlay.move(1), "hiding forgets all logical candidates")
	check(not owned_window:get_visible() and not owned_window:get_mapped(), "the owned GTK window is physically hidden")
	Overlay.destroy()
	pump()
	check(#Gtk.Window.list_toplevels() == 0 and owned_window:get_window() == nil, "destroy releases the owned native GTK surface")
end, debug.traceback)
if Overlay then pcall(Overlay.destroy) end
if not passed then io.stderr:write("FAIL: " .. tostring(failure) .. "\n"); os.exit(1) end
print(string.format("NATIVE_PREDICTION_OVERLAY_PASS %d checks", checks))
