--- modules/llm/proxy_relay_receipt.lua

--- ==============================================================================
--- MODULE: Proxy Sign-In Refusal Receipt
--- DESCRIPTION:
--- The closed reason the sign-in relay refused with when the stock daemon last
--- started (run_with_proxy_sign_in_relay in network-retry.sh). That daemon runs
--- without the proxy for the models on disk; a pull reads this receipt and is
--- refused with the relay's own message, as on Windows and Linux.
---
--- FEATURES & RATIONALE:
--- 1. A file, because the shell that starts the daemon outlives no Lua state and
---    the same daemon can serve a reloaded driver. Each start removes it first.
--- 2. An unreadable receipt or one outside the closed set is the relay's
---    relay_unavailable: the file exists, so a refusal did happen.
--- ==============================================================================

local M = {}

local FileSystem = require("core.fs.adapters.file_system")
local AppDirs = require("core.fs.engine.app_dirs")

-- Under the user's own caches, not the temporary folder of one login shell.
local RELATIVE = "/" .. AppDirs.macos.cache_relative .. "/proxy_relay_refusal"
local _path_override = nil

--- The receipt's path, handed to the daemon start.
--- @return string|nil path Nil without a home folder.
function M.path()
	if _path_override then return _path_override end
	local home = os.getenv("HOME")
	if type(home) ~= "string" or home == "" then return nil end
	return home .. RELATIVE
end

--- The closed refusal of the current daemon start.
--- @return string|nil reason Nil when the sign-in was not refused.
function M.reason()
	local path = M.path()
	if not path or not FileSystem.exists(path) then return nil end
	local relay = require("modules.llm.network_env").proxy_auth_relay()
	local Contract = require("core.network.engine.proxy_auth_relay_core")
	local ok, bytes, status = pcall(FileSystem.read_with_status, path, function() end)
	local reason = ok and status == "ok" and type(bytes) == "string" and bytes:match("^([a-z_]+)\n?$") or nil
	if relay and reason and relay.is_refusal(reason) then return reason end
	return Contract.UNAVAILABLE
end

--- The locale key of the message that refuses a pull, with its reason.
--- @return string|nil key Nil when the pull may go ahead.
--- @return string|nil reason
function M.pull_refusal()
	local reason = M.reason()
	if not reason then return nil, nil end
	local relay = require("modules.llm.network_env").proxy_auth_relay()
	return relay and relay.message_key(reason) or "network.relay.failed", reason
end

--- Test seam: reads this path instead of the user's own.
--- @param path string|nil
function M._set_path(path) _path_override = path end

return M
