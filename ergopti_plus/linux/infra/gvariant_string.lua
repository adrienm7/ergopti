--- infra/gvariant_string.lua

--- ==============================================================================
--- MODULE: Native GLib GVariant String Admission
--- DESCRIPTION:
--- Decodes gsettings output with the same GLib grammar that printed it. Quote
--- selection and escapes belong to GVariant, not to an approximate Lua parser.
--- Only a complete string variant is admitted; every native variant and error
--- allocation is released before the decoded bytes leave this boundary.
--- ==============================================================================

local M = {}
local ffi = require("ffi")
ffi.cdef([[
	void *g_variant_parse(const void *type, const char *text, const char *limit,
		const char **endptr, void **error);
	const char *g_variant_get_string(void *value, size_t *length);
	void g_variant_unref(void *value);
	void g_error_free(void *error);
]])
local glib = ffi.load(require("_generated.native_runtime").network_runtime.libraries.glib)
local STRING_TYPE = ffi.new("char[2]", "s")

--- Decodes exactly one complete native string without borrowing its allocation.
--- @param text any gsettings' GVariant output.
--- @return string|nil value Decoded string, including the empty string.
--- @return string|nil error Constant refusal without settings content.
function M.decode(text)
	if type(text) ~= "string" or text:find("\0", 1, true) then return nil, "invalid GVariant string" end
	local variant, error_slot = nil, ffi.new("void *[1]")
	local called, value = pcall(function()
		-- A null endptr requires the whole input, and the explicit type refuses
		-- arrays, object paths and other variants that happen to contain text.
		variant = glib.g_variant_parse(STRING_TYPE, text, nil, nil, error_slot)
		if variant == nil or error_slot[0] ~= nil then return nil end
		local length = ffi.new("size_t[1]")
		local bytes = glib.g_variant_get_string(variant, length)
		if bytes == nil then return nil end
		return ffi.string(bytes, length[0])
	end)
	if variant ~= nil then glib.g_variant_unref(variant) end
	if error_slot[0] ~= nil then glib.g_error_free(error_slot[0]) end
	if not called or type(value) ~= "string" then return nil, "invalid GVariant string" end
	return value
end

return M
