--- tools/test/fixtures/linux-network-runtime-factory.lua

--- ==============================================================================
--- MODULE: Linux Native Runtime Factory Admission Controls
--- DESCRIPTION:
--- Independent owned-schema witnesses guard the actual canonical factory. These
--- fake native-function controls do not substitute for actual native API proof.
--- ==============================================================================
local root = arg[1]
assert(type(root) == "string" and root:sub(1, 1) == "/", "Absolute driver root required")
package.path = root .. "/?.lua;" .. package.path
package.loaded["_generated.native_runtime"] = {
	network_runtime = { proxy_schema = "org.gnome.system.proxy" },
}
local Runtime = require("platform.network.native_proxy_runtime")
local passed = 0

--- Creates independent owned-schema/factory witnesses with forbidden early construction.
local function witness(has_source, has_schema, backend)
	local source, schema, resolver = {}, {}, {}
	local facts = { lookup = 0, unref = 0, factory = 0 }
	local native = {
		ffi = { string = function(value) assert(value == backend); return value end },
		gio = {
			g_settings_schema_source_get_default = function() return has_source and source or nil end,
			g_settings_schema_source_lookup = function(actual_source, id, recursive)
				assert(actual_source == source and id == "org.gnome.system.proxy" and recursive == 1)
				facts.lookup = facts.lookup + 1
				return has_schema and schema or nil
			end,
			g_settings_schema_unref = function(actual_schema)
				assert(actual_schema == schema and facts.unref == 0)
				facts.unref = facts.unref + 1
			end,
			g_proxy_resolver_get_default = function()
				assert(facts.unref == 1, "Factory ran before owned schema retirement")
				facts.factory = facts.factory + 1
				return resolver
			end,
			g_proxy_resolver_is_supported = function(actual_resolver)
				assert(actual_resolver == resolver)
				return 1
			end,
		},
		gobject = { g_type_name_from_instance = function(actual_resolver)
			assert(actual_resolver == resolver)
			return backend
		end },
	}
	return native, facts, resolver
end

local native, facts = witness(false, false, "GProxyResolverLibproxy")
local resolver, backend, reason = Runtime.default_resolver(native)
assert(resolver == nil and backend == nil and reason == "proxy-backend-unavailable")
assert(facts.lookup == 0 and facts.unref == 0 and facts.factory == 0)
passed = passed + 1

native, facts = witness(true, false, "GProxyResolverLibproxy")
resolver, backend, reason = Runtime.default_resolver(native)
assert(resolver == nil and backend == nil and reason == "proxy-backend-unavailable")
assert(facts.lookup == 1 and facts.unref == 0 and facts.factory == 0)
passed = passed + 1

local expected_resolver
native, facts, expected_resolver = witness(true, true, "GProxyResolverLibproxy")
resolver, backend, reason = Runtime.default_resolver(native)
assert(resolver == expected_resolver and backend == "GProxyResolverLibproxy" and reason == nil)
assert(facts.lookup == 1 and facts.unref == 1 and facts.factory == 1)
passed = passed + 1

native, facts = witness(true, true, "GDummyProxyResolver")
resolver, backend, reason = Runtime.default_resolver(native)
assert(resolver == nil and backend == "GDummyProxyResolver" and reason == "proxy-backend-unavailable")
assert(facts.lookup == 1 and facts.unref == 1 and facts.factory == 1)
passed = passed + 1

print("PASS network runtime factory controls: " .. passed .. " passed; 0 skipped")
