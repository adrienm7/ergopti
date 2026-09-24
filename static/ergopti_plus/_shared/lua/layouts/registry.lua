--- _shared/lua/layouts/registry.lua

--- ==============================================================================
--- MODULE: Layout Registry Client (Shared)
--- DESCRIPTION:
--- The part of downloading a registry keyboard layout that macOS and Linux do
--- the same way: the registry location read from the shared defaults, its raw
--- URLs, the layout's entry in index.json, and the refusal of a file that does
--- not match that entry. The Windows driver applies the same rules in
--- modules/keymap/keylayout/layout_registry.ahk.
---
--- FEATURES & RATIONALE:
--- 1. PURE Lua: no driver imports, no io/network/OS calls. The transport, the
---    JSON decoder and the SHA-256 digest are injected, so both drivers share
---    one decision table and tests replay a download without a network.
--- 2. One location: folder, branch, URL template, bounds and local folder come
---    from _shared/modules/layouts/defaults.json, owner and repo from
---    _shared/modules/updater/defaults.json.
--- 3. Fail fast: every failure names its reason, and a layout is handed back
---    only once its size and checksum match the index it was downloaded with.
--- ==============================================================================

local M = {}

--- A registry id is also a file name: a lowercase letter, then lowercase
--- letters, digits and underscores, the rule tools/build/build-layouts-index.cjs
--- enforces (tools/test/test-layouts-defaults-single-source.cjs pins this copy).
M.ID_PATTERN = "^[a-z][a-z0-9_]*$"

local NAME_PATTERN = "^[A-Za-z0-9._-]+$"
local FOLDER_PATTERN = "^[A-Za-z0-9._/-]+$"
local USER_AGENT = "ErgoptiPlus-Layouts/1.0"
local TEMPLATE_PLACEHOLDERS = { "{owner}", "{repo}", "{branch}", "{folder}", "{path}" }





-- ================================
-- ================================
-- ======= 1/ Settings ============
-- ================================
-- ================================

