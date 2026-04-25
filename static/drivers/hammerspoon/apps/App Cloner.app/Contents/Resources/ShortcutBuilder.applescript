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
-- actions. setTarget:me + top-level `on btnXClicked:sender` handlers are the
-- canonical pattern that works in plain osascript.
-- AppleScript script objects can serve as Cocoa targets when their handler
-- names end with `:` — Cocoa dispatches `btnXClicked:` to handler
-- `btnXClicked:` on this object. We store the picked button index and the
-- captured input/checkbox values here so customDialog() can read them back
-- after the modal returns.
-- Dialog state held as top-level properties of the running script. We use
-- `setTarget:me` for button actions — `me` (the script itself) is the
-- canonical NSObject target that osascript exposes to Cocoa, and top-level
-- handlers `on btnXClicked:sender` are bridged 1:1 to Cocoa selectors of
-- the same name. Trying to wrap this in a `script Foo ... end script`
-- with `property parent : class "NSObject"` works in app bundles but
-- crashes when the file is run by raw osascript on macOS Tahoe — hence
-- the flat top-level layout.
property panelResult : 0          -- 1-based button index, 0 if cancelled
property panelInputText : ""
property panelChecked : false
property panelInputView : missing value
property panelCheckboxView : missing value
property panelIsTextView : false  -- true for NSTextView, false for NSTextField

on captureDialogValues()
	-- `my` qualifier is mandatory inside handlers; without it, AppleScript
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
	(current application's NSApplication's sharedApplication())'s stopModal()
end btn1Clicked:

on btn2Clicked:sender
	captureDialogValues()
	set my panelResult to 2
	(current application's NSApplication's sharedApplication())'s stopModal()
end btn2Clicked:

on btn3Clicked:sender
	captureDialogValues()
	set my panelResult to 3
	(current application's NSApplication's sharedApplication())'s stopModal()
