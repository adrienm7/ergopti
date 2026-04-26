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
		set tinted to my tintedIconImage((my tintPreviewSourceImage), currentColor)
		set imgView to my tintPreviewImageView
		imgView's setImage:tinted
		-- Force a repaint: setImage: alone does not always invalidate the view's
		-- cached display on Tahoe, especially when the new NSImage has the same
		-- size as the previous one.
		imgView's setNeedsDisplay:true
	on error errMsg
		my logmsg("doUpdatePreview failed: " & errMsg)
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
-- time. Returns "" when the value is acceptable, or a French error message
-- describing what's wrong so we can re-prompt.
--
-- Catches the most common mistakes:
--   * empty string after trimming
--   * the user typed text instead of pasting a URL / path
--   * a typo in the scheme such as «mstems:» or «msteams//» (missing colon)
--   * a Teams clone with a non-Teams URL (and vice-versa) — best-effort hint
on validateOpenArg(inputVal, sourceAppPath)
	if inputVal is "" then return "Le champ est vide. Colle une URL ou un chemin de fichier."

	-- File-system path: must point to something that actually exists
	if (inputVal starts with "/") or (inputVal starts with "~") then
		set resolvedPath to inputVal
		if resolvedPath starts with "~" then
			set resolvedPath to (POSIX path of (path to home folder)) & (text 2 thru -1 of inputVal)
		end if
		try
			do shell script "test -e " & quoted form of resolvedPath
		on error
			return "Le chemin « " & inputVal & " » n'existe pas sur le disque."
		end try
		return ""
	end if

	-- URL: must contain «://» — most copy-paste typos break here
	-- (e.g. «msteams:/l/chat», «https:/example.com», «msteams.com»).
	if inputVal does not contain "://" then
		-- Tolerate the single-slash msteams form Microsoft documents
		if not (inputVal starts with "msteams:/l/" or inputVal starts with "msteams:/calendar") then
			return "Format invalide. Une URL doit contenir « :// » (ex. https://… , msteams://… , slack://…)."
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
		return "Cette app source est Teams, mais l'URL ne commence pas par « msteams: » ni « https: »."
	end if

	return ""
end validateOpenArg

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
on validatePWAURL(inputVal)
	if inputVal is "" then return "L'URL de la PWA est obligatoire en mode PWA."
	set v to my toLower(inputVal)
	if not (v starts with "http://" or v starts with "https://") then
		return "L'URL doit commencer par http:// ou https:// (Edge --app= n'accepte que des URLs web)."
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

-- Count visible lines in a string (LF and CR both count as breaks).
on countLines(s)
	if s is "" then return 0
	set n to 1
	repeat with i from 1 to (length of s)
		set c to character i of s
		if (c is return) or (c is linefeed) then set n to n + 1
	end repeat
	return n
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

