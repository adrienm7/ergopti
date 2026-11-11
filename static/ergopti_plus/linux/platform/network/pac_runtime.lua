--- platform/network/pac_runtime.lua

--- ==============================================================================
--- MODULE: Owned PAC Evaluation (Linux)
--- DESCRIPTION:
--- Runs a proxy auto-config script in the system Duktape engine, the one
--- libproxy and glib-pacrunner already load, with the shared PAC helpers that
--- the Windows worker embeds (_shared/modules/network/pac_helpers.js). GIO and
--- libproxy 0.5 keep only the "METHOD host" entries of a PAC answer, so
--- "PROXY a; DIRECT" reached the driver as `a` alone; this module returns the
--- complete ordered list so the caller can walk it, as Windows and macOS do.
---
--- FEATURES & RATIONALE:
--- 1. Only the lookup child loads this module: a script that never returns is
---    bounded by that child's deadline, which the parent enforces by killing
---    it. The system engine is built without Duktape's execution-timeout hook.
--- 2. The heap is capped at proxy_policy.json native_pac.max_heap_bytes by an
---    accounting allocator; a refused allocation is a script failure.
---    Allocations made while a native helper builds its answer are admitted,
---    so an engine error can never unwind through a Lua callback frame.
--- 3. Native helpers never raise: dnsResolve, myIpAddress and
---    sortIpAddressList read their arguments without Duktape's throwing
---    accessors and answer null or a negative return code instead.
--- 4. The answer is parsed strictly: DIRECT, PROXY/HTTP, HTTPS, SOCKS/SOCKS5
---    and SOCKS4 with a host:port; any other entry refuses the whole answer
---    (fail closed) rather than dropping it.
--- 5. Every failure is a closed code; neither the script, the URL nor an
---    address ever appears in one.
--- ==============================================================================

local M = {}

-- The engine SONAME is the one the native runtime catalogue ships.
local Catalogue = require("_generated.native_runtime")

-- The loaded engine and its declared ABI, once per module instance.
local _engine = nil

--- The engine library could not be loaded or declared.
M.ENGINE_UNAVAILABLE = "proxy-pac-engine-unavailable"

--- The script failed, raised, exceeded a bound or answered something invalid.
M.EVALUATION_FAILED = "proxy-pac-evaluation-failed"

--- Duktape compile flags of duk_peval_lstring_noresult (duktape.h 2.x):
--- EVAL | SAFE | NORESULT | NOSOURCE | NOFILENAME.
local PEVAL_NORESULT = 8 + 128 + 256 + 512 + 2048

--- Duktape's "return a TypeError" code for a native function (-DUK_ERR_TYPE_ERROR).
local RETURN_TYPE_ERROR = -6

--- The variable-arguments marker of duk_push_c_function.
local VARARGS = -1

--- Address families and flags of glibc and musl on Linux.
local AF_INET, AF_INET6, SOCK_STREAM = 2, 10, 1
local IFF_UP, IFF_LOOPBACK = 1, 8