--- Replaces every occurrence of a literal needle, without pattern magic in
--- either the needle or the value (a value may hold "%").
--- @param text string
--- @param needle string
--- @param value string
--- @return string
local function replace_plain(text, needle, value)
	local parts = {}
	local start = 1
	while true do
		local first, last = text:find(needle, start, true)
		if not first then break end
		parts[#parts + 1] = text:sub(start, first - 1)
		parts[#parts + 1] = value
		start = last + 1
	end
	parts[#parts + 1] = text:sub(start)
	return table.concat(parts)
end

--- Reads one strictly positive integer.
--- @param value any
--- @return number|nil
local function positive_integer(value)
	if type(value) ~= "number" or value <= 0 or value % 1 ~= 0 then return nil end
	return value
end

--- Validates the shared defaults and returns the registry settings.
--- @param layout_defaults table Decoded _shared/modules/layouts/defaults.json.
--- @param updater_defaults table Decoded _shared/modules/updater/defaults.json.
--- @return table|nil settings { owner, repo, folder, index_file, branch, url_template, timeout_ms, max_file_bytes, local_folder }
--- @return string|nil error Exact reason when the defaults are unusable.
function M.resolve(layout_defaults, updater_defaults)
	local registry = type(layout_defaults) == "table" and layout_defaults.registry or nil
	if type(registry) ~= "table" then return nil, "layout defaults declare no registry table" end
	local github = type(updater_defaults) == "table" and updater_defaults.github or nil
	local owner = type(github) == "table" and github.owner or nil
	local repo = type(github) == "table" and github.repo or nil
	if type(owner) ~= "string" or not owner:match(NAME_PATTERN)
		or type(repo) ~= "string" or not repo:match(NAME_PATTERN) then
		return nil, "updater defaults declare no valid github.owner/github.repo"
	end
	local template = registry.raw_url_template
	if type(template) ~= "string" or not template:match("^https://") then
		return nil, "registry.raw_url_template is not an https URL template"
	end
	for _, placeholder in ipairs(TEMPLATE_PLACEHOLDERS) do
		if not template:find(placeholder, 1, true) then
			return nil, "registry.raw_url_template lacks " .. placeholder
		end
	end
	local settings = {
		owner = owner,
		repo = repo,
		folder = registry.folder,
		index_file = registry.index_file,
		branch = registry.branch,
		url_template = template,
		local_folder = registry.local_folder,
	}
	if type(settings.folder) ~= "string" or not settings.folder:match(FOLDER_PATTERN) then
		return nil, "registry.folder is not a repository path"
	end
	for _, key in ipairs({ "index_file", "branch", "local_folder" }) do
		if type(settings[key]) ~= "string" or not settings[key]:match(NAME_PATTERN) then
			return nil, "registry." .. key .. " is not a plain name"
		end
	end
	local timeout_sec = positive_integer(registry.download_timeout_sec)
	local max_bytes = positive_integer(registry.max_file_bytes)
	if not timeout_sec then return nil, "registry.download_timeout_sec is not a positive integer" end
	if not max_bytes then return nil, "registry.max_file_bytes is not a positive integer" end
	settings.timeout_ms = timeout_sec * 1000
	settings.max_file_bytes = max_bytes
	return settings, nil
end

--- Download URL of a file of the registry folder.
--- @param settings table Result of M.resolve().
--- @param relative_path string Path inside the registry ("index.json", "ergol/ergol.keylayout").
--- @return string
function M.raw_url(settings, relative_path)
	local url = settings.url_template
	for name, value in pairs({
		owner = settings.owner,
		repo = settings.repo,
		branch = settings.branch,
		folder = settings.folder,
		path = relative_path,
	}) do
		url = replace_plain(url, "{" .. name .. "}", value)
	end
	return url
end

--- Whether a value can name a registry layout (and therefore a local file).
--- @param id any
--- @return boolean
function M.is_valid_id(id)
	return type(id) == "string" and id:match(M.ID_PATTERN) ~= nil
end





-- ==============================
-- ==============================
-- ======= 2/ Index =============
-- ==============================
-- ==============================

--- Entry of a layout in a decoded registry index.
--- @param index any Decoded index.json.
--- @param id string Registry id.
--- @return table|nil entry
--- @return string|nil error
function M.find_entry(index, id)
	local layouts = type(index) == "table" and index.layouts or nil
	if type(layouts) ~= "table" then return nil, "the registry index has no layouts list" end
	for _, entry in ipairs(layouts) do
		if type(entry) == "table" and entry.id == id then return entry, nil end
	end
	return nil, "the layout '" .. tostring(id) .. "' is not in the registry index"
end

--- Refuses a layout file that is not exactly the one its entry describes.
--- @param entry table Registry index entry.
--- @param text string The file's bytes.
--- @param digest string|nil Lowercase hex SHA-256 of those bytes.
--- @return boolean ok
--- @return string|nil error
function M.verify(entry, text, digest)
	if type(text) ~= "string" then return false, "the layout was not downloaded" end
	if #text ~= entry.size then
		return false, string.format("the layout '%s' has %d bytes instead of %s",
			tostring(entry.id), #text, tostring(entry.size))
	end
	if type(digest) ~= "string" or digest:lower() ~= entry.sha256 then
		return false, string.format("the layout '%s' does not match its registry checksum", tostring(entry.id))
	end
	return true, nil
end





-- ==============================
-- ==============================
-- ======= 3/ Download ==========
-- ==============================
-- ==============================

--- Describes a failed request without echoing response content.
--- @param url string
--- @param status any
--- @param err any
--- @return string
local function failure_reason(url, status, err)
	status = tonumber(status) or 0
	if status ~= 0 then return "HTTP " .. tostring(status) .. " for " .. url end
	if type(err) == "string" and err ~= "" then return err .. " for " .. url end
	return "no HTTP response for " .. url .. " (network, proxy or timeout)"
end

--- Downloads index.json and one layout, and verifies the layout against it.
--- transport.get(url, headers, timeout_ms, callback(status, body, err)) must call
--- back exactly once and bound the request; transport.decode_json(text) returns
--- the decoded value (nil or a raise when invalid); transport.sha256(text,
--- callback(hex, err)) digests
--- the bytes. on_done(true, { entry, index_text, layout_text }) or
--- on_done(false, reason) is called exactly once; nothing is written here.
--- @param settings table Result of M.resolve().
--- @param id string Registry id.
--- @param transport table { get, decode_json, sha256 }.
--- @param on_done function Terminal callback.
function M.fetch(settings, id, transport, on_done)
	local finished = false
	local function finish(ok, detail)
		if finished then return end
		finished = true
		on_done(ok, detail)
	end
	if not M.is_valid_id(id) then
		finish(false, "'" .. tostring(id) .. "' is not a registry layout id")
		return
	end
	local headers = { ["User-Agent"] = USER_AGENT }

	local function on_layout(entry, index_text, url, status, body, err)
		if tonumber(status) ~= 200 or type(body) ~= "string" then
			finish(false, failure_reason(url, status, err))
			return
		end
		transport.sha256(body, function(digest, digest_err)
			if type(digest) ~= "string" then
				finish(false, "cannot digest the downloaded layout: " .. tostring(digest_err))
				return
			end
			local ok, reason = M.verify(entry, body, digest)
			if not ok then
				finish(false, reason)
				return
			end
			finish(true, { entry = entry, index_text = index_text, layout_text = body })
		end)
	end

	local index_url = M.raw_url(settings, settings.index_file)
	transport.get(index_url, headers, settings.timeout_ms, function(status, body, err)
		if tonumber(status) ~= 200 or type(body) ~= "string" then
			finish(false, failure_reason(index_url, status, err))
			return
		end
		if #body > settings.max_file_bytes then
			finish(false, "the registry index exceeds the download bound")
			return
		end
		-- A decoder may raise or return nil (the shared json.lua returns nil).
		local decoded_ok, index = pcall(transport.decode_json, body)
		if not decoded_ok or type(index) ~= "table" then
			finish(false, "the registry index is not valid JSON"
				.. (decoded_ok and "" or ": " .. tostring(index)))
			return
		end
		local entry, entry_err = M.find_entry(index, id)
		if not entry then
			finish(false, entry_err)
			return
		end
		if type(entry.size) ~= "number" or entry.size > settings.max_file_bytes
			or type(entry.file) ~= "string" or type(entry.sha256) ~= "string" then
			finish(false, "the registry entry of '" .. id .. "' has no usable file, size or checksum")
			return
		end
		local layout_url = M.raw_url(settings, entry.file)
		transport.get(layout_url, headers, settings.timeout_ms, function(layout_status, layout_body, layout_err)
			on_layout(entry, body, layout_url, layout_status, layout_body, layout_err)
		end)
	end)
end

return M
