--- _shared/lua/keylogger/private_window.lua

--- ==============================================================================
--- MODULE: Private-Browsing Window Detection (shared)
--- DESCRIPTION:
--- The one list of window-title markers that identify a private / incognito
--- browser window, plus the matcher that applies it.
---
--- WHY THIS MODULE EXISTS:
--- "Keystrokes typed while a private browser window is focused must be dropped"
--- is a cross-driver privacy guarantee — it is one of the four categories in
--- _shared/tests/corpus/security/keylogger_no_persist_vectors.json. It was
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
}




-- ==========================
-- ==========================
-- ======= 2/ Matching ======
-- ==========================
-- ==========================

--- Reports whether a window title marks a private/incognito browser window.
--- @param title string|nil          Focused window title.
--- @param extra_keywords table|nil  Additional markers (e.g. a localised term).
--- @return boolean
function M.matches(title, extra_keywords)
	if type(title) ~= "string" or title == "" then return false end
	local haystack = title:lower()

	for _, keyword in ipairs(M.KEYWORDS) do
		if haystack:find(keyword:lower(), 1, true) then return true end
	end

	if type(extra_keywords) == "table" then
		for _, keyword in ipairs(extra_keywords) do
			if type(keyword) == "string" and keyword ~= ""
				and haystack:find(keyword:lower(), 1, true) then
				return true
			end
		end
	end

	return false
end

return M
