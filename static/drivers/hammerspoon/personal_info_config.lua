-- Personal information shortcuts configuration
-- ============================================================
-- Edit the values in `info` with your real personal data.
-- The `letters` table maps one letter to one key in `info`.
--
-- Usage: type  @<letters><trigger_char>  anywhere.
--   @np★  →  LastName [Tab] FirstName
--   @e★   →  EmailAddress
--   @npa★ →  LastName [Tab] FirstName [Tab] StreetAddress
--
-- Only letters that appear in the `letters` table are resolved;
-- unrecognised letters inside the combo are silently skipped.
-- ============================================================

return {
	-- Character that triggers expansion (default: ★).
	-- To type this character on a standard keyboard you may need an
	-- autohotkey/karabiner shortcut or copy-paste it once.
	trigger_char = "★",

	-- ----------------------------------------------------------
	-- Personal information — replace dummy values with your own.
	-- ----------------------------------------------------------
	info = {
		FirstName            = "Prénom",
		LastName             = "Nom",
		DateOfBirth          = "01/01/2000",
		EmailAddress         = "prenom.nom@mail.fr",
		WorkEmailAddress     = "prenom.nom@mail.pro",
		PhoneNumber          = "0606060606",
		PhoneNumberFormatted = "06 06 06 06 06",
		StreetAddress        = "1 Rue de la Paix",
		City                 = "Ville",
		Country              = "France",
		PostalCode           = "75000",
		IBAN                 = "FR00 0000 0000 0000 0000 0000 000",
		BIC                  = "ABCDFRPP",
		CreditCard           = "1234 5678 9012 3456",
		SocialSecurityNumber = "1 99 99 99 999 999 99",
	},

	-- ----------------------------------------------------------
	-- Letter → key mapping.
	-- Each single letter is resolved to one field from `info`.
	-- You can add, remove or remap entries freely.
	-- ----------------------------------------------------------
	letters = {
		a = "StreetAddress",
		b = "BIC",
		c = "CreditCard",
		d = "DateOfBirth",
		e = "EmailAddress",
		f = "PhoneNumberFormatted",
		i = "IBAN",
		m = "EmailAddress",
		n = "LastName",
		p = "FirstName",
		s = "SocialSecurityNumber",
		t = "PhoneNumber",
		w = "WorkEmailAddress",
	},
}
