-- apps/App Cloner.app/Contents/Resources/ShortcutBuilder.applescript
--
-- User interface for App Cloner.
-- Builds a lightweight clone of an existing macOS application with:
--   * custom name and tinted/grayscale/imported icon
--   * unique bundle ID (no Dock grouping with the original app)
--   * optional launch argument (file, folder, or URL scheme)

use AppleScript version "2.4"
use framework "Foundation"
use framework "AppKit"
use scripting additions

-- =========================================
-- =========================================
-- ======= 0/ Locale & UI strings ==========
-- =========================================
-- =========================================

-- Resolve the active locale: ERGOPTI_LOCALE (injected by menu_apps.lua)
-- → $LANG prefix → "fr" default (App Cloner's native language).
on resolve_locale()
	set loc to ""
	try
		set loc to do shell script "echo \"$ERGOPTI_LOCALE\""
	end try
	if loc is "" then
		try
			set lang_val to do shell script "echo \"$LANG\""
			if (length of lang_val) >= 2 then
				set loc to text 1 thru 2 of lang_val
			end if
		end try
	end if
	if loc is "" then set loc to "fr"
	return loc
end resolve_locale

-- Resolve the absolute path to the locales directory.
-- Priority: ERGOPTI_LOCALES_DIR (injected by menu_apps.lua) → path relative
-- to the .app bundle's Resources/ folder for standalone use.
on resolve_locales_dir()
	set d to ""
	try
		set d to do shell script "echo \"$ERGOPTI_LOCALES_DIR\""
	end try
	if d is not "" then return d
	-- Fallback: climb from this script's bundle to find a sibling locales/ dir.
	try
		set bundle_res to POSIX path of (path to me)
		set cmd to "d=" & quoted form of bundle_res ¬
			& "; d=$(dirname \"$d\"); d=$(dirname \"$d\"); d=$(dirname \"$d\"); d=$(dirname \"$d\"); d=$(dirname \"$d\"); echo \"$d/locales\""
		set d to do shell script cmd
	end try
	return d
end resolve_locales_dir

-- Load the requested locale once. The selected catalogue must exist and be a JSON object.
on load_catalogue(loc, locales_dir)
	set json_path to locales_dir & "/" & loc & ".json"
	set json_data to current application's NSData's dataWithContentsOfFile:json_path
	if json_data is missing value then error "App Cloner locale catalogue is unavailable."
	set {catalogue, parse_error} to current application's NSJSONSerialization's JSONObjectWithData:json_data options:0 |error|:(reference)
	if catalogue is missing value then error "App Cloner locale catalogue is invalid JSON."
	if not ((catalogue's isKindOfClass:(current application's NSDictionary)) as boolean) then ¬
		error "App Cloner locale catalogue must be a JSON object."
	return catalogue
end load_catalogue

