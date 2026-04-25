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
		display dialog "❌  Échec de la création du clone." & return & return ¬
			& "Détails : " & raw ¬
			buttons {"OK"} default button 1 with title "App Cloner"
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
