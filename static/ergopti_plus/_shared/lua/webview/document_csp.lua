--- _shared/lua/webview/document_csp.lua

--- ==============================================================================
--- MODULE: Generated Webview Document CSP (Shared)
--- DESCRIPTION:
--- Publishes the one Content Security Policy of a webview document that a
--- native driver built by inlining the shared UI's local scripts and styles.
---
--- FEATURES & RATIONALE:
--- 1. Exactly one policy: a shared page may carry a browser-host CSP written
---    for external same-origin assets ("script-src 'self'"). Once the driver
---    has inlined those assets, keeping that policy blocks every inline
---    script, so the page never runs and stays in its initial state (the
---    changelog kept spinning forever). The source policy is removed and this
---    module's policy is the only one published.
--- 2. No remote execution or connection: scripts are inline only, network
---    access is limited to the local files the page reads (locale JSON).
--- 3. Nonce mode: a page that renders remote content authorizes exactly the
---    scripts the driver generated, through a per-document nonce.
---
--- This module is PURE Lua — no driver imports, no io/network, no OS calls.
--- Each driver generates the nonce with its own secure random source.
--- ==============================================================================

local M = {}

local META_PATTERN = '<meta%s+[^>]-http%-equiv%s*=%s*["\']Content%-Security%-Policy["\'][^>]*>%s*'
local NONCE_PATTERN = "^[%w+/=_-]+$"





-- ===================================
-- ===================================
-- ======= 1/ Policy =================
-- ===================================
-- ===================================

--- Builds the policy text for one script source list.
--- @param script_sources string CSP source expression for script-src.
--- @return string
function M.policy(script_sources)
	return "default-src 'none'; base-uri 'none'; connect-src 'self' file:; "
		.. "font-src 'self' data:; form-action 'none'; frame-src 'none'; "
		.. "img-src 'self' data: blob: file:; media-src 'none'; object-src 'none'; "
		.. "script-src " .. script_sources .. "; style-src 'unsafe-inline'; worker-src 'none'"
end





-- ===================================
-- ===================================
-- ======= 2/ Document Rewrite =======
-- ===================================
-- ===================================

--- Replaces every source policy of a generated document with the single
--- driver policy, injected first in <head> so it covers every script.
--- @param html string Generated document with inlined assets.
--- @param nonce string|nil Per-document nonce; nil authorizes inline scripts.
--- @return string|nil html Rewritten document.
--- @return string|nil error Exact reason when the document cannot be secured.
function M.apply(html, nonce)
	if type(html) ~= "string" then return nil, "document is not a string" end
	if not html:find("<head[^>]*>") then return nil, "document has no <head> element" end
	local script_sources = "'unsafe-inline'"
	local rewritten = html:gsub(META_PATTERN, "")
	if nonce ~= nil then
		if type(nonce) ~= "string" or not nonce:match(NONCE_PATTERN) then
			return nil, "nonce is not a CSP base64 value"
		end
		rewritten = rewritten:gsub("<script([^>]*)>", function(attributes)
			return '<script nonce="' .. nonce .. '"' .. attributes .. ">"
		end)
		script_sources = "'nonce-" .. nonce .. "'"
	end
	local meta = '<meta http-equiv="Content-Security-Policy" content="' .. M.policy(script_sources) .. '" />'
	rewritten = rewritten:gsub("(<head[^>]*>)", function(tag)
		return tag .. meta
	end, 1)
	return rewritten, nil
end

return M