local CDEF = [[
	typedef struct ergopti_duk_context ergopti_duk_context;
	typedef void *(*ergopti_duk_alloc)(void *udata, size_t size);
	typedef void *(*ergopti_duk_realloc)(void *udata, void *ptr, size_t size);
	typedef void (*ergopti_duk_free)(void *udata, void *ptr);
	typedef void (*ergopti_duk_fatal)(void *udata, const char *message);
	typedef int (*ergopti_duk_function)(ergopti_duk_context *context);
	ergopti_duk_context *duk_create_heap(ergopti_duk_alloc alloc, ergopti_duk_realloc resize,
		ergopti_duk_free release, void *udata, ergopti_duk_fatal fatal);
	void duk_destroy_heap(ergopti_duk_context *context);
	int duk_eval_raw(ergopti_duk_context *context, const char *source, size_t length, unsigned int flags);
	unsigned int duk_get_global_string(ergopti_duk_context *context, const char *key);
	unsigned int duk_put_global_string(ergopti_duk_context *context, const char *key);
	int duk_push_c_function(ergopti_duk_context *context, ergopti_duk_function function, int arguments);
	const char *duk_push_lstring(ergopti_duk_context *context, const char *text, size_t length);
	void duk_push_null(ergopti_duk_context *context);
	int duk_pcall(ergopti_duk_context *context, int arguments);
	unsigned int duk_is_string(ergopti_duk_context *context, int index);
	unsigned int duk_is_boolean(ergopti_duk_context *context, int index);
	unsigned int duk_get_boolean(ergopti_duk_context *context, int index);
	const char *duk_get_lstring(ergopti_duk_context *context, int index, size_t *length);
	int duk_get_top(ergopti_duk_context *context);

	void *malloc(size_t size);
	void *realloc(void *pointer, size_t size);
	void free(void *pointer);
	void _exit(int status);

	struct ergopti_pac_sockaddr { unsigned short family; char data[14]; };
	struct ergopti_pac_addrinfo {
		int flags; int family; int socktype; int protocol; unsigned int addrlen;
		struct ergopti_pac_sockaddr *addr; char *canonname; struct ergopti_pac_addrinfo *next;
	};
	struct ergopti_pac_ifaddrs {
		struct ergopti_pac_ifaddrs *next; char *name; unsigned int flags;
		struct ergopti_pac_sockaddr *addr; struct ergopti_pac_sockaddr *netmask;
		struct ergopti_pac_sockaddr *broadcast; void *data;
	};
	int getaddrinfo(const char *node, const char *service, const struct ergopti_pac_addrinfo *hints,
		struct ergopti_pac_addrinfo **result);
	void freeaddrinfo(struct ergopti_pac_addrinfo *result);
	int getifaddrs(struct ergopti_pac_ifaddrs **result);
	void freeifaddrs(struct ergopti_pac_ifaddrs *result);
	const char *inet_ntop(int family, const void *source, char *destination, unsigned int size);
	int inet_pton(int family, const char *source, void *destination);
]]

--- The size header of every accounted block (keeps 16-byte alignment).
local HEADER = 16

--- Byte offset of the address inside sockaddr_in and sockaddr_in6.
local ADDRESS_OFFSET = { [AF_INET] = 4, [AF_INET6] = 8 }

--- Returns the address text of one IPv4 or IPv6 socket address.
--- @param ffi table
--- @param address userdata struct ergopti_pac_sockaddr *
--- @return string|nil
local function address_text(ffi, address)
	local family = address.family
	local offset = ADDRESS_OFFSET[family]
	if not offset then return nil end
	local text = ffi.new("char[46]")
	if ffi.C.inet_ntop(family, ffi.cast("const char *", address) + offset, text, 46) == nil then return nil end
	return ffi.string(text)
end

