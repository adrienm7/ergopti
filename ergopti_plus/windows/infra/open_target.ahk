; infra/open_target.ahk

; ==============================================================================
; MODULE: Open Target Classifier
; DESCRIPTION:
; Decides what a selected text names before the copy_selected_path action
; (SearchPath in modules/shortcuts/win.ahk) opens it: a URL (with or without
; its scheme, an IP address, localhost, a mail address, ms-settings:, shell:),
; a file or folder path, a registry key, a bare file name, or plain text to
; search the web for. The macOS and Linux drivers apply the same rule through
; _shared/lua/open_target; both ports replay one corpus,
; _shared/tests/corpus/shortcuts/open_target_vectors.json.
;
; FEATURES & RATIONALE:
; 1. Pure: the caller passes the environment lookup, so the unit suite replays
;    the corpus without reading this machine's variables.
; 2. Classification only: the result names a target and its kind, never a
;    command line. SearchPath hands a path to the shell quoted as one file and
;    a URL only when it holds no whitespace, so no selected text becomes
;    program arguments.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================
; ===============================
; ======= 1/ Vocabularies =======
; ===============================
; ===============================

; Every kind a classification can carry.
global OPEN_TARGET_KINDS := ["url", "path", "registry", "search", "file_name", "unsupported", "empty"]

; Schemes written without "//" that name something the shell opens.
global OPEN_TARGET_OPAQUE_SCHEMES := ["mailto", "tel", "sms", "callto", "sip", "xmpp", "magnet", "news"]

; Opaque schemes only the Windows shell understands.
global OPEN_TARGET_WINDOWS_SCHEMES := ["ms-settings", "shell"]

; Schemes that run code in the handler instead of naming a resource.
global OPEN_TARGET_SCRIPT_SCHEMES := ["javascript", "vbscript", "data"]

