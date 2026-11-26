--- _shared/metrics/engine/view/private_window.lua

--- ==============================================================================
--- MODULE: Private-Browsing Window Detection (shared)
--- DESCRIPTION:
--- The one list of window-title markers that identify a private / incognito
--- browser window, plus the matcher that applies it.
---
--- WHY THIS MODULE EXISTS:
--- "Keystrokes typed while a private browser window is focused must be dropped"
--- is a cross-driver privacy guarantee — it is one of the four categories in
--- _shared/tests/corpus/security/keystats_no_persist_vectors.json. It was
--- implemented once, inline, in the macOS context tracker, and nowhere else, so
--- the Linux driver had no private-browsing filter at all. A guarantee stated in
--- a shared corpus cannot live in one driver's private variable.
---
--- FEATURES & RATIONALE:
--- 1. Case-insensitive substring match. Browsers append the marker to the title
---    in varying positions and casings ("… — Private Browsing", "… - Incognito"),
---    and an exact match would silently stop filtering after any cosmetic
---    upstream change.
--- 2. Callers may pass extra keywords so a driver can add its own localised term
---    without forking the list.
--- ==============================================================================

local M = {}
local UnicodeCase = require("core.text.engine.unicode_case")





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Window-title markers used by the major browsers for a private session.
--- Firefox: "Private Browsing". Chrome/Chromium/Brave/Opera: "Incognito".
--- Edge: "InPrivate". Safari (localised builds) and several forks: "Anonymous".
M.KEYWORDS = {
	"Private Browsing",
	"Incognito",
	"InPrivate",
	"Anonymous",
	-- Firefox's browser-main-private-window-title in its shipped translations.
	-- https://github.com/mozilla-l10n/firefox-l10n/tree/master
	"Navigation privée", "Privater Modus", "Navegación privada", "Navigazione anonima",
	"navegação privativa", "privénavigatie", "tryb prywatny", "Приватный просмотр",
	"Приватний перегляд", "Gizli Gezinti", "プライベートブラウジング", "사생활 보호 모드",
	"隐私浏览", "التصفح الخاص", "Anonymní prohlížení", "Privat browsing",
	"Privat surfning", "Privat nettlesing", "גלישה פרטית",
}





-- ===========================
-- ===========================
-- ======= 2/ Matching =======
-- ===========================
-- ===========================

-- Cache only the public built-in markers, by index and exact source value. This
-- respects runtime changes to M.KEYWORDS without retaining window titles or
-- caller-supplied keywords after a check.
local lowered_keywords, keywords_owner, keyword_count = {}, nil, 0
local function lower(value)
	if not value:find("[\128-\255]") then return value:lower() end
	return UnicodeCase.lower(value)
end

--- Reports whether a window title marks a private/incognito browser window.
--- @param title string|nil          Focused window title.
--- @param extra_keywords table|nil  Additional markers (e.g. a localised term).
--- @return boolean
function M.matches(title, extra_keywords)
	if type(title) ~= "string" or title == "" then return false end
	if keywords_owner ~= M.KEYWORDS then
		lowered_keywords, keywords_owner, keyword_count = {}, M.KEYWORDS, 0
	end
	local current_count = #M.KEYWORDS
	for index = current_count + 1, keyword_count do lowered_keywords[index] = nil end
	keyword_count = current_count
	local ascii_title = not title:find("[\128-\255]")
	local haystack = ascii_title and title:lower() or lower(title)

	for index, keyword in ipairs(M.KEYWORDS) do
		local cached = lowered_keywords[index]
		if not cached or cached.source ~= keyword then
			cached = { source = keyword, value = lower(keyword) }
			cached.ascii = not cached.value:find("[\128-\255]")
			lowered_keywords[index] = cached
		end
		if (not ascii_title or cached.ascii) and haystack:find(cached.value, 1, true) then return true end
	end

	if type(extra_keywords) == "table" then
		for _, keyword in ipairs(extra_keywords) do
			if type(keyword) == "string" and keyword ~= ""
				and haystack:find(lower(keyword), 1, true) then
				return true
			end
		end
	end

	return false
end

return M
