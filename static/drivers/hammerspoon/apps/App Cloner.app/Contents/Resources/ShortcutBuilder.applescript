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

-- Text input via NSAlert + NSTextField. Unlike `display dialog with default
-- answer`, which has no Edit menu attached, NSTextField inherits the standard
-- Cocoa responder chain so Cmd+C/V/X/A work natively.
on askText(prompt, defaultValue, dialogTitle)
	set anAlert to current application's NSAlert's alloc()'s init()
	anAlert's setMessageText:dialogTitle
	anAlert's setInformativeText:prompt
	set inputField to current application's NSTextField's alloc()'s initWithFrame:(current application's NSMakeRect(0, 0, 420, 24))
	inputField's setStringValue:defaultValue
	anAlert's setAccessoryView:inputField
	anAlert's addButtonWithTitle:"OK"
	anAlert's addButtonWithTitle:"Annuler"
	-- Move focus from the OK button to the text field so the user can paste
	-- a URL immediately on Cmd+V without first tabbing into the field
	(anAlert's |window|()'s makeFirstResponder:inputField)
	set response to anAlert's runModal()
	if response = (current application's NSAlertFirstButtonReturn) then
		return (inputField's stringValue() as text)
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
		with prompt "Choisir l'application à cloner :" ¬
		default location appsFolder ¬
		of type {"com.apple.application-bundle"}
	set sourcePath to POSIX path of sourceFile
	logmsg("source: " & sourcePath)

	-- Default clone name derived from the source app's basename
	set defaultName to do shell script "basename " & quoted form of sourcePath & " .app"
	logmsg("defaultName: " & defaultName)

	-- ===== 2) Clone name =====
	tell me to activate
	set cloneName to my askText("Choisis un nom (apparaîtra sous l'icône du Dock) :", defaultName & " — Clone", "Nom du clone")
	if cloneName is "" then set cloneName to defaultName & " Clone"
	logmsg("cloneName: " & cloneName)

	-- ===== 3) Optional launch argument =====
	-- Three cases: nothing, a folder (VSCode), or a free URL/path. URLs like
	-- msteams:/l/chat/… or ms-outlook://events let Teams/Outlook/Slack/Spotify/
	-- Notion launch directly on a specific view (chat, calendar, channel…).
	tell me to activate
	set openTypeAnswer to button returned of (display dialog ¬
		"Ouvrir quelque chose de spécifique au lancement ?" ¬
		buttons {"Rien", "Dossier", "URL ou chemin"} ¬
		default button 1 ¬
		with title "App Cloner")
	set openArg to ""
	if openTypeAnswer is "Dossier" then
		try
			set openAlias to choose folder with prompt "Dossier à ouvrir avec le clone :"
			set openArg to POSIX path of openAlias
		end try
	else if openTypeAnswer is "URL ou chemin" then
		set urlPrompt to ¬
			"Colle l'URL ou le chemin à ouvrir au lancement (Cmd+V supporté)." & return & return & ¬
			"📅  Outlook calendrier :   ms-outlook://events" & return & ¬
			"📨  Outlook mail :         ms-outlook://" & return & ¬
			"💬  Teams (une conv) :     msteams:/l/chat/0/0?users=foo@bar.com" & return & ¬
			"      → dans Teams : clic-droit sur la conv → « Get link to chat »" & return & ¬
			"📅  Teams calendrier :     msteams:/l/calendar" & return & ¬
			"💼  Slack (une chaîne) :   slack://channel?team=T1234&id=C5678" & return & ¬
			"      → Slack → ⋮ d'une chaîne → « Copy » → « Copy link »" & return & ¬
			"📝  Notion (une page) :    notion://www.notion.so/My-Page-abc123" & return & ¬
			"      → Notion : … en haut de page → « Copy link »" & return & ¬
			"🎵  Spotify (playlist) :   spotify:playlist:37i9dQZF1DXcBWIGoYBM5M" & return & ¬
			"      → clic-droit sur playlist → Share → Copy Spotify URI" & return & ¬
			"🎮  Discord (un salon) :   discord://discord.com/channels/SERVER/CHANNEL" & return & ¬
			"      → Discord : clic-droit sur le salon → « Copy Link »" & return & ¬
			"🌐  Tout site web :        https://example.com" & return & ¬
			"📁  Dossier ou fichier :   /Users/moi/projet"
		try
			set openArg to my askText(urlPrompt, "", "URL ou chemin")
		end try
	end if
	logmsg("openArg: " & openArg)

	-- ===== 4) Icon style =====
	tell me to activate
	set iconMode to "tint"
	set iconPath to ""
	set iconChoice to button returned of (display dialog ¬
		"Style d'icône pour le clone ?" & return & return & ¬
		"  • Teinte couleur : applique une teinte sur l'icône d'origine" & return & ¬
		"  • Noir & blanc : convertit en niveaux de gris" & return & ¬
		"  • Personnalisée : choisir une image (PNG, ICNS, JPG…)" ¬
		buttons {"Personnalisée", "Noir & blanc", "Teinte couleur"} ¬
		default button 3 ¬
		with title "App Cloner")
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
				with prompt "Choisir l'image pour l'icône :" ¬
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
	set summary to "Récapitulatif :" & return & return ¬
		& "• Source : " & sourcePath & return ¬
		& "• Nom    : " & cloneName & return ¬
		& "• Icône  : " & iconDisplay & return ¬
		& "• Ouvre  : " & openArgDisplay
	tell me to activate
	set go to button returned of (display dialog summary ¬
		buttons {"Annuler", "Créer le clone"} default button 2 ¬
		with title "App Cloner")
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
		set errDlg to display dialog "❌  Échec de la création du clone" & return & return ¬
			& "Le diagnostic complet est dans /tmp/clone_diag.log" ¬
			buttons {"Ouvrir le log", "Fermer"} ¬
			default button 1 ¬
			with title "App Cloner"
		if button returned of errDlg is "Ouvrir le log" then
			do shell script "open -e /tmp/clone_diag.log"
		end if
		return
	end if

	-- Success dialog. Short text with a blank line before AND after the body
	-- so the visual padding feels balanced top/bottom. The clone path is not
	-- repeated — the user already sees the name in the headline and knows to
	-- look in ~/Applications.
	set successMsg to "✅  Clone créé avec succès" & return & return & ¬
		"« " & cloneName & " »" & return & ¬
		"a été ajouté au Dock et au dossier Applications."
	set dlg to display dialog successMsg ¬
		buttons {"Ouvrir Applications", "Terminé"} ¬
		default button 2 ¬
		with title "App Cloner"
	if button returned of dlg is "Ouvrir Applications" then
		do shell script "open ~/Applications"
	end if
end run
