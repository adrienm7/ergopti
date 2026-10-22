--- _shared/lua/open_target/init.lua

--- ==============================================================================
--- MODULE: Open Target Classifier
--- DESCRIPTION:
--- Decides what a selected text names before the copy_selected_path action
--- opens it on macOS and Linux: a URL (with or without its scheme, an IP
--- address, localhost, a mail address), a file or folder path, a Windows
--- registry key, a bare file name, or plain text to search the web for.
--- Windows ports the same rule in windows/infra/open_target.ahk.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the caller passes the environment lookup, so the module needs no
---    OS call and both Lua suites replay one corpus,
---    _shared/tests/corpus/shortcuts/open_target_vectors.json, which the
---    Windows suite replays against its own port too.
--- 2. Classification only: the result names a target and its kind, never a
---    command. The drivers hand the target to the OS opener as one argument
---    (open on macOS, xdg-open on Linux), so no text reaches a shell.
--- 3. A recognised target that cannot be opened here (a registry key, a
---    Windows path, a shell: URI) is reported as unsupported rather than
---    searched: the user asked to open that thing, and a web search for it
---    would hide why nothing opened.
--- ==============================================================================

local M = {}

--- The search URL the Lua drivers fall back to. The Windows driver reads the
--- same default from the shortcuts.search feature
--- (_shared/modules/features/manifest.toml); test-open-target-vectors-shared
--- pins the two together.
M.DEFAULT_SEARCH_URL = "https://www.google.com/search?q="

--- Every kind a classification can carry.
M.KINDS = { "url", "path", "registry", "search", "file_name", "unsupported", "empty" }

--- Schemes written without "//" that name something the OS opens.
M.OPAQUE_SCHEMES = { "mailto", "tel", "sms", "callto", "sip", "xmpp", "magnet", "news" }

--- Opaque schemes only the Windows shell understands.
M.WINDOWS_SCHEMES = { "ms-settings", "shell" }

