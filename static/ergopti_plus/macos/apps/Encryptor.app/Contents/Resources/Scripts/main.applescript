-- apps/Encryptor.app/Contents/Resources/Scripts/main.applescript
--
-- Encryptor: chiffre ou déchiffre n'importe quel fichier via openssl AES-256-CBC.
-- Détection automatique : si le fichier se termine par .enc → déchiffrement,
-- sinon → chiffrement. Le fichier chiffré reçoit l'extension .enc ;
-- le fichier déchiffré perd cette extension (ex. rapport.pdf.enc → rapport.pdf).
--
-- Locale : lit ERGOPTI_LOCALE (injecté par menu_apps.lua) en priorité,
-- puis le préfixe ISO-2 de $LANG, puis "en" par défaut.
-- Les chaînes UI sont chargées depuis le fichier JSON
-- <ERGOPTI_LOCALES_DIR>/<code>.json (injecté par menu_apps.lua).
-- Cela couvre automatiquement toutes les locales supportées par Ergopti.
--
-- Compilation : osacompile -o main.scpt main.applescript
-- (à lancer sur macOS depuis le dossier Scripts/).

use AppleScript version "2.4"
use scripting additions


-- =========================================
-- =========================================
-- ======= 1/ Locale & UI strings ==========
-- =========================================
-- =========================================

-- Resolve the active locale code from the environment.
-- Priority: ERGOPTI_LOCALE → $LANG prefix → "en".
on resolve_locale()
	set loc to ""
	try
		set loc to do shell script "echo \"$ERGOPTI_LOCALE\""
	end try
	if loc is "" then
		try
			set lang_val to do shell script "echo \"$LANG\""
			if (length of lang_val) >= 2 then
				set loc to text 1 thru 2 of lang_val
			end if
		end try
	end if
	if loc is "" then set loc to "en"
	return loc
end resolve_locale

-- Extract a single string value from a JSON file by key, using grep+sed.
-- Returns the fallback string if the key is not found or the file does not exist.
-- This approach requires no external tools beyond macOS-native grep/sed.
on json_get(json_path, json_key, fallback)
	try
		-- grep finds the line containing the key, sed strips the surrounding JSON syntax.
		-- The pattern matches: "key": "value" and extracts value.
		set cmd to "grep -m1 '\"" & json_key & "\"' " & quoted form of json_path ¬
			& " | sed 's/.*\"" & json_key & "\"[[:space:]]*:[[:space:]]*\"//;s/\"[[:space:]]*,\\{0,1\\}[[:space:]]*$//'"
		set val to do shell script cmd
		if val is "" then return fallback
		return val
	on error
		return fallback
	end try
end json_get

-- Load all UI strings for the given locale from the locale JSON file.
-- Falls back to English if the locale file is not found, then to hardcoded
-- English strings as a last resort (so the app always works even without the
-- locales directory).
on load_ui(loc, locales_dir)
	-- Determine which JSON file to read, falling back to English.
	set json_path to locales_dir & "/" & loc & ".json"
	set ok to false
	try
		do shell script "test -f " & quoted form of json_path
		set ok to true
	end try
	if not ok then
		set json_path to locales_dir & "/en.json"
		try
			do shell script "test -f " & quoted form of json_path
		on error
			-- No locale files at all — return hardcoded English strings.
			return my hardcoded_en_strings()
		end try
	end if

	-- Load each string from the JSON file, with inline English fallback.
	return {¬
		title_encrypt: my json_get(json_path, "apps.encryptor.title_encrypt", "Encrypt File"), ¬
		title_decrypt: my json_get(json_path, "apps.encryptor.title_decrypt", "Decrypt File"), ¬
		prompt_password: my json_get(json_path, "apps.encryptor.prompt_password", "Password:"), ¬
		prompt_confirm: my json_get(json_path, "apps.encryptor.prompt_confirm", "Confirm password:"), ¬
		btn_encrypt: my json_get(json_path, "button.encrypt", "Encrypt"), ¬
		btn_decrypt: my json_get(json_path, "button.decrypt", "Decrypt"), ¬
		btn_cancel: my json_get(json_path, "button.cancel", "Cancel"), ¬
		err_empty_password: my json_get(json_path, "apps.encryptor.err_empty_password", "Password cannot be empty."), ¬
		err_password_mismatch: my json_get(json_path, "apps.encryptor.err_password_mismatch", "Passwords do not match."), ¬
		err_file_missing: my json_get(json_path, "apps.encryptor.err_file_missing", "File not found."), ¬
		err_openssl_missing: my json_get(json_path, "apps.encryptor.err_openssl_missing", "openssl not found. Install Xcode Command Line Tools."), ¬
		err_encrypt_failed: my json_get(json_path, "apps.encryptor.err_encrypt_failed", "Encryption failed."), ¬
		err_decrypt_failed: my json_get(json_path, "apps.encryptor.err_decrypt_failed", "Decryption failed. Wrong password or corrupted file?"), ¬
		success_encrypted: my json_get(json_path, "apps.encryptor.success_encrypted", "File encrypted:"), ¬
		success_decrypted: my json_get(json_path, "apps.encryptor.success_decrypted", "File decrypted:"), ¬
		btn_reveal: my json_get(json_path, "apps.encryptor.btn_reveal", "Show in Finder"), ¬
		btn_close: my json_get(json_path, "common.close", "Close"), ¬
		warn_overwrite: my json_get(json_path, "apps.encryptor.warn_overwrite", "A destination file already exists. Overwrite?"), ¬
		btn_overwrite: my json_get(json_path, "apps.encryptor.btn_overwrite", "Overwrite"), ¬
		lbl_file: my json_get(json_path, "apps.encryptor.lbl_file", "File:")}
