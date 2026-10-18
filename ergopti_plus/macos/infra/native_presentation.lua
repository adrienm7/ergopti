--- infra/native_presentation.lua

--- ==============================================================================
--- MODULE: Native Presentation Receiving
--- DESCRIPTION:
--- Issues opaque bare-caption receipts from the real generated policy and live
--- locale cohort. Callers retain the original native dialog/notification owner.
--- ==============================================================================

local M = {}
local Policy = require("window_titles")
local Shared = require("native_presentation")
local I18n = require("infra.i18n")
local Locale = require("infra.locale")
local Core = require("locale.core")
local Modules = package.loaded
local Lookup, Prepare = rawget(Policy, "native_presentation"), rawget(Shared, "prepare")
local Translate, LocaleGet = rawget(I18n, "get"), rawget(Locale, "get")
local LocaleCurrent, CoreGet, CoreCurrent = rawget(Locale, "current_locale"), rawget(Core, "get"), rawget(Core, "current_locale")
local PrepareApi, TitleApi
local receipts = setmetatable({}, { __mode = "k" })

local function owners_current()
	return getmetatable(M) == nil and getmetatable(Policy) == nil and getmetatable(Shared) == nil
		and getmetatable(I18n) == nil and getmetatable(Locale) == nil and getmetatable(Core) == nil
		and rawget(package, "loaded") == Modules and rawget(Modules, "infra.native_presentation") == M
		and rawget(Modules, "window_titles") == Policy and rawget(Modules, "native_presentation") == Shared
		and rawget(Modules, "infra.i18n") == I18n and rawget(Modules, "infra.locale") == Locale
		and rawget(Modules, "locale.core") == Core
		and rawget(Policy, "native_presentation") == Lookup and rawget(Shared, "prepare") == Prepare
		and rawget(I18n, "get") == Translate and rawget(Locale, "get") == LocaleGet
		and rawget(Locale, "current_locale") == LocaleCurrent and rawget(Core, "get") == CoreGet
		and rawget(Core, "current_locale") == CoreCurrent
		and rawget(M, "prepare") == PrepareApi and rawget(M, "title") == TitleApi
end

--- Prepares one exact native declaration before a caller enters its native port.
--- @param presentation_id string Native notification/dialog identity.
--- @param kind string Required native kind.
--- @return table|nil Opaque native receiving receipt.
function M.prepare(presentation_id, kind)
	if type(Lookup) ~= "function" or type(Prepare) ~= "function" or not owners_current() then return nil end
	local admitted, prepared = pcall(Prepare, Policy, I18n, Locale, presentation_id, kind, "hs", owners_current)
	if not admitted or type(prepared) ~= "table" or getmetatable(prepared) ~= nil
		or type(rawget(prepared, "title")) ~= "string" or type(rawget(prepared, "current")) ~= "function"
		or not owners_current() then return nil end
	local live, current = pcall(prepared.current)
	if not live or current ~= true or not owners_current() then return nil end
	local receipt = {}
	receipts[receipt] = { title = prepared.title, current = prepared.current }
	return receipt
end

--- Receives only this factory's still-current original bare title.
--- @param receipt table Opaque native receiving receipt.
--- @return string|nil Original title, without application branding or a page label.
function M.title(receipt)
	local retained = receipts[receipt]
	if retained == nil or not owners_current() then return nil end
	local called, current = pcall(retained.current)
	if not called or current ~= true or not owners_current() then return nil end
	return retained.title
end

PrepareApi, TitleApi = M.prepare, M.title
return M
