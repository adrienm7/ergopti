--- _shared/lua/updater/channels.lua

--- ==============================================================================
--- MODULE: Update Channel Registry (Shared Lua Port)
--- DESCRIPTION:
--- Interprets the shared update-channel registry
--- (_shared/modules/updater/channels.json) for the macOS and Linux drivers:
--- which channel a release tag belongs to, how a persisted value maps to a
--- channel, which releases a channel's Versions view lists, whether an update
--- check offers a candidate, which release is a channel's latest, and which
--- other channels published a newer release than the installed build.
---
--- FEATURES & RATIONALE:
--- 1. Port of the canonical JavaScript matcher (_shared/ui/update_channels.js);
---    both replay _shared/modules/updater/channel_vectors.json, so the tag rule
---    is interpreted, never translated into a Lua pattern of a JS regex.
--- 2. PURE Lua (LuaJIT and 5.4): no driver imports, no io, no OS calls. The
---    driver decodes channels.json and passes the table to M.load().
--- 3. Fail fast: M.load() returns nil and the exact reason for a malformed
---    registry; the caller logs it and refuses the channel features.
--- ==============================================================================

local Version = require("updater.version")

local M = {}

local SCHEMA_VERSION = 1
local CORE_SEMVER = "semver"
-- A publish time exactly as GitHub writes it (UTC, whole seconds), so text
-- order is time order in every runtime without a date parser.
local PUBLISHED_AT = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"





-- =====================================
-- =====================================
-- ======= 1/ Tag Parsing ==============
-- =====================================
-- =====================================

--- Reports whether a string is one numeric semver identifier without a
--- leading zero ("0" or [1-9][0-9]*).
--- @param text string
--- @return boolean
local function is_number_identifier(text)
	return text == "0" or text:match("^[1-9]%d*$") ~= nil
end

--- Reports whether a string is an X.Y.Z core without leading zeros.
--- @param text any
--- @return boolean
local function is_core(text)
	if type(text) ~= "string" then return false end
	local major, minor, patch = text:match("^(%d+)%.(%d+)%.(%d+)$")
	return major ~= nil and is_number_identifier(major)
		and is_number_identifier(minor) and is_number_identifier(patch)
end