end load_ui

-- Hardcoded English strings used only when the locales directory is unavailable.
on hardcoded_en_strings()
	return {¬
		title_encrypt: "Encrypt File", ¬
		title_decrypt: "Decrypt File", ¬
		prompt_password: "Password:", ¬
		prompt_confirm: "Confirm password:", ¬
		btn_encrypt: "Encrypt", ¬
		btn_decrypt: "Decrypt", ¬
		btn_cancel: "Cancel", ¬
		err_empty_password: "Password cannot be empty.", ¬
		err_password_mismatch: "Passwords do not match.", ¬
		err_file_missing: "File not found.", ¬
		err_openssl_missing: "openssl not found. Install Xcode Command Line Tools.", ¬
		err_encrypt_failed: "Encryption failed.", ¬
		err_decrypt_failed: "Decryption failed. Wrong password or corrupted file?", ¬
		success_encrypted: "File encrypted:", ¬
		success_decrypted: "File decrypted:", ¬
		btn_reveal: "Show in Finder", ¬
		btn_close: "Close", ¬
		warn_overwrite: "A destination file already exists. Overwrite?", ¬
		btn_overwrite: "Overwrite", ¬
		lbl_file: "File:"}
end hardcoded_en_strings

-- Resolve the absolute path to the locales directory.
-- Priority: ERGOPTI_LOCALES_DIR (injected by menu_apps.lua) → path relative
-- to the .app bundle's Resources/ folder (for standalone use).
on resolve_locales_dir()
	set d to ""
	try
		set d to do shell script "echo \"$ERGOPTI_LOCALES_DIR\""
	end try
	if d is not "" then return d
	-- Fallback: climb from Scripts/ → Resources/ → Contents/ → .app/ → parent → locales/
	-- This allows the app to work when launched directly from the Finder without
	-- the env var, as long as the locales/ folder is adjacent to the .app bundle.
	try
		set bundle_res to POSIX path of (path to me)
		-- Strip trailing "/Contents/Resources/Scripts/main.scpt" or similar
		set cmd to "d=" & quoted form of bundle_res ¬
			& "; d=$(dirname \"$d\"); d=$(dirname \"$d\"); d=$(dirname \"$d\"); d=$(dirname \"$d\");" ¬
			& " d=$(dirname \"$d\"); d=$(dirname \"$d\"); d=$(dirname \"$d\"); d=$(dirname \"$d\"); echo \"$d/locales\""
		set d to do shell script cmd
	end try
	return d
end resolve_locales_dir


-- ================================================
-- ================================================
-- ======= 2/ Password dialog (hidden input) =======
-- ================================================
-- ================================================

-- Ask for a password using a secure dialog (text is hidden).
-- Returns the entered string, or throws error -128 on cancel.
on ask_password(prompt_text, dialog_title, btn_cancel_label)
	set r to display dialog prompt_text with title dialog_title ¬
		default answer "" with hidden answer ¬
		buttons {btn_cancel_label, "OK"} default button "OK" cancel button btn_cancel_label
	return text returned of r
end ask_password


-- ====================================================
-- ====================================================
-- ======= 3/ Main entry point (open handler) ==========
-- ====================================================
-- ====================================================

-- Called by macOS when files are dropped on the app icon or passed via
-- `open -a Encryptor file1 file2 …`. Each file is processed in sequence.
on open dropped_files
	set loc to my resolve_locale()
	set locales_dir to my resolve_locales_dir()
	set s to my load_ui(loc, locales_dir)

	-- Verify openssl is available once before processing any file.
	try
		do shell script "which openssl"
	on error
		display alert err_openssl_missing of s as critical ¬
			buttons {btn_close of s} default button 1
		return
	end try

	repeat with f in dropped_files
		set file_path to POSIX path of f

		-- Auto-detect mode from extension.
		set is_decrypt to (file_path ends with ".enc")

		if is_decrypt then
			my process_file(file_path, false, s)
		else
			my process_file(file_path, true, s)
		end if
	end repeat
end open


-- ============================================================
-- ============================================================
-- ======= 4/ Per-file processing (encrypt or decrypt) =========
-- ============================================================
-- ============================================================

