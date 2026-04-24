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
	-- argv[1] : répertoire du bundle (passé par l'exécutable MacOS/AppCloner)
	-- Quand l'app est lancée depuis le Dock, argv peut être vide : on le résout
	-- via le chemin du script lui-même grâce à osascript
	set appDir to ""
	if argv is not {} then
		set appDir to item 1 of argv
	end if
	if appDir is "" then
		-- Fallback : remonter depuis Resources/ → Contents/ → bundle root
		set appDir to do shell script "dirname $(dirname $(osascript -e 'POSIX path of (path to me)'))"
	end if
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
			set openAlias to choose file or folder ¬
				with prompt "Fichier ou dossier à ouvrir avec le clone :"
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
	set summary to "Récapitulatif :" & return & return ¬
		& "• Source : " & sourcePath & return ¬
		& "• Nom    : " & cloneName & return ¬
		& "• Teinte : " & colorHex & return ¬
		& "• Arg    : " & (openArg is not "" and openArg or "(aucun)")
	set go to button returned of (display dialog summary ¬
		buttons {"Annuler", "Créer le clone"} default button 2)
	if go is "Annuler" then return

	-- Vérifier que le script shell est exécutable
	try
		do shell script "chmod +x " & quoted form of cloneScript
	end try

	set cmd to quoted form of cloneScript ¬
		& " " & quoted form of sourcePath ¬
		& " " & quoted form of cloneName ¬
		& " " & quoted form of colorHex ¬
		& " " & quoted form of openArg
	logmsg("cmd: " & cmd)

	try
		set result_path to do shell script cmd
		logmsg("résultat: " & result_path)
		set dlg to display dialog "Clone créé avec succès :" & return & result_path ¬
			buttons {"Ouvrir le Bureau", "OK"} default button 2
		if button returned of dlg is "Ouvrir le Bureau" then
			do shell script "open ~/Desktop"
		end if
	on error errMsg
		logmsg("erreur: " & errMsg)
		display dialog "Erreur lors de la création du clone :" & return & errMsg ¬
			buttons {"OK"} default button 1
	end try
end run
