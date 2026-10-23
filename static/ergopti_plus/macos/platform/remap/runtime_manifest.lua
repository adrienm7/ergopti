--- platform/remap/runtime_manifest.lua

--- ==============================================================================
--- MODULE: Owned Runtime Artifact Pin
--- DESCRIPTION:
--- Decides whether the manifest of the owned Karabiner runtime (ADR 011, WP5)
--- pins an artifact completely, and if so hands the runtime owner the facts it
--- needs: the VirtualHIDDevice version it must find and the capture declaration
--- it must start. Pure data checks; no file is read here.
---
--- FEATURES & RATIONALE:
--- 1. Unpinned Is A Named Refusal: the digest of the runtime tarball and the
---    designated requirement exist only after the hosted build produced and
---    signed the artifact. Until then every one of those fields is null and the
---    verdict names the first missing path, so the owner reports
---    `artifact_unpinned` with a sentence instead of guessing a version.
--- 2. One Field List: M.FIELDS is the single list of what a complete pin
---    contains. The build gate (tools/test/test-remap-runtime-manifest.cjs)
---    reads this list from this file, so the gate and the runtime cannot
---    disagree about what "pinned" means.
--- 3. Shapes, Not Trust: a digest is 64 lower-case hex characters, a URL is an
---    https address without credentials or fragment whose last segment is the
---    pinned file name, and sizes and limits are positive integers.
--- ==============================================================================

local M = {}

--- Every path a complete pin carries, with the shape its value must have.
--- Kept one entry per line: the build gate reads it textually.
M.FIELDS = {
	{ "runtime.upstream_repository", "text" },
	{ "runtime.upstream_revision", "revision" },
	{ "runtime.version", "version" },
	{ "runtime.file_name", "file_name" },
	{ "runtime.source_url", "url" },
	{ "runtime.sha256", "sha256" },
	{ "runtime.size", "count" },
	{ "virtual_hid_device.version", "version" },
	{ "virtual_hid_device.team_identifier", "team" },
	{ "virtual_hid_device.file_name", "file_name" },
	{ "virtual_hid_device.source_url", "url" },
	{ "virtual_hid_device.sha256", "sha256" },
	{ "virtual_hid_device.size", "count" },
	{ "capture.requirement", "requirement" },
	{ "capture.batch_limit", "count" },
	{ "capture.frame_limit", "count" },
	{ "capture.history_capacity", "count" },
}

--- The manifest schema this module understands.
M.SCHEMA = 1

local SHAPES = {
	text = function(value) return type(value) == "string" and value:match("^[%w%-_/.]+$") ~= nil end,
	revision = function(value) return type(value) == "string" and value:match("^%x+$") ~= nil and #value == 40 end,
	version = function(value) return type(value) == "string" and value:match("^%d+%.%d+%.%d+[%w%.%-+]*$") ~= nil end,
	file_name = function(value)
		return type(value) == "string" and value:match("^[%w][%w%._%-]*$") ~= nil
	end,
	url = function(value)
		return type(value) == "string" and value:match("^https://[%w%.%-]+/[^%s@#]*$") ~= nil
	end,
	sha256 = function(value) return type(value) == "string" and value:match("^%x+$") ~= nil and #value == 64
		and value == value:lower() end,
	team = function(value) return type(value) == "string" and value:match("^%u[%u%d]+$") ~= nil and #value == 10 end,
	requirement = function(value)
		return type(value) == "string" and value ~= "" and not value:find("[%z\r\n]")
	end,
	count = function(value) return math.type(value) == "integer" and value >= 1 end,
}

--- Reads one dotted path.
--- @param manifest table Decoded manifest.
--- @param path string Dotted path.
--- @return any value
local function lookup(manifest, path)
	local value = manifest
	for key in path:gmatch("[^%.]+") do
		if type(value) ~= "table" then return nil end
		value = value[key]
	end
	return value
end

--- Lists the paths that are absent, null or malformed.
--- @param manifest any Decoded manifest.
--- @return table paths Dotted paths, in field order.
function M.unpinned(manifest)
	local missing = {}
	if type(manifest) ~= "table" or manifest.schema ~= M.SCHEMA then
		for _, field in ipairs(M.FIELDS) do missing[#missing + 1] = field[1] end
		return missing
	end
	local flagged = {}
	for _, field in ipairs(M.FIELDS) do
		if not SHAPES[field[2]](lookup(manifest, field[1])) then
			missing[#missing + 1] = field[1]
			flagged[field[1]] = true
		end
	end
	-- A download address must end in the very file name that is pinned.
	for _, group in ipairs({ "runtime", "virtual_hid_device" }) do
		local url, name = group .. ".source_url", group .. ".file_name"
		if not flagged[url] and not flagged[name]
			and lookup(manifest, url):match("[^/]+$") ~= lookup(manifest, name) then
			missing[#missing + 1] = url
		end
	end
	return missing
end

--- The pinned facts the runtime owner needs, or the reason there are none.
--- @param manifest any Decoded manifest.
--- @return table|nil pinned { virtual_hid_version, capture = { requirement, batch_limit, frame_limit, history_capacity } }.
--- @return string|nil reason Names the first unpinned path and how many follow.
function M.pinned(manifest)
	local missing = M.unpinned(manifest)
	if #missing > 0 then
		local more = #missing > 1 and (" and " .. (#missing - 1) .. " more") or ""
		return nil, "the runtime manifest is not pinned (" .. missing[1] .. more .. ")"
	end
	return {
		virtual_hid_version = manifest.virtual_hid_device.version,
		capture = {
			requirement = manifest.capture.requirement,
			batch_limit = manifest.capture.batch_limit,
			frame_limit = manifest.capture.frame_limit,
			history_capacity = manifest.capture.history_capacity,
		},
	}
end

return M