; Extensions that make "name.ext" a file name rather than a domain. Real
; top-level domains common in links (.ai, .app, .cc, .co, .dev, .io, .me, .pl,
; .rs, .tv) are left out on purpose.
global OPEN_TARGET_FILE_EXTENSIONS := ["txt", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "csv", "tsv", "md", "json", "toml", "yaml", "yml", "xml", "ini", "cfg", "conf", "log", "bak", "tmp", "html", "htm", "php", "js", "ts", "py", "lua", "ahk", "sh", "bat", "cmd", "ps1", "c", "h", "cpp", "hpp", "cs", "java", "go", "rb", "swift", "kt", "sql", "db", "sqlite", "ipynb", "epub", "png", "jpg", "jpeg", "gif", "bmp", "svg", "webp", "heic", "tif", "tiff", "ico", "mp3", "wav", "flac", "ogg", "m4a", "mp4", "mkv", "avi", "mov", "wmv", "webm", "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "iso", "dmg", "pkg", "deb", "rpm", "msi", "exe", "dll", "lnk", "keylayout"]

; Prefixes Regedit's address bar and PowerShell put before a root, lower-cased
; and longest first so the provider path wins over its own suffix.
global OPEN_TARGET_REGISTRY_PREFIXES := ["microsoft.powershell.core\registry::", "registry::", "computer\", "ordinateur\"]

; Registry roots by every spelling the classifier accepts, upper-cased.
global OPEN_TARGET_REGISTRY_ROOTS := Map(
	"HKCR", "HKEY_CLASSES_ROOT", "HKEY_CLASSES_ROOT", "HKEY_CLASSES_ROOT",
	"HKCU", "HKEY_CURRENT_USER", "HKEY_CURRENT_USER", "HKEY_CURRENT_USER",
	"HKLM", "HKEY_LOCAL_MACHINE", "HKEY_LOCAL_MACHINE", "HKEY_LOCAL_MACHINE",
	"HKU", "HKEY_USERS", "HKEY_USERS", "HKEY_USERS",
	"HKCC", "HKEY_CURRENT_CONFIG", "HKEY_CURRENT_CONFIG", "HKEY_CURRENT_CONFIG"
)

; The ASCII spaces Lua's %s names, then the no-break, narrow no-break and
; zero-width spaces and the byte-order mark a copied cell can start with.
global OPEN_TARGET_SPACES := " `t`r`n`v`f" . Chr(0xA0) . Chr(0x202F) . Chr(0x200B) . Chr(0xFEFF)

; Pairs a selection can be wrapped in, opening then closing.
global OPEN_TARGET_WRAPPERS := [
	[Chr(34), Chr(34)], ["'", "'"], [Chr(96), Chr(96)], ["<", ">"], ["(", ")"], ["[", "]"],
	[Chr(0x201C), Chr(0x201D)], [Chr(0x2018), Chr(0x2019)], [Chr(0x201E), Chr(0x201C)],
	[Chr(0xAB), Chr(0xBB)]
]

; Punctuation a sentence leaves after a link, ellipsis included.
global OPEN_TARGET_TRAILING_PUNCTUATION := [".", ",", ";", ":", "!", "?", Chr(0x2026)]





; ===================================
; ===================================
; ======= 2/ Text primitives ========
; ===================================
; ===================================

; @returns {Map} One classification.
_OpenTarget_Result(Kind, Target, Reason := "") {
	return Map("kind", Kind, "target", Target, "reason", Reason)
}

; @returns {Boolean} Whether List holds Value, compared case-sensitively.
_OpenTarget_ListHas(List, Value) {
	for _, Item in List {
		if (Item == Value)
			return true
	}
	return false
}

; @returns {Boolean} Whether Text holds a control character.
_OpenTarget_HasControl(Text) {
	return RegExMatch(Text, "[\x00-\x1F\x7F]") > 0
}

; @returns {Integer} The plain occurrences of Needle in Text.
_OpenTarget_Count(Text, Needle) {
	StrReplace(Text, Needle, "", true, &Found)
	return Found
}

; @returns {Boolean} Whether brackets stay balanced through the whole text.
_OpenTarget_Balanced(Text, Open, Close) {
	Depth := 0
	Loop Parse Text {
		if (A_LoopField == Open)
			Depth += 1
		else if (A_LoopField == Close) {
			Depth -= 1
			if (Depth < 0)
				return false
		}
	}
	return Depth = 0
}

; Removes the quotes, brackets or guillemets wrapping the whole text.
_OpenTarget_Unwrap(Text) {
	global OPEN_TARGET_WRAPPERS, OPEN_TARGET_SPACES
	Changed := true
	while Changed {
		Changed := false
		for _, Pair in OPEN_TARGET_WRAPPERS {
			Open := Pair[1], Close := Pair[2]
			if (StrLen(Text) <= StrLen(Open) + StrLen(Close))
				continue
			if (SubStr(Text, 1, StrLen(Open)) !== Open || SubStr(Text, -StrLen(Close)) !== Close)
				continue
			Inner := SubStr(Text, StrLen(Open) + 1, StrLen(Text) - StrLen(Open) - StrLen(Close))
			if (Open == "(" || Open == "[")
				Wraps := _OpenTarget_Balanced(Inner, Open, Close)
			else
				Wraps := !InStr(Inner, Open, true) && !InStr(Inner, Close, true)
			if Wraps {
				Text := Trim(Inner, OPEN_TARGET_SPACES)
				Changed := true
				break
			}
		}
	}
	return Text
}

; Removes the punctuation a sentence leaves after a target, and a closing
; bracket the target never opened.
_OpenTarget_StripTrailing(Text) {
	global OPEN_TARGET_TRAILING_PUNCTUATION
	loop {
		Previous := Text
		for _, Mark in OPEN_TARGET_TRAILING_PUNCTUATION {
			while (Text != "" && SubStr(Text, -StrLen(Mark)) == Mark)
				Text := SubStr(Text, 1, StrLen(Text) - StrLen(Mark))
		}
		for _, Pair in [["(", ")"], ["[", "]"], ["{", "}"]] {
			if (Text != "" && SubStr(Text, -1) == Pair[2]
					&& _OpenTarget_Count(Text, Pair[2]) > _OpenTarget_Count(Text, Pair[1]))
				Text := SubStr(Text, 1, StrLen(Text) - 1)
		}
		if (Text == Previous)
			return Text
	}
}

; @returns {Boolean} Whether what follows a host is empty, a port, a path, a
;   query or a fragment.
_OpenTarget_ValidTail(Tail) {
	if (Tail == "")
		return true
	if RegExMatch(Tail, "\s")
		return false
	if RegExMatch(Tail, "^:(\d+)(.*)$", &Port) {
		if (StrLen(Port[1]) > 5 || Integer(Port[1]) < 1 || Integer(Port[1]) > 65535)
			return false
		Tail := Port[2]
		if (Tail == "")
			return true
	}
	return RegExMatch(Tail, "^[/?#]") > 0
}

; @returns {Boolean} Whether the text is an IPv6 address without brackets,
;   port or zone.
_OpenTarget_ValidIPv6(Text) {
	if !RegExMatch(Text, "^[0-9A-Fa-f:]+$") || !RegExMatch(Text, "[0-9A-Fa-f]")
		return false
	Colons := _OpenTarget_Count(Text, ":")
	Compressed := _OpenTarget_Count(Text, "::")
	if (Colons < 2 || Colons > 7 || Compressed > 1 || InStr(Text, ":::"))
		return false
	if (Compressed = 0 && Colons != 7)
		return false
	if ((SubStr(Text, 1, 1) == ":" && SubStr(Text, 1, 2) != "::")
			|| (SubStr(Text, -1) == ":" && SubStr(Text, -2) != "::"))
		return false
	for _, Group in StrSplit(Text, ":") {
		if (StrLen(Group) > 4)
			return false
	}
	return true
}

; @returns {String} The top-level domain when Host is a domain name, else "".
_OpenTarget_DomainTld(Host) {
	Labels := StrSplit(Host, ".")
	if (Labels.Length < 2)
		return ""
	for _, Label in Labels {
		if (StrLen(Label) < 1 || StrLen(Label) > 63 || !RegExMatch(Label, "^[A-Za-z0-9-]+$")
				|| SubStr(Label, 1, 1) == "-" || SubStr(Label, -1) == "-")
			return ""
	}
	Tld := Labels[Labels.Length]
	if (RegExMatch(Tld, "^[A-Za-z]+$") && StrLen(Tld) >= 2) || RegExMatch(Tld, "i)^xn--[A-Za-z0-9-]+$")
		return Tld
	return ""
}

; Expands every %NAME% the lookup knows; an unknown one stays literal, so the
; path then fails its existence check instead of naming a different folder.
_OpenTarget_ExpandVariables(Path, EnvFn) {
	Expanded := ""
	Position := 1
	while RegExMatch(Path, "%([A-Za-z_][A-Za-z0-9_()]*)%", &Found, Position) {
		Value := EnvFn.Call(Found[1])
		Expanded .= SubStr(Path, Position, Found.Pos - Position)
			. ((Value is String && Value != "") ? Value : Found[0])
		Position := Found.Pos + Found.Len
	}
	return Expanded . SubStr(Path, Position)
}

; A Windows path with backslashes and its variables expanded.
_OpenTarget_WindowsPath(Path, EnvFn) {
	return _OpenTarget_Result("path", StrReplace(_OpenTarget_ExpandVariables(Path, EnvFn), "/", "\"))
}





; ===================================
; ===================================
; ======= 3/ Candidate kinds ========
; ===================================
; ===================================

; A registry key, opened in Regedit.
_OpenTarget_Registry(Text) {
	global OPEN_TARGET_REGISTRY_PREFIXES, OPEN_TARGET_REGISTRY_ROOTS
	Rest := Text
	for _, Prefix in OPEN_TARGET_REGISTRY_PREFIXES {
		if (StrLower(SubStr(Text, 1, StrLen(Prefix))) == Prefix) {
			Rest := SubStr(Text, StrLen(Prefix) + 1)
			break
		}
	}
	if !RegExMatch(Rest, "^([^\\:]+)(.*)$", &Parts)
		return ""
	Root := StrUpper(Parts[1])
	if !OPEN_TARGET_REGISTRY_ROOTS.Has(Root)
		return ""
	Tail := Parts[2]
	if (SubStr(Tail, 1, 1) == ":")
		Tail := SubStr(Tail, 2)
	if (Tail != "" && SubStr(Tail, 1, 1) != "\")
		return ""
	return _OpenTarget_Result("registry", OPEN_TARGET_REGISTRY_ROOTS[Root] . RTrim(Tail, "\"))
}

; A file: URI naming a drive or UNC path. Any other file: URI stays a URL.
_OpenTarget_FileUri(Text, EnvFn) {
	if (StrLower(SubStr(Text, 1, 5)) != "file:" || RegExMatch(Text, "\s"))
		return ""
	Rest := SubStr(Text, 6)
	if (SubStr(Rest, 1, 2) == "//") {
		Authority := SubStr(Rest, 3)
		Slash := InStr(Authority, "/")
		Host := Slash ? SubStr(Authority, 1, Slash - 1) : Authority
		Rest := Slash ? SubStr(Authority, Slash) : ""
		if (Host != "" && StrLower(Host) != "localhost") {
			Path := UriDecode(Rest)
			if _OpenTarget_HasControl(Host . Path)
				return ""
			return _OpenTarget_Result("path", "\\" . Host . StrReplace(Path, "/", "\"))
		}
	}
	Path := UriDecode(Rest)
	if _OpenTarget_HasControl(Path) || !RegExMatch(Path, "^/[A-Za-z]:(/|$)")
		return ""
	Drive := SubStr(Path, 2)
	if (StrLen(Drive) = 2)
		Drive .= "\"
	return _OpenTarget_Result("path", StrReplace(Drive, "/", "\"))
}

; A drive, UNC or %VARIABLE% path.
_OpenTarget_DrivePath(Text, EnvFn) {
	if RegExMatch(Text, "^[A-Za-z]:($|[\\/])") {
		if RegExMatch(SubStr(Text, 3), '[<>"|?*:]')
			return ""
		return _OpenTarget_WindowsPath(StrLen(Text) = 2 ? Text . "\" : Text, EnvFn)
	}
	if RegExMatch(Text, "^\\\\[^\\/]") {
		if RegExMatch(Text, '[<>"|?*]')
			return ""
		return _OpenTarget_WindowsPath(Text, EnvFn)
	}
	if RegExMatch(Text, "^%[A-Za-z_][A-Za-z0-9_()]*%", &Variable)
			&& (StrLen(Text) = Variable.Len || RegExMatch(SubStr(Text, Variable.Len + 1), "^[\\/]"))
		return _OpenTarget_WindowsPath(Text, EnvFn)
	return ""
}

; ~ and ~\ or ~/ name the user's profile folder.
_OpenTarget_HomePath(Text, EnvFn) {
	if (Text != "~" && !RegExMatch(Text, "^~[\\/]"))
		return ""
	Home := EnvFn.Call("USERPROFILE")
	if !(Home is String) || Home == ""
		return _OpenTarget_Result("path", Text)
	return _OpenTarget_Result("path", StrReplace(Home . SubStr(Text, 2), "/", "\"))
}

; A URL that names its scheme.
_OpenTarget_SchemeUrl(Text) {
	global OPEN_TARGET_OPAQUE_SCHEMES, OPEN_TARGET_WINDOWS_SCHEMES, OPEN_TARGET_SCRIPT_SCHEMES
	if !RegExMatch(Text, "^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$", &Parts) || _OpenTarget_HasControl(Text)
		return ""
	Scheme := StrLower(Parts[1]), Rest := Parts[2]
	; A shell: folder name can hold spaces ("shell:Common Startup"), never
	; start with one ("Shell: a sentence").
	if _OpenTarget_ListHas(OPEN_TARGET_WINDOWS_SCHEMES, Scheme)
			&& (Rest == "" || RegExMatch(Rest, "^[A-Za-z0-9]")) && !RegExMatch(Text, '["<>|]')
			&& (Scheme == "shell" || !RegExMatch(Text, "\s")) && (Scheme != "shell" || Rest != "")
		return _OpenTarget_Result("url", Text)
	if _OpenTarget_ListHas(OPEN_TARGET_SCRIPT_SCHEMES, Scheme) || RegExMatch(Text, "\s")
		return ""
	if (StrLen(Parts[1]) >= 2 && SubStr(Rest, 1, 2) == "//" && StrLen(Rest) > 2)
		return _OpenTarget_Result("url", Text)
	if (_OpenTarget_ListHas(OPEN_TARGET_OPAQUE_SCHEMES, Scheme) && Rest != "")
		return _OpenTarget_Result("url", Text)
	return ""
}

; A mail address, an IPv6 or IPv4 address, localhost, then a domain name or a
; bare file name that only looks like one.
_OpenTarget_Address(Text) {
	global OPEN_TARGET_FILE_EXTENSIONS
	if RegExMatch(Text, "\s")
		return ""
	if RegExMatch(Text, "^([A-Za-z0-9._%+\-]+)@([A-Za-z0-9.\-]+)$", &Mail) && _OpenTarget_DomainTld(Mail[2]) != ""
		return _OpenTarget_Result("url", "mailto:" . Text)
	if RegExMatch(Text, "^\[([0-9A-Fa-f:]+)\](.*)$", &Bracketed)
			&& _OpenTarget_ValidIPv6(Bracketed[1]) && _OpenTarget_ValidTail(Bracketed[2])
		return _OpenTarget_Result("url", "http://" . Text)
	if RegExMatch(Text, "^(\d+)\.(\d+)\.(\d+)\.(\d+)(.*)$", &Ip) {
		Loop 4 {
			if (StrLen(Ip[A_Index]) > 3 || Integer(Ip[A_Index]) > 255)
				return ""
		}
		return _OpenTarget_ValidTail(Ip[5]) ? _OpenTarget_Result("url", "http://" . Text) : ""
	}
	if (StrLower(SubStr(Text, 1, 9)) == "localhost" && _OpenTarget_ValidTail(SubStr(Text, 10)))
		return _OpenTarget_Result("url", "http://" . Text)
	if _OpenTarget_ValidIPv6(Text)
		return _OpenTarget_Result("url", "http://[" . Text . "]")
	if !RegExMatch(Text, "^([^:/?#]+)(.*)$", &Parts) || !_OpenTarget_ValidTail(Parts[2])
		return ""
	Tld := _OpenTarget_DomainTld(Parts[1])
	if (Tld == "")
		return ""
	if (Parts[2] == "" && !RegExMatch(Parts[1], "i)^www\.")
			&& _OpenTarget_ListHas(OPEN_TARGET_FILE_EXTENSIONS, StrLower(Tld)))
		return _OpenTarget_Result("file_name", Text)
	return _OpenTarget_Result("url", "https://" . Text)
}

; A name.ext that is no host name either (an underscore, a one-letter
; extension): a file name without its folder.
_OpenTarget_BareFileName(Text) {
	global OPEN_TARGET_FILE_EXTENSIONS
	if RegExMatch(Text, '[\s\\/:*?"<>|]') || _OpenTarget_HasControl(Text)
		return ""
	if RegExMatch(Text, "^[^.].*\.([A-Za-z0-9]+)$", &Extension)
			&& _OpenTarget_ListHas(OPEN_TARGET_FILE_EXTENSIONS, StrLower(Extension[1]))
		return _OpenTarget_Result("file_name", Text)
	return ""
}

; Classifies one candidate that holds no line break, in the rule's order.
_OpenTarget_Token(Text, EnvFn) {
	for _, Step in [
		() => _OpenTarget_Registry(Text),
		() => _OpenTarget_FileUri(Text, EnvFn),
		() => _OpenTarget_DrivePath(Text, EnvFn),
		() => _OpenTarget_HomePath(Text, EnvFn),
		() => _OpenTarget_SchemeUrl(Text),
		() => _OpenTarget_Address(Text),
		() => _OpenTarget_BareFileName(Text)
	] {
		Found := Step.Call()
		if (Found is Map)
			return Found
	}
	return ""
}





; ================================
; ================================
; ======= 4/ Public entry ========
; ================================
; ================================

; Classifies a selected text.
; @param {String} Text The selection.
; @param {Func} EnvFn Receives a variable name, returns its value or "".
; @returns {Map} Map("kind", ..., "target", ..., "reason", ...): kind is one of
;   OPEN_TARGET_KINDS; for "search" the target is the trimmed selection.
OpenTarget_Classify(Text, EnvFn := EnvGet) {
	global OPEN_TARGET_SPACES
	if !(Text is String)
		return _OpenTarget_Result("empty", "")
	Trimmed := Trim(Text, OPEN_TARGET_SPACES)
	if (Trimmed == "")
		return _OpenTarget_Result("empty", "")
	if (InStr(Trimmed, "`n") || InStr(Trimmed, "`r"))
		return _OpenTarget_Result("search", Trimmed)
	Candidate := _OpenTarget_Unwrap(Trimmed)
	Found := _OpenTarget_Token(Candidate, EnvFn)
	Cleaned := _OpenTarget_StripTrailing(Candidate)
	if (Cleaned !== Candidate && Cleaned != "") {
		Retry := _OpenTarget_Token(Cleaned, EnvFn)
		if (Retry is Map) && (!(Found is Map) || Retry["kind"] == Found["kind"])
			Found := Retry
	}
	return (Found is Map) ? Found : _OpenTarget_Result("search", Trimmed)
}
