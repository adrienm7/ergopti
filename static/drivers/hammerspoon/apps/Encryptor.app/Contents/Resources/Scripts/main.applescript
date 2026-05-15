-- apps/Encryptor.app/Contents/Resources/Scripts/main.applescript
--
-- Encryptor: chiffre ou déchiffre n'importe quel fichier via openssl AES-256-CBC.
-- Détection automatique : si le fichier se termine par .enc → déchiffrement,
-- sinon → chiffrement. Le fichier chiffré reçoit l'extension .enc ;
-- le fichier déchiffré perd cette extension (ex. rapport.pdf.enc → rapport.pdf).
--
-- Locale : lit ERGOPTI_LOCALE (injecté par menu_apps.lua) en priorité,
-- puis le préfixe ISO-2 de $LANG, puis "en" par défaut.
-- Les chaînes UI sont définies dans le handler ui_strings() et couvrent
-- fr, en, de, es, it, pt, nl, pl, ja, zh — fallback en anglais.
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

-- Return a record with all UI strings for the given locale code.
-- Unsupported locales fall back to English.
on ui_strings(loc)
	-- French
	if loc is "fr" then
		return {¬
			title_encrypt: "Chiffrer le fichier", ¬
			title_decrypt: "Déchiffrer le fichier", ¬
			prompt_password: "Mot de passe :", ¬
			prompt_confirm: "Confirmer le mot de passe :", ¬
			btn_encrypt: "Chiffrer", ¬
			btn_decrypt: "Déchiffrer", ¬
			btn_cancel: "Annuler", ¬
			err_empty_password: "Le mot de passe ne peut pas être vide.", ¬
			err_password_mismatch: "Les mots de passe ne correspondent pas.", ¬
			err_file_missing: "Fichier introuvable.", ¬
			err_openssl_missing: "openssl est introuvable. Installez les Xcode Command Line Tools.", ¬
			err_encrypt_failed: "Le chiffrement a échoué.", ¬
			err_decrypt_failed: "Le déchiffrement a échoué. Mot de passe incorrect ou fichier corrompu ?", ¬
			success_encrypted: "Fichier chiffré :", ¬
			success_decrypted: "Fichier déchiffré :", ¬
			btn_reveal: "Afficher dans le Finder", ¬
			btn_close: "Fermer", ¬
			warn_overwrite: "Un fichier de destination existe déjà. Écraser ?", ¬
			btn_overwrite: "Écraser", ¬
			lbl_file: "Fichier :"}
	-- German
	else if loc is "de" then
		return {¬
			title_encrypt: "Datei verschlüsseln", ¬
			title_decrypt: "Datei entschlüsseln", ¬
			prompt_password: "Passwort:", ¬
			prompt_confirm: "Passwort bestätigen:", ¬
			btn_encrypt: "Verschlüsseln", ¬
			btn_decrypt: "Entschlüsseln", ¬
			btn_cancel: "Abbrechen", ¬
			err_empty_password: "Das Passwort darf nicht leer sein.", ¬
			err_password_mismatch: "Die Passwörter stimmen nicht überein.", ¬
			err_file_missing: "Datei nicht gefunden.", ¬
			err_openssl_missing: "openssl nicht gefunden. Installieren Sie die Xcode Command Line Tools.", ¬
			err_encrypt_failed: "Verschlüsselung fehlgeschlagen.", ¬
			err_decrypt_failed: "Entschlüsselung fehlgeschlagen. Falsches Passwort oder beschädigte Datei?", ¬
			success_encrypted: "Datei verschlüsselt:", ¬
			success_decrypted: "Datei entschlüsselt:", ¬
			btn_reveal: "Im Finder anzeigen", ¬
			btn_close: "Schließen", ¬
			warn_overwrite: "Eine Zieldatei existiert bereits. Überschreiben?", ¬
			btn_overwrite: "Überschreiben", ¬
			lbl_file: "Datei:"}
	-- Spanish
	else if loc is "es" then
		return {¬
			title_encrypt: "Cifrar archivo", ¬
			title_decrypt: "Descifrar archivo", ¬
			prompt_password: "Contraseña:", ¬
			prompt_confirm: "Confirmar contraseña:", ¬
			btn_encrypt: "Cifrar", ¬
			btn_decrypt: "Descifrar", ¬
			btn_cancel: "Cancelar", ¬
			err_empty_password: "La contraseña no puede estar vacía.", ¬
			err_password_mismatch: "Las contraseñas no coinciden.", ¬
			err_file_missing: "Archivo no encontrado.", ¬
			err_openssl_missing: "openssl no encontrado. Instale las Xcode Command Line Tools.", ¬
			err_encrypt_failed: "El cifrado ha fallado.", ¬
			err_decrypt_failed: "El descifrado ha fallado. ¿Contraseña incorrecta o archivo dañado?", ¬
			success_encrypted: "Archivo cifrado:", ¬
			success_decrypted: "Archivo descifrado:", ¬
			btn_reveal: "Mostrar en Finder", ¬
			btn_close: "Cerrar", ¬
			warn_overwrite: "Ya existe un archivo de destino. ¿Sobrescribir?", ¬
			btn_overwrite: "Sobrescribir", ¬
			lbl_file: "Archivo:"}
	-- Italian
	else if loc is "it" then
		return {¬
			title_encrypt: "Cifra il file", ¬
			title_decrypt: "Decifra il file", ¬
			prompt_password: "Password:", ¬
			prompt_confirm: "Conferma password:", ¬
			btn_encrypt: "Cifra", ¬
			btn_decrypt: "Decifra", ¬
			btn_cancel: "Annulla", ¬
			err_empty_password: "La password non può essere vuota.", ¬
			err_password_mismatch: "Le password non corrispondono.", ¬
			err_file_missing: "File non trovato.", ¬
			err_openssl_missing: "openssl non trovato. Installa gli Xcode Command Line Tools.", ¬
			err_encrypt_failed: "La cifratura è fallita.", ¬
			err_decrypt_failed: "La decifratura è fallita. Password errata o file corrotto?", ¬
			success_encrypted: "File cifrato:", ¬
			success_decrypted: "File decifrato:", ¬
			btn_reveal: "Mostra nel Finder", ¬
			btn_close: "Chiudi", ¬
			warn_overwrite: "Esiste già un file di destinazione. Sovrascrivere?", ¬
			btn_overwrite: "Sovrascrivi", ¬
			lbl_file: "File:"}
	-- Portuguese
	else if loc is "pt" then
		return {¬
			title_encrypt: "Cifrar arquivo", ¬
			title_decrypt: "Decifrar arquivo", ¬
			prompt_password: "Senha:", ¬
			prompt_confirm: "Confirmar senha:", ¬
			btn_encrypt: "Cifrar", ¬
			btn_decrypt: "Decifrar", ¬
			btn_cancel: "Cancelar", ¬
			err_empty_password: "A senha não pode estar vazia.", ¬
			err_password_mismatch: "As senhas não coincidem.", ¬
			err_file_missing: "Arquivo não encontrado.", ¬
			err_openssl_missing: "openssl não encontrado. Instale as Xcode Command Line Tools.", ¬
			err_encrypt_failed: "A cifragem falhou.", ¬
			err_decrypt_failed: "A decifragem falhou. Senha incorreta ou arquivo corrompido?", ¬
			success_encrypted: "Arquivo cifrado:", ¬
			success_decrypted: "Arquivo decifrado:", ¬
			btn_reveal: "Mostrar no Finder", ¬
			btn_close: "Fechar", ¬
			warn_overwrite: "Já existe um arquivo de destino. Substituir?", ¬
			btn_overwrite: "Substituir", ¬
			lbl_file: "Arquivo:"}
	-- Dutch
	else if loc is "nl" then
		return {¬
			title_encrypt: "Bestand versleutelen", ¬
			title_decrypt: "Bestand ontsleutelen", ¬
			prompt_password: "Wachtwoord:", ¬
			prompt_confirm: "Wachtwoord bevestigen:", ¬
			btn_encrypt: "Versleutelen", ¬
			btn_decrypt: "Ontsleutelen", ¬
			btn_cancel: "Annuleren", ¬
			err_empty_password: "Het wachtwoord mag niet leeg zijn.", ¬
			err_password_mismatch: "De wachtwoorden komen niet overeen.", ¬
			err_file_missing: "Bestand niet gevonden.", ¬
			err_openssl_missing: "openssl niet gevonden. Installeer de Xcode Command Line Tools.", ¬
			err_encrypt_failed: "Versleuteling mislukt.", ¬
			err_decrypt_failed: "Ontsleuteling mislukt. Verkeerd wachtwoord of beschadigd bestand?", ¬
			success_encrypted: "Bestand versleuteld:", ¬
			success_decrypted: "Bestand ontsleuteld:", ¬
			btn_reveal: "Toon in Finder", ¬
			btn_close: "Sluiten", ¬
			warn_overwrite: "Er bestaat al een doelbestand. Overschrijven?", ¬
			btn_overwrite: "Overschrijven", ¬
			lbl_file: "Bestand:"}
	-- Polish
	else if loc is "pl" then
		return {¬
			title_encrypt: "Zaszyfruj plik", ¬
			title_decrypt: "Odszyfruj plik", ¬
			prompt_password: "Hasło:", ¬
			prompt_confirm: "Potwierdź hasło:", ¬
			btn_encrypt: "Szyfruj", ¬
			btn_decrypt: "Odszyfruj", ¬
			btn_cancel: "Anuluj", ¬
			err_empty_password: "Hasło nie może być puste.", ¬
			err_password_mismatch: "Hasła nie są zgodne.", ¬
			err_file_missing: "Plik nie znaleziony.", ¬
			err_openssl_missing: "openssl nie znaleziony. Zainstaluj Xcode Command Line Tools.", ¬
			err_encrypt_failed: "Szyfrowanie nie powiodło się.", ¬
			err_decrypt_failed: "Deszyfrowanie nie powiodło się. Błędne hasło lub uszkodzony plik?", ¬
			success_encrypted: "Plik zaszyfrowany:", ¬
			success_decrypted: "Plik odszyfrowany:", ¬
			btn_reveal: "Pokaż w Finderze", ¬
			btn_close: "Zamknij", ¬
			warn_overwrite: "Plik docelowy już istnieje. Nadpisać?", ¬
			btn_overwrite: "Nadpisz", ¬
			lbl_file: "Plik:"}
	-- Japanese
	else if loc is "ja" then
		return {¬
			title_encrypt: "ファイルを暗号化", ¬
			title_decrypt: "ファイルを復号", ¬
			prompt_password: "パスワード：", ¬
			prompt_confirm: "パスワード確認：", ¬
			btn_encrypt: "暗号化", ¬
			btn_decrypt: "復号", ¬
			btn_cancel: "キャンセル", ¬
			err_empty_password: "パスワードを入力してください。", ¬
			err_password_mismatch: "パスワードが一致しません。", ¬
			err_file_missing: "ファイルが見つかりません。", ¬
			err_openssl_missing: "opensslが見つかりません。Xcode Command Line Toolsをインストールしてください。", ¬
			err_encrypt_failed: "暗号化に失敗しました。", ¬
			err_decrypt_failed: "復号に失敗しました。パスワードが違うか、ファイルが破損しています。", ¬
			success_encrypted: "暗号化完了：", ¬
			success_decrypted: "復号完了：", ¬
			btn_reveal: "Finderで表示", ¬
			btn_close: "閉じる", ¬
			warn_overwrite: "同名のファイルが既に存在します。上書きしますか？", ¬
			btn_overwrite: "上書き", ¬
			lbl_file: "ファイル："}
	-- Chinese
	else if loc is "zh" then
		return {¬
			title_encrypt: "加密文件", ¬
			title_decrypt: "解密文件", ¬
			prompt_password: "密码：", ¬
			prompt_confirm: "确认密码：", ¬
			btn_encrypt: "加密", ¬
			btn_decrypt: "解密", ¬
			btn_cancel: "取消", ¬
			err_empty_password: "密码不能为空。", ¬
			err_password_mismatch: "两次输入的密码不一致。", ¬
			err_file_missing: "文件未找到。", ¬
			err_openssl_missing: "未找到 openssl。请安装 Xcode Command Line Tools。", ¬
			err_encrypt_failed: "加密失败。", ¬
			err_decrypt_failed: "解密失败。密码错误或文件已损坏？", ¬
			success_encrypted: "文件已加密：", ¬
			success_decrypted: "文件已解密：", ¬
			btn_reveal: "在 Finder 中显示", ¬
			btn_close: "关闭", ¬
			warn_overwrite: "目标文件已存在。是否覆盖？", ¬
			btn_overwrite: "覆盖", ¬
			lbl_file: "文件："}
	-- English (default)
	else
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
	end if
end ui_strings


-- ================================================
-- ================================================
-- ======= 2/ Password dialog (hidden input) =======
-- ================================================
-- ================================================

-- Ask for a password using a secure dialog (text is hidden).
-- Returns the entered string, or throws error -128 on cancel.
on ask_password(prompt_text, dialog_title)
	set r to display dialog prompt_text with title dialog_title ¬
		default answer "" with hidden answer ¬
		buttons {"Annuler", "OK"} default button "OK" cancel button "Annuler"
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
	set s to my ui_strings(loc)

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
			set the_password to my ask_password(prompt_password of s, dialog_title)
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
					set confirm_pw to my ask_password(prompt_confirm of s, dialog_title)
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
	set s to my ui_strings(loc)

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
