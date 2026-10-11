--- _shared/lua/native_presentation.lua

--- ==============================================================================
--- MODULE: Declared Native Presentation Captions
--- DESCRIPTION:
--- Resolves notification/dialog labels using retained declaration and translation
--- owners. Native dispatchers keep their original branding and lifecycle policy.
--- ==============================================================================

local M = {}

local function plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function descriptor_fields(value, kind, platform)
	if not plain(value) or rawget(value, "kind") ~= kind then return nil end
	local key, platforms = rawget(value, "title_key"), rawget(value, "platforms")
	if type(key) ~= "string" or not key:match("^[a-z][a-z0-9_.]*$") or not plain(platforms) then return nil end
	local fields = 0
	for name in next, value do
		if name ~= "kind" and name ~= "title_key" and name ~= "platforms" then return nil end
		fields = fields + 1
	end
	if fields ~= 3 then return nil end
	local projected, seen, count, selected = {}, {}, 0, false
	for index, native in next, platforms do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > 3
			or (native ~= "ahk" and native ~= "hs" and native ~= "linux") or seen[native] then return nil end
		projected[index], seen[native], count = native, true, count + 1
		if native == platform then selected = true end
	end
	if not selected then return nil end
	for index = 1, count do if rawget(projected, index) == nil then return nil end end
	return key, projected, count
end

--- Prepares one original bare native title from an authenticated dependency cohort.
--- @param policy table Actual generated title policy.
--- @param translator table Actual driver translation facade.
--- @param locale table Actual delegated locale owner.
--- @param presentation_id string Exact native declaration identity.
--- @param kind string Notification or dialog identity.
--- @param platform string Native platform identity.
--- @param current function Native source/module custody predicate.
--- @return table|nil Original bare title and retained current predicate.
function M.prepare(policy, translator, locale, presentation_id, kind, platform, current)
	if not plain(policy) or not plain(translator) or not plain(locale)
		or type(presentation_id) ~= "string" or not presentation_id:match("^[a-z][a-z0-9_]*$")
		or (kind ~= "notification" and kind ~= "dialog")
		or (platform ~= "ahk" and platform ~= "hs" and platform ~= "linux")
		or type(current) ~= "function" then return nil end
	local lookup, translate = rawget(policy, "native_presentation"), rawget(translator, "get")
	local locale_get, locale_current = rawget(locale, "get"), rawget(locale, "current_locale")
	if type(lookup) ~= "function" or type(translate) ~= "function"
		or type(locale_get) ~= "function" or type(locale_current) ~= "function" then return nil end
	local function owners_live()
		return plain(policy) and plain(translator) and plain(locale)
			and rawget(policy, "native_presentation") == lookup and rawget(translator, "get") == translate
			and rawget(locale, "get") == locale_get and rawget(locale, "current_locale") == locale_current
			and current() == true
	end
	if not owners_live() then return nil end
	local read_ok, code = pcall(locale_current)
	if not read_ok or type(code) ~= "string" or code == "" or not owners_live() then return nil end
	local source_ok, source = pcall(lookup, presentation_id, kind, platform)
	if not source_ok or not owners_live() then return nil end
	local key, platforms, count = descriptor_fields(source, kind, platform)
	if key == nil then return nil end
	local function live()
		if not owners_live() then return false end
		local locale_ok, current_code = pcall(locale_current)
		if not locale_ok or current_code ~= code or not owners_live() then return false end
		local lookup_ok, latest = pcall(lookup, presentation_id, kind, platform)
		if not lookup_ok or not owners_live() then return false end
		local latest_key, latest_platforms, latest_count = descriptor_fields(latest, kind, platform)
		if latest_key ~= key or latest_count ~= count then return false end
		for index = 1, count do if rawget(latest_platforms, index) ~= rawget(platforms, index) then return false end end
		return owners_live()
	end
	if not live() then return nil end
	local translated, title = pcall(translate, key)
	if not translated or type(title) ~= "string" or title == "" or title == key or not live() then return nil end
	return { title = title, current = live }
end

return M
