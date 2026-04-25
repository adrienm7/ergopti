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
-- Hand back a zero-sized NSImage. NSAlert sizes its icon slot from the
-- image's pixel dimensions; {0, 0} fully collapses the slot so the
-- dialog renders flush-left with no awkward leading gap. A 1×1 image
-- still leaves the icon column padding intact.
on blankImage()
	return current application's NSImage's alloc()'s initWithSize:(current application's NSMakeSize(0, 0))
end blankImage

-- Wrapper around `display dialog` that also strips the implicit Dock-app icon
-- from the dialog. AppleScript's classic display dialog always shows the host
-- app's icon top-left; this helper rebuilds the same prompt as an NSAlert
-- with no icon and returns the title of the clicked button — same shape as
-- `button returned of (display dialog …)`.
on chooseButton(messageText, informativeText, buttonList, dialogTitle)
	set anAlert to current application's NSAlert's alloc()'s init()
	anAlert's setMessageText:messageText
	anAlert's setInformativeText:informativeText
	anAlert's setIcon:(my blankImage())
	-- NSAlert places buttons right-to-left. Add the rightmost (= default)
	-- first by iterating the AppleScript-style button list backwards. That
	-- preserves the natural reading order: leftmost button = "Annuler",
	-- rightmost = the action verb.
	set lastIdx to (count of buttonList)
	repeat with i from lastIdx to 1 by -1
		anAlert's addButtonWithTitle:(item i of buttonList)
	end repeat
	set response to (anAlert's runModal()) as integer
	-- Hard-coded NSAlertFirstButtonReturn (1000) — bridging the AppKit
	-- enum constant via `current application's NSAlertFirstButtonReturn`
	-- is unreliable across macOS versions and silently returns missing
	-- value, leading to off-by-one button mapping or a crash.
	set picked to response - 1000 + 1
	return item (lastIdx - picked + 1) of buttonList
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

-- Text input via NSAlert with optional multi-line text view. Width and line
-- count are tunable so different prompts can size their dialog appropriately
-- (short name → narrow + 1 line; URL with examples → wide + 3 lines).
--   widthPx     : pixel width of the input area (drives overall dialog width)
--   lineCount   : 1 for an NSTextField, ≥2 for a multi-line NSTextView
on askText(prompt, defaultValue, dialogTitle, widthPx, lineCount)
	set anAlert to current application's NSAlert's alloc()'s init()
	anAlert's setMessageText:dialogTitle
	anAlert's setInformativeText:prompt

	-- Suppress the NSAlert default app/folder icon — visually distracting
	-- and irrelevant for plain text input.
	anAlert's setIcon:(my blankImage())

	if lineCount is 1 then
		set inputField to current application's NSTextField's alloc()'s initWithFrame:(current application's NSMakeRect(0, 0, widthPx, 24))
		inputField's setStringValue:defaultValue
		anAlert's setAccessoryView:inputField
		set firstResponderTarget to inputField
	else
		-- NSTextView inside an NSScrollView gives a real multi-line editor
		-- with native Cmd+A/C/V/X/Z, scroll bar when content overflows, and
		-- correct first-responder behavior inside an NSAlert.
		set lineHeight to 18
		set viewHeight to (lineCount * lineHeight) + 8
		set scrollFrame to current application's NSMakeRect(0, 0, widthPx, viewHeight)
		set scrollView to current application's NSScrollView's alloc()'s initWithFrame:scrollFrame
		scrollView's setHasVerticalScroller:true
		scrollView's setBorderType:(current application's NSBezelBorder)
		set textView to current application's NSTextView's alloc()'s initWithFrame:scrollFrame
		textView's setRichText:false
		textView's setAllowsUndo:true
		textView's setFont:(current application's NSFont's systemFontOfSize:13)
		textView's setString:defaultValue
		scrollView's setDocumentView:textView
		anAlert's setAccessoryView:scrollView
		set firstResponderTarget to textView
	end if

	anAlert's addButtonWithTitle:"OK"
	anAlert's addButtonWithTitle:"Annuler"
	-- Hand focus to the input on open so paste works immediately on Cmd+V
	(anAlert's |window|()'s makeFirstResponder:firstResponderTarget)
	set response to (anAlert's runModal()) as integer
	-- 1000 = NSAlertFirstButtonReturn (the OK we added first / rightmost)
	if response = 1000 then
		if lineCount is 1 then
			return (firstResponderTarget's stringValue() as text)
		else
			return (firstResponderTarget's |string|() as text)
		end if
	else
		error number -128
	end if
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
	tell me to activate
	set iconMode to "tint"
	set iconPath to ""
	set iconChoice to my chooseButton("Style d'icône", ¬
		"  • Teinte couleur — applique une teinte sur l'icône d'origine." & return & ¬
		"  • Noir & blanc — convertit l'icône d'origine en niveaux de gris." & return & ¬
		"  • Personnalisée — utilise une image (PNG, ICNS, JPG…) en remplacement.", ¬
		{"Personnalisée", "Noir & blanc", "Teinte couleur"}, "App Cloner")
	if iconChoice is "Teinte couleur" then
		set iconMode to "tint"
		set colorList to choose color default color {52428, 0, 0}
		set colorHex to my rgbToHex(item 1 of colorList, item 2 of colorList, item 3 of colorList)
	else if iconChoice is "Noir & blanc" then
		set iconMode to "bw"
		-- Color ignored downstream but we still need a placeholder for the shell
		set colorHex to "#808080"
	else
		set iconMode to "custom"
		set colorHex to "#000000"
		try
			set iconAlias to choose file ¬
				with prompt "Image à utiliser pour l'icône" ¬
				of type {"public.image", "com.apple.icns"}
			set iconPath to POSIX path of iconAlias
		on error
			-- Cancellation in the file picker → fall back to default red tint
			set iconMode to "tint"
			set colorHex to "#CC0000"
		end try
	end if
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
	set go to my chooseButton("Récapitulatif", summary, {"Annuler", "Créer le clone"}, "App Cloner")
	if go is "Annuler" then return

	do shell script "chmod +x " & quoted form of cloneScript

	set cmd to quoted form of cloneScript ¬
		& " " & quoted form of sourcePath ¬
		& " " & quoted form of cloneName ¬
		& " " & quoted form of colorHex ¬
		& " " & quoted form of openArg ¬
		& " " & quoted form of iconMode ¬
		& " " & quoted form of iconPath
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