-- UI text is an actual nonempty JSON string, never a coerced number, null or container.
on ui_string(catalogue, json_key)
	set localized_value to catalogue's objectForKey:json_key
	if localized_value is missing value then error "App Cloner locale key is missing."
	if not ((localized_value's isKindOfClass:(current application's NSString)) as boolean) then ¬
		error "App Cloner locale value must be a string."
	if ((localized_value's |length|()) as integer) is 0 then error "App Cloner locale string is empty."
	return localized_value as text
end ui_string

-- Load one selected catalogue for the whole wizard; every UI value is required.
on load_ui(loc, locales_dir)
	set catalogue to my load_catalogue(loc, locales_dir)
	-- Keep each record within the native compiler's line-continuation limit.
	set controls_ui to {¬
		btn_ok: my ui_string(catalogue, "common.ok"), ¬
		btn_back: my ui_string(catalogue, "apps.cloner.btn_back"), ¬
		btn_choose: my ui_string(catalogue, "apps.cloner.btn_choose"), ¬
		btn_clone: my ui_string(catalogue, "apps.cloner.btn_clone"), ¬
		btn_validate: my ui_string(catalogue, "apps.cloner.btn_validate"), ¬
		btn_browse: my ui_string(catalogue, "apps.cloner.btn_browse"), ¬
		btn_pwa_recommended: my ui_string(catalogue, "apps.cloner.btn_pwa_recommended"), ¬
		btn_try_native: my ui_string(catalogue, "apps.cloner.btn_try_native"), ¬
		btn_native_clone: my ui_string(catalogue, "apps.cloner.btn_native_clone"), ¬
		btn_pwa_webapp: my ui_string(catalogue, "apps.cloner.btn_pwa_webapp"), ¬
		btn_custom_icon: my ui_string(catalogue, "apps.cloner.btn_custom_icon"), ¬
		btn_tint_icon: my ui_string(catalogue, "apps.cloner.btn_tint_icon"), ¬
		btn_open_log: my ui_string(catalogue, "apps.cloner.btn_open_log"), ¬
		btn_close: my ui_string(catalogue, "common.close"), ¬
		title_clone_name: my ui_string(catalogue, "apps.cloner.title_clone_name"), ¬
		title_pwa_mode: my ui_string(catalogue, "apps.cloner.title_pwa_mode"), ¬
		title_pwa_recommended: my ui_string(catalogue, "apps.cloner.title_pwa_recommended"), ¬
		title_open_arg: my ui_string(catalogue, "apps.cloner.title_open_arg"), ¬
		title_url_path: my ui_string(catalogue, "apps.cloner.title_url_path"), ¬
		title_pwa_url: my ui_string(catalogue, "apps.cloner.title_pwa_url"), ¬
		title_icon_style: my ui_string(catalogue, "apps.cloner.title_icon_style"), ¬
		title_summary: my ui_string(catalogue, "apps.cloner.title_summary"), ¬
		title_error: my ui_string(catalogue, "apps.cloner.title_error"), ¬
		title_tint: my ui_string(catalogue, "apps.cloner.title_tint"), ¬
		msg_bundle_missing: my ui_string(catalogue, "apps.cloner.msg_bundle_missing"), ¬
		lbl_progress_prep: my ui_string(catalogue, "apps.cloner.lbl_progress_prep"), ¬
		lbl_progress_icon: my ui_string(catalogue, "apps.cloner.lbl_progress_icon"), ¬
		lbl_progress_sign: my ui_string(catalogue, "apps.cloner.lbl_progress_sign"), ¬
		lbl_progress_dock: my ui_string(catalogue, "apps.cloner.lbl_progress_dock"), ¬
		lbl_progress_done: my ui_string(catalogue, "apps.cloner.lbl_progress_done"), ¬
		lbl_progress_title: my ui_string(catalogue, "apps.cloner.lbl_progress_title")}
	set wizard_ui to {¬
		msg_choose_source: my ui_string(catalogue, "apps.cloner.msg_choose_source"), ¬
		msg_clone_name: my ui_string(catalogue, "apps.cloner.msg_clone_name"), ¬
		msg_pwa_recommended: my ui_string(catalogue, "apps.cloner.msg_pwa_recommended"), ¬
		msg_pwa_optional: my ui_string(catalogue, "apps.cloner.msg_pwa_optional"), ¬
		msg_pwa_url: my ui_string(catalogue, "apps.cloner.msg_pwa_url"), ¬
		title_invalid_url: my ui_string(catalogue, "apps.cloner.title_invalid_url"), ¬
		msg_native_open_optional: my ui_string(catalogue, "apps.cloner.msg_native_open_optional"), ¬
		msg_url_path: my ui_string(catalogue, "apps.cloner.msg_url_path"), ¬
		prompt_choose_folder: my ui_string(catalogue, "apps.cloner.prompt_choose_folder"), ¬
		title_empty_input: my ui_string(catalogue, "apps.cloner.title_empty_input"), ¬
		msg_empty_input: my ui_string(catalogue, "apps.cloner.msg_empty_input"), ¬
		title_invalid_input: my ui_string(catalogue, "apps.cloner.title_invalid_input"), ¬
		msg_icon_style: my ui_string(catalogue, "apps.cloner.msg_icon_style"), ¬
		prompt_choose_icon: my ui_string(catalogue, "apps.cloner.prompt_choose_icon"), ¬
		mode_native: my ui_string(catalogue, "apps.cloner.mode_native"), ¬
		mode_pwa: my ui_string(catalogue, "apps.cloner.mode_pwa"), ¬
		summary_source: my ui_string(catalogue, "apps.cloner.summary_source"), ¬
		summary_name: my ui_string(catalogue, "apps.cloner.summary_name"), ¬
		summary_mode: my ui_string(catalogue, "apps.cloner.summary_mode"), ¬
		summary_icon: my ui_string(catalogue, "apps.cloner.summary_icon"), ¬
		summary_url: my ui_string(catalogue, "apps.cloner.summary_url"), ¬
		err_open_empty: my ui_string(catalogue, "apps.cloner.err_open_empty"), ¬
		err_path_missing: my ui_string(catalogue, "apps.cloner.err_path_missing"), ¬
		err_url_format: my ui_string(catalogue, "apps.cloner.err_url_format"), ¬
		err_teams_url: my ui_string(catalogue, "apps.cloner.err_teams_url"), ¬
		err_pwa_required: my ui_string(catalogue, "apps.cloner.err_pwa_required"), ¬
		err_pwa_scheme: my ui_string(catalogue, "apps.cloner.err_pwa_scheme"), ¬
		menu_edit: my ui_string(catalogue, "apps.cloner.menu_edit"), ¬
		menu_cut: my ui_string(catalogue, "apps.cloner.menu_cut"), ¬
		menu_copy: my ui_string(catalogue, "apps.cloner.menu_copy"), ¬
		menu_paste: my ui_string(catalogue, "apps.cloner.menu_paste"), ¬
		menu_select_all: my ui_string(catalogue, "apps.cloner.menu_select_all"), ¬
		menu_undo: my ui_string(catalogue, "apps.cloner.menu_undo"), ¬
		menu_redo: my ui_string(catalogue, "apps.cloner.menu_redo"), ¬
		default_clone_name: my ui_string(catalogue, "apps.cloner.default_clone_name"), ¬
		diagnostic_log_path: my ui_string(catalogue, "apps.cloner.diagnostic_log_path"), ¬
		value_none: my ui_string(catalogue, "common.none")}
	return controls_ui & wizard_ui
end load_ui


-- osascript runs without a real Edit menu. Even though NSTextField responds
-- to selectAll:/cut:/copy:/paste:, the keyboard shortcuts are dispatched via
-- the menu — without those menu items, Cmd+A/C/V/X are dropped. We install
-- a minimal Edit menu once at startup so every text field in this app gets
-- standard editing shortcuts.
-- ─────────────────────────────────────────────────────────────────────────
-- Custom NSPanel-based dialog. Replaces NSAlert entirely so we get full
-- control over the layout — most importantly, no reserved icon column
-- forcing an empty gap at the top-left of every prompt.
--
-- One big customDialog() handles every prompt shape we need:
--   * pure choice (header + body + buttons)
--   * text input (1 line or N lines)
--   * input + checkbox (used by the summary screen for the badge toggle)
-- ─────────────────────────────────────────────────────────────────────────

-- The script itself acts as the AppleScript-ObjC bridge target for NSButton
-- actions. setTarget:me + top-level ObjC selector handlers are the
-- canonical pattern that works in plain osascript.
-- AppleScript script objects can serve as Cocoa targets when their handler
-- names end with a colon — Cocoa dispatches btnXClicked: to the matching
-- handler on this object. We store the picked button index and the
-- captured input/checkbox values here so customDialog() can read them back
-- after the modal returns.
-- Dialog state held as top-level properties of the running script. We use
-- setTarget:me for button actions — me (the script itself) is the
-- canonical NSObject target that osascript exposes to Cocoa, and top-level
-- ObjC selector handlers are bridged 1:1 to Cocoa selectors of
-- the same name. Trying to wrap this in a script object
-- with property parent set to NSObject works in app bundles but
-- crashes when the file is run by raw osascript on macOS Tahoe — hence
-- the flat top-level layout.
property panelResult : 0          -- 1-based button index, 0 if cancelled
property panelInputText : ""
property panelChecked : false
property panelInputView : missing value
property panelCheckboxView : missing value
property panelIsTextView : false  -- true for NSTextView, false for NSTextField
-- State for the live tint preview panel (showTintColorPicker)
property tintPreviewImageView : missing value
property tintPreviewColorWell : missing value
property tintPreviewSourceImage : missing value
property tintPreviewAppPath : ""
-- Absolute path to the App Cloner bundle, captured from argv at startup so
-- helpers that need bundled resources (extract_icon.py, etc.) can locate them.
property appBundlePath : ""

on captureDialogValues()
	-- The my qualifier is mandatory inside handlers; without it, AppleScript
	-- creates a local variable that shadows the script property, and the
	-- caller never sees the captured value.
	if (my panelInputView) is not missing value then
		try
			if my panelIsTextView then
				set my panelInputText to ((my panelInputView)'s |string|()) as text
			else
				set my panelInputText to ((my panelInputView)'s stringValue()) as text
			end if
		end try
	end if
	if (my panelCheckboxView) is not missing value then
		try
			set my panelChecked to (((my panelCheckboxView)'s state()) as integer) is 1
		end try
	end if
end captureDialogValues

-- Window delegate: the red close button on any App Cloner dialog fully quits
-- the app rather than leaving an invisible osascript process running.
on windowWillClose:notification
	(current application's NSApplication's sharedApplication)'s terminate:missing value
end windowWillClose:

on btn1Clicked:sender
	captureDialogValues()
	set my panelResult to 1
	set theApp to current application's NSApplication's sharedApplication
	theApp's stopModal()
end btn1Clicked:

on btn2Clicked:sender
	captureDialogValues()
	set my panelResult to 2
	set theApp to current application's NSApplication's sharedApplication
	theApp's stopModal()
end btn2Clicked:

on btn3Clicked:sender
	captureDialogValues()
	set my panelResult to 3
	set theApp to current application's NSApplication's sharedApplication
	theApp's stopModal()
end btn3Clicked:

on btn4Clicked:sender
	captureDialogValues()
	set my panelResult to 4
	set theApp to current application's NSApplication's sharedApplication
	theApp's stopModal()
end btn4Clicked:

on doUpdatePreview()
	if (my tintPreviewColorWell) is missing value then return
	if (my tintPreviewImageView) is missing value then return
	if (my tintPreviewSourceImage) is missing value then return
	try
		set currentColor to (my tintPreviewColorWell)'s |color|
		my logmsg("[preview] doUpdatePreview: calling applyTintToImageView")
		-- Pass imgView directly so the handler calls setImage: without crossing
		-- the AppleScript return boundary, which coerces NSImage to NSString.
		my applyTintToImageView((my tintPreviewSourceImage), currentColor, (my tintPreviewAppPath), (my tintPreviewImageView))
	on error errMsg
		my logmsg("[preview] doUpdatePreview failed: " & errMsg)
	end try
end doUpdatePreview

-- Action target wired on the NSColorWell — fires every time the user picks
-- a new colour in the system NSColorPanel. Replaces the old NSTimer polling
-- approach which never fired during runModalForWindow: because the timer
-- was registered in NSRunLoopCommonModes (which excludes modal mode).
on colorWellChanged:sender
	my doUpdatePreview()
end colorWellChanged:

-- Strip leading and trailing whitespace (spaces, tabs, CR/LF). Pure
-- AppleScript implementation to avoid spawning a shell.
on trim(s)
	set whitespaces to {" ", tab, return, linefeed, character id 160}
	set i to 1
	set n to length of s
	repeat while i ≤ n and (character i of s) is in whitespaces
		set i to i + 1
	end repeat
	repeat while n ≥ i and (character n of s) is in whitespaces
		set n to n - 1
	end repeat
	if i > n then return ""
	return text i thru n of s
end trim

-- Validate the optional launch argument the user pasted at clone-creation
-- time. Returns "" when the value is acceptable, or a localized error message
-- describing what's wrong so we can re-prompt.
--
-- Catches the most common mistakes:
--   * empty string after trimming
--   * the user typed text instead of pasting a URL / path
--   * a typo in the scheme such as «mstems:» or «msteams//» (missing colon)
--   * a Teams clone with a non-Teams URL (and vice-versa) — best-effort hint
on validateOpenArg(inputVal, sourceAppPath, u)
	if inputVal is "" then return (err_open_empty of u)

	-- File-system path: must point to something that actually exists
	if (inputVal starts with "/") or (inputVal starts with "~") then
		set resolvedPath to inputVal
		if resolvedPath starts with "~" then
			set resolvedPath to (POSIX path of (path to home folder)) & (text 2 thru -1 of inputVal)
		end if
		try
			do shell script "test -e " & quoted form of resolvedPath
		on error
			return my format_ui(err_path_missing of u, inputVal)
		end try
		return ""
	end if

	-- URL: must contain «://» — most copy-paste typos break here
	-- (e.g. «msteams:/l/chat», «https:/example.com», «msteams.com»).
	if inputVal does not contain "://" then
		-- Tolerate the single-slash msteams form Microsoft documents
		if not (inputVal starts with "msteams:/l/" or inputVal starts with "msteams:/calendar") then
			return (err_url_format of u)
		end if
	end if

	-- Cross-check: if the source app is Teams, warn when the URL clearly
	-- targets another product (and vice-versa). Pure heuristic, only
	-- triggered when we're confident the mismatch is a typo.
	set sourceLower to my toLower(sourceAppPath)
	set inputLower to my toLower(inputVal)
	set isTeamsSource to (sourceLower contains "teams")
	set isTeamsURL to (inputLower starts with "msteams:")
	set isHTTP to (inputLower starts with "http")
	if isTeamsSource and not (isTeamsURL or isHTTP or (inputLower starts with "/")) then
		return (err_teams_url of u)
	end if

	return ""
end validateOpenArg

-- Substitute one canonical positional placeholder without interpreting user data.
on format_ui(templateText, argumentText)
	set templateString to current application's NSString's stringWithString:templateText
	return (templateString's stringByReplacingOccurrencesOfString:"{1}" withString:argumentText) as text
end format_ui

-- Lowercase via NSString since AppleScript has no case-insensitive ops.
on toLower(s)
	return ((current application's NSString's stringWithString:s)'s lowercaseString()) as text
end toLower

-- Read the source app's CFBundleIdentifier so we can map known sandboxed
-- apps (Teams, Outlook, …) to their web equivalents for PWA mode.
on getBundleId(appPath)
	try
		return (do shell script "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' " & quoted form of (appPath & "/Contents/Info.plist"))
	on error
		return ""
	end try
end getBundleId

-- Decide whether the source app should default to PWA mode and what URL
-- to pre-fill. Returns {forced, defaultURL}:
--   forced=true  → app is known to be uncloneable natively; PWA recommended
--   forced=false → PWA optional; defaultURL is "" unless we have a guess
on pwaSuggestionFor(bundleId, appPath)
	set bid to my toLower(bundleId)
	-- Strict allowlist of apps known to require PWA mode. Source: every
	-- macOS-sandboxed Microsoft 365 / Apple iWork client whose entitlements
	-- are bound to a vendor team-id we can't reuse.
	if bid contains "com.microsoft.teams" then return {true, "https://teams.microsoft.com/v2/"}
	if bid contains "com.microsoft.outlook" then return {true, "https://outlook.office.com/mail/"}
	if bid contains "com.microsoft.onenotemac" or bid contains "com.microsoft.onenote" then return {true, "https://www.onenote.com/notebooks"}
	if bid contains "com.microsoft.word" then return {true, "https://www.office.com/launch/word"}
	if bid contains "com.microsoft.excel" then return {true, "https://www.office.com/launch/excel"}
	if bid contains "com.microsoft.powerpoint" then return {true, "https://www.office.com/launch/powerpoint"}
	-- Best-effort suggestions for non-Microsoft apps where a web version
	-- is just nice to have (still optional).
	if bid contains "com.tinyspeck.slackmacgap" then return {false, "https://app.slack.com/client"}
	if bid contains "com.hnc.discord" then return {false, "https://discord.com/app"}
	if bid contains "notion.id" then return {false, "https://www.notion.so/"}
	if bid contains "com.spotify.client" then return {false, "https://open.spotify.com/"}
	return {false, ""}
end pwaSuggestionFor

-- Validate a URL specifically for PWA mode. Stricter than validateOpenArg:
-- requires http(s) since Edge --app= only accepts navigable web URLs.
on validatePWAURL(inputVal, u)
	if inputVal is "" then return (err_pwa_required of u)
	set v to my toLower(inputVal)
	if not (v starts with "http://" or v starts with "https://") then
		return (err_pwa_scheme of u)
	end if
	return ""
end validatePWAURL

-- Rough text-width estimator (no NSAttributedString.size to keep it pure
-- AppleScript). Buttons are clamped between 90 and 220 pixels.
on measureButtonWidth(title)
	set w to ((length of title) * 8) + 32
	if w < 90 then set w to 90
	if w > 220 then set w to 220
	return w
end measureButtonWidth

-- Count visual lines in a string accounting for soft wrapping.
-- Uses a fixed chars-per-line estimate (body width ÷ avg char width at 12pt).
on countLines(s)
	if s is "" then return 0
	set charsPerLine to 65
	set totalLines to 0
	set lineStart to 1
	set sLen to length of s
	repeat with i from 1 to sLen
		set c to character i of s
		if (c is return) or (c is linefeed) or (i = sLen) then
			set segLen to i - lineStart + 1
			-- Each logical line wraps into ceil(segLen / charsPerLine) visual rows.
			set visualRows to segLen div charsPerLine
			if (segLen mod charsPerLine) > 0 then set visualRows to visualRows + 1
			if visualRows < 1 then set visualRows to 1
			set totalLines to totalLines + visualRows
			set lineStart to i + 1
		end if
	end repeat
	return totalLines
end countLines

-- The swiss-army-knife dialog. Every UI prompt routes through this.
--   header       : bold heading string (top)
--   body         : informative string below the header (multi-line OK)
--   buttonList   : list of button titles, leftmost first; the rightmost
--                  becomes the default (Enter), the leftmost becomes the
--                  cancel button (Esc) when there are 2+ buttons.
--   hasInput     : true to add a text editor below the body
--   defaultText  : prefilled value for the input
--   lineCount    : 1 → NSTextField, ≥2 → NSTextView in NSScrollView
--   inputWidth   : pixel width of the input area; drives the panel width
--   hasCheckbox  : true to add a checkbox above the buttons
--   checkboxLabel: title shown next to the checkbox
-- Returns a record: {chosenButton, inputText, checked}.
on customDialog(header, body, buttonList, hasInput, defaultText, lineCount, inputWidth, hasCheckbox, checkboxLabel)
	set marginX to 24
	set marginYTop to 22
	set marginYBottom to 18
	set itemSpacing to 14
	set headerHeight to 22
	set bodyLineHeight to 16
	set buttonHeight to 28
	set buttonGap to 8

	-- Width: derive from input area, never smaller than 380, and never
	-- smaller than the total buttons row (so buttons don't overflow the margin)
	set panelWidth to inputWidth + (2 * marginX)
	if panelWidth < 380 then set panelWidth to 380
	set totalBtnW to 0
	repeat with bTitle in buttonList
		set totalBtnW to totalBtnW + (my measureButtonWidth(bTitle))
	end repeat
	set totalBtnW to totalBtnW + ((count of buttonList) - 1) * buttonGap + (2 * marginX)
	if panelWidth < totalBtnW then set panelWidth to totalBtnW

	-- Body height: 0 if no body, else lines × line height
	set bodyLines to my countLines(body)
	if bodyLines = 0 then
		set bodyHeight to 0
	else
		set bodyHeight to (bodyLines * bodyLineHeight) + 4
	end if

	-- Input height
	-- lineCount = 1  → single-line NSTextField (Enter = validate)
	-- lineCount = -1 → wrapped multi-line-looking NSTextField, still Enter = validate
	-- lineCount ≥ 2  → NSTextView (Enter = newline, scrollable)
	set inputHeight to 0
	if hasInput then
		if lineCount = 1 then
			set inputHeight to 24
		else if lineCount = -1 then
			-- 3-row wrapped NSTextField: enough height to show a pasted URL without scrolling
			set inputHeight to 58
		else
			set inputHeight to (lineCount * 18) + 12
		end if
	end if

	-- Checkbox height
	set checkboxHeight to 0
	if hasCheckbox then set checkboxHeight to 22

	-- Total panel height (sum of stack + margins + spacings between items)
	set verticalElements to {headerHeight}
	if bodyHeight > 0 then set end of verticalElements to bodyHeight
	if hasInput then set end of verticalElements to inputHeight
	if hasCheckbox then set end of verticalElements to checkboxHeight
	set end of verticalElements to buttonHeight

	set panelHeight to marginYTop + marginYBottom
	set elemCount to count of verticalElements
	repeat with i from 1 to elemCount
		set panelHeight to panelHeight + (item i of verticalElements)
	end repeat
	set panelHeight to panelHeight + ((elemCount - 1) * itemSpacing)

	-- Build panel: titled + closable, no resize, no minimise
	set panelRect to current application's NSMakeRect(0, 0, panelWidth, panelHeight)
	set panelStyle to 3 -- NSWindowStyleMaskTitled (1) + Closable (2)
	set panelWin to current application's NSPanel's alloc()'s initWithContentRect:panelRect styleMask:panelStyle backing:2 defer:false
	panelWin's setTitle:"App Cloner"
	panelWin's |center|()
	panelWin's setReleasedWhenClosed:false
	-- Ensure the panel always becomes key, not just when a text field needs it,
	-- so that Cmd key equivalents are dispatched even before the user clicks.
	panelWin's setBecomesKeyOnlyIfNeeded:false
	-- Route close-button clicks through windowWillClose: so the red X quits
	-- the app entirely instead of leaving a ghost osascript process.
	panelWin's setDelegate:me

	set contentView to panelWin's contentView

	-- Layout top → bottom
	set yCursor to panelHeight - marginYTop - headerHeight

	-- Header (bold)
	set headerFrame to current application's NSMakeRect(marginX, yCursor, panelWidth - (2 * marginX), headerHeight)
	set headerLabel to current application's NSTextField's alloc()'s initWithFrame:headerFrame
	headerLabel's setStringValue:header
	set headerFont to current application's NSFont's boldSystemFontOfSize:14
	headerLabel's setFont:headerFont
	headerLabel's setBordered:false
	headerLabel's setEditable:false
	headerLabel's setSelectable:false
	headerLabel's setDrawsBackground:false
	contentView's addSubview:headerLabel

	-- Body (multi-line, selectable so users can copy text from prompts)
	if bodyHeight > 0 then
		set yCursor to yCursor - itemSpacing - bodyHeight
		set bodyFrame to current application's NSMakeRect(marginX, yCursor, panelWidth - (2 * marginX), bodyHeight)
		set bodyLabel to current application's NSTextField's alloc()'s initWithFrame:bodyFrame
		bodyLabel's setStringValue:body
		set bodyFont to current application's NSFont's systemFontOfSize:12
		bodyLabel's setFont:bodyFont
		bodyLabel's setBordered:false
		bodyLabel's setEditable:false
		bodyLabel's setSelectable:true
		bodyLabel's setDrawsBackground:false
		set bodyCell to bodyLabel's cell
		bodyCell's setWraps:true
		bodyCell's setLineBreakMode:0
		contentView's addSubview:bodyLabel
	end if

	-- Input (optional)
	if hasInput then
		set yCursor to yCursor - itemSpacing - inputHeight
		set inputFrame to current application's NSMakeRect(marginX, yCursor, panelWidth - (2 * marginX), inputHeight)
		if lineCount = 1 or lineCount = -1 then
			set inputView to current application's NSTextField's alloc()'s initWithFrame:inputFrame
			inputView's setStringValue:defaultText
			set inputFont to current application's NSFont's systemFontOfSize:13
			inputView's setFont:inputFont
			-- lineCount=-1: enable word-wrap so long URLs wrap across the 3-row height
			-- instead of scrolling horizontally out of view
			if lineCount = -1 then
				set inputCell to inputView's cell
				inputCell's setWraps:true
				inputCell's setScrollable:false
			end if
			contentView's addSubview:inputView
			set my panelInputView to inputView
			set my panelIsTextView to false
		else
			set scrollView to current application's NSScrollView's alloc()'s initWithFrame:inputFrame
			scrollView's setHasVerticalScroller:true
			scrollView's setBorderType:2 -- NSBezelBorder
			set textView to current application's NSTextView's alloc()'s initWithFrame:inputFrame
			textView's setRichText:false
			textView's setAllowsUndo:true
			set textFont to current application's NSFont's systemFontOfSize:13
			textView's setFont:textFont
			textView's setString:defaultText
			scrollView's setDocumentView:textView
			contentView's addSubview:scrollView
			set my panelInputView to textView
			set my panelIsTextView to true
		end if
	else
		set my panelInputView to missing value
	end if

	-- Checkbox (optional)
	if hasCheckbox then
		set yCursor to yCursor - itemSpacing - checkboxHeight
		set cbFrame to current application's NSMakeRect(marginX, yCursor, panelWidth - (2 * marginX), checkboxHeight)
		set cbBtn to current application's NSButton's alloc()'s initWithFrame:cbFrame
		cbBtn's setButtonType:3 -- NSSwitchButton
		cbBtn's setTitle:checkboxLabel
		cbBtn's setState:0
		contentView's addSubview:cbBtn
		set my panelCheckboxView to cbBtn
	else
		set my panelCheckboxView to missing value
	end if

	-- Buttons row, right-to-left so the rightmost = default
	set xCursor to (panelWidth - marginX)
	set lastIdx to (count of buttonList)
	repeat with i from lastIdx to 1 by -1
		set btnTitle to item i of buttonList
		set btnW to my measureButtonWidth(btnTitle)
		set btnX to xCursor - btnW
		set btnFrame to current application's NSMakeRect(btnX, marginYBottom, btnW, buttonHeight)
		set btn to current application's NSButton's alloc()'s initWithFrame:btnFrame
		btn's setTitle:btnTitle
		btn's setBezelStyle:1 -- rounded
		btn's setTarget:me
		if i = 1 then
			btn's setAction:"btn1Clicked:"
			-- Leftmost = cancel-style: bind Esc
			if lastIdx > 1 then btn's setKeyEquivalent:(character id 27)
		else if i = 2 then
			btn's setAction:"btn2Clicked:"
		else if i = 3 then
			btn's setAction:"btn3Clicked:"
		else if i = 4 then
			btn's setAction:"btn4Clicked:"
		end if
		if i = lastIdx then btn's setKeyEquivalent:(character id 13)
		contentView's addSubview:btn
		set xCursor to btnX - buttonGap
	end repeat

	-- Reset state, focus the input if any, and run modal
	set my panelResult to 0
	set my panelInputText to ""
	set my panelChecked to false
	if hasInput then
		panelWin's makeFirstResponder:(my panelInputView)
	end if

	set theApp to current application's NSApplication's sharedApplication
	theApp's runModalForWindow:panelWin
	panelWin's orderOut:(missing value)

	if my panelResult is 0 then error number -128

	return {chosenButton:(item (my panelResult) of buttonList), inputText:(my panelInputText), checked:(my panelChecked)}
end customDialog

-- Convenience wrappers around customDialog so call sites stay readable.

on chooseButton(headerText, bodyText, buttonList, dialogTitle)
	set r to my customDialog(headerText, bodyText, buttonList, false, "", 0, 380, false, "")
	return chosenButton of r
end chooseButton

-- Render a 128×128 tinted preview by delegating to tint_icon.py.
-- The srcImage is already rasterised (resolved via NSWorkspace in the main
-- AppleScript process which has a display server). We serialise it to TIFF
-- using writeToFile:atomically: (no reserved-word keyword arguments), then
-- convert to PNG with sips, then hand the PNG to tint_icon.py.
-- Applies a colour tint to srcImage and sets the result directly on imgView.
-- The NSImage object is never returned across the AppleScript handler boundary
-- because AppleScript coerces ObjC objects to NSString on return, which causes
-- "NSImageCell's object value must be an NSImage" errors when passed to setImage:.
-- Calling setImage: inside this handler avoids that coercion entirely.
on applyTintToImageView(srcImage, tintColor, appPath, imgView)
	set helperPath to (my appBundlePath) & "/Contents/Resources/tint_icon.py"
	-- Use PID-based names to avoid mktemp conflicts between rapid preview updates.
	set pid to do shell script "echo $$"
	set tmpTiff to "/tmp/appcloner_tint_" & pid & ".tiff"
	set tmpSrc to "/tmp/appcloner_tint_" & pid & "_src.png"
	set tmpDst to "/tmp/appcloner_tint_" & pid & "_dst.png"
	do shell script "rm -f " & quoted form of tmpTiff & " " & quoted form of tmpSrc & " " & quoted form of tmpDst

	-- Serialise the rasterised NSImage to TIFF (no keyword-arg issues).
	set tiffData to srcImage's TIFFRepresentation()
	set tiffOk to tiffData's writeToFile:tmpTiff atomically:true
	my logmsg("[tint] tiffOk=" & tiffOk & " tmpTiff=" & tmpTiff)
	-- Convert TIFF to PNG using the system sips tool (no PyObjC needed).
	do shell script "/usr/bin/sips -s format png " & quoted form of tmpTiff & " --out " & quoted form of tmpSrc & " > /dev/null 2>&1"
	do shell script "rm -f " & quoted form of tmpTiff
	my logmsg("[tint] srcPngBytes=" & (do shell script "wc -c < " & quoted form of tmpSrc) & " tmpSrc=" & tmpSrc)

	-- Build hex colour string from tintColor.
	set sRGB to tintColor's colorUsingColorSpaceName:"NSCalibratedRGBColorSpace"
	set r to (sRGB's redComponent()) as real
	set g to (sRGB's greenComponent()) as real
	set b to (sRGB's blueComponent()) as real
	set a to (sRGB's alphaComponent()) as real
	set rHex to do shell script "printf '%02X' " & (round (r * 255) rounding to nearest)
	set gHex to do shell script "printf '%02X' " & (round (g * 255) rounding to nearest)
	set bHex to do shell script "printf '%02X' " & (round (b * 255) rounding to nearest)
	set hexColor to "#" & rHex & gHex & bHex
	my logmsg("[tint] color=" & hexColor & " alpha=" & a)

	-- Determine mode: alpha < 0.02 means greyscale (bw), else tint.
	if a < 0.02 then
		set tintMode to "bw"
	else
		set tintMode to "tint"
	end if
	-- Encode alpha as an integer (0–10000) to avoid locale-dependent decimal
	-- separators (e.g. "0,8" on French systems) breaking the Python argument.
	set alphaInt to round (a * 10000) rounding to nearest

	-- Run Python helper; capture stdout+stderr into the central log.
	set pyCmd to "/usr/bin/python3 " & quoted form of helperPath & " " & quoted form of tmpSrc & " " & quoted form of tmpDst & " " & quoted form of hexColor & " " & tintMode & " " & alphaInt
	my logmsg("[tint] running: " & pyCmd)
	try
		set logPath to my app_log_path()
		if logPath is "" then
			do shell script pyCmd & " >/dev/null 2>&1"
		else
			do shell script pyCmd & " >> " & quoted form of logPath & " 2>&1"
		end if
	on error pyErr number pyNum
		my logmsg("[tint] python error " & pyNum & ": " & pyErr)
	end try
	my logmsg("[tint] dstPngBytes=" & (do shell script "wc -c < " & quoted form of tmpDst & " 2>/dev/null || echo MISSING") & " tmpDst=" & tmpDst)

	-- Load PNG via NSData/initWithData: and call setImage: immediately, without
	-- returning the NSImage across the handler boundary (which would coerce it).
	set pngData to current application's NSData's dataWithContentsOfFile:tmpDst
	do shell script "rm -f " & quoted form of tmpSrc & " " & quoted form of tmpDst
	if pngData is missing value then
		my logmsg("[tint] NSData load failed — keeping current image")
		return
	end if
	set tinted to current application's NSImage's alloc()'s initWithData:pngData
	my logmsg("[tint] initWithData result is missing value: " & (tinted is missing value))
	if tinted is missing value then
		my logmsg("[tint] initWithData failed — keeping current image")
		return
	end if
	-- setImage: called here, inside the handler, so tinted is still a live ObjC ref.
	imgView's setImage:tinted
	imgView's setNeedsDisplay:true
	my logmsg("[tint] setImage + setNeedsDisplay done OK")
end applyTintToImageView

-- Resolve the source app's icon as a high-resolution NSImage.
-- NSWorkspace.iconForFile: is called directly from AppleScript-ObjC, which
-- runs in a real Cocoa process with a display server — unlike a Python
-- subprocess it always returns a correctly populated NSImage, including for
-- sandboxed apps whose icon lives in Assets.car (Teams, Outlook, …).
-- The Python/iconutil path (extract_icon.py) is only used by clone_app.sh
-- to generate the final clone icon on disk; it is not needed here.
on resolveAppIcon(appPath)
	set ws to current application's NSWorkspace's sharedWorkspace
	set lazyImg to ws's iconForFile:appPath
	-- NSWorkspace returns a lazy NSImage whose pixel data is not loaded until
	-- it is actually drawn into a context. Calling TIFFRepresentation() forces
	-- Cocoa to rasterise every representation into memory before we ever call
	-- lockFocus or drawInRect — without this, the first draw produces a blank
	-- white bitmap because no pixels exist yet.
	set tiffData to lazyImg's TIFFRepresentation()
	set img to current application's NSImage's alloc()'s initWithData:tiffData
	if img is missing value then set img to lazyImg
	-- NSWorkspace can return an NSImage marked as a template (monochrome mask).
	-- Template images are rendered black-on-transparent by Cocoa, making the
	-- tint preview appear white after compositing. Clearing the flag forces the
	-- full-colour representation to be used for drawing.
	try
		img's setTemplate:false
	end try
	return img
end resolveAppIcon

-- Custom colour-picker dialog with a live 128×128 icon preview. The colour
-- well fires its target/action on every change in the system NSColorPanel,
-- giving immediate visual feedback as the user drags sliders.
-- Returns the chosen NSColor, or missing value when the user clicks Retour.
on showTintColorPicker(appPath, titleStr, btnValidate, btnBack)
	set srcImage to my resolveAppIcon(appPath)
	set my tintPreviewSourceImage to srcImage
	set my tintPreviewAppPath to appPath

	-- Panel: titled only (no close button) — forces the user to use the buttons
	-- so the modal loop can never get stuck if the window is X-closed.
	set pW to 300
	set pH to 320
	set pickerPanel to current application's NSPanel's alloc()'s initWithContentRect:(current application's NSMakeRect(0, 0, pW, pH)) styleMask:1 backing:2 defer:false
	pickerPanel's setTitle:"App Cloner"
	pickerPanel's |center|()
	pickerPanel's setReleasedWhenClosed:false
	pickerPanel's setBecomesKeyOnlyIfNeeded:false
	set cv to pickerPanel's contentView

	-- Header
	set hLabel to current application's NSTextField's alloc()'s initWithFrame:(current application's NSMakeRect(16, pH - 42, pW - 32, 22))
	hLabel's setStringValue:titleStr
	set pickerHeaderFont to current application's NSFont's boldSystemFontOfSize:14
	hLabel's setFont:pickerHeaderFont
	hLabel's setBordered:false
	hLabel's setEditable:false
	hLabel's setDrawsBackground:false
	cv's addSubview:hLabel

	-- Subtitle
	set bLabel to current application's NSTextField's alloc()'s initWithFrame:(current application's NSMakeRect(16, pH - 62, pW - 32, 16))
	bLabel's setStringValue:"Aperçu en temps réel — cliquer sur la couleur pour la modifier."
	set pickerBodyFont to current application's NSFont's systemFontOfSize:11
	bLabel's setFont:pickerBodyFont
	bLabel's setBordered:false
	bLabel's setEditable:false
	bLabel's setDrawsBackground:false
	cv's addSubview:bLabel

	-- Icon preview (128×128, horizontally centred)
	set imgSize to 128
	set imgX to (pW - imgSize) / 2
	set imgY to pH - 62 - 12 - imgSize
	set imgView to current application's NSImageView's alloc()'s initWithFrame:(current application's NSMakeRect(imgX, imgY, imgSize, imgSize))
	imgView's setImage:srcImage
	imgView's setImageScaling:3
	cv's addSubview:imgView
	set my tintPreviewImageView to imgView

	-- Colour well (centred, below icon)
	set cwW to 64
	set cwH to 32
	set cwX to (pW - cwW) / 2
	set cwY to imgY - 12 - cwH
	set colorWell to current application's NSColorWell's alloc()'s initWithFrame:(current application's NSMakeRect(cwX, cwY, cwW, cwH))
	-- Seed with a vivid red so the tint effect is visible immediately
	set initialColor to current application's NSColor's colorWithSRGBRed:0.8 green:0.0 blue:0.0 alpha:1.0
	colorWell's setColor:initialColor
	cv's addSubview:colorWell
	-- Activate the well so it tracks the system NSColorPanel: without this,
	-- changes the user makes in the colour panel never propagate back to the
	-- well's color property. "false" means non-exclusive activation.
	colorWell's |activate|:false
	-- Wire a target/action callback that fires every time the user picks a new
	-- colour. This is far more reliable than NSTimer polling: NSTimer needs
	-- explicit registration in NSModalPanelRunLoopMode and AppleScript-ObjC has
	-- subtle issues calling addTimer:forMode: twice for the same timer.
	colorWell's setTarget:me
	colorWell's setAction:"colorWellChanged:"
	set my tintPreviewColorWell to colorWell

	-- Buttons
	set btnY to 16
	set btnH to 28
	set btnW to 90
	set valBtn to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(pW - 16 - btnW, btnY, btnW, btnH))
	valBtn's setTitle:btnValidate
	valBtn's setBezelStyle:1
	valBtn's setTarget:me
	valBtn's setAction:"btn2Clicked:"
	valBtn's setKeyEquivalent:(character id 13)
	cv's addSubview:valBtn

	set retBtn to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(16, btnY, btnW, btnH))
	retBtn's setTitle:btnBack
	retBtn's setBezelStyle:1
	retBtn's setTarget:me
	retBtn's setAction:"btn1Clicked:"
	retBtn's setKeyEquivalent:(character id 27)
	cv's addSubview:retBtn

	-- Render initial preview before showing the panel
	my doUpdatePreview()

	set my panelResult to 0
	set my panelInputView to missing value
	set my panelCheckboxView to missing value

	set theApp to current application's NSApplication's sharedApplication
	theApp's runModalForWindow:pickerPanel
	pickerPanel's orderOut:(missing value)

	-- Clear shared preview state
	set my tintPreviewImageView to missing value
	set my tintPreviewColorWell to missing value
	set my tintPreviewSourceImage to missing value
	set my tintPreviewAppPath to ""

	-- Close the system NSColorPanel that the NSColorWell brings up — it is
	-- a separate window that does not belong to our modal session and would
	-- otherwise stay floating on screen after the user clicks Valider/Retour.
	try
		set sharedColorPanel to current application's NSColorPanel's sharedColorPanel
		sharedColorPanel's orderOut:(missing value)
	end try

	-- btn1 = Retour, btn2 = Valider
	if my panelResult is not 2 then return missing value
	return colorWell's |color|
end showTintColorPicker

on installEditMenu(u)
	try
		set theApp to current application's NSApplication's sharedApplication
		-- Always rebuild the main menu from scratch. The existence check is unsafe:
		-- osascript may return a non-nil stale menu object that prevents our Edit
		-- items from being installed, silently leaving Cmd+V/A/C/X non-functional.
		set appMainMenu to current application's NSMenu's alloc()'s init
		theApp's setMainMenu:appMainMenu
		set editItem to current application's NSMenuItem's alloc()'s initWithTitle:(menu_edit of u) action:(missing value) keyEquivalent:""
		set editMenu to current application's NSMenu's alloc()'s initWithTitle:(menu_edit of u)
		editMenu's addItemWithTitle:(menu_cut of u)        action:"cut:"        keyEquivalent:"x"
		editMenu's addItemWithTitle:(menu_copy of u)       action:"copy:"       keyEquivalent:"c"
		editMenu's addItemWithTitle:(menu_paste of u)      action:"paste:"      keyEquivalent:"v"
		editMenu's addItemWithTitle:(menu_select_all of u) action:"selectAll:"  keyEquivalent:"a"
		editMenu's addItemWithTitle:(menu_undo of u)       action:"undo:"       keyEquivalent:"z"
		editMenu's addItem:(current application's NSMenuItem's separatorItem())
		editMenu's addItemWithTitle:(menu_redo of u)       action:"redo:"       keyEquivalent:"Z"
		editItem's setSubmenu:editMenu
		appMainMenu's addItem:editItem
	on error errMsg
		my logmsg("installEditMenu failed: " & errMsg)
	end try
end installEditMenu

on askText(promptText, defaultValue, dialogTitle, widthPx, lineCount)
	set r to my customDialog(dialogTitle, promptText, {"Annuler", "OK"}, true, defaultValue, lineCount, widthPx, false, "")
	if (chosenButton of r) is "Annuler" then error number -128
	return inputText of r
end askText

on app_log_path()
	try
		return system attribute "ERGOPTI_APPCLONER_LOG"
	on error
		return ""
	end try
end app_log_path

on logmsg(m)
	set logPath to my app_log_path()
	if logPath is "" then return
	try
		do shell script "echo " & quoted form of m & " >> " & quoted form of logPath
	end try
end logmsg

-- Converts three 0-65535 RGB components into a CSS hex string (#RRGGBB)
on rgbToHex(r, g, b)
	set r8 to r div 257
	set g8 to g div 257
	set b8 to b div 257
	return do shell script "printf '#%02X%02X%02X' " & r8 & " " & g8 & " " & b8
end rgbToHex

on run argv
	-- Resolve locale and load UI strings once for the whole session.
	set _loc to my resolve_locale()
	set _locales_dir to my resolve_locales_dir()
	set u to my load_ui(_loc, _locales_dir)

	-- Promote osascript from background/accessory to a regular foreground app.
	-- Without this, NSApp.sendEvent: never checks the main menu for key
	-- equivalents — Cmd+V/A/C/X and every other shortcut are silently dropped
	-- even though the windows are key and text input works.
	set nsApp to current application's NSApplication's sharedApplication
	nsApp's setActivationPolicy:0  -- NSApplicationActivationPolicyRegular

	-- Install a standard Edit menu (Cut/Copy/Paste/Select All/Undo/Redo) so
	-- the keyboard shortcuts work in every NSAlert text input we open later.
	my installEditMenu(u)

	-- Bring App Cloner to the front (switch Space if needed) on every relaunch.
	-- Without this, after going into Teams to copy a chat link, clicking the
	-- App Cloner Dock icon doesn't actually surface its window.
	tell me to activate

	-- argv[1]: absolute bundle path, forwarded by Contents/MacOS/AppCloner
	if argv is {} or item 1 of argv is "" then
		display dialog (msg_bundle_missing of u) buttons {btn_ok of u} default button 1
		return
	end if
	set appDir to item 1 of argv
	set my appBundlePath to appDir
	set cloneScript to appDir & "/Contents/Resources/clone_app.sh"

	logmsg("--- App Cloner start " & (do shell script "date"))
	logmsg("appDir: " & appDir)

	-- Flow state — initialised here, mutated step by step
	set sourcePath to ""
	set defaultName to ""
	set cloneName to ""
	set pwaMode to false
	set pwaURL to ""
	set pwaDefaultURL to ""
	set pwaForced to false

	set openArg to ""
	set iconMode to ""
	set iconPath to ""
	set colorHex to ""

	-- Step machine: each step can go to step-1 (Retour) or step+1 (continue).
	-- Closing a dialog via the X button throws -128, caught and treated as Retour.
	-- The only true exit is step 1 (file picker cancel → return from on run).
	set step to 1
	repeat
		-- ===== 1) Pick the source application =====
		if step = 1 then
			-- Use NSOpenPanel directly so the action button carries the
			-- catalogue's "Choose" label. Its Cancel button keeps the system
			-- label: NSOpenPanel has no key-value accessor for that title,
			-- and a guarded setter here always failed silently.
			set panel to current application's NSOpenPanel's openPanel
			panel's setMessage:(msg_choose_source of u)
			panel's setPrompt:(btn_choose of u)
			panel's setCanChooseFiles:true
			panel's setCanChooseDirectories:false
			panel's setAllowsMultipleSelection:false
			panel's setAllowedFileTypes:{"app"}
			set appsFolder to path to applications folder
			try
				panel's setDirectoryURL:(current application's NSURL's fileURLWithPath:(POSIX path of appsFolder))
			end try
			set rc to panel's runModal()
			if rc is not 1 then
				-- Cancel at step 1 → nothing to go back to
				return
			end if
			set chosenURL to (panel's |URLs|()'s firstObject())
			set sourcePath to (chosenURL's |path|()) as text
			logmsg("source: " & sourcePath)
			set defaultName to do shell script "basename " & quoted form of sourcePath & " .app"
			set cloneName to my format_ui(default_clone_name of u, defaultName)
			set step to 2

		-- ===== 2) Clone name =====
		else if step = 2 then
			tell me to activate
			try
				set r to my customDialog((title_clone_name of u), (msg_clone_name of u), ¬
					{btn_back of u, btn_ok of u}, true, cloneName, 1, 280, false, "")
				if (chosenButton of r) is (btn_back of u) then
					set step to 1
				else
					set entered to my trim(inputText of r)
					if entered is "" then set entered to my format_ui(default_clone_name of u, defaultName)
					set cloneName to entered
					logmsg("cloneName: " & cloneName)
					set step to 3
				end if
			on error
				set step to 1
			end try

		-- ===== 3) PWA mode detection + opt-in =====
		-- Sandboxed apps (Teams, Outlook, OneNote…) cannot be cloned at the binary
		-- level — their entitlements are bound to the vendor's team-id. The web
		-- version wrapped in our launcher is the only reliable alternative.
		else if step = 3 then
			set sourceBundleId to my getBundleId(sourcePath)
			set pwaSuggestion to my pwaSuggestionFor(sourceBundleId, sourcePath)
			set pwaForced to item 1 of pwaSuggestion
			set pwaDefaultURL to item 2 of pwaSuggestion
			tell me to activate
			try
				if pwaForced then
					set pwaAnswer to my chooseButton((title_pwa_recommended of u), ¬
						(msg_pwa_recommended of u), ¬
						{btn_back of u, btn_try_native of u, btn_pwa_recommended of u}, "App Cloner")
				else
					set pwaAnswer to my chooseButton((title_pwa_mode of u), ¬
						(msg_pwa_optional of u), ¬
						{btn_back of u, btn_pwa_webapp of u, btn_native_clone of u}, "App Cloner")
				end if
				if pwaAnswer is (btn_back of u) then
					set step to 2
				else if pwaAnswer contains "PWA" then
					set pwaMode to true
					set pwaURL to pwaDefaultURL
					set step to 4
				else
					set pwaMode to false
					set openArg to ""
					set step to 4
				end if
			on error
				set step to 2
			end try

		-- ===== 4) URL / chemin ou URL PWA =====
		else if step = 4 then
			tell me to activate
			if pwaMode then
				-- PWA: single URL input + an opt-in checkbox to lock the PWA
				-- to its initial URL. With the lock on, navigations to a
				-- different page (different scheme/host/path or fragment-path)
				-- are dispatched to the source desktop app via `open -a`,
				-- forcing the user to switch to the real app for anything
				-- outside the original conversation/page.
				set urlBody to (msg_pwa_url of u)
				try
					set r to my customDialog((title_pwa_url of u), urlBody, ¬
						{btn_back of u, btn_ok of u}, true, pwaURL, -1, 600, false, "")
					if (chosenButton of r) is (btn_back of u) then
						set step to 3
					else
						set candidate to my trim(inputText of r)
						set pwaErr to my validatePWAURL(candidate, u)
						if pwaErr is "" then
							set pwaURL to candidate
							set openArg to candidate
							set step to 5
						else
							display alert (title_invalid_url of u) message pwaErr as warning
							-- Stay on step 4 to re-prompt
						end if
					end if
				on error
					set step to 3
				end try
			else
				-- Native clone: optional launch argument.
				-- Sub-step 0 = choice dialog (Rien / URL ou chemin).
				-- Sub-step 1 = text input with embedded Parcourir… button.
				-- Retour in sub-step 0 → step 3; Retour in sub-step 1 → sub-step 0.
				set nativeSubStep to 0
				set nativeDone to false
				repeat while not nativeDone
					if nativeSubStep = 0 then
						try
							set openTypeAnswer to my chooseButton((title_open_arg of u), ¬
								(my format_ui(msg_native_open_optional of u, value_none of u)), ¬
								{btn_back of u, value_none of u, title_url_path of u}, "App Cloner")
							if openTypeAnswer is (btn_back of u) then
								set step to 3
								set nativeDone to true
							else if openTypeAnswer is (value_none of u) then
								set openArg to ""
								set step to 5
								set nativeDone to true
							else
								-- Carry over any previously entered value as the default
								set nativeSubStep to 1
							end if
						on error
							set step to 3
							set nativeDone to true
						end try
					else
						-- URL / path input with an inline Parcourir… button that fills
						-- the field with a folder path chosen via the system picker.
						set urlPrompt to (msg_url_path of u)
						set inputDefault to openArg
						set inputDone to false
						repeat while not inputDone
							try
								set r to my customDialog((title_url_path of u), urlPrompt, ¬
									{btn_back of u, btn_browse of u, btn_validate of u}, true, inputDefault, 1, 560, false, "")
								set btnChosen to chosenButton of r
								if btnChosen is (btn_back of u) then
									-- Go back to choice dialog (Rien / URL ou chemin)
									set nativeSubStep to 0
									set inputDone to true
								else if btnChosen is (btn_browse of u) then
									-- Open folder picker and pre-fill the text field
									try
										set folderAlias to choose folder with prompt (prompt_choose_folder of u)
										set inputDefault to POSIX path of folderAlias
									on error
										-- Picker cancelled — keep current inputDefault
									end try
								else
									-- Valider
									set candidate to my trim(inputText of r)
									if candidate is "" then
										display alert (title_empty_input of u) message (my format_ui(msg_empty_input of u, btn_browse of u)) as warning
									else
										set validationError to my validateOpenArg(candidate, sourcePath, u)
										if validationError is "" then
											set openArg to candidate
											set step to 5
											set nativeDone to true
											set inputDone to true
										else
											display alert (title_invalid_input of u) message validationError as warning
											set inputDefault to candidate
										end if
									end if
								end if
							on error
								-- X-close treated as Retour → back to choice dialog
								set nativeSubStep to 0
								set inputDone to true
							end try
						end repeat
					end if
				end repeat
			end if

		-- ===== 5) Icon style =====
		else if step = 5 then
			tell me to activate
			set iconChosen to false
			repeat while not iconChosen
				try
					set iconChoice to my chooseButton((title_icon_style of u), ¬
						(msg_icon_style of u), ¬
						{btn_back of u, btn_custom_icon of u, btn_tint_icon of u}, "App Cloner")
					if iconChoice is (btn_back of u) then
						set step to 4
						set iconChosen to true -- exit inner loop; outer repeat re-enters step 4
					else if iconChoice is (btn_tint_icon of u) then
						set chosenNSColor to my showTintColorPicker(sourcePath, title_tint of u, btn_validate of u, btn_back of u)
						if chosenNSColor is not missing value then
							-- Convert sRGB float components (0.0–1.0) to 16-bit integers for rgbToHex
							set sRGBSpace to current application's NSColorSpace's sRGBColorSpace
							set rgbColor to chosenNSColor's colorUsingColorSpace:sRGBSpace
							set r16 to (((rgbColor's redComponent()) * 65535.0) as integer)
							set g16 to (((rgbColor's greenComponent()) * 65535.0) as integer)
							set b16 to (((rgbColor's blueComponent()) * 65535.0) as integer)
							set iconMode to "tint"
							set colorHex to my rgbToHex(r16, g16, b16)
							set step to 6
							set iconChosen to true
						end if
						-- missing value means Retour → iconChosen stays false, re-loop to style chooser
					else if iconChoice is (btn_custom_icon of u) then
						try
							set iconAlias to choose file ¬
								with prompt (prompt_choose_icon of u) ¬
								of type {"public.image", "com.apple.icns"} ¬
								default location (path to downloads folder)
							set iconPath to POSIX path of iconAlias
							set iconMode to "custom"
							set colorHex to "#000000"
							set step to 6
							set iconChosen to true
						on error
							-- File picker cancelled → re-loop to style chooser
						end try
					end if
				on error
					-- X-close → back to step 4
					set step to 4
					set iconChosen to true
				end try
			end repeat

		-- ===== 6) Confirmation and creation =====
		else if step = 6 then
			set openArgDisplay to (value_none of u)
			if openArg is not "" then set openArgDisplay to openArg
			set iconDisplay to ""
			if iconMode is "tint" then
				set iconDisplay to (btn_tint_icon of u) & " " & colorHex
			else
				set iconDisplay to (btn_custom_icon of u) & " — " & iconPath
			end if
			set modeDisplay to (mode_native of u)
			if pwaMode then set modeDisplay to (mode_pwa of u)
			set summary to "• " & (summary_source of u) & " : " & sourcePath & return ¬
				& "• " & (summary_name of u) & " : " & cloneName & return ¬
				& "• " & (summary_mode of u) & " : " & modeDisplay & return ¬
				& "• " & (summary_icon of u) & " : " & iconDisplay & return ¬
				& "• " & (summary_url of u) & " : " & openArgDisplay
			tell me to activate
			try
				set summaryResult to my customDialog((title_summary of u), summary, ¬
					{btn_back of u, btn_clone of u}, false, "", 0, 460, false, "")
				if (chosenButton of summaryResult) is (btn_back of u) then
					set step to 5
				else
					-- User confirmed — exit the step machine and proceed to creation
					exit repeat
				end if
			on error
				set step to 5
			end try
		end if
	end repeat

	logmsg("openArg: " & openArg & "  pwaMode: " & (pwaMode as text))
	logmsg("iconMode: " & iconMode & "  iconPath: " & iconPath & "  colorHex: " & colorHex)

	do shell script "chmod +x " & quoted form of cloneScript

	set pwaArg to "0"
	if pwaMode then set pwaArg to "1"
	set appLogPath to my app_log_path()
	set cmd to quoted form of cloneScript ¬
		& " " & quoted form of sourcePath ¬
		& " " & quoted form of cloneName ¬
		& " " & quoted form of colorHex ¬
		& " " & quoted form of openArg ¬
		& " " & quoted form of iconMode ¬
		& " " & quoted form of iconPath ¬
		& " " & quoted form of pwaArg ¬
		& " " & quoted form of appLogPath
	logmsg("cmd: " & cmd)

	-- Give this run an unguessable private channel for its output, exit status,
	-- and completion signal. Concurrent App Cloner instances cannot consume or
	-- overwrite one another's files.
	set runDir to do shell script "mktemp -d \"${TMPDIR:-/tmp}/ergopti-appcloner.XXXXXXXX\""
	set resultPath to runDir & "/result"
	set statusPath to runDir & "/status"
	set donePath to runDir & "/done"
	set bgCmd to "(" & cmd ¬
		& " > " & quoted form of resultPath & " 2>&1 ; " ¬
		& "run_status=$?; echo \"$run_status\" > " & quoted form of statusPath & " ; " ¬
		& "touch " & quoted form of donePath & ") >/dev/null 2>&1 &"
	do shell script bgCmd

	set progress total steps to 100
	set progress completed steps to 0
	set progress description to (lbl_progress_title of u)
	set progress additional description to (lbl_progress_prep of u)

	set tickCount to 0
	set isDone to false
	repeat until isDone
		delay 0.08
		set tickCount to tickCount + 1
		-- Asymptotic curve: ~95 % after roughly 7 s of waiting
		set pct to round (95 * (1 - (0.96 ^ tickCount)))
		set progress completed steps to pct
		if tickCount = 12 then
			set progress additional description to (lbl_progress_icon of u)
		else if tickCount = 30 then
			set progress additional description to (lbl_progress_sign of u)
		else if tickCount = 50 then
			set progress additional description to (lbl_progress_dock of u)
		end if
		try
			do shell script "test -e " & quoted form of donePath
			set isDone to true
		end try
	end repeat

	set progress completed steps to 100
	set progress additional description to (lbl_progress_done of u)
	delay 0.2

	-- Read the exact run's status and last output line before releasing its
	-- private directory.
	set exitStatus to do shell script "cat " & quoted form of statusPath & " 2>/dev/null || echo 'missing'"
	set result_path to do shell script "tail -n 1 " & quoted form of resultPath & " 2>/dev/null || echo ''"
	logmsg("result: " & result_path)
	try
		do shell script "/bin/rm -f " & quoted form of resultPath & " " ¬
			& quoted form of statusPath & " " & quoted form of donePath ¬
			& " ; /bin/rmdir " & quoted form of runDir
	on error cleanupError
		logmsg("run cleanup failed: " & cleanupError)
	end try

	if exitStatus is not "0" or result_path does not start with "/" then
		set diagnosticMessage to (title_error of u)
		set errorButtons to {btn_close of u}
		if appLogPath is not "" then
			set diagnosticMessage to my format_ui(diagnostic_log_path of u, appLogPath)
			set errorButtons to {btn_open_log of u, btn_close of u}
		end if
		set errBtn to my chooseButton((title_error of u), ¬
			diagnosticMessage, errorButtons, "App Cloner")
		if appLogPath is not "" then
			if errBtn is (btn_open_log of u) then
				do shell script "/usr/bin/open -e " & quoted form of appLogPath
			end if
		end if
		return
	end if

	-- Success: close silently — the clone appears in the Dock immediately,
	-- which is confirmation enough without an extra click to dismiss.
end run