end btn3Clicked:

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
	set spacing to 14
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
	set inputHeight to 0
	if hasInput then
		if lineCount ≤ 1 then
			set inputHeight to 24
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
	set panelHeight to panelHeight + ((elemCount - 1) * spacing)

	-- Build panel: titled + closable, no resize, no minimise
	set rect to current application's NSMakeRect(0, 0, panelWidth, panelHeight)
	set styleMask to 3 -- NSWindowStyleMaskTitled (1) + Closable (2)
	set win to current application's NSPanel's alloc()'s initWithContentRect:rect styleMask:styleMask backing:2 defer:false
	win's setTitle:"App Cloner"
	win's |center|()
	win's setReleasedWhenClosed:false

	set contentView to win's contentView()

	-- Layout top → bottom
	set yCursor to panelHeight - marginYTop - headerHeight

	-- Header (bold)
	set headerFrame to current application's NSMakeRect(marginX, yCursor, panelWidth - (2 * marginX), headerHeight)
	set headerLabel to current application's NSTextField's alloc()'s initWithFrame:headerFrame
	headerLabel's setStringValue:header
	headerLabel's setFont:(current application's NSFont's boldSystemFontOfSize:14)
	headerLabel's setBordered:false
	headerLabel's setEditable:false
	headerLabel's setSelectable:false
	headerLabel's setDrawsBackground:false
	contentView's addSubview:headerLabel

	-- Body (multi-line, selectable so users can copy text from prompts)
	if bodyHeight > 0 then
		set yCursor to yCursor - spacing - bodyHeight
		set bodyFrame to current application's NSMakeRect(marginX, yCursor, panelWidth - (2 * marginX), bodyHeight)
		set bodyLabel to current application's NSTextField's alloc()'s initWithFrame:bodyFrame
		bodyLabel's setStringValue:body
		bodyLabel's setFont:(current application's NSFont's systemFontOfSize:12)
		bodyLabel's setBordered:false
		bodyLabel's setEditable:false
		bodyLabel's setSelectable:true
		bodyLabel's setDrawsBackground:false
		(bodyLabel's cell())'s setWraps:true
		(bodyLabel's cell())'s setLineBreakMode:0
		contentView's addSubview:bodyLabel
	end if

	-- Input (optional)
	if hasInput then
		set yCursor to yCursor - spacing - inputHeight
		set inputFrame to current application's NSMakeRect(marginX, yCursor, panelWidth - (2 * marginX), inputHeight)
		if lineCount ≤ 1 then
			set inputView to current application's NSTextField's alloc()'s initWithFrame:inputFrame
			inputView's setStringValue:defaultText
			inputView's setFont:(current application's NSFont's systemFontOfSize:13)
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
			textView's setFont:(current application's NSFont's systemFontOfSize:13)
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
		set yCursor to yCursor - spacing - checkboxHeight
		set cbFrame to current application's NSMakeRect(marginX, yCursor, panelWidth - (2 * marginX), checkboxHeight)
		set cb to current application's NSButton's alloc()'s initWithFrame:cbFrame
		cb's setButtonType:3 -- NSSwitchButton
		cb's setTitle:checkboxLabel
		cb's setState:0
		contentView's addSubview:cb
		set my panelCheckboxView to cb
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
		end if
		if i = lastIdx then btn's setKeyEquivalent:return
		contentView's addSubview:btn
		set xCursor to btnX - buttonGap
	end repeat

	-- Reset state, focus the input if any, and run modal
	set my panelResult to 0
	set my panelInputText to ""
	set my panelChecked to false
	if hasInput then
		win's makeFirstResponder:(my panelInputView)
	end if

	(current application's NSApplication's sharedApplication())'s runModalForWindow:win
	win's orderOut:(missing value)

	if my panelResult is 0 then error number -128

	return {chosenButton:(item (my panelResult) of buttonList), inputText:(my panelInputText), checked:(my panelChecked)}
end customDialog

-- Convenience wrappers around customDialog so call sites stay readable.

on chooseButton(headerText, bodyText, buttonList, dialogTitle)
	set r to my customDialog(headerText, bodyText, buttonList, false, "", 0, 380, false, "")
	return chosenButton of r
end chooseButton

on installEditMenu()
	try
		-- NSApp is a C global, not a property; in AppleScript-ObjC we have to
		-- go through NSApplication's sharedApplication. Wrap everything in
		-- try/end try so a Cocoa hiccup never crashes the whole UI.
		set theApp to current application's NSApplication's sharedApplication()
		set mainMenu to theApp's mainMenu()
		if mainMenu is missing value then
			set mainMenu to current application's NSMenu's alloc()'s init()
			theApp's setMainMenu:mainMenu
		end if
		-- Skip if an Edit menu is already present (e.g. installed by the host)
		set itemCount to mainMenu's numberOfItems() as integer
		repeat with i from 0 to (itemCount - 1)
			set existing to ((mainMenu's itemAtIndex:i)'s title()) as text
			if existing is "Edit" or existing is "Édition" then return
		end repeat
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
		mainMenu's addItem:editItem
	on error errMsg
		my logmsg("installEditMenu failed: " & errMsg)
	end try
end installEditMenu

on askText(prompt, defaultValue, dialogTitle, widthPx, lineCount)
	set r to my customDialog(dialogTitle, prompt, {"Annuler", "OK"}, true, defaultValue, lineCount, widthPx, false, "")
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

	-- ===== 1) Pick the source application =====
	-- `path to applications folder` returns an alias macOS treats as a proper
	-- sidebar location, unlike POSIX file "/Applications" which the file picker
	-- often ignores in favour of its last-visited location.
	set appsFolder to path to applications folder
	set sourceFile to choose file ¬
		with prompt "Application à cloner" ¬
		default location appsFolder ¬
		of type {"com.apple.application-bundle"}
	set sourcePath to POSIX path of sourceFile
	logmsg("source: " & sourcePath)

	-- Default clone name derived from the source app's basename
	set defaultName to do shell script "basename " & quoted form of sourcePath & " .app"
	logmsg("defaultName: " & defaultName)

	-- ===== 2) Clone name =====
	tell me to activate
	-- Narrow single-line dialog: the name rarely exceeds 30 characters
	set cloneName to my askText("Nom à afficher sous l'icône du Dock.", defaultName & " — Clone", "Nom du clone", 280, 1)
	if cloneName is "" then set cloneName to defaultName & " Clone"
	logmsg("cloneName: " & cloneName)

	-- ===== 3) Optional launch argument =====
	-- Three cases: nothing, a folder (VSCode), or a free URL/path. URLs like
	-- msteams:/l/chat/… or ms-outlook://events let Teams/Outlook/Slack/Spotify/
	-- Notion launch directly on a specific view (chat, calendar, channel…).
	tell me to activate
	set openTypeAnswer to my chooseButton("Élément à ouvrir au lancement", ¬
		"Optionnel — laisser à « Rien » pour simplement lancer l'app.", ¬
		{"Rien", "Dossier", "URL ou chemin"}, "App Cloner")
	set openArg to ""
	if openTypeAnswer is "Dossier" then
		try
			set openAlias to choose folder with prompt "Dossier à ouvrir avec le clone"
			set openArg to POSIX path of openAlias
		end try
	else if openTypeAnswer is "URL ou chemin" then
		-- Each example separated by a blank line for readability. The how-to
		-- hint sits on the line right under the URL it explains.
		set urlPrompt to ¬
			"Coller l'URL ou le chemin à ouvrir au lancement." & return & return & ¬
			"📅  Outlook calendrier :   ms-outlook://events" & return & return & ¬
			"📨  Outlook mail :         ms-outlook://" & return & return & ¬
			"💬  Teams (une conv) :     msteams:/l/chat/0/0?users=foo@bar.com" & return & ¬
			"        → dans Teams : clic-droit sur la conv → « Get link to chat »" & return & return & ¬
			"📅  Teams calendrier :     msteams:/l/calendar" & return & return & ¬
			"💼  Slack (une chaîne) :   slack://channel?team=T1234&id=C5678" & return & ¬
			"        → Slack → ⋮ d'une chaîne → « Copy » → « Copy link »" & return & return & ¬
			"📝  Notion (une page) :    notion://www.notion.so/My-Page-abc123" & return & ¬
			"        → Notion : … en haut de page → « Copy link »" & return & return & ¬
			"🎵  Spotify (playlist) :   spotify:playlist:37i9dQZF1DXcBWIGoYBM5M" & return & ¬
			"        → clic-droit sur playlist → Share → Copy Spotify URI" & return & return & ¬
			"🎮  Discord (un salon) :   discord://discord.com/channels/SERVER/CHANNEL" & return & ¬
			"        → Discord : clic-droit sur le salon → « Copy Link »" & return & return & ¬
			"🌐  Tout site web :        https://example.com" & return & return & ¬
			"📁  Dossier ou fichier :   /Users/moi/projet"
		try
			-- Wide dialog (URLs can be very long), 3-line input view to avoid
			-- horizontal scrolling on long Teams/Slack permalinks
			set openArg to my askText(urlPrompt, "", "URL ou chemin", 560, 3)
		end try
	end if
	logmsg("openArg: " & openArg)

	-- ===== 4) Icon style =====
	-- The whole step is wrapped in a loop so that cancelling a sub-prompt
	-- (color picker, file picker) sends the user back to the style chooser
	-- instead of silently falling through to a hardcoded default.
	tell me to activate
	set iconMode to ""
	set iconPath to ""
	set colorHex to ""
	repeat while iconMode is ""
		-- Leftmost button gets the Esc-key binding from customDialog. We put a
		-- real "Annuler" there so pressing Esc actually aborts the whole flow.
		set iconChoice to my chooseButton("Style d'icône", ¬
			"  • Teinte couleur — applique une teinte sur l'icône d'origine." & return & ¬
			"  • Noir & blanc — convertit l'icône d'origine en niveaux de gris." & return & ¬
			"  • Personnalisée — utilise une image (PNG, ICNS, JPG…) en remplacement.", ¬
			{"Annuler", "Personnalisée", "Noir & blanc", "Teinte couleur"}, "App Cloner")
		if iconChoice is "Annuler" then return
		if iconChoice is "Teinte couleur" then
			try
				set colorList to choose color default color {52428, 0, 0}
				set iconMode to "tint"
				set colorHex to my rgbToHex(item 1 of colorList, item 2 of colorList, item 3 of colorList)
			on error
				-- User cancelled the color picker → re-loop to style chooser
			end try
		else if iconChoice is "Noir & blanc" then
			set iconMode to "bw"
			-- Color ignored downstream but we still need a placeholder for the shell
			set colorHex to "#808080"
		else if iconChoice is "Personnalisée" then
			try
				set iconAlias to choose file ¬
					with prompt "Image à utiliser pour l'icône" ¬
					of type {"public.image", "com.apple.icns"}
				set iconPath to POSIX path of iconAlias
				set iconMode to "custom"
				set colorHex to "#000000"
			on error
				-- User cancelled the file picker → re-loop to style chooser
			end try
		end if
	end repeat
	logmsg("iconMode: " & iconMode & "  iconPath: " & iconPath & "  colorHex: " & colorHex)

	-- ===== 5) Confirmation and creation =====
	set openArgDisplay to "(aucun)"
	if openArg is not "" then set openArgDisplay to openArg
	set iconDisplay to ""
	if iconMode is "tint" then
		set iconDisplay to "Teinte " & colorHex
	else if iconMode is "bw" then
		set iconDisplay to "Noir & blanc"
	else
		set iconDisplay to "Personnalisée — " & iconPath
	end if
	set summary to "• Source : " & sourcePath & return ¬
		& "• Nom    : " & cloneName & return ¬
		& "• Icône  : " & iconDisplay & return ¬
		& "• Ouvre  : " & openArgDisplay
	tell me to activate
	-- Summary screen also exposes the experimental unread-badge toggle.
	-- Default off — implementation needs a Cocoa wrapper helper that we
	-- spawn alongside the app, and the helper requires Accessibility
	-- permissions (System Settings → Privacy → Accessibility).
	set summaryResult to my customDialog("Récapitulatif", summary, ¬
		{"Annuler", "Créer le clone"}, false, "", 0, 380, true, ¬
		"Activer le badge unread (expérimental, Teams uniquement)")
	set go to chosenButton of summaryResult
	set badgeEnabled to checked of summaryResult
	if go is "Annuler" then return

	do shell script "chmod +x " & quoted form of cloneScript

	set badgeArg to "0"
	if badgeEnabled then set badgeArg to "1"
	set cmd to quoted form of cloneScript ¬
		& " " & quoted form of sourcePath ¬
		& " " & quoted form of cloneName ¬
		& " " & quoted form of colorHex ¬
		& " " & quoted form of openArg ¬
		& " " & quoted form of iconMode ¬
		& " " & quoted form of iconPath ¬
		& " " & quoted form of badgeArg
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

	-- Success dialog. Headline + one-sentence body. The clone path is not
	-- repeated — the user already sees the name and knows to look in
	-- ~/Applications.
	set successInfo to "« " & cloneName & " » a été ajouté au Dock et au dossier Applications."
	set successBtn to my chooseButton("✅  Clone créé avec succès", successInfo, ¬
		{"Ouvrir Applications", "Terminé"}, "App Cloner")
	if successBtn is "Ouvrir Applications" then
		do shell script "open ~/Applications"
	end if
end run
