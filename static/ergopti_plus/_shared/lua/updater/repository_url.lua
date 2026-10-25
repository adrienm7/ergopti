--- _shared/lua/updater/repository_url.lua

--- ==============================================================================
--- MODULE: Repository URL Policy (Shared Lua)
--- DESCRIPTION:
--- Decides which links the native hosts open on behalf of a page that renders
--- remote release notes: absolute https URLs on this repository's github.com
--- surface, never a longer repository name and never another host.
---
--- FEATURES & RATIONALE:
--- 1. Second line of defence: the shared pages only offer a link that passes
---    `isRepositoryUrl` (_shared/ui/repository_links.js); the host checks the
---    same rule again before it opens anything, because a page message is data.
--- 2. One predicate for the Versions window and the update-check window's notes
---    pane on macOS and Linux, so the two cannot drift.
--- 3. PURE Lua (LuaJIT and 5.4): no driver imports, no io, no OS calls.
--- ==============================================================================

local M = {}

local NAME_PATTERN = "^[A-Za-z0-9._-]+$"
-- What may follow the repository root: a path, query or fragment of plain URL
-- characters, with percent-encoding.
local REST_PATTERN = "^[/%?#][A-Za-z0-9._~/%?=&+#%%-]*$"

--- Returns whether a URL belongs to the repository's HTTPS surface.
--- @param value any Candidate URL.
--- @param owner any Repository owner.
--- @param repo any Repository name.
--- @return boolean allowed
function M.is_repository_url(value, owner, repo)
	if type(value) ~= "string" or type(owner) ~= "string" or type(repo) ~= "string" then return false end
	if not owner:match(NAME_PATTERN) or not repo:match(NAME_PATTERN) then return false end
	local root = "https://github.com/" .. owner .. "/" .. repo
	if value:sub(1, #root) ~= root then return false end
	local rest = value:sub(#root + 1)
	return rest == "" or rest:match(REST_PATTERN) ~= nil
end

return M
