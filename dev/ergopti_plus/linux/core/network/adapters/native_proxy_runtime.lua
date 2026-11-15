--- core/network/adapters/native_proxy_runtime.lua

--- ==============================================================================
--- MODULE: Shared Native GIO Runtime Inspection (Linux)
--- DESCRIPTION:
--- Owns the lookup child's native ABI and borrowed resolver inspection. Package
--- admission uses the same implementation without a destination lookup, PAC
--- evaluation or settings write. Libproxy support acknowledges native selection;
--- it does not prove every desktop settings provider.
--- ==============================================================================

local M = {}

--- Loads the native ABI without requiring a development package or lgi.
--- @return table|nil
function M.load()
	local loaded, ffi = pcall(require, "ffi")
	if not loaded then return nil end
	local declared = pcall(ffi.cdef, [[
		typedef struct { unsigned int domain; int code; char *message; } ErgoptiProxyError;
		void *g_proxy_resolver_get_default(void);
		int g_proxy_resolver_is_supported(void *resolver);
		char **g_proxy_resolver_lookup(void *resolver, const char *uri,
			void *cancellable, ErgoptiProxyError **error);
		const char *g_type_name_from_instance(void *instance);
		void g_strfreev(char **strings);
		void g_error_free(ErgoptiProxyError *error);
		int unsetenv(const char *name);
		void *g_settings_schema_source_get_default(void);
		void *g_settings_schema_source_lookup(void *source, const char *schema_id, int recursive);
		void g_settings_schema_unref(void *schema);
		void *g_settings_new(const char *schema_id);
		char *g_settings_get_string(void *settings, const char *key);
		void g_free(void *memory);
		void g_object_unref(void *object);
	]])
	if not declared then return nil end
	local ok, gio, gobject, glib, null_pointer = pcall(function()
		local catalogue = require("_generated.native_runtime")
		local names = catalogue.network_runtime.libraries
		return ffi.load(names.gio), ffi.load(names.gobject), ffi.load(names.glib), ffi.cast("void *", 0)
	end)
	if not ok then return nil end
	return { ffi = ffi, gio = gio, gobject = gobject, glib = glib, null_pointer = null_pointer }
end

--- Tests a native pointer without relying on LuaJIT's cross-type nil equality.
--- Lua nil remains the absence value for Lua-owned receipts and native test ports.
--- @param native table Loaded native ABI and its retained NULL pointer.
--- @param pointer userdata|nil Actual native pointer value.
--- @return boolean
function M.is_null(native, pointer)
	return pointer == nil or pointer == native.null_pointer
end

--- Returns the exact native borrowed resolver and observed implementation type.
--- @param native table
--- @return userdata|nil, string|nil, string|nil
function M.default_resolver(native)
	-- GIO constructs candidates before their support check, including off GNOME.
	-- Every lookup/installer entry must admit the owned compiled schema first.
	if not M.proxy_schema_available(native) then
		return nil, nil, "proxy-backend-unavailable"
	end
	local ffi = native.ffi
	local resolver = native.gio.g_proxy_resolver_get_default()
	if M.is_null(native, resolver) or native.gio.g_proxy_resolver_is_supported(resolver) ~= 1 then
		return nil, nil, "proxy-backend-unavailable"
	end
	local type_name = native.gobject.g_type_name_from_instance(resolver)
	local backend = not M.is_null(native, type_name) and ffi.string(type_name) or "unknown"
	-- GDummyProxyResolver always returns DIRECT and is not desktop configuration.
	if backend == "GDummyProxyResolver" then
		return nil, backend, "proxy-backend-unavailable"
	end
	return resolver, backend
end

--- Checks a compiled schema without instantiating settings or reading its values.
--- The lookup returns one owned schema reference, released before returning.
--- @param native table
--- @return boolean
function M.proxy_schema_available(native)
	local source = native.gio.g_settings_schema_source_get_default()
	if M.is_null(native, source) then return false end
	local catalogue = require("_generated.native_runtime")
	local schema = native.gio.g_settings_schema_source_lookup(source,
		catalogue.network_runtime.proxy_schema, 1)
	if M.is_null(native, schema) then return false end
	native.gio.g_settings_schema_unref(schema)
	return true
end

--- Reads the PAC address of the GNOME proxy settings GProxyResolverGnome reads.
--- The resolver answers DIRECT for a PAC it could not download, so only this
--- address lets the lookup child tell that apart from a PAC that said DIRECT.
--- @param native table Loaded native ABI.
--- @return string|nil url The PAC address while the mode is "auto", else nil.
function M.configured_pac_url(native)
	if not M.proxy_schema_available(native) then return nil end
	local catalogue = require("_generated.native_runtime")
	local settings = native.gio.g_settings_new(catalogue.network_runtime.proxy_schema)
	if M.is_null(native, settings) then return nil end
	local function read(key)
		local value = native.gio.g_settings_get_string(settings, key)
		if M.is_null(native, value) then return nil end
		local text = native.ffi.string(value)
		native.glib.g_free(value)
		return text
	end
	local mode, url = read("mode"), read("autoconfig-url")
	native.gobject.g_object_unref(settings)
	if mode ~= "auto" or type(url) ~= "string" or url == "" or url:find("[%z\r\n]") then return nil end
	return url
end

--- Reports required ABI/backend availability without calling proxy lookup.
--- The shipped module set requires its compiled proxy schema even off GNOME:
--- GIO constructs candidates before checking their desktop support. A supported
--- libproxy resolver still acknowledges selection, not every desktop's settings.
--- @return table
function M.inspect()
	local loaded, uv = pcall(require, "luv")
	if not loaded or type(uv) ~= "table" then return { ok = false, error = "proxy-async-unavailable" } end
	for _, name in ipairs({ "spawn", "new_pipe", "new_timer", "exepath", "close", "is_closing", "run", "kill",
		"read_start", "read_stop", "write", "shutdown", "timer_stop", "fs_stat",
		"fs_open", "fs_fstat", "fs_read", "fs_close", "fs_readlink" }) do
		if type(uv[name]) ~= "function" then return { ok = false, error = "proxy-async-unavailable" } end
	end
	local native = M.load()
	if not native then return { ok = false, error = "proxy-native-unavailable" } end
	local resolver, _, refusal = M.default_resolver(native)
	if not resolver then return { ok = false, error = refusal or "proxy-backend-unavailable" } end
	return { ok = true, acknowledgement = "native-runtime", schema_available = true,
		schema_required = true, selection_scope = "native-selection" }
end

return M
