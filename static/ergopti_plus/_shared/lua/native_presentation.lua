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

--- Builds one driver's receiving owner: opaque bare-caption receipts issued
--- from the real generated policy and live locale cohort. The macOS and Linux
--- owners were the same file but for their platform tag.
--- @param options table { platform = "hs"|"linux", name = the receiver's package.loaded
---   key, i18n, locale, core = each { name = package.loaded key, module = loaded module } }.
--- @return table receiver { prepare(presentation_id, kind), title(receipt) }
function M.receiver(options)
	assert(plain(options), "native presentation receiver: options must be a plain table")
	for key in pairs(options) do
		assert(key == "platform" or key == "name" or key == "i18n" or key == "locale" or key == "core",
			"native presentation receiver: unknown option " .. tostring(key))
	end
	local platform, name = options.platform, options.name
	assert(platform == "hs" or platform == "linux", "native presentation receiver: unknown platform " .. tostring(platform))
	assert(type(name) == "string" and name ~= "", "native presentation receiver: name must be its package.loaded key")
	for _, owner in ipairs({ "i18n", "locale", "core" }) do
		local entry = options[owner]
		assert(plain(entry) and type(entry.name) == "string" and entry.name ~= "" and type(entry.module) == "table",
			"native presentation receiver: " .. owner .. " needs its name and module")
	end
	local R = {}
	local Policy = require("window_titles")
	local Shared = M
	local I18n, Locale, Core = options.i18n.module, options.locale.module, options.core.module
	local i18n_name, locale_name, core_name = options.i18n.name, options.locale.name, options.core.name
	local Modules = package.loaded
	local Lookup, Prepare = rawget(Policy, "native_presentation"), rawget(Shared, "prepare")
	local Translate, LocaleGet = rawget(I18n, "get"), rawget(Locale, "get")
	local LocaleCurrent, CoreGet, CoreCurrent = rawget(Locale, "current_locale"), rawget(Core, "get"), rawget(Core, "current_locale")
	local PrepareApi, TitleApi
	local receipts = setmetatable({}, { __mode = "k" })

	local function owners_current()
		return getmetatable(R) == nil and getmetatable(Policy) == nil and getmetatable(Shared) == nil
			and getmetatable(I18n) == nil and getmetatable(Locale) == nil and getmetatable(Core) == nil
			and rawget(package, "loaded") == Modules and rawget(Modules, name) == R
			and rawget(Modules, "window_titles") == Policy and rawget(Modules, "native_presentation") == Shared
			and rawget(Modules, i18n_name) == I18n and rawget(Modules, locale_name) == Locale
			and rawget(Modules, core_name) == Core
			and rawget(Policy, "native_presentation") == Lookup and rawget(Shared, "prepare") == Prepare
			and rawget(I18n, "get") == Translate and rawget(Locale, "get") == LocaleGet
			and rawget(Locale, "current_locale") == LocaleCurrent and rawget(Core, "get") == CoreGet
			and rawget(Core, "current_locale") == CoreCurrent
			and rawget(R, "prepare") == PrepareApi and rawget(R, "title") == TitleApi
	end

	--- Prepares one exact native declaration before a caller enters its native port.
	--- @param presentation_id string Native notification/dialog identity.
	--- @param kind string Required native kind.
	--- @return table|nil Opaque native receiving receipt.
	function R.prepare(presentation_id, kind)
		if type(Lookup) ~= "function" or type(Prepare) ~= "function" or not owners_current() then return nil end
		local admitted, prepared = pcall(Prepare, Policy, I18n, Locale, presentation_id, kind, platform, owners_current)
		if not admitted or type(prepared) ~= "table" or getmetatable(prepared) ~= nil
			or type(rawget(prepared, "title")) ~= "string" or type(rawget(prepared, "current")) ~= "function"
			or not owners_current() then return nil end
		local live, current = pcall(prepared.current)
		if not live or current ~= true or not owners_current() then return nil end
		local receipt = {}
		receipts[receipt] = { title = prepared.title, current = prepared.current }
		return receipt
	end

	--- Receives only this receiver's still-current original bare title.
	--- @param receipt table Opaque native receiving receipt.
	--- @return string|nil Original title, without application branding or a page label.
	function R.title(receipt)
		local retained = receipts[receipt]
		if retained == nil or not owners_current() then return nil end
		local called, current = pcall(retained.current)
		if not called or current ~= true or not owners_current() then return nil end
		return retained.title
	end

	PrepareApi, TitleApi = R.prepare, R.title
	return R
end

return M