-- Render a 128×128 NSImage with the tint color overlaid using a 4-pass
-- compositing pipeline that preserves both hue and the icon's alpha mask.
on tintedIconImage(srcImage, tintColor)
	set sz to current application's NSMakeSize(128, 128)
	set tinted to current application's NSImage's alloc()'s initWithSize:sz
	-- lockFocus is deprecated on Tahoe but still functional. The recommended
	-- replacement (NSBitmapImageRep + initWithBitmapDataPlanes:) cannot be
	-- called from AppleScript-ObjC because its first parameter is unsigned
	-- char ** which has no AppleScript bridge for nil — passing
	-- (missing value) makes the script fail to compile (-1750).
	tinted's lockFocus()
	set destRect to current application's NSMakeRect(0, 0, 128, 128)
	set ctx to current application's NSGraphicsContext's currentContext
	ctx's saveGraphicsState()
	-- Pass 1: draw the original icon. Establishes colour and alpha mask.
	srcImage's drawInRect:destRect fromRect:(current application's NSZeroRect) operation:2 fraction:1.0
	-- Pass 2 (optional — grayscale mode): desaturate via Saturation blend.
	-- Only applied when tintAlpha ≈ 0; otherwise Pass 3 (Multiply) works
	-- directly on the coloured icon with no prior desaturation needed.
	set sRGBSpace to current application's NSColorSpace's sRGBColorSpace
	set tintRGB to tintColor's colorUsingColorSpace:sRGBSpace
	set tintAlpha to (tintRGB's alphaComponent()) as real
	if tintAlpha <= 0.01 then
		-- Grayscale path: strip hue with a neutral grey Saturation fill.
		ctx's setCompositingOperation:26  -- NSCompositingOperationSaturation
		set grayFill to current application's NSColor's colorWithWhite:0.5 alpha:1.0
		grayFill's setFill()
		current application's NSBezierPath's fillRect:destRect
	else
		-- Tint path: Multiply blends the tint colour into every pixel.
		-- Multiply formula: dst × src. On white pixels (dst=1) it applies the
		-- tint at full strength; on dark pixels (dst≈0) it stays dark — which
		-- is exactly right for icons like Outlook whose background is white.
		-- Screen (the former operation) collapses to white on white backgrounds,
		-- making the whole preview appear blank for such icons.
		ctx's setCompositingOperation:16  -- NSCompositingOperationMultiply
		tintColor's setFill()
		current application's NSBezierPath's fillRect:destRect
	end if
	-- Pass 3: restore the icon's alpha mask (DestinationIn). Transparent pixels
	-- the icon left empty are zeroed out — no coloured square halo remains.
	srcImage's drawInRect:destRect fromRect:(current application's NSZeroRect) operation:7 fraction:1.0
	-- Post-pass: place opaque white behind the result (DestinationOver).
	-- Flattens semi-transparent edges onto a clean white matte so no fringe
	-- appears when the preview panel renders on its own white background.
	ctx's setCompositingOperation:3  -- NSCompositingOperationDestinationOver
	set whiteFill to current application's NSColor's whiteColor
	whiteFill's setFill()
	current application's NSBezierPath's fillRect:destRect
	ctx's restoreGraphicsState()
	tinted's unlockFocus()
	return tinted
end tintedIconImage

-- Custom colour-picker dialog with a live 128×128 icon preview.
-- An NSTimer fires every 80 ms, reads the NSColorWell's current colour, and
-- repaints the preview — giving immediate visual feedback as the user drags
-- sliders in the system colour panel.
-- Returns the chosen NSColor, or missing value when the user clicks Retour.
on showTintColorPicker(appPath)
	set ws to current application's NSWorkspace's sharedWorkspace
	set srcImage to ws's iconForFile:appPath
	set my tintPreviewSourceImage to srcImage

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
	hLabel's setStringValue:"Teinte de couleur"
	set pickerHeaderFont to current application's NSFont's boldSystemFontOfSize:14
	hLabel's setFont:pickerHeaderFont
	hLabel's setBordered:false
	hLabel's setEditable:false
	hLabel's setDrawsBackground:false
	cv's addSubview:hLabel

	-- Subtitle
	set bLabel to current application's NSTextField's alloc()'s initWithFrame:(current application's NSMakeRect(16, pH - 62, pW - 32, 16))
	bLabel's setStringValue:"Aperçu en temps réel — cliquez sur la couleur pour la modifier."
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
	valBtn's setTitle:"Valider"
	valBtn's setBezelStyle:1
	valBtn's setTarget:me
	valBtn's setAction:"btn2Clicked:"
	valBtn's setKeyEquivalent:(character id 13)
	cv's addSubview:valBtn

	set retBtn to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(16, btnY, btnW, btnH))
	retBtn's setTitle:"Retour"
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

on installEditMenu()
	try
		set theApp to current application's NSApplication's sharedApplication
		-- Always rebuild the main menu from scratch. The existence check is unsafe:
		-- osascript may return a non-nil stale menu object that prevents our Edit
		-- items from being installed, silently leaving Cmd+V/A/C/X non-functional.
		set appMainMenu to current application's NSMenu's alloc()'s init
		theApp's setMainMenu:appMainMenu
		set editItem to current application's NSMenuItem's alloc()'s initWithTitle:"Edit" action:(missing value) keyEquivalent:""
		set editMenu to current application's NSMenu's alloc()'s initWithTitle:"Edit"
		editMenu's addItemWithTitle:"Cut"        action:"cut:"        keyEquivalent:"x"
		editMenu's addItemWithTitle:"Copy"       action:"copy:"       keyEquivalent:"c"
		editMenu's addItemWithTitle:"Paste"      action:"paste:"      keyEquivalent:"v"
		editMenu's addItemWithTitle:"Select All" action:"selectAll:"  keyEquivalent:"a"
		editMenu's addItemWithTitle:"Undo"       action:"undo:"       keyEquivalent:"z"
		editMenu's addItem:(current application's NSMenuItem's separatorItem())
		editMenu's addItemWithTitle:"Redo"       action:"redo:"       keyEquivalent:"Z"
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