--- Extensions that make "name.ext" a file name rather than a domain. Real
--- top-level domains common in links (.ai, .app, .cc, .co, .dev, .io, .me,
--- .pl, .rs, .tv) are left out on purpose.
M.FILE_EXTENSIONS = { "txt", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "csv", "tsv", "md", "json", "toml", "yaml", "yml", "xml", "ini", "cfg", "conf", "log", "bak", "tmp", "html", "htm", "php", "js", "ts", "py", "lua", "ahk", "sh", "bat", "cmd", "ps1", "c", "h", "cpp", "hpp", "cs", "java", "go", "rb", "swift", "kt", "sql", "db", "sqlite", "ipynb", "epub", "png", "jpg", "jpeg", "gif", "bmp", "svg", "webp", "heic", "tif", "tiff", "ico", "mp3", "wav", "flac", "ogg", "m4a", "mp4", "mkv", "avi", "mov", "wmv", "webm", "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "iso", "dmg", "pkg", "deb", "rpm", "msi", "exe", "dll", "lnk", "keylayout" }

--- Registry roots by every spelling the classifier accepts, upper-cased.
M.REGISTRY_ROOTS = {
	HKCR = "HKEY_CLASSES_ROOT", HKEY_CLASSES_ROOT = "HKEY_CLASSES_ROOT",
	HKCU = "HKEY_CURRENT_USER", HKEY_CURRENT_USER = "HKEY_CURRENT_USER",
	HKLM = "HKEY_LOCAL_MACHINE", HKEY_LOCAL_MACHINE = "HKEY_LOCAL_MACHINE",
	HKU = "HKEY_USERS", HKEY_USERS = "HKEY_USERS",
	HKCC = "HKEY_CURRENT_CONFIG", HKEY_CURRENT_CONFIG = "HKEY_CURRENT_CONFIG",
}

--- Prefixes Regedit's address bar and PowerShell put before a root, lower-cased
--- and longest first so the provider path wins over its own suffix.
M.REGISTRY_PREFIXES = { "microsoft.powershell.core\\registry::", "registry::", "computer\\", "ordinateur\\" }

local BACKSLASH = "\\"

--- Multi-byte spaces trimmed with the ASCII ones: no-break, narrow no-break,
--- zero-width space and the byte-order mark a copied cell can start with.
local UNICODE_SPACES = { "\194\160", "\226\128\175", "\226\128\139", "\239\187\191" }

--- Pairs a selection can be wrapped in, opening then closing.
local WRAPPERS = {
	{ "\"", "\"" }, { "'", "'" }, { "`", "`" }, { "<", ">" }, { "(", ")" }, { "[", "]" },
	{ "\226\128\156", "\226\128\157" }, { "\226\128\152", "\226\128\153" },
	{ "\226\128\158", "\226\128\156" }, { "\194\171", "\194\187" },
}

--- Punctuation a sentence leaves after a link, ellipsis included.
local TRAILING_PUNCTUATION = { ".", ",", ";", ":", "!", "?", "\226\128\166" }

--- @param list table
--- @return table set Keys are the list's values.
local function set_of(list)
	local set = {}
	for _, value in ipairs(list) do set[value] = true end
	return set
end

--- Schemes that run code in the handler instead of naming a resource: never
--- opened, whatever follows them.
M.SCRIPT_SCHEMES = { "javascript", "vbscript", "data" }

local OPAQUE = set_of(M.OPAQUE_SCHEMES)
local SCRIPT_SCHEMES = set_of(M.SCRIPT_SCHEMES)
local WINDOWS_ONLY = set_of(M.WINDOWS_SCHEMES)
local EXTENSIONS = set_of(M.FILE_EXTENSIONS)

--- @param text string
--- @param prefix string
--- @return boolean
local function starts_with(text, prefix)
	return text:sub(1, #prefix) == prefix
end

--- @param text string
--- @param suffix string
--- @return boolean
local function ends_with(text, suffix)
	return suffix ~= "" and text:sub(-#suffix) == suffix
end

--- Trims ASCII and Unicode spaces from both ends.
--- @param text string
--- @return string
local function trim(text)
	local previous
	repeat
		previous = text
		text = text:gsub("^%s+", ""):gsub("%s+$", "")
		for _, space in ipairs(UNICODE_SPACES) do
			while starts_with(text, space) do text = text:sub(#space + 1) end
			while ends_with(text, space) do text = text:sub(1, -#space - 1) end
		end
	until text == previous
	return text
end

--- Counts the plain occurrences of a substring.
--- @param text string
--- @param needle string
--- @return number
local function count(text, needle)
	local found, at = 0, 1
	while true do
		local start = text:find(needle, at, true)
		if not start then return found end
		found, at = found + 1, start + #needle
	end
end

--- Whether brackets stay balanced through the whole text.
--- @param text string
--- @param open string
--- @param close string
--- @return boolean
local function balanced(text, open, close)
	local depth = 0
	for index = 1, #text do
		local char = text:sub(index, index)
		if char == open then depth = depth + 1
		elseif char == close then
			depth = depth - 1
			if depth < 0 then return false end
		end
	end
	return depth == 0
end

--- Removes the quotes, brackets or guillemets wrapping the whole text.
--- @param text string Trimmed text.
--- @return string
local function unwrap(text)
	local changed = true
	while changed do
		changed = false
		for _, pair in ipairs(WRAPPERS) do
			local open, close = pair[1], pair[2]
			if #text > #open + #close and starts_with(text, open) and ends_with(text, close) then
				local inner = text:sub(#open + 1, -#close - 1)
				local wraps
				if open == "(" or open == "[" then wraps = balanced(inner, open, close)
				else wraps = not inner:find(open, 1, true) and not inner:find(close, 1, true) end
				if wraps then
					text, changed = trim(inner), true
					break
				end
			end
		end
	end
	return text
end

--- Removes the punctuation a sentence leaves after a target, and a closing
--- bracket the target never opened.
--- @param text string
--- @return string
local function strip_trailing(text)
	local previous
	repeat
		previous = text
		for _, mark in ipairs(TRAILING_PUNCTUATION) do
			while ends_with(text, mark) do text = text:sub(1, -#mark - 1) end
		end
		for _, pair in ipairs({ { "(", ")" }, { "[", "]" }, { "{", "}" } }) do
			if ends_with(text, pair[2]) and count(text, pair[2]) > count(text, pair[1]) then
				text = text:sub(1, -2)
			end
		end
	until text == previous
	return text
end

--- Decodes %XX escapes, leaving malformed ones as they are.
--- @param text string
--- @return string
local function percent_decode(text)
	return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

--- Whether the text holds a control character (a path or URL never does).
--- @param text string
--- @return boolean
local function has_control(text)
	return text:find("[%z\1-\31\127]") ~= nil
end

--- Whether what follows a host is empty, a port, a path, a query or a fragment.
--- @param tail string
--- @return boolean
local function valid_tail(tail)
	if tail == "" then return true end
	if tail:find("%s") then return false end
	local port, rest = tail:match("^:(%d+)(.*)$")
	if port then
		local number = tonumber(port)
		if #port > 5 or number < 1 or number > 65535 then return false end
		tail = rest
		if tail == "" then return true end
	end
	return tail:find("^[/?#]") ~= nil
end

--- Whether the text is an IPv6 address without brackets, port or zone.
--- @param text string
--- @return boolean
local function valid_ipv6(text)
	if not text:find("^[%x:]+$") or not text:find("%x") then return false end
	local colons = count(text, ":")
	local compressed = count(text, "::")
	if colons < 2 or colons > 7 or compressed > 1 or text:find(":::", 1, true) then return false end
	if compressed == 0 and colons ~= 7 then return false end
	if (starts_with(text, ":") and not starts_with(text, "::"))
		or (ends_with(text, ":") and not ends_with(text, "::")) then return false end
	for group in text:gmatch("[^:]+") do
		if #group > 4 then return false end
	end
	return true
end

--- Whether one dot-separated label can be part of a host name.
--- @param label string
--- @return boolean
local function valid_label(label)
	return #label >= 1 and #label <= 63 and label:find("^[%w-]+$") ~= nil
		and not starts_with(label, "-") and not ends_with(label, "-")
end

--- Splits a host into labels and checks its top-level domain.
--- @param host string
--- @return string|nil tld The last label when the host is a domain name.
local function domain_tld(host)
	local labels = {}
	for label in (host .. "."):gmatch("([^.]*)%.") do labels[#labels + 1] = label end
	if #labels < 2 then return nil end
	for _, label in ipairs(labels) do
		if not valid_label(label) then return nil end
	end
	local tld = labels[#labels]
	if tld:find("^%a+$") and #tld >= 2 then return tld end
	if tld:lower():find("^xn%-%-[%w-]+$") then return tld end
	return nil
end

--- Looks up an environment variable through the caller's port.
--- @param env function|nil
--- @param name string
--- @return string|nil
local function lookup(env, name)
	if type(env) ~= "function" then return nil end
	local value = env(name)
	if type(value) == "string" and value ~= "" then return value end
	return nil
end

--- @param kind string
--- @param target string
--- @param reason string|nil
--- @return table
local function result(kind, target, reason)
	return { kind = kind, target = target, reason = reason }
end

--- Classifies a registry key, which only Windows can open.
--- @param text string
--- @return table|nil
local function registry(text)
	local rest = text
	local lowered = text:lower()
	for _, prefix in ipairs(M.REGISTRY_PREFIXES) do
		if starts_with(lowered, prefix) then
			rest = text:sub(#prefix + 1)
			break
		end
	end
	local root, tail = rest:match("^([^\\:]+)(.*)$")
	if not root then return nil end
	local full = M.REGISTRY_ROOTS[root:upper()]
	if not full then return nil end
	if starts_with(tail, ":") then tail = tail:sub(2) end
	if tail ~= "" and not starts_with(tail, BACKSLASH) then return nil end
	return result("unsupported", full .. tail:gsub("\\+$", ""), "windows_only")
end

--- Classifies a file: URI as the local path it names.
--- @param text string
--- @return table|nil
local function file_uri(text)
	if text:sub(1, 5):lower() ~= "file:" or text:find("%s") then return nil end
	local rest = text:sub(6)
	if starts_with(rest, "//") then
		local host, path = rest:sub(3):match("^([^/]*)(.*)$")
		if host ~= "" and host:lower() ~= "localhost" then return result("url", text) end
		rest = path
	end
	local path = percent_decode(rest)
	if not starts_with(path, "/") or has_control(path) then return nil end
	if path:find("^/%a:/") or path:find("^/%a:$") then return result("unsupported", text, "windows_only") end
	return result("path", path)
end

--- Classifies a Windows drive, UNC or %VARIABLE% path.
--- @param text string
--- @return table|nil
local function windows_path(text)
	if text:find("^%a:$") or text:find("^%a:[\\/]") then
		if text:sub(3):find("[<>\"|?*:]") then return nil end
		return result("unsupported", text, "windows_only")
	end
	if text:find("^\\\\[^\\/]") then
		if text:find("[<>\"|?*]") then return nil end
		return result("url", "smb:" .. text:gsub("\\", "/"):gsub(" ", "%%20"))
	end
	local variable = text:match("^%%[%a_][%w_()]*%%")
	if variable and (#text == #variable or text:sub(#variable + 1):find("^[\\/]")) then
		return result("unsupported", text, "windows_only")
	end
	return nil
end

--- Classifies a home-relative or $VARIABLE path.
--- @param text string
--- @param env function|nil
--- @return table|nil
local function posix_path(text, env)
	if has_control(text) then return nil end
	if text == "~" or starts_with(text, "~/") then
		local home = lookup(env, "HOME")
		return result("path", home and (home .. text:sub(2)) or text)
	end
	if starts_with(text, "/") and not starts_with(text, "//") then return result("path", text) end
	local name, rest = text:match("^%$([%a_][%w_]*)(.*)$")
	if not name then name, rest = text:match("^%${([%a_][%w_]*)}(.*)$") end
	if name and (rest == "" or starts_with(rest, "/")) then
		local value = lookup(env, name)
		return result("path", value and (value .. rest) or text)
	end
	return nil
end

--- Classifies a URL that names its scheme.
--- @param text string
--- @return table|nil
local function scheme_url(text)
	local scheme, rest = text:match("^(%a[%w+.-]*):(.*)$")
	if not scheme or has_control(text) then return nil end
	local lowered = scheme:lower()
	-- A shell: folder name can hold spaces ("shell:Common Startup"), never
	-- start with one ("Shell: a sentence").
	if WINDOWS_ONLY[lowered] and (rest == "" or rest:find("^%w")) and not text:find("[\"<>|]")
		and (lowered == "shell" or not text:find("%s")) and (lowered ~= "shell" or rest ~= "") then
		return result("unsupported", text, "windows_only")
	end
	if SCRIPT_SCHEMES[lowered] or text:find("%s") then return nil end
	if #scheme >= 2 and starts_with(rest, "//") and #rest > 2 then return result("url", text) end
	if OPAQUE[lowered] and rest ~= "" then return result("url", text) end
	return nil
end

--- Classifies an address: mail, IPv6, IPv4, localhost, then a domain name or a
--- bare file name that only looks like one.
--- @param text string
--- @return table|nil
local function address(text)
	if text:find("%s") then return nil end
	local mailbox, mail_domain = text:match("^([%w._%%+-]+)@([%w.-]+)$")
	if mailbox and domain_tld(mail_domain) then return result("url", "mailto:" .. text) end
	local inner, bracket_tail = text:match("^%[([%x:]+)%](.*)$")
	if inner and valid_ipv6(inner) and valid_tail(bracket_tail) then
		return result("url", "http://" .. text)
	end
	local a, b, c, d, ip_tail = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)(.*)$")
	if a then
		for _, octet in ipairs({ a, b, c, d }) do
			if #octet > 3 or tonumber(octet) > 255 then return nil end
		end
		if valid_tail(ip_tail) then return result("url", "http://" .. text) end
		return nil
	end
	if text:sub(1, 9):lower() == "localhost" and valid_tail(text:sub(10)) then
		return result("url", "http://" .. text)
	end
	if valid_ipv6(text) then return result("url", "http://[" .. text .. "]") end
	local host, tail = text:match("^([^:/?#]+)(.*)$")
	if not host or not valid_tail(tail) then return nil end
	local tld = domain_tld(host)
	if not tld then return nil end
	if tail == "" and not host:lower():find("^www%.") and EXTENSIONS[tld:lower()] then
		return result("file_name", text)
	end
	return result("url", "https://" .. text)
end

--- Classifies a name.ext that is no host name either (an underscore, a
--- one-letter extension): a file name without its folder.
--- @param text string
--- @return table|nil
local function bare_file_name(text)
	if text:find("[%s\\/:*?\"<>|]") or has_control(text) then return nil end
	local extension = text:match("^[^.].*%.(%w+)$")
	if extension and EXTENSIONS[extension:lower()] then return result("file_name", text) end
	return nil
end

--- Classifies one candidate that holds no line break.
--- @param text string
--- @param env function|nil
--- @return table|nil
local function classify_token(text, env)
	return registry(text) or file_uri(text) or windows_path(text) or posix_path(text, env)
		or scheme_url(text) or address(text) or bare_file_name(text)
end

--- Classifies a selected text for the macOS and Linux drivers.
--- @param text any The selection.
--- @param env function|nil Receives a variable name, returns its value or nil.
--- @return table { kind, target, reason } kind is one of M.KINDS; for "search"
---   the target is the trimmed selection, for "unsupported" the reason is
---   "windows_only".
function M.classify(text, env)
	if type(text) ~= "string" then return result("empty", "") end
	local trimmed = trim(text)
	if trimmed == "" then return result("empty", "") end
	if trimmed:find("[\r\n]") then return result("search", trimmed) end
	local candidate = unwrap(trimmed)
	local found = classify_token(candidate, env)
	local cleaned = strip_trailing(candidate)
	if cleaned ~= candidate and cleaned ~= "" then
		local retry = classify_token(cleaned, env)
		if retry and (found == nil or retry.kind == found.kind) then found = retry end
	end
	return found or result("search", trimmed)
end

return M
