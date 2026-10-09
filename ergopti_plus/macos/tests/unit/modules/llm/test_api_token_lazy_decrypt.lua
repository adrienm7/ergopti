--- tests/unit/modules/llm/test_api_token_lazy_decrypt.lua

--- ==============================================================================
--- MODULE: Regression — no synchronous Keychain path remains (F-MED-9)
--- DESCRIPTION:
--- The historical guard required get_active_entry() to call the blocking
--- decrypt function and therefore certified the run-loop freeze it claimed to
--- prevent. This class-wide guard now forbids every synchronous primitive and
--- requires metadata/menu/network callers to use their non-blocking contracts.
--- ==============================================================================

local helpers = require("tests.helpers")

local crypto_src = helpers.read_driver_source("function M.encrypt_async")
helpers.assert_true(crypto_src ~= nil and crypto_src ~= "",
	"api_token_crypto.lua must be locatable by its async write entry point")

for _, forbidden in ipairs({
	"hs.execute", "waitUntilExit", "function M.encrypt(",
	"function M.decrypt(", "function M.delete(", "/usr/bin/security",
	"add-generic-password", "find-generic-password", "delete-generic-password",
}) do
	helpers.assert_true(crypto_src:find(forbidden, 1, true) == nil,
		"Keychain token crypto must not expose or use synchronous primitive: " .. forbidden)
end
for _, required in ipairs({ "encrypt_async", "decrypt_async", "delete_async" }) do
	helpers.assert_true(crypto_src:find("function M." .. required .. "(", 1, true) ~= nil,
		"Keychain token crypto must expose " .. required)
end
for _, required in ipairs({
	"LauncherHelper.resolve", "--keychain-token-write",
	"--keychain-token-read", "--keychain-token-delete",
}) do
	helpers.assert_true(crypto_src:find(required, 1, true) ~= nil,
		"Keychain token crypto must route through the signed launcher: " .. required)
end

local remote_src = helpers.read_driver_source("function M.resolve_active_entry")
helpers.assert_true(remote_src ~= nil and remote_src ~= "",
	"api_remote.lua must be locatable by its async resolver")

local metadata_start = remote_src:find("function M.get_active_entry()", 1, true)
helpers.assert_true(metadata_start ~= nil, "api_remote must expose metadata-only get_active_entry")
local metadata_end = remote_src:find("\nend\n", metadata_start, true)
helpers.assert_true(metadata_end ~= nil, "get_active_entry must have a complete function body")
local metadata_body = remote_src:sub(metadata_start, metadata_end)
for _, forbidden in ipairs({ "TokenCrypto", "ShellRunner", "decrypt", "resolve_active_entry" }) do
	helpers.assert_true(metadata_body:find(forbidden, 1, true) == nil,
		"menu-safe get_active_entry must not start credential resolution: " .. forbidden)
end

for _, signature in ipairs({
	"function M.warmup(",
	"function M.check_availability(",
	"local function post_and_parse(",
}) do
	local start_at = remote_src:find(signature, 1, true)
	helpers.assert_true(start_at ~= nil, "network path must exist: " .. signature)
	local body = remote_src:sub(start_at, start_at + 1700)
	helpers.assert_true(body:find("M.resolve_active_entry", 1, true) ~= nil,
		"every network path must resolve the active token asynchronously: " .. signature)
end

local init_src = helpers.read_driver_source("function M.persist_api_entries")
helpers.assert_true(init_src ~= nil and init_src ~= "",
	"modules/llm/init.lua must be locatable by persistence entry point")
helpers.assert_true(init_src:find("TokenCrypto.encrypt(", 1, true) == nil,
	"API persistence must never use a synchronous encryption fallback")
helpers.assert_true(init_src:find("TokenCrypto.encrypt_async", 1, true) ~= nil,
	"API persistence must wait for asynchronous Keychain encryption")
helpers.assert_true(init_src:find("API_STATE_KEY", 1, true) ~= nil,
	"entries and active identity must publish through one combined settings key")

print("[PASS] test_api_token_lazy_decrypt")
