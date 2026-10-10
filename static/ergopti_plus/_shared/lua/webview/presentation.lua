--- _shared/lua/webview/presentation.lua

--- ==============================================================================
--- MODULE: Declared Webview Presentations
--- DESCRIPTION:
--- Resolves a real app context once and retains its declaration and translation
--- cohort. Native factories authenticate their dependencies and receipt owners.
--- ==============================================================================

local M = {}

local function plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function identifier(value)
	return type(value) == "string" and value:match("^[a-z][a-z0-9_]*$") ~= nil
end

local function locale_key(value)
	return type(value) == "string" and value:match("^[a-z][a-z0-9_.]*$") ~= nil
end

--- Prepares immutable strings using an authenticated native dependency cohort.
--- @param policy table Actual generated title/presentation policy.
--- @param translator table Actual locale facade.
--- @param locale table Actual delegated locale owner.
--- @param app_id string Genuine app identity.
--- @param presentation_id string Genuine contextual identity.
--- @param platform string Native platform identity.
--- @param current function Native module/source custody predicate.
--- @return table|nil Prepared strings with a retained current predicate.
function M.prepare(policy, translator, locale, app_id, presentation_id, platform, current)
	if not plain(policy) or not plain(translator) or not plain(locale)
		or not identifier(app_id) or not identifier(presentation_id)
		or (platform ~= "ahk" and platform ~= "hs" and platform ~= "linux")
		or type(current) ~= "function" then return nil end
	local lookup, compose = rawget(policy, "presentation_for_app"), rawget(policy, "compose")
	local translate, locale_get = rawget(translator, "get"), rawget(locale, "get")
	local locale_current = rawget(locale, "current_locale")
	if type(lookup) ~= "function" or type(compose) ~= "function" or type(translate) ~= "function"
		or type(locale_get) ~= "function" or type(locale_current) ~= "function" then return nil end
	local function owners_live()
		return plain(policy) and plain(translator) and plain(locale)
			and rawget(policy, "presentation_for_app") == lookup and rawget(policy, "compose") == compose
			and rawget(translator, "get") == translate and rawget(locale, "get") == locale_get
			and rawget(locale, "current_locale") == locale_current and current() == true
	end
	if not owners_live() then return nil end
	local ok, code = pcall(locale_current)
	if not ok or type(code) ~= "string" or code == "" or not owners_live() then return nil end
	local admitted, descriptor = pcall(lookup, app_id, presentation_id, platform)
	if not admitted or not owners_live() or not plain(descriptor) then return nil end
	local title_key, label_key = rawget(descriptor, "title_key"), rawget(descriptor, "label_key")
	local platforms = rawget(descriptor, "platforms")
	if not locale_key(title_key) or not locale_key(label_key) or not plain(platforms) then return nil end
	local fields = 0
	for key in next, descriptor do
		if key ~= "title_key" and key ~= "label_key" and key ~= "platforms" then return nil end
		fields = fields + 1
	end
	if fields ~= 3 then return nil end
	local native_platforms, seen, selected = {}, {}, false
	for index, native in next, platforms do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > 3
			or (native ~= "ahk" and native ~= "hs" and native ~= "linux") or seen[native] then return nil end
		native_platforms[index], seen[native] = native, true
		if native == platform then selected = true end
	end
	if not selected then return nil end
	local platform_count = 0
	for _ in next, native_platforms do platform_count = platform_count + 1 end
	for index = 1, platform_count do if rawget(native_platforms, index) == nil then return nil end end
	local function live()
		if not owners_live() or not plain(descriptor) or not plain(platforms)
			or rawget(descriptor, "title_key") ~= title_key or rawget(descriptor, "label_key") ~= label_key
			or rawget(descriptor, "platforms") ~= platforms then return false end
		local count = 0
		for key in next, descriptor do
			if key ~= "title_key" and key ~= "label_key" and key ~= "platforms" then return false end
			count = count + 1
		end
		if count ~= 3 then return false end
		count = 0
		for index, native in next, platforms do
			if rawget(native_platforms, index) ~= native then return false end
			count = count + 1
		end
		if count ~= platform_count then return false end
		local current_ok, current_code = pcall(locale_current)
		if not current_ok or current_code ~= code or not owners_live() then return false end
		local source_ok, source = pcall(lookup, app_id, presentation_id, platform)
		if not source_ok or not owners_live() or not plain(source)
			or rawget(source, "title_key") ~= title_key or rawget(source, "label_key") ~= label_key then return false end
		local source_platforms = rawget(source, "platforms")
		if not plain(source_platforms) then return false end
		count = 0
		for key in next, source do
			if key ~= "title_key" and key ~= "label_key" and key ~= "platforms" then return false end
			count = count + 1
		end
		if count ~= 3 then return false end
		count = 0
		for index, native in next, source_platforms do
			if rawget(native_platforms, index) ~= native then return false end
			count = count + 1
		end
		return count == platform_count and owners_live()
	end
	local function read(owner, value, refuse_echo)
		if not live() then return nil end
		local read_ok, text = pcall(owner, value)
		if not read_ok or type(text) ~= "string" or text == "" or (refuse_echo and text == value) or not live() then return nil end
		return text
	end
	local title = read(translate, title_key, true)
	if title == nil then return nil end
	local label = read(translate, label_key, true)
	if label == nil then return nil end
	local caption = read(compose, title, false)
	if caption == nil or not live() then return nil end
	return { title = title, label = label, caption = caption, current = live }
end

return M
