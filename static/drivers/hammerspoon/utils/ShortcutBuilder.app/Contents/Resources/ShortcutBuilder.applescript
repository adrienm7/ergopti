on logmsg(m)
    try
        do shell script "echo " & quoted form of m & " >> " & quoted form of "/tmp/shortcutbuilder-applescript.log"
    end try
end logmsg

on run argv
    -- argv: appDir
    if argv is {} then
        display dialog "Erreur interne: appDir manquant." buttons {"OK"} default button 1
        return
    end if
    set appDir to item 1 of argv

    logmsg("--- ShortcutBuilder start " & (do shell script "date"))
    logmsg("appDir: " & appDir)
    set makeScript to (appDir & "/Contents/Resources/make_shortcut.sh")
    logmsg("makeScript: " & makeScript)

    -- Choisir dossier cible
    set targetAlias to choose folder with prompt "Choisir le dossier à ouvrir"
    set targetPath to POSIX path of targetAlias
    logmsg("target: " & targetPath)

    -- Default name derived from folder: replace _ with space and Title Case each word
    try
        set folderName to do shell script "basename " & quoted form of targetPath
        set defaultName to do shell script "perl -e '$_=shift; s/_/ /g; s/([A-Za-z0-9]+)/ucfirst(lc($1))/ge; print $_' " & quoted form of folderName
    on error
        set defaultName to "Nouvel élément"
    end try
    logmsg("defaultName: " & defaultName)

    -- Choisir application (.app) — ouvrir par défaut dans /Applications
    logmsg("about to choose application")
    set appFile to choose file with prompt "Choisir l'application (sélectionner le .app)" default location (POSIX file "/Applications")
    set appPath to POSIX path of appFile
    logmsg("selected app: " & appPath)

    -- Default label: initials (first letter of up to 3 words of the folder), uppercased
    try
        set labelDefault to do shell script "echo " & quoted form of folderName & " | sed 's/_/ /g' | awk '{for(i=1;i<=NF && i<=3;i++){printf toupper(substr($i,1,1))}}'"
    on error
        set labelDefault to "APP"
    end try
    logmsg("labelDefault: " & labelDefault)

    -- Choisir couleur
    set colorList to choose color default color {45000, 32000, 12000}
    set r8 to (item 1 of colorList) div 257
    set g8 to (item 2 of colorList) div 257
    set b8 to (item 3 of colorList) div 257
    set colorHex to do shell script "printf '#%02X%02X%02X' " & r8 & " " & g8 & " " & b8
    logmsg("colorHex: " & colorHex)

    -- Texte sur l'icône (par défaut 3 premières lettres de l'app en MAJ)
    set labelText to text returned of (display dialog "Texte sur l'icône:" default answer labelDefault)
    -- Nom du raccourci (par défaut le nom du dossier formaté)
    set nameText to text returned of (display dialog "Nom du raccourci (optionnel):" default answer defaultName)
    logmsg("label: " & labelText & " name: " & nameText)

    -- Appel du script shell (make_shortcut.sh)
    set cmd to quoted form of makeScript & " " & quoted form of nameText & " " & quoted form of targetPath & " " & quoted form of appPath & " " & quoted form of colorHex & " " & quoted form of labelText
    logmsg("running cmd: " & cmd)
    -- check existence
    try
        set existsCheck to do shell script "test -x " & quoted form of makeScript & " && echo OK || echo MISSING"
    on error
        set existsCheck to "ERR"
    end try
    logmsg("existsCheck: " & existsCheck)
    try
        set res to do shell script cmd
        logmsg("cmd result: " & res)
        display dialog "Raccourci créé:\n" & res buttons {"OK"} default button 1
    on error errMsg
        logmsg("cmd error: " & errMsg)
        display dialog "Erreur lors de la création:\n" & errMsg buttons {"OK"} default button 1
    end try
end run
