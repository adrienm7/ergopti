-- utils/encryptor/encryptor.applescript

-- ==============================================================================
-- MODULE: Encryptor AppleScript Payload
-- DESCRIPTION:
-- The core logic for the Encryptor application.
-- Handles GUI, CLI, and Droplet modes to encrypt or decrypt keylogger files.
--
-- FEATURES & RATIONALE:
-- 1. Tri-Mode Operation: Runs via GUI, Droplet, or CLI for Hammerspoon.
-- 2. Hardware-Bound: Fetches the Mac serial number for the encryption key.
-- 3. Unicode Safe: Uses character IDs to prevent encoding issues (???).
-- ==============================================================================





-- =====================================
-- =====================================
-- ======= 1/ Hardware Identity ========
-- =====================================
-- =====================================

on getLocalSerial()
	set macSerial to ""
	
	-- Method 1: Direct I/O Kit registry access
	try
		set macSerial to do shell script "ioreg -l | grep IOPlatformSerialNumber | sed 's/.*= \"//;s/\"//'"
	end try
	
	-- Method 2: System Profiler fallback for MDM-restricted Macs
	if macSerial is "" or macSerial contains "UNKNOWN" then
		try
			set macSerial to do shell script "system_profiler SPHardwareDataType | awk '/Serial Number/ {print $4}'"
		end try
	end if
	
	-- Method 3: Hardware UUID fallback
	if macSerial is "" then
		try
			set macSerial to do shell script "ioreg -rd1 -c IOPlatformExpertDevice | grep -E 'IOPlatformUUID' | sed 's/.*= \"//;s/\"//'"
		end try
	end if
	
	-- Method 4: Dynamic Volume UUID fallback
	if macSerial is "" then
		try
			set macSerial to do shell script "diskutil info / | awk '/Volume UUID/ {print $3}'"
		end try
	end if
	
	-- Method 5: Ultimate failsafe to local username
	if macSerial is "" then
		try
			set macSerial to do shell script "id -un"
		end try
	end if
	
	-- Remove spaces and newlines strictly
	set macSerial to do shell script "echo " & quoted form of macSerial & " | tr -d '[:space:]'"
	
	return macSerial
end getLocalSerial





-- =====================================
-- =====================================
-- ======= 2/ Core Processing ==========
-- =====================================
-- =====================================

on processFiles(theFiles, macSerial, isSilent)
	set successCount to 0
	set errorCount to 0
	set totalCount to count of theFiles
	
	-- Character IDs for UI
	set iconCheck to (character id 9989) -- ?
	set iconCross to (character id 10060) -- ?
	
	-- Communicate start status to Hammerspoon IPC
	do shell script "echo \"0\n\" & totalCount & \"\n0\n0\nprocessing\" > /tmp/.ergopti_encryptor_status"
	
	set i to 1
	repeat with f in theFiles
		if class of f is text then
			set filePath to f
		else
			set filePath to POSIX path of f
		end if
		
		try
			if filePath ends with ".gz.enc" then
				set outFile to text 1 thru -8 of filePath
				do shell script "openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"" & macSerial & "\" -in " & quoted form of filePath & " | gzip -d > " & quoted form of outFile
				do shell script "rm " & quoted form of filePath
				set successCount to successCount + 1
			else if filePath ends with ".enc" then
				set outFile to text 1 thru -5 of filePath
				do shell script "openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"" & macSerial & "\" -in " & quoted form of filePath & " > " & quoted form of outFile
				do shell script "rm " & quoted form of filePath
				set successCount to successCount + 1
			else if filePath ends with ".gz" then
				set outFile to filePath & ".enc"
				do shell script "openssl enc -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"" & macSerial & "\" -in " & quoted form of filePath & " > " & quoted form of outFile
				do shell script "rm " & quoted form of filePath
				set successCount to successCount + 1
			else if filePath ends with ".log" then
				set outFile to filePath & ".gz.enc"
				do shell script "gzip -c " & quoted form of filePath & " | openssl enc -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"" & macSerial & "\" > " & quoted form of outFile
				do shell script "rm " & quoted form of filePath
				set successCount to successCount + 1
			end if
		on error
			set errorCount to errorCount + 1
		end try
		
		do shell script "echo \"" & i & "\n\" & totalCount & \"\n\" & successCount & \"\n\" & errorCount & \"\nprocessing\" > /tmp/.ergopti_encryptor_status"
		set i to i + 1
	end repeat
	
	do shell script "echo \"" & totalCount & "\n\" & totalCount & \"\n\" & successCount & \"\n\" & errorCount & \"\ndone\" > /tmp/.ergopti_encryptor_status"
	
	if not isSilent then
		display alert "OpŽration terminŽe" message iconCheck & " Fichiers traitŽs avec succs : " & successCount & return & iconCross & " Erreurs : " & errorCount
	end if
end processFiles





-- ===============================
-- ===============================
-- ======= 3/ Entry Points =======
-- ===============================
-- ===============================

on run argv
	set hasArgs to false
	try
		if class of argv is list then set hasArgs to true
	end try

	if hasArgs and (count of argv) > 0 then
		set macSerial to getLocalSerial()
		set fileList to {}
		
		set i to 1
		repeat while i <= count of argv
			set arg to item i of argv
			if arg is "--serial" and i < (count of argv) then
				set macSerial to item (i + 1) of argv
				set i to i + 2
			else
				set end of fileList to arg
				set i to i + 1
			end if
		end repeat
		
		if (count of fileList) > 0 then
			processFiles(fileList, macSerial, true)
			return
		end if
	end if

	-- Character IDs for GUI
	set iconShield to (character id 128737) -- ???
	set iconLight to (character id 128161) -- ??
	set iconKey to (character id 128273) -- ??

	set localSerial to getLocalSerial()
	set infoMsg to iconShield & " Utilitaire de SŽcuritŽ Encryptor" & return & return & "Cet outil permet de chiffrer ou dŽchiffrer vos fichiers de logs de faon sŽcurisŽe." & return & return & iconLight & "ASTUCE : Vous pouvez directement glisser-dŽposer vos fichiers ou double-cliquer sur un fichier .enc pour le dŽchiffrer instantanŽment !" & return & return & iconKey & " ClŽ de sŽcuritŽ (laissez la valeur par dŽfaut pour utiliser ce Mac) :"
	
	try
		set dialogResult to display dialog infoMsg default answer localSerial buttons {"Quitter", "Choisir des fichiers..."} default button 2 with title "Encryptor"
		if button returned of dialogResult is "Quitter" then return
		set macSerial to text returned of dialogResult
	on error
		return
	end try
	
	set theFiles to choose file with prompt "SŽlectionnez les fichiers (.log, .gz ou .enc) :" with multiple selections allowed
	processFiles(theFiles, macSerial, false)
end run





-- =================================
-- ===== 3.1) Droplet Handler ======
-- =================================

on open theFiles
	set isSilent to false
	set macSerial to getLocalSerial()
	
	try
		set cliArgs to do shell script "cat /tmp/.ergopti_encryptor_cli 2>/dev/null"
		if cliArgs is not "" then
			set isSilent to true
			if cliArgs is not "LOCAL" then set macSerial to cliArgs
			do shell script "rm /tmp/.ergopti_encryptor_cli"
		end if
	end try
	
	processFiles(theFiles, macSerial, isSilent)
end open
