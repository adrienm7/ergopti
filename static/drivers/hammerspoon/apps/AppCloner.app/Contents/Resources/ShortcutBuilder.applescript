-- apps/AppCloner.app/Contents/Resources/ShortcutBuilder.applescript
--
-- Interface utilisateur pour App Cloner.
-- Permet de créer un clone léger d'une application macOS existante avec :
--   • nom et icône personnalisés (teinte de couleur, N&B, ou image custom)
--   • bundle ID unique (pas de regroupement Dock avec l'originale)
--   • argument d'ouverture optionnel (fichier, dossier, ou URL scheme)

use AppleScript version "2.4"
use framework "Foundation"
use framework "AppKit"
use scripting additions

-- Saisie texte via NSAlert + NSTextField. Contrairement à `display dialog with
-- default answer` qui n'expose pas de menu Edit, NSTextField hérite de la
-- responder chain Cocoa standard → Cmd+C/V/X/A fonctionnent nativement.
on askText(prompt, defaultValue, dialogTitle)
	set anAlert to current application's NSAlert's alloc()'s init()
	anAlert's setMessageText:dialogTitle
	anAlert's setInformativeText:prompt
	set inputField to current application's NSTextField's alloc()'s initWithFrame:(current application's NSMakeRect(0, 0, 420, 24))
	inputField's setStringValue:defaultValue
	anAlert's setAccessoryView:inputField
	anAlert's addButtonWithTitle:"OK"
	anAlert's addButtonWithTitle:"Annuler"
	-- Focus sur le champ texte au lieu du bouton, pour pouvoir coller direct
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

-- Convertit trois composantes RGB 0-65535 en chaîne hexadécimale CSS (#RRGGBB)
on rgbToHex(r, g, b)
	set r8 to r div 257
	set g8 to g div 257
	set b8 to b div 257
	return do shell script "printf '#%02X%02X%02X' " & r8 & " " & g8 & " " & b8
end rgbToHex

on run argv
	-- Forcer App Cloner au premier plan (et changer de Space si besoin) à
	-- chaque relance. Sans ça, après être allé dans Teams pour copier un
	-- lien, cliquer sur l'icône AppCloner du Dock ne ramène pas la fenêtre
	-- de saisie au premier plan.
	tell me to activate

	-- argv[1] : répertoire absolu du bundle, passé par MacOS/AppCloner via $APPROOT
	if argv is {} or item 1 of argv is "" then
		display dialog "Erreur : chemin du bundle manquant. Lancez l'app normalement." buttons {"OK"} default button 1
		return
	end if
	set appDir to item 1 of argv
	set cloneScript to appDir & "/Contents/Resources/clone_app.sh"

	logmsg("--- App Cloner démarrage " & (do shell script "date"))
	logmsg("appDir: " & appDir)

	-- ── 1) Choix de l'application source ───────────────────────────────────
	set sourceFile to choose file ¬
		with prompt "Choisir l'application à cloner :" ¬
		default location (POSIX file "/Applications") ¬
		of type {"com.apple.application-bundle"}
	set sourcePath to POSIX path of sourceFile
	logmsg("source: " & sourcePath)

	-- Nom par défaut = nom de l'app source sans .app
	set defaultName to do shell script "basename " & quoted form of sourcePath & " .app"
	logmsg("defaultName: " & defaultName)

	-- ── 2) Nom du clone ─────────────────────────────────────────────────────
	tell me to activate
	set cloneName to my askText("Choisis un nom (apparaîtra sous l'icône du Dock) :", defaultName & " — Clone", "Nom du clone")
	if cloneName is "" then set cloneName to defaultName & " Clone"
	logmsg("cloneName: " & cloneName)

	-- ── 3) Argument d'ouverture (optionnel) ─────────────────────────────────
	-- Trois cas : rien, un dossier (VSCode), ou une URL/chemin libre. Les URLs
	-- type msteams:/l/chat/… ou outlook://calendar permettent d'ouvrir Teams,
	-- Outlook, Slack, Spotify, Notion… directement sur une vue spécifique.
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

	-- ── 4) Type d'icône ─────────────────────────────────────────────────────
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
		-- Couleur ignorée mais on doit fournir quelque chose au shell
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
			-- Annulation → on retombe sur teinte rouge par défaut
			set iconMode to "tint"
			set colorHex to "#CC0000"
		end try
	end if
	logmsg("iconMode: " & iconMode & "  iconPath: " & iconPath & "  colorHex: " & colorHex)

	-- ── 5) Confirmation et création ─────────────────────────────────────────
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

	-- Lancement du script en arrière-plan + polling. Un fichier sentinelle
	-- /tmp/appcloner_done est créé à la fin pour signaler la complétion.
	-- La barre de progression avance pendant que le shell tourne — elle est
	-- volontairement asymptotique (n'atteint 95 % qu'au bout de ~5 s) puis
	-- saute à 100 % dès que le sentinel apparaît.
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
		-- Courbe asymptotique : ~95 % au bout de ~7 s
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

	-- Récupérer le résultat (dernière ligne de stdout) et l'éventuelle erreur
	set raw to do shell script "cat /tmp/appcloner_result 2>/dev/null || echo ''"
	set result_path to do shell script "tail -n 1 /tmp/appcloner_result 2>/dev/null || echo ''"
	logmsg("résultat: " & result_path)

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

	-- Dialog de succès. On garde le texte court avec un saut de ligne avant
	-- ET après le contenu pour équilibrer les marges visuelles haut/bas.
	-- Le chemin du clone n'est pas répété puisque le nom est déjà dans la
	-- ligne d'introduction — l'utilisateur sait où chercher (~/Applications).
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
