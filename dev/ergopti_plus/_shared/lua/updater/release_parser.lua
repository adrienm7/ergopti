--- _shared/lua/updater/release_parser.lua

--- ==============================================================================
--- MODULE: GitHub Release JSON Parser (Shared)
--- DESCRIPTION:
--- Pure functions for parsing GitHub Releases API JSON payloads without a
--- full JSON decoder. Extracted from macos/infra/updater.lua (parse_tag,
--- parse_notes, parse_asset_url, split_releases_array, parse_prerelease_flag)
--- and windows/infra/updater/core.ahk (Updater_ParseTagName, Updater_ParseBody,
--- _Updater_SplitReleasesArray, _Updater_ParsePrerelease) so both drivers
--- share a single implementation.
---
--- The AHK driver cannot require Lua modules, so its copy in
--- infra/updater/core.ahk is hand-maintained and pinned by the shared corpus
--- test (see _shared/tests/corpus/updater/).
---
--- This module is PURE Lua — no driver imports, no io/network, no OS calls.
--- ==============================================================================

local M = {}





-- ==========================================
-- ==========================================
-- ======= 1/ Tag & Notes Parsers ===========
-- ==========================================
-- ==========================================

--- Extracts the "tag_name" field from a GitHub release JSON string.
--- @param body string Raw JSON (single object or array wrapper)
--- @return string tag or ""
function M.parse_tag(body)
	if not body or body == "" then return "" end
	return body:match('"tag_name"%s*:%s*"([^"]+)"') or ""
end


--- Extracts the "body" field (release notes markdown) from a GitHub release
--- JSON string. Handles GitHub's "body": null sentinel and unescapes the
--- common JSON escape sequences (\n, \r, \t, \", \\).
--- @param body string Raw JSON
--- @return string notes or ""
function M.parse_notes(body)
	if not body or body == "" then return "" end
	-- GitHub sets "body": null when a release has no description
	if body:match('"body"%s*:%s*null') then return "" end
	local raw = body:match('"body"%s*:%s*"(.-[^\\])"')
	if not raw then return "" end
	return (raw:gsub("\\n", "\n"):gsub("\\r", ""):gsub('\\"', '"'):gsub("\\\\", "\\"))
end


--- Extracts the browser_download_url for a named asset from a GitHub release
--- JSON string. Walks the "assets" array looking for a matching "name" field.
--- @param body string Raw JSON
--- @param asset_name string The asset filename to find (e.g. "ErgoptiPlus.app.zip")
--- @return string url or ""
function M.parse_asset_url(body, asset_name)
	if not body or body == "" then return "" end
	if not asset_name or asset_name == "" then return "" end
	-- Isolate the "assets" array BEFORE iterating objects. On a real single-
	-- release payload the outermost %b{} spans the ENTIRE release object, so
	-- iterating `body` directly yields one chunk and `"name"` then matches the
	-- release title, not any asset — the wanted asset is never found. Scoping to
	-- the assets array makes each %b{} an individual asset, so its name and
	-- browser_download_url come from the SAME object.
	local assets = body:match('"assets"%s*:%s*(%b[])')
	if not assets then return "" end
	for obj in assets:gmatch("%b{}") do
		local name = obj:match('"name"%s*:%s*"([^"]+)"')
		if name == asset_name then
			return obj:match('"browser_download_url"%s*:%s*"([^"]+)"') or ""
		end
	end
	return ""
end


--- Extracts the "html_url" field from a single-release JSON object.
--- @param body string Raw JSON
--- @return string url or ""
function M.parse_html_url(body)
	if not body or body == "" then return "" end
	return body:match('"html_url"%s*:%s*"([^"]+)"') or ""
end


--- Extracts the "published_at" ISO-8601 timestamp from a release object.
--- @param body string Raw JSON
--- @return string timestamp or ""
function M.parse_published_at(body)
	if not body or body == "" then return "" end
	return body:match('"published_at"%s*:%s*"([^"]+)"') or ""
end


--- Extracts the boolean "prerelease" flag from a release JSON object.
--- @param body string Raw JSON
--- @return boolean true if prerelease flag is true, false otherwise
function M.parse_prerelease_flag(body)
	if not body or body == "" then return false end
	return body:match('"prerelease"%s*:%s*true') ~= nil
end




-- ================================================
-- ================================================
-- ======= 2/ Releases Array Splitter ==============
-- ================================================
-- ================================================

--- Splits a top-level JSON array of releases into one substring per object,
--- honouring quoted strings and escape sequences so a "}" inside a release
--- body field cannot fool the depth counter.
--- @param json string Raw JSON array string
--- @return table Array of object-JSON strings
function M.split_releases_array(json)
	local out = {}
	if type(json) ~= "string" or json == "" then return out end
	local trimmed = json:match("^%s*(.*)$") or json
	if trimmed:sub(1, 1) ~= "[" then return out end
	local pos, depth, start = 2, 0, 0
	local in_str, esc = false, false
	while pos <= #trimmed do
		local c = trimmed:sub(pos, pos)
		if in_str then
			if esc then esc = false
			elseif c == "\\" then esc = true
			elseif c == '"' then in_str = false end
		elseif c == '"' then in_str = true
		elseif c == "{" then
			if depth == 0 then start = pos end
			depth = depth + 1
		elseif c == "}" then
			depth = depth - 1
			if depth == 0 and start > 0 then
				out[#out + 1] = trimmed:sub(start, pos)
				start = 0
			end
		end
		pos = pos + 1
	end
	return out
end


--- Picks the highest-semver prerelease chunk from a releases array JSON string.
--- Falls back to the first chunk when no prerelease is found.
--- @param json string Raw releases array JSON
--- @param compare_fn function(a, b) → 1|-1|0 (semver compare)
--- @return string The best-matching release object JSON string
function M.pick_latest_prerelease(json, compare_fn)
	local chunks = M.split_releases_array(json)
	local best_chunk, best_tag = "", ""
	for _, chunk in ipairs(chunks) do
		if M.parse_prerelease_flag(chunk) then
			local tag = M.parse_tag(chunk)
			if tag ~= "" and (best_tag == "" or compare_fn(tag, best_tag) > 0) then
				best_tag = tag
				best_chunk = chunk
			end
		end
	end
	if best_chunk ~= "" then return best_chunk end
	return chunks[1] or json
end


--- Builds an array of release records from raw releases-list JSON.
--- Each entry: { tag, body, html_url, published_at, prerelease, raw }
--- @param json string Raw releases array JSON
--- @param main_only boolean If true, filter out prereleases
--- @return table Array of release records
function M.parse_releases_list(json, main_only)
	local out = {}
	for _, chunk in ipairs(M.split_releases_array(json)) do
		local tag = M.parse_tag(chunk)
		if tag ~= "" then
			local prerelease = M.parse_prerelease_flag(chunk)
			if not (main_only and prerelease) then
				out[#out + 1] = {
					tag         = tag,
					body        = M.parse_notes(chunk),
					html_url    = M.parse_html_url(chunk),
					published_at = M.parse_published_at(chunk),
					prerelease  = prerelease,
					raw         = chunk,
				}
			end
		end
	end
	return out
end

return M
