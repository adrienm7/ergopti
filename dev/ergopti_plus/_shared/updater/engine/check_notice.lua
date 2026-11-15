--- _shared/updater/engine/check_notice.lua

--- ==============================================================================
--- MODULE: Update Check Notice (Shared)
--- DESCRIPTION:
--- Words the notification a manual check sends when the update-check window
--- cannot open (Linux without WebKitGTK or a display, a macOS webview that
--- refuses to open). It reads the same structured answer
--- the window shows (updater.check_result), so each outcome keeps its own
--- sentence, as Windows' Updater_ShowAvailableUpdateCallback words them.
---
--- FEATURES & RATIONALE:
--- 1. The notice used to read only (available, release, err): a release
---    without the Linux bundle or a channel with no release said « up to
---    date », a parse failure said « no connection », and a failed check with a
---    release already known said « new version ». The result's state and
---    reason key decide instead.
--- 2. Fail fast on an answer that is not a check result: a caller passing the
---    wrong value is a bug, not an outcome to word.
--- 3. A background check's announcement of a release read from the public
---    feed says it cannot be installed yet, as Windows' balloon does.
--- 4. Pure: the locale lookup and the channel label are injected.
--- ==============================================================================

local M = {}

--- Replaces each {name} placeholder the locale string carries.
--- @param text string
--- @param values table name -> replacement
--- @return string
local function fill(text, values)
	return (text:gsub("{([%w_]+)}", function(name)
		local value = values[name]
		if value == nil then return nil end
		return tostring(value)
	end))
end

--- Builds the notification body of one manual check's answer.
--- @param result table The updater.check_result answer the check published.
--- @param get function Locale lookup, key -> string.
--- @param channel_label function Channel id -> its localized name.
--- @return string body
function M.body(result, get, channel_label)
	if type(result) ~= "table" then error("an update-check notice needs the check's answer", 2) end
	local state = result.state
	if state == "available" then
		return fill(get("updater.tray_new_version_body"), { ["1"] = result.latest })
	elseif state == "up_to_date" then
		return fill(get("updater.up_to_date"), { ["1"] = result.current })
	elseif state == "no_release" then
		return fill(get("updater.no_release_on_channel"), { channel = channel_label(result.channel) })
	elseif state == "error" then
		if type(result.reason_key) ~= "string" then error("a failed check carries no reason key", 2) end
		return fill(get(result.reason_key), {
			channel = channel_label(result.channel), tag = result.latest, current = result.current,
		})
	end
	error("unknown update-check state: " .. tostring(state), 2)
end

--- Builds the notification body announcing one release a background check found.
--- @param release table { tag, check_only? } The updater's cached release.
--- @param get function Locale lookup, key -> string.
--- @return string body
function M.release_body(release, get)
	if type(release) ~= "table" or type(release.tag) ~= "string" then
		error("a release announcement needs the release's tag", 2)
	end
	local body = fill(get("updater.tray_new_version_body"), { ["1"] = release.tag })
	-- The feed names tags only: the install needs the API's asset list.
	if release.check_only == true then body = body .. " " .. get("update_check.check_only") end
	return body
end

return M
