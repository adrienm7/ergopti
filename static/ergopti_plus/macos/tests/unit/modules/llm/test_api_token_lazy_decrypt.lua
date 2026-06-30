--- tests/unit/modules/llm/test_api_token_lazy_decrypt.lua

--- Regression test for M-17: API-token Keychain decryption must not run on
--- the boot tick. load_api_entries() previously iterated the stored entries
--- and called TokenCrypto.decrypt() on each token synchronously — even when
--- deferred to doAfter(0), N stored entries caused N blocking
--- security(1) subprocess calls on the very first run-loop tick.
---
--- Fix: load_api_entries() passes the raw entry list (with keychain:<id>
--- references intact) to ApiRemote.set_entries(). ApiRemote.get_active_entry()
--- resolves the Keychain reference on first use and caches the cleartext back
--- into the entry so the subprocess fires at most once per entry.

local helpers = require("tests.helpers")

local init_path   = helpers.driver_root() .. "modules/llm/init.lua"
local remote_path = helpers.driver_root() .. "modules/llm/api_remote.lua"

local fh = io.open(init_path, "r")
if not fh then error("init.lua not readable at: " .. init_path) end
local init_src = fh:read("*a") ; fh:close()

local fh2 = io.open(remote_path, "r")
if not fh2 then error("api_remote.lua not readable at: " .. remote_path) end
local remote_src = fh2:read("*a") ; fh2:close()

-- Test 1: load_api_entries must NOT call TokenCrypto.decrypt inside its loop.
-- A decrypt call at load time is the root cause: any positive match here means
-- the eager-decrypt pattern was reintroduced.
helpers.assert_true(
	init_src:find("TokenCrypto%.decrypt", 1, true) == nil,
	"load_api_entries must not call TokenCrypto.decrypt — eager decryption blocks the boot tick"
)

-- Test 2: api_remote.lua must require api_token_crypto for lazy resolution.
helpers.assert_true(
	remote_src:find("api_token_crypto", 1, true) ~= nil,
	"api_remote.lua must require modules.llm.api_token_crypto for lazy token resolution"
)

-- Test 3: get_active_entry must call TokenCrypto.decrypt for lazy resolution.
-- The call must appear in the body of get_active_entry (after the function
-- declaration and before the end), not elsewhere.
local fn_start = remote_src:find("function M%.get_active_entry", 1, true)
helpers.assert_true(fn_start ~= nil, "api_remote.lua must define M.get_active_entry")

local fn_body_start = fn_start
local fn_end = remote_src:find("\nend\n", fn_body_start, true)
helpers.assert_true(fn_end ~= nil, "get_active_entry function body must have a matching 'end'")

local fn_body = remote_src:sub(fn_body_start, fn_end)
helpers.assert_true(
	fn_body:find("TokenCrypto%.decrypt", 1, true) ~= nil,
	"get_active_entry must call TokenCrypto.decrypt for lazy Keychain resolution"
)

-- Test 4: get_active_entry must call is_encrypted before decrypt (guard pattern).
helpers.assert_true(
	fn_body:find("is_encrypted", 1, true) ~= nil,
	"get_active_entry must guard the decrypt call with TokenCrypto.is_encrypted"
)

print("[PASS] test_api_token_lazy_decrypt")