-- Process a single file: prompt for password, run openssl, report result.
-- is_encrypt=true → encrypt (adds .enc); is_encrypt=false → decrypt (removes .enc).
on process_file(file_path, is_encrypt, s)
	-- Verify the file exists.
	try
		do shell script "test -f " & quoted form of file_path
	on error
		display alert (err_file_missing of s) & return & return & file_path ¬
			as critical buttons {btn_close of s} default button 1
		return
	end try

	-- Determine destination path.
	set dest_path to ""
	if is_encrypt then
		set dest_path to file_path & ".enc"
	else
		-- Strip the trailing .enc extension.
		set dest_path to text 1 thru -5 of file_path
		-- If stripping .enc leaves an empty name, append "_decrypted".
		if dest_path is "" or dest_path ends with "/" then
			set dest_path to file_path & "_decrypted"
		end if
	end if

	-- Warn if destination already exists.
	set dest_exists to false
	try
		do shell script "test -e " & quoted form of dest_path
		set dest_exists to true
	end try
	if dest_exists then
		set overwrite_answer to button returned of ¬
			(display alert (warn_overwrite of s) ¬
				buttons {btn_cancel of s, btn_overwrite of s} ¬
				default button btn_overwrite of s ¬
				cancel button btn_cancel of s)
		if overwrite_answer is (btn_cancel of s) then return
	end if

	-- Collect password (and confirmation for encryption).
	set dialog_title to ""
	if is_encrypt then
		set dialog_title to title_encrypt of s
	else
		set dialog_title to title_decrypt of s
	end if

	set password_ok to false
	set the_password to ""
	repeat until password_ok
		try
			set the_password to my ask_password(prompt_password of s, dialog_title, btn_cancel of s)
		on error number -128
			return
		end try
		if the_password is "" then
			display alert (err_empty_password of s) as warning ¬
				buttons {btn_close of s} default button 1
		else if is_encrypt then
			-- Confirm password for encryption.
			set confirm_ok to false
			repeat until confirm_ok
				set confirm_pw to ""
				try
					set confirm_pw to my ask_password(prompt_confirm of s, dialog_title, btn_cancel of s)
				on error number -128
					return
				end try
				if confirm_pw is the_password then
					set confirm_ok to true
					set password_ok to true
				else
					display alert (err_password_mismatch of s) as warning ¬
						buttons {btn_close of s} default button 1
				end if
			end repeat
		else
			set password_ok to true
		end if
	end repeat

	-- Run openssl.
	-- AES-256-CBC with PBKDF2 key derivation (-pbkdf2 -iter 600000).
	-- -pbkdf2 is supported by the LibreSSL shipped with macOS 10.15+ and
	-- by any OpenSSL 1.1.1+; it eliminates the legacy MD5 key derivation
	-- warning and dramatically increases brute-force cost.
	set openssl_cmd to ""
	if is_encrypt then
		set openssl_cmd to "openssl enc -aes-256-cbc -pbkdf2 -iter 600000" ¬
			& " -in " & quoted form of file_path ¬
			& " -out " & quoted form of dest_path ¬
			& " -pass pass:" & quoted form of the_password
	else
		set openssl_cmd to "openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000" ¬
			& " -in " & quoted form of file_path ¬
			& " -out " & quoted form of dest_path ¬
			& " -pass pass:" & quoted form of the_password
	end if

	set openssl_ok to false
	try
		do shell script openssl_cmd
		set openssl_ok to true
	on error
		-- Remove partial output file on failure.
		try
			do shell script "rm -f " & quoted form of dest_path
		end try
	end try

	if not openssl_ok then
		if is_encrypt then
			display alert (err_encrypt_failed of s) as critical ¬
				buttons {btn_close of s} default button 1
		else
			display alert (err_decrypt_failed of s) as critical ¬
				buttons {btn_close of s} default button 1
		end if
		return
	end if

	-- Report success with option to reveal in Finder.
	set success_msg to ""
	if is_encrypt then
		set success_msg to (success_encrypted of s) & return & dest_path
	else
		set success_msg to (success_decrypted of s) & return & dest_path
	end if

	set result_btn to button returned of ¬
		(display alert success_msg ¬
			buttons {btn_close of s, btn_reveal of s} ¬
			default button btn_reveal of s)

	if result_btn is (btn_reveal of s) then
		do shell script "open -R " & quoted form of dest_path
	end if
end process_file


-- ============================================================
-- ============================================================
-- ======= 5/ run handler (launched without file drop) =========
-- ============================================================
-- ============================================================

-- When launched without a file (double-click from Finder or menu),
-- present a file picker so the user can select a file to process.
on run
	set loc to my resolve_locale()
	set locales_dir to my resolve_locales_dir()
	set s to my load_ui(loc, locales_dir)

	-- Verify openssl is available.
	try
		do shell script "which openssl"
	on error
		display alert (err_openssl_missing of s) as critical ¬
			buttons {btn_close of s} default button 1
		return
	end try

	-- Ask the user to pick a file.
	set chosen to ""
	try
		set chosen to POSIX path of (choose file with prompt (lbl_file of s))
	on error number -128
		return
	end try

	set is_encrypt to not (chosen ends with ".enc")
	my process_file(chosen, is_encrypt, s)
end run