--- Splits on every dot, keeping empty parts so "a..b" stays visibly malformed.
--- @param text string
--- @return table parts
local function split_dots(text)
	local parts = {}
	local start = 1
	while true do
		local dot = text:find(".", start, true)
		if not dot then
			parts[#parts + 1] = text:sub(start)
			return parts
		end
		parts[#parts + 1] = text:sub(start, dot - 1)
		start = dot + 1
	end
end

--- Parses a release tag into its X.Y.Z core and prerelease identifiers.
--- Build metadata ("+...") is refused: the workflow never publishes it. Only
--- ASCII blanks are trimmed, as in the JavaScript and AHK ports.
--- @param tag any Release tag, with or without its leading "v".
--- @return table|nil parsed { core = string, prerelease = table|nil }
local function parse_tag(tag)
	if type(tag) ~= "string" then return nil end
	local text = tag:match("^[ \t\r\n]*(.-)[ \t\r\n]*$")
	local first = text:sub(1, 1)
	if first == "v" or first == "V" then text = text:sub(2) end
	if text:find("+", 1, true) then return nil end
	local dash = text:find("-", 1, true)
	local core = dash and text:sub(1, dash - 1) or text
	if not is_core(core) then return nil end
	if not dash then return { core = core, prerelease = nil } end
	local parts = split_dots(text:sub(dash + 1))
	for _, part in ipairs(parts) do
		if part == "" then return nil end
	end
	return { core = core, prerelease = parts }
end

--- Applies one channel's structured tag rule to a parsed tag.
--- @param rule table { core = string, prerelease = { label, counter }|nil }
--- @param parsed table|nil
--- @return boolean
local function matches_rule(rule, parsed)
	if not parsed then return false end
	if rule.core ~= CORE_SEMVER and rule.core ~= parsed.core then return false end
	if rule.prerelease == nil then return parsed.prerelease == nil end
	local parts = parsed.prerelease
	if parts == nil or parts[1] ~= rule.prerelease.label then return false end
	if rule.prerelease.counter then
		return #parts == 2 and parts[2]:match("^[1-9]%d*$") ~= nil
	end
	return #parts == 1
end

--- Reports whether one tag could satisfy both rules.
--- @return boolean
local function rules_overlap(a, b)
	local cores = a.core == CORE_SEMVER or b.core == CORE_SEMVER or a.core == b.core
	if not cores then return false end
	if a.prerelease == nil or b.prerelease == nil then return a.prerelease == b.prerelease end
	return a.prerelease.label == b.prerelease.label and a.prerelease.counter == b.prerelease.counter
end





-- ======================================
-- ======================================
-- ======= 2/ Registry Validation =======
-- ======================================
-- ======================================

local function is_channel_id(value)
	return type(value) == "string" and value:match("^[a-z][a-z0-9_]*$") ~= nil
end

local function is_locale_key(value)
	return type(value) == "string" and value:match("^[a-z][a-z0-9_]*%.[a-z0-9_.]+$") ~= nil
		and not value:find("..", 1, true) and value:sub(-1) ~= "."
end

--- Validates one tag rule and returns a detached copy.
--- @return table|nil rule
--- @return string|nil error
local function validate_rule(id, tag)
	if type(tag) ~= "table" then return nil, "channel " .. id .. " has no tag rule" end
	if tag.core ~= CORE_SEMVER and not is_core(tag.core) then
		return nil, "channel " .. id .. " has an invalid tag core"
	end
	-- false, not null: the shared JSON decoder turns a null into a sentinel table.
	local pre = tag.prerelease
	if pre == false then return { core = tag.core, prerelease = nil } end
	if type(pre) ~= "table" or type(pre.label) ~= "string" or not pre.label:match("^[a-z][a-z0-9]*$") then
		return nil, "channel " .. id .. " has an invalid prerelease label"
	end
	if type(pre.counter) ~= "boolean" then
		return nil, "channel " .. id .. " has no prerelease counter flag"
	end
	return { core = tag.core, prerelease = { label = pre.label, counter = pre.counter } }
end

--- Validates one decoded channel entry.
--- @return table|nil record
--- @return string|nil error
local function validate_channel(entry, index)
	if type(entry) ~= "table" then return nil, "channel #" .. index .. " is not an object" end
	local id = entry.id
	if not is_channel_id(id) then return nil, "channel #" .. index .. " has an invalid id" end
	if not is_locale_key(entry.label_key) then return nil, "channel " .. id .. " has an invalid label_key" end
	if not is_locale_key(entry.menu_label_key) then
		return nil, "channel " .. id .. " has an invalid menu_label_key"
	end
	if type(entry.github_prerelease) ~= "boolean" then
		return nil, "channel " .. id .. " has no github_prerelease flag"
	end
	if type(entry.sparkle_feed) ~= "string" or not entry.sparkle_feed:match("^appcast%-[a-z0-9_%-]+%.xml$") then
		return nil, "channel " .. id .. " has an invalid sparkle_feed"
	end
	if type(entry.aliases) ~= "table" then return nil, "channel " .. id .. " has no aliases list" end
	local rule, rule_err = validate_rule(id, entry.tag)
	if not rule then return nil, rule_err end
	local aliases = {}
	for _, alias in ipairs(entry.aliases) do aliases[#aliases + 1] = alias end
	return {
		id = id,
		rank = index,
		label_key = entry.label_key,
		menu_label_key = entry.menu_label_key,
		aliases = aliases,
		github_prerelease = entry.github_prerelease,
		sparkle_feed = entry.sparkle_feed,
		rule = rule,
	}
end





-- =====================================
-- =====================================
-- ======= 3/ Public Interpreter =======
-- =====================================
-- =====================================

--- Validates a decoded channels.json and returns its interpreter.
--- @param decoded table Decoded _shared/modules/updater/channels.json.
--- @return table|nil registry Interpreter, see the methods below.
--- @return string|nil error Exact reason when the registry is unusable.
function M.load(decoded)
	if type(decoded) ~= "table" then return nil, "the update channel registry is not a table" end
	if decoded.schema_version ~= SCHEMA_VERSION then
		return nil, "the update channel registry has an unsupported schema_version"
	end
	if type(decoded.channels) ~= "table" or #decoded.channels == 0 then
		return nil, "the update channel registry declares no channel"
	end
	local order, by_id, aliases = {}, {}, {}
	for index, entry in ipairs(decoded.channels) do
		local record, err = validate_channel(entry, index)
		if not record then return nil, err end
		if by_id[record.id] then return nil, "channel id " .. record.id .. " is declared twice" end
		for _, previous in ipairs(order) do
			if rules_overlap(previous.rule, record.rule) then
				return nil, "channels " .. previous.id .. " and " .. record.id .. " claim the same tags"
			end
		end
		order[#order + 1] = record
		by_id[record.id] = record
	end
	for _, record in ipairs(order) do
		for _, alias in ipairs(record.aliases) do
			if not is_channel_id(alias) then return nil, "channel " .. record.id .. " has an invalid alias" end
			if by_id[alias] or aliases[alias] then return nil, "alias " .. alias .. " is declared twice" end
			aliases[alias] = record.id
		end
	end
	local unreleased = decoded.unreleased_build_channel
	if type(unreleased) ~= "string" or not by_id[unreleased] then
		return nil, "unreleased_build_channel names no channel"
	end

	local R = {}
	R.unreleased_build_channel = unreleased

	--- Returns the channel ids in stability order (a fresh list).
	--- @return table ids
	function R.ids()
		local ids = {}
		for i, record in ipairs(order) do ids[i] = record.id end
		return ids
	end

	--- Returns a detached view of one channel, or nil.
	--- @param id any
	--- @return table|nil channel { id, rank, label_key, menu_label_key, github_prerelease, sparkle_feed }
	function R.channel(id)
		local record = type(id) == "string" and by_id[id] or nil
		if not record then return nil end
		return {
			id = record.id,
			rank = record.rank,
			label_key = record.label_key,
			menu_label_key = record.menu_label_key,
			github_prerelease = record.github_prerelease,
			sparkle_feed = record.sparkle_feed,
		}
	end

	--- Maps a persisted value or an alias to a channel id (exact match).
	--- @param value any
	--- @return string|nil id
	function R.resolve(value)
		if type(value) ~= "string" then return nil end
		if by_id[value] then return value end
		return aliases[value]
	end

	--- Reports whether a release tag belongs to one channel.
	--- @return boolean
	function R.matches(id, tag)
		local record = type(id) == "string" and by_id[id] or nil
		return record ~= nil and matches_rule(record.rule, parse_tag(tag))
	end

	--- Returns the channel that owns a release tag, or nil.
	--- @param tag any
	--- @return string|nil id
	function R.channel_for_tag(tag)
		local parsed = parse_tag(tag)
		for _, record in ipairs(order) do
			if matches_rule(record.rule, parsed) then return record.id end
		end
		return nil
	end

	--- Reports whether a channel's Versions view lists a release: its own
	--- releases and those of every more stable channel.
	--- @return boolean
	function R.visible_in(view_id, tag)
		local view = type(view_id) == "string" and by_id[view_id] or nil
		if not view then return false end
		local owner = R.channel_for_tag(tag)
		return owner ~= nil and by_id[owner].rank <= view.rank
	end

	--- Decides whether an update check offers a candidate. A deliberate switch
	--- to another channel offers that channel's latest release even when semver
	--- orders it below the installed build; within one channel only a strictly
	--- newer release is offered.
	--- @return boolean
	function R.should_offer(latest, current, selected, installed)
		if not R.matches(selected, latest) then return false end
		if selected ~= installed then
			return type(installed) == "string" and by_id[installed] ~= nil
		end
		return Version.compare_versions(latest, current) > 0
	end

	--- Returns the position of a channel's latest tag in a list (semver order,
	--- first occurrence on a tie), or nil.
	--- @param tags table Array of tags.
	--- @param id string Channel id.
	--- @return number|nil index
	function R.pick_latest(tags, id)
		if type(tags) ~= "table" or not (type(id) == "string" and by_id[id]) then return nil end
		local best = nil
		for index, tag in ipairs(tags) do
			if R.matches(id, tag) and (best == nil or Version.compare_versions(tag, tags[best]) > 0) then
				best = index
			end
		end
		return best
	end

	--- Lists, in registry order, every channel other than the checked one whose
	--- latest release was published strictly after the installed build. The
	--- installed build's time is that of the first listed release of the same
	--- version; a build that is not listed (older than the list, or a source
	--- checkout), or listed without a valid time, predates the list.
	--- @param releases table Array of { tag, published_at }, in list order.
	--- @param selected string The checked channel.
	--- @param installed string The installed build's version.
	--- @return table found Array of { channel, tag }.
	function R.newer_elsewhere(releases, selected, installed)
		local found = {}
		if type(releases) ~= "table" or not (type(selected) == "string" and by_id[selected]) then
			return found
		end
		local tags = {}
		for index, release in ipairs(releases) do
			tags[index] = type(release) == "table" and type(release.tag) == "string" and release.tag or ""
		end
		local function valid_time(value)
			return type(value) == "string" and value:match(PUBLISHED_AT) ~= nil
		end
		local installed_at = nil
		if R.channel_for_tag(installed) ~= nil then
			for index, tag in ipairs(tags) do
				if R.channel_for_tag(tag) ~= nil and Version.compare_versions(tag, installed) == 0 then
					local own = releases[index].published_at
					installed_at = valid_time(own) and own or nil
					break
				end
			end
		end
		for _, record in ipairs(order) do
			if record.id ~= selected then
				local index = R.pick_latest(tags, record.id)
				local at = index and releases[index].published_at or nil
				if index and valid_time(at) and (installed_at == nil or at > installed_at) then
					found[#found + 1] = { channel = record.id, tag = tags[index] }
				end
			end
		end
		return found
	end

	return R
end

return M
