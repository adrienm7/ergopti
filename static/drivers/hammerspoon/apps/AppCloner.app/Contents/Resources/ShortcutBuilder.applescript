-- apps/AppCloner.app/Contents/Resources/ShortcutBuilder.applescript
--
-- Interface utilisateur pour App Cloner.
-- Permet de créer un clone léger d'une application macOS existante avec :
--   • nom et icône personnalisés (teinte de couleur)
--   • bundle ID unique (pas de regroupement Dock avec l'originale)
--   • argument d'ouverture optionnel (fichier ou dossier)

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
	set cloneName to text returned of (display dialog ¬
		"Nom du clone :" ¬
		default answer (defaultName & " — Clone") ¬
		buttons {"Annuler", "Suivant"} default button 2)
	if cloneName is "" then set cloneName to defaultName & " Clone"
	logmsg("cloneName: " & cloneName)

	-- ── 3) Argument d'ouverture (optionnel) ─────────────────────────────────
	set openArgAnswer to button returned of (display dialog ¬
		"Ouvrir un fichier ou dossier spécifique au lancement ?" ¬
		buttons {"Non", "Choisir…"} default button 1)
	set openArg to ""
	if openArgAnswer is "Choisir…" then
		try
			set openAlias to choose folder ¬
				with prompt "Dossier à ouvrir avec le clone :"
			set openArg to POSIX path of openAlias
			logmsg("openArg: " & openArg)
		on error
			set openArg to ""
		end try
	end if

	-- ── 4) Couleur de teinte ────────────────────────────────────────────────
	set colorList to choose color default color {52428, 0, 0}
	set colorHex to my rgbToHex(item 1 of colorList, item 2 of colorList, item 3 of colorList)
	logmsg("colorHex: " & colorHex)

	-- ── 5) Confirmation et création ─────────────────────────────────────────
	set openArgDisplay to "(aucun)"
	if openArg is not "" then set openArgDisplay to openArg
	set summary to "Récapitulatif :" & return & return ¬
		& "• Source : " & sourcePath & return ¬
		& "• Nom    : " & cloneName & return ¬
		& "• Teinte : " & colorHex & return ¬
		& "• Arg    : " & openArgDisplay
	set go to button returned of (display dialog summary ¬
		buttons {"Annuler", "Créer le clone"} default button 2)
	if go is "Annuler" then return

	do shell script "chmod +x " & quoted form of cloneScript

	set cmd to quoted form of cloneScript ¬
		& " " & quoted form of sourcePath ¬
		& " " & quoted form of cloneName ¬
		& " " & quoted form of colorHex ¬
		& " " & quoted form of openArg
	logmsg("cmd: " & cmd)

	-- Afficher une progress bar pendant la création (bloquante mais informative)
	tell application "System Events"
		set progressDescription to "Création du clone en cours…"
		set progressAdditionalDescription to "Extraction de l'icône, application de la teinte, génération du bundle…"
		set progress total steps to -1
		set progress completed steps to 0
		set progress description to progressDescription
		set progress additional description to progressAdditionalDescription
	end tell

	try
		set result_path to do shell script cmd
		tell application "System Events"
			set progress total steps to 0
		end tell
		logmsg("résultat: " & result_path)
		set dlg to display dialog "Clone créé avec succès :" & return & result_path ¬
			buttons {"Ouvrir Applications", "OK"} default button 2
		if button returned of dlg is "Ouvrir Applications" then
			do shell script "open ~/Applications"
		end if
	on error errMsg
		tell application "System Events"
			set progress total steps to 0
		end tell
		logmsg("erreur: " & errMsg)
		display dialog "Erreur lors de la création du clone :" & return & errMsg ¬
			buttons {"OK"} default button 1
	end try
end run