--- The DNS answer of dnsResolve (first IPv4) or dnsResolveEx (every address).
--- @param ffi table
--- @param host string
--- @param extended boolean
--- @param limit number Most addresses read.
--- @return string|nil
local function resolve(ffi, host, extended, limit)
	local hints = ffi.new("struct ergopti_pac_addrinfo")
	hints.family = extended and 0 or AF_INET
	hints.socktype = SOCK_STREAM
	local result = ffi.new("struct ergopti_pac_addrinfo *[1]")
	if ffi.C.getaddrinfo(host, nil, hints, result) ~= 0 then return nil end
	local addresses, seen, current = {}, 0, result[0]
	while current ~= nil and seen < limit do
		seen = seen + 1
		local text = current.addr ~= nil and address_text(ffi, current.addr) or nil
		if text then
			addresses[#addresses + 1] = text
			if not extended then break end
		end
		current = current.next
	end
	ffi.C.freeaddrinfo(result[0])
	return #addresses > 0 and table.concat(addresses, ";") or nil
end

--- The interface addresses of myIpAddress (first IPv4) or myIpAddressEx.
--- @param ffi table
--- @param extended boolean
--- @param limit number Most interface entries read.
--- @return string|nil
local function local_addresses(ffi, extended, limit)
	local result = ffi.new("struct ergopti_pac_ifaddrs *[1]")
	if ffi.C.getifaddrs(result) ~= 0 then return nil end
	local addresses, seen, current = {}, 0, result[0]
	while current ~= nil and seen < limit do
		seen = seen + 1
		local up = current.flags % (2 * IFF_UP) >= IFF_UP
		local loopback = current.flags % (2 * IFF_LOOPBACK) >= IFF_LOOPBACK
		if up and not loopback and current.addr ~= nil
			and (current.addr.family == AF_INET or (extended and current.addr.family == AF_INET6)) then
			local text = address_text(ffi, current.addr)
			if text then
				addresses[#addresses + 1] = text
				if not extended then break end
			end
		end
		current = current.next
	end
	ffi.C.freeifaddrs(result[0])
	return #addresses > 0 and table.concat(addresses, ";") or nil
end

--- sortIpAddressList: IPv6 before IPv4 (RFC 6724 default precedence), each
--- family in its given order; any invalid address refuses the list.
--- @param ffi table
--- @param list string
--- @param limit number Most addresses admitted.
--- @return string|nil
local function sort_addresses(ffi, list, limit)
	local six, four, count = {}, {}, 0
	local buffer = ffi.new("unsigned char[16]")
	for entry in (list .. ";"):gmatch("([^;]*);") do
		count = count + 1
		if count > limit or entry == "" then return nil end
		if ffi.C.inet_pton(AF_INET6, entry, buffer) == 1 then six[#six + 1] = entry
		elseif ffi.C.inet_pton(AF_INET, entry, buffer) == 1 then four[#four + 1] = entry
		else return nil end
	end
	for _, entry in ipairs(four) do six[#six + 1] = entry end
	return table.concat(six, ";")
end

--- Parses the host of the destination URL handed to FindProxyForURL.
--- @param url string
--- @return string|nil
function M.host_of(url)
	if type(url) ~= "string" then return nil end
	local authority = url:match("^%a[%w+.-]*://([^/?#]*)")
	if not authority then return nil end
	authority = authority:gsub("^.*@", "")
	local host = authority:match("^%[([%x:.]+)%]") or authority:match("^([^:]+)")
	if not host or host == "" then return nil end
	return host:lower()
end

--- The URI scheme each PAC method selects (the form GIO answers in).
local METHODS = {
	PROXY = "http", HTTP = "http", HTTPS = "https",
	SOCKS = "socks5", SOCKS5 = "socks5", SOCKS4 = "socks4",
}

--- Turns a PAC answer into the ordered selection of the lookup receipt.
--- @param answer string The string FindProxyForURL returned.
--- @param max_selections number Bound of the shared proxy policy.
--- @return table|nil proxies URIs ("http://host:port") and "direct://".
function M.parse_answer(answer, max_selections)
	if type(answer) ~= "string" or answer == "" or answer:find("[%z\r\n]") then return nil end
	local proxies = {}
	local entries = {}
	for entry in (answer .. ";"):gmatch("([^;]*);") do entries[#entries + 1] = entry end
	-- A browser ignores one trailing separator ("PROXY a; DIRECT;").
	if #entries > 1 and entries[#entries]:match("^%s*$") then entries[#entries] = nil end
	for _, raw in ipairs(entries) do
		local entry = raw:match("^%s*(.-)%s*$")
		if entry:upper() == "DIRECT" then
			proxies[#proxies + 1] = "direct://"
		else
			local method, endpoint = entry:match("^(%a+%d?)%s+(%S+)$")
			local scheme = method and METHODS[method:upper()]
			if not scheme then return nil end
			local host, port = endpoint:match("^(%[[%x:.]+%]):(%d+)$")
			if not host then host, port = endpoint:match("^([%w%.%-_]+):(%d+)$") end
			port = tonumber(port)
			if not host or not port or port < 1 or port > 65535 then return nil end
			proxies[#proxies + 1] = scheme .. "://" .. host .. ":" .. port
		end
		if #proxies > max_selections then return nil end
	end
	return #proxies > 0 and proxies or nil
end

--- Loads the engine and declares its ABI once per process.
--- @return table|nil native { ffi, engine }
local function load_engine()
	if _engine then return _engine end
	local loaded, ffi = pcall(require, "ffi")
	if not loaded then return nil end
	-- The declarations are process-wide: another instance may own them already.
	if not pcall(ffi.typeof, "struct ergopti_pac_ifaddrs") and not pcall(ffi.cdef, CDEF) then return nil end
	if type(Catalogue.network_runtime) ~= "table" or type(Catalogue.network_runtime.pac_engine) ~= "string" then
		return nil
	end
	local opened, engine = pcall(ffi.load, Catalogue.network_runtime.pac_engine)
	if not opened then return nil end
	_engine = { ffi = ffi, engine = engine }
	return _engine
end

--- Evaluates one PAC script for one destination.
--- @param script string Decoded UTF-8 PAC source.
--- @param helpers string The shared PAC helper source.
--- @param url string Destination URL.
--- @param limits table { max_heap_bytes, max_native_queries, max_output_bytes, max_selections }
--- @return table|nil proxies Ordered selection.
--- @return string|nil error M.ENGINE_UNAVAILABLE or M.EVALUATION_FAILED.
function M.evaluate(script, helpers, url, limits)
	local host = M.host_of(url)
	if type(script) ~= "string" or script == "" or type(helpers) ~= "string" or helpers == "" or not host
		or type(limits) ~= "table" then return nil, M.EVALUATION_FAILED end
	local native = load_engine()
	if not native then return nil, M.ENGINE_UNAVAILABLE end
	local ffi, engine = native.ffi, native.engine
	local C = ffi.C
	local state = { retained = 0, refused = false, native = false, queries = 0, failed = false }
	local max_heap = limits.max_heap_bytes

	--- Admits a block of `bytes` while the cap allows it (or a helper answers).
	--- @param extra number
	--- @return boolean
	local function admit(extra)
		if state.native or state.retained + extra <= max_heap then return true end
		state.refused = true
		return false
	end
	local allocate = ffi.cast("ergopti_duk_alloc", function(_, size)
		if size == 0 or not admit(size + HEADER) then return nil end
		local block = C.malloc(size + HEADER)
		if block == nil then state.refused = true; return nil end
		ffi.cast("size_t *", block)[0] = size + HEADER
		state.retained = state.retained + size + HEADER
		return ffi.cast("char *", block) + HEADER
	end)
	local release = ffi.cast("ergopti_duk_free", function(_, pointer)
		if pointer == nil then return end
		local block = ffi.cast("char *", pointer) - HEADER
		state.retained = state.retained - tonumber(ffi.cast("size_t *", block)[0])
		C.free(block)
	end)
	local resize = ffi.cast("ergopti_duk_realloc", function(_, pointer, size)
		if pointer == nil then
			if size == 0 or not admit(size + HEADER) then return nil end
			local block = C.malloc(size + HEADER)
			if block == nil then state.refused = true; return nil end
			ffi.cast("size_t *", block)[0] = size + HEADER
			state.retained = state.retained + size + HEADER
			return ffi.cast("char *", block) + HEADER
		end
		local block = ffi.cast("char *", pointer) - HEADER
		local previous = tonumber(ffi.cast("size_t *", block)[0])
		if size == 0 then
			state.retained = state.retained - previous
			C.free(block)
			return nil
		end
		if size + HEADER > previous and not admit(size + HEADER - previous) then return nil end
		local moved = C.realloc(block, size + HEADER)
		if moved == nil then state.refused = true; return nil end
		ffi.cast("size_t *", moved)[0] = size + HEADER
		state.retained = state.retained - previous + size + HEADER
		return ffi.cast("char *", moved) + HEADER
	end)
	-- An unrecoverable engine error must not return into the engine; the
	-- parent reads the missing receipt as a failed lookup.
	local fatal = ffi.cast("ergopti_duk_fatal", function() C._exit(125) end)

	--- Wraps a helper: bounded calls, no raise, accounted answer.
	--- @param body function(context) -> string|nil|false
	--- @return userdata callback
	local function helper(body)
		return ffi.cast("ergopti_duk_function", function(context)
			state.queries = state.queries + 1
			if state.queries > limits.max_native_queries then state.failed = true; return RETURN_TYPE_ERROR end
			local called, answer = pcall(body, context)
			if not called or answer == false then state.failed = true; return RETURN_TYPE_ERROR end
			state.native = true
			if answer == nil or #answer == 0 or #answer > limits.max_output_bytes then engine.duk_push_null(context)
			else engine.duk_push_lstring(context, answer, #answer) end
			state.native = false
			return 1
		end)
	end
	local length = ffi.new("size_t[1]")

	--- Reads argument `index` as a bounded string, or nil.
	--- @param context userdata
	--- @param index number
	--- @return string|nil
	local function text_argument(context, index)
		if engine.duk_get_top(context) <= index or engine.duk_is_string(context, index) == 0 then return nil end
		local value = engine.duk_get_lstring(context, index, length)
		if value == nil or length[0] == 0 or length[0] > limits.max_output_bytes then return nil end
		local text = ffi.string(value, length[0])
		return not text:find("%z") and text or nil
	end

	--- Reads argument `index` as a boolean, or nil.
	--- @param context userdata
	--- @param index number
	--- @return boolean|nil
	local function boolean_argument(context, index)
		if engine.duk_get_top(context) <= index or engine.duk_is_boolean(context, index) == 0 then return nil end
		return engine.duk_get_boolean(context, index) ~= 0
	end
	local dns = helper(function(context)
		local name, extended = text_argument(context, 0), boolean_argument(context, 1)
		if not name or extended == nil then return false end
		return resolve(ffi, name, extended, limits.max_native_queries)
	end)
	local interfaces = helper(function(context)
		local extended = boolean_argument(context, 0)
		if extended == nil then return false end
		return local_addresses(ffi, extended, limits.max_native_queries)
	end)
	local sorter = helper(function(context)
		local list = text_argument(context, 0)
		if not list then return false end
		return sort_addresses(ffi, list, limits.max_native_queries)
	end)
	local callbacks = { allocate, resize, release, fatal, dns, interfaces, sorter }

	local answer
	local context = engine.duk_create_heap(allocate, resize, release, nil, fatal)
	if context ~= nil then
		local bindings = { __ergoptiDns = dns, __ergoptiLocalAddresses = interfaces, __ergoptiSortAddresses = sorter }
		for _, name in ipairs({ "__ergoptiDns", "__ergoptiLocalAddresses", "__ergoptiSortAddresses" }) do
			engine.duk_push_c_function(context, bindings[name], VARARGS)
			engine.duk_put_global_string(context, name)
		end
		if engine.duk_eval_raw(context, helpers, #helpers, PEVAL_NORESULT) == 0
			and engine.duk_eval_raw(context, script, #script, PEVAL_NORESULT) == 0 then
			engine.duk_get_global_string(context, "FindProxyForURL")
			engine.duk_push_lstring(context, url, #url)
			engine.duk_push_lstring(context, host, #host)
			if engine.duk_pcall(context, 2) == 0 and engine.duk_is_string(context, -1) ~= 0 then
				local value = engine.duk_get_lstring(context, -1, length)
				if value ~= nil and length[0] > 0 and length[0] <= limits.max_output_bytes then
					answer = ffi.string(value, length[0])
				end
			end
		end
		engine.duk_destroy_heap(context)
	end
	local leaked = state.retained ~= 0
	-- A callback freed while the engine could still call it would crash; the
	-- heap is destroyed above, so none of them can run again.
	if not leaked then for _, callback in ipairs(callbacks) do callback:free() end end
	if context == nil or state.refused or state.failed or leaked or not answer then return nil, M.EVALUATION_FAILED end
	local proxies = M.parse_answer(answer, limits.max_selections)
	if not proxies then return nil, M.EVALUATION_FAILED end
	return proxies
end

-- Callbacks run inside engine calls: compiled callers would forbid them.
if jit then jit.off(M.evaluate, true) end

return M
