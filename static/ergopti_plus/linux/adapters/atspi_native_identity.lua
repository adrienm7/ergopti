--- adapters/atspi_native_identity.lua

--- ==============================================================================
--- MODULE: Native AT-SPI Object Identity
--- DESCRIPTION:
--- Reads public AtspiObject/AtspiApplication fields inside the isolated helper.
--- The layouts follow atspi-object.h, atspi-application.h and GLib gobject.h;
--- runtime GType checks precede the public struct casts. No label is an owner.
--- ==============================================================================

local M = {}
local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then return M end
local ok_cdef = pcall(ffi.cdef, [[
	typedef struct { void *g_class; } ErgoptiAtspiTypeInstance;
	typedef struct {
		ErgoptiAtspiTypeInstance g_type_instance;
		unsigned int ref_count;
		void *qdata;
	} ErgoptiAtspiGObject;
	typedef struct {
		ErgoptiAtspiGObject parent;
		void *hash;
		char *bus_name;
	} ErgoptiAtspiApplicationPrefix;
	typedef struct {
		ErgoptiAtspiGObject parent;
		ErgoptiAtspiApplicationPrefix *app;
		char *path;
	} ErgoptiAtspiObjectPrefix;
	unsigned long atspi_object_get_type(void);
	unsigned long atspi_application_get_type(void);
	int g_type_check_instance_is_a(void *instance, unsigned long iface_type);
]])
local ok_atspi, atspi = pcall(ffi.load, "libatspi.so.0")
local ok_gobject, gobject = pcall(ffi.load, "libgobject-2.0.so.0")
if not ok_cdef or not ok_atspi or not ok_gobject then return M end

--- Copies the live object's native destination while its reference is retained.
--- Caller must release the accessible only after this copy has completed.
--- @param node cdata Retained AtspiAccessible native reference.
--- @return table|nil identity Exact unique bus name and accessible object path.
function M.capture(node)
	if node == nil or gobject.g_type_check_instance_is_a(node, atspi.atspi_object_get_type()) == 0 then return nil end
	local object = ffi.cast("ErgoptiAtspiObjectPrefix *", node)
	if object.app == nil or object.path == nil
		or gobject.g_type_check_instance_is_a(object.app, atspi.atspi_application_get_type()) == 0
		or object.app.bus_name == nil then return nil end
	local bus, path = ffi.string(object.app.bus_name), ffi.string(object.path)
	if not bus:match("^:%d+%.%d+$") or path:sub(1, 1) ~= "/" then return nil end
	return { native_bus_name = bus, native_object_path = path }
end

return M
