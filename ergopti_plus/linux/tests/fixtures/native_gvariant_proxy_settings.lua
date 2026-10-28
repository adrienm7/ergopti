--- tests/fixtures/native_gvariant_proxy_settings.lua

--- ==============================================================================
--- MODULE: Actual GLib Proxy Setting String Regression
--- DESCRIPTION:
--- GLib's real GVariant printer supplies the exact gsettings output bytes to
--- the native settings boundary. Both quote choices, escapes and Unicode must
--- reach the field-check PAC port unchanged; invalid variants fail the check.
--- Every allocated variant and printed string is explicitly released.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_gvariant_proxy_settings%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef([[
	void *g_variant_new_string(const char *string);
	char *g_variant_print(void *value, int type_annotate);
	void g_variant_unref(void *value);
	void g_free(void *memory);
]])
local glib = ffi.load(require("_generated.native_runtime").network_runtime.libraries.glib)
local Shell = require("adapters.shell_runner")
local Ports = require("adapters.network_check_ports")
local original_exec, original_has, original_load = Shell.exec_checked, Shell.has_command, ffi.load
local variants, errors = {}, {}
local acquired_variants, released_variants, acquired_errors, released_errors = 0, 0, 0, 0
-- Observe genuine parser allocations and releases without inventing a pointer
-- or changing any native result. Printer allocations above stay independent.
local observed = setmetatable({}, { __index = function(_, key) return glib[key] end })
observed.g_variant_parse = function(kind, text, limit, endptr, error_slot)
	local value = glib.g_variant_parse(kind, text, limit, endptr, error_slot)
	if value ~= nil then variants[tostring(value)] = true; acquired_variants = acquired_variants + 1 end
	if error_slot[0] ~= nil then errors[tostring(error_slot[0])] = true; acquired_errors = acquired_errors + 1 end
	return value
end
observed.g_variant_unref = function(value)
	assert(variants[tostring(value)], "unref did not name the acquired native variant")
	variants[tostring(value)] = nil
	released_variants = released_variants + 1
	return glib.g_variant_unref(value)
end
observed.g_error_free = function(value)
	assert(errors[tostring(value)], "free did not name the acquired native error")
	errors[tostring(value)] = nil
	released_errors = released_errors + 1
	return glib.g_error_free(value)
end
ffi.load = function(name, ...)
	if name == require("_generated.native_runtime").network_runtime.libraries.glib then return observed end
	return original_load(name, ...)
end
local pac_output, commands = nil, 0
local checks, failures = 0, 0

local function printed(value)
	local variant = assert(glib.g_variant_new_string(value))
	local bytes = glib.g_variant_print(variant, 1)
	assert(bytes ~= nil)
	local output = ffi.string(bytes)
	glib.g_free(bytes)
	glib.g_variant_unref(variant)
	return output
end

Shell.has_command = function(name) return name == "gsettings" end
Shell.exec_checked = function(command)
	commands = commands + 1
	assert(command:match("^timeout %d+ gsettings get org%.gnome%.system%.proxy "))
	if command:find("autoconfig-url", 1, true) then return true, pac_output .. "\n" end
	assert(command:find(" mode", 1, true))
	return true, printed("auto") .. "\n"
end

local function check(name, body)
	checks = checks + 1
	local ok, err = xpcall(body, debug.traceback)
	if ok then
		assert(next(variants) == nil and next(errors) == nil, "native parser retained an allocation")
		print("PASS " .. name)
	else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local cases = {
	{ name = "plain", value = "https://pac.example/proxy.pac" },
	{ name = "apostrophe", value = "https://pac.example/proxy.pac?key='quoted'" },
	{ name = "double quote", value = 'https://pac.example/proxy.pac?key="quoted"' },
	{ name = "both quote forms", value = 'https://pac.example/proxy.pac?key=\'"both"\'' },
	{ name = "backslash", value = "https://pac.example/proxy\\name.pac" },
	{ name = "Unicode", value = "https://pac.example/été-键盘.pac" },
	{ name = "control escapes", value = "https://pac.example/\1\7\8\9\10\11\12\13.pac" },
}
for _, case in ipairs(cases) do
	check("actual GLib " .. case.name .. " string preserves exact PAC bytes", function()
		pac_output = printed(case.value)
		local result, callbacks, before = nil, 0, commands
		Ports.new().proxy_settings(function(value) result, callbacks = value, callbacks + 1 end)
		assert(callbacks == 1 and commands == before + 2)
		assert(result.failure == nil and result.kinds:find("gnome_pac", 1, true))
		assert(result.pac_url == case.value, "native GVariant string was dropped or changed")
	end)
end

for _, invalid in ipairs({ "['not a string']", "'valid' trailing", "'unterminated", "'before'\0'after'" }) do
	check("invalid native GVariant refuses settings", function()
		pac_output = invalid
		local result, callbacks = nil, 0
		Ports.new().proxy_settings(function(value) result, callbacks = value, callbacks + 1 end)
		assert(callbacks == 1 and result.failure == "unreadable", "invalid GVariant silently became missing PAC settings")
	end)
end

Shell.exec_checked, Shell.has_command, ffi.load = original_exec, original_has, original_load
assert(acquired_variants == 18 and released_variants == acquired_variants,
	"every successful native mode/PAC parse must release its exact variant")
assert(acquired_errors == 3 and released_errors == acquired_errors,
	"every refused native parse must release its exact error")
print(string.format("Native GVariant proxy settings: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