on logmsg(m)
	try
		do shell script "echo " & quoted form of m & " >> /tmp/appcloner.log"
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
	-- Promote osascript from background/accessory to a regular foreground app.
	-- Without this, NSApp.sendEvent: never checks the main menu for key
	-- equivalents — Cmd+V/A/C/X and every other shortcut are silently dropped
	-- even though the windows are key and text input works.
	set nsApp to current application's NSApplication's sharedApplication
	nsApp's setActivationPolicy:0  -- NSApplicationActivationPolicyRegular

	-- Install a standard Edit menu (Cut/Copy/Paste/Select All/Undo/Redo) so
	-- the keyboard shortcuts work in every NSAlert text input we open later.
	my installEditMenu()

	-- Bring App Cloner to the front (switch Space if needed) on every relaunch.
	-- Without this, after going into Teams to copy a chat link, clicking the
	-- App Cloner Dock icon doesn't actually surface its window.
	tell me to activate

	-- argv[1]: absolute bundle path, forwarded by Contents/MacOS/AppCloner
	if argv is {} or item 1 of argv is "" then
		display dialog "Erreur : chemin du bundle manquant. Lancez l'app normalement." buttons {"OK"} default button 1
		return
	end if
	set appDir to item 1 of argv
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
			set appsFolder to path to applications folder
			try
				set sourceFile to choose file ¬
					with prompt "Application à cloner" ¬
					default location appsFolder ¬
					of type {"com.apple.application-bundle"}
				set sourcePath to POSIX path of sourceFile
				logmsg("source: " & sourcePath)
				set defaultName to do shell script "basename " & quoted form of sourcePath & " .app"
				set cloneName to defaultName & " — Clone"
				set step to 2
			on error
				-- File picker cancelled at step 1 → nothing to go back to
				return
			end try

		-- ===== 2) Clone name =====
		else if step = 2 then
			tell me to activate
			try
				set r to my customDialog("Nom du clone", "Nom à afficher sous l'icône du Dock.", ¬
					{"Retour", "OK"}, true, cloneName, 1, 280, false, "")
				if (chosenButton of r) is "Retour" then
					set step to 1
				else
					set entered to my trim(inputText of r)
					if entered is "" then set entered to defaultName & " Clone"
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
					set pwaAnswer to my chooseButton("Mode PWA recommandé", ¬
						"Cette app ne peut pas être clonée au niveau binaire" & return & ¬
						"(sandbox + signature liée au fournisseur)." & return & return & ¬
						"Le mode PWA installe une version web isolée via un navigateur" & return & ¬
						"avec sa propre fenêtre, son propre profil et son propre compte.", ¬
						{"Retour", "Tenter natif", "PWA (recommandé)"}, "App Cloner")
				else
					set pwaAnswer to my chooseButton("Mode PWA ?", ¬
						"Cloner via une web app (navigateur --app=URL)" & return & ¬
						"au lieu de relancer l'app native." & return & return & ¬
						"Utile pour avoir des comptes séparés sans dépendance au binaire.", ¬
						{"Retour", "PWA web app", "Cloner l'app native"}, "App Cloner")
				end if
				if pwaAnswer is "Retour" then
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
				-- PWA: single URL input, no folder picker needed
				set urlBody to ¬
					"URL à ouvrir dans la PWA (Entrée pour valider) :" & return & return & ¬
					"── Microsoft Teams ──────────────────────────────" & return & ¬
					"App entière : https://teams.microsoft.com/v2/" & return & ¬
					"Conversation : Teams → conv → ⋯ → « Copier le lien »" & return & ¬
					"Canal : clic-droit canal → « Lien vers le canal »" & return & return & ¬
					"── Outlook ──────────────────────────────────────" & return & ¬
					"Boîte de réception : https://outlook.office.com/mail/" & return & ¬
					"Calendrier : https://outlook.office.com/calendar/"
				try
					set r to my customDialog("URL PWA", urlBody, ¬
						{"Retour", "OK"}, true, pwaURL, -1, 600, false, "")
					if (chosenButton of r) is "Retour" then
						set step to 3
					else
						set candidate to my trim(inputText of r)
						set pwaErr to my validatePWAURL(candidate)
						if pwaErr is "" then
							set pwaURL to candidate
							set openArg to candidate
							set step to 5
						else
							display alert "URL invalide" message pwaErr as warning
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
							set openTypeAnswer to my chooseButton("Élément à ouvrir au lancement", ¬
								"Optionnel — laisser à « Rien » pour simplement lancer l'app.", ¬
								{"Retour", "Rien", "URL ou chemin"}, "App Cloner")
							if openTypeAnswer is "Retour" then
								set step to 3
								set nativeDone to true
							else if openTypeAnswer is "Rien" then
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
						set urlPrompt to ¬
							"Coller l'URL ou le chemin à ouvrir au lancement." & return & return & ¬
							"📅  Outlook calendrier :   ms-outlook://events" & return & return & ¬
							"📨  Outlook mail :         ms-outlook://" & return & return & ¬
							"💬  Teams (une conv) :     msteams:/l/chat/0/0?users=foo@bar.com" & return & ¬
							"     → Teams : clic-droit conv → « Get link to chat »" & return & return & ¬
							"📅  Teams calendrier :     msteams:/l/calendar" & return & return & ¬
							"💼  Slack (chaîne) :       slack://channel?team=T1234&id=C5678" & return & ¬
							"     → Slack → ⋮ d'une chaîne → « Copy link »" & return & return & ¬
							"📝  Notion (page) :        notion://www.notion.so/My-Page-abc123" & return & return & ¬
							"🎵  Spotify (playlist) :   spotify:playlist:37i9dQZF1DXcBWIGoYBM5M" & return & return & ¬
							"🎮  Discord (salon) :      discord://discord.com/channels/SERVER/CHANNEL" & return & return & ¬
							"🌐  Tout site web :        https://example.com" & return & return & ¬
							"📁  Dossier ou fichier :   /Users/moi/projet"
						set inputDefault to openArg
						set inputDone to false
						repeat while not inputDone
							try
								set r to my customDialog("URL ou chemin", urlPrompt, ¬
									{"Retour", "Parcourir…", "Valider"}, true, inputDefault, 1, 560, false, "")
								set btnChosen to chosenButton of r
								if btnChosen is "Retour" then
									-- Go back to choice dialog (Rien / URL ou chemin)
									set nativeSubStep to 0
									set inputDone to true
								else if btnChosen is "Parcourir…" then
									-- Open folder picker and pre-fill the text field
									try
										set folderAlias to choose folder with prompt "Dossier à ouvrir avec le clone"
										set inputDefault to POSIX path of folderAlias
									on error
										-- Picker cancelled — keep current inputDefault
									end try
								else
									-- Valider
									set candidate to my trim(inputText of r)
									if candidate is "" then
										display alert "Champ vide" message "Saisis une URL ou un chemin, ou clique sur Parcourir…" as warning
									else
										set validationError to my validateOpenArg(candidate, sourcePath)
										if validationError is "" then
											set openArg to candidate
											set step to 5
											set nativeDone to true
											set inputDone to true
										else
											display alert "Entrée invalide" message validationError as warning
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
					set iconChoice to my chooseButton("Style d'icône", ¬
						"  • Teinte couleur — applique une teinte sur l'icône d'origine." & return & ¬
						"    (opacité 0 = noir & blanc)" & return & ¬
						"  • Personnalisée — utilise une image (PNG, ICNS, JPG…) en remplacement.", ¬
						{"Retour", "Personnalisée", "Teinte couleur"}, "App Cloner")
					if iconChoice is "Retour" then
						set step to 4
						set iconChosen to true -- exit inner loop; outer repeat re-enters step 4
					else if iconChoice is "Teinte couleur" then
						set chosenNSColor to my showTintColorPicker(sourcePath)
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
					else if iconChoice is "Personnalisée" then
						try
							set iconAlias to choose file ¬
								with prompt "Image à utiliser pour l'icône" ¬
								of type {"public.image", "com.apple.icns"}
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
			set openArgDisplay to "(aucun)"
			if openArg is not "" then set openArgDisplay to openArg
			set iconDisplay to ""
			if iconMode is "tint" then
				set iconDisplay to "Teinte " & colorHex
			else
				set iconDisplay to "Personnalisée — " & iconPath
			end if
			set modeDisplay to "App native"
			if pwaMode then set modeDisplay to "PWA web app (navigateur)"
			set summary to "• Source :  " & sourcePath & return ¬
				& "• Nom :     " & cloneName & return ¬
				& "• Mode :    " & modeDisplay & return ¬
				& "• Icône :   " & iconDisplay & return ¬
				& "• Ouvre :   " & openArgDisplay
			tell me to activate
			try
				set summaryResult to my customDialog("Récapitulatif", summary, ¬
					{"Retour", "Cloner l'application"}, false, "", 0, 380, false, "")
				if (chosenButton of summaryResult) is "Retour" then
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
	set cmd to quoted form of cloneScript ¬
		& " " & quoted form of sourcePath ¬
		& " " & quoted form of cloneName ¬
		& " " & quoted form of colorHex ¬
		& " " & quoted form of openArg ¬
		& " " & quoted form of iconMode ¬
		& " " & quoted form of iconPath ¬
		& " " & quoted form of pwaArg
	logmsg("cmd: " & cmd)

	-- Run the shell script in the background, signal completion via a
	-- sentinel file (/tmp/appcloner_done). The progress bar updates while
	-- the shell runs — deliberately asymptotic (only reaches ~95 % after
	-- ~7 s) then jumps to 100 % the moment the sentinel appears.
	do shell script "rm -f /tmp/appcloner_done /tmp/appcloner_result"
	set bgCmd to "(" & cmd & " > /tmp/appcloner_result 2>&1 ; touch /tmp/appcloner_done) >/dev/null 2>&1 &"
	do shell script bgCmd

	set progress total steps to 100
	set progress completed steps to 0
	set progress description to "Création du clone en cours…"
	set progress additional description to "Préparation de l'icône et du bundle"

	set tickCount to 0
	set isDone to false
	repeat until isDone
		delay 0.08
		set tickCount to tickCount + 1
		-- Asymptotic curve: ~95 % after roughly 7 s of waiting
		set pct to round (95 * (1 - (0.96 ^ tickCount)))
		set progress completed steps to pct
		if tickCount = 12 then
			set progress additional description to "Génération de l'icône teintée…"
		else if tickCount = 30 then
			set progress additional description to "Signature ad-hoc du bundle…"
		else if tickCount = 50 then
			set progress additional description to "Enregistrement dans le Dock…"
		end if
		try
			do shell script "test -e /tmp/appcloner_done"
			set isDone to true
		end try
	end repeat

	set progress completed steps to 100
	set progress additional description to "Terminé"
	delay 0.2

	-- Pull the result (last line of stdout) plus any error output
	set raw to do shell script "cat /tmp/appcloner_result 2>/dev/null || echo ''"
	set result_path to do shell script "tail -n 1 /tmp/appcloner_result 2>/dev/null || echo ''"
	logmsg("result: " & result_path)

	if result_path does not start with "/" then
		set errBtn to my chooseButton("❌  Échec de la création du clone", ¬
			"Le diagnostic complet est dans /tmp/clone_diag.log", ¬
			{"Ouvrir le log", "Fermer"}, "App Cloner")
		if errBtn is "Ouvrir le log" then
			do shell script "open -e /tmp/clone_diag.log"
		end if
		return
	end if

	-- Success: close silently — the clone appears in the Dock immediately,
	-- which is confirmation enough without an extra click to dismiss.
end run
