--- _shared/lua/personal_info/defaults.lua

--- ==============================================================================
--- MODULE: Personal-Info First-Boot Defaults (shared)
--- DESCRIPTION:
--- The placeholder [info] values and the shortcut letters written to a missing
--- personal_info.toml at first boot. Pure data: no OS calls and no state.
---
--- FEATURES & RATIONALE:
--- 1. One source. macOS and Linux both materialise the file from this table, so
---    an editor opened on a fresh install shows the same fields on each system.
--- 2. Placeholders only. None of these values is a real person's data.
--- ==============================================================================

local M = {}

M.info = {
	first_name             = "Prénom",
	last_name              = "Nom",
	date_of_birth          = "01/01/1990",
	email_address          = "prenom.nom@exemple.fr",
	work_email_address     = "prenom.nom@entreprise.fr",
	phone_number           = "0600000000",
	phone_number_clean     = "06 00 00 00 00",
	street_address         = "1 Rue de la Paix",
	city                   = "Paris",
	country                = "France",
	postal_code            = "75001",
	iban                   = "FR00 0000 0000 0000 0000 0000 000",
	bic                    = "ABCDFRPP",
	credit_card            = "0000 0000 0000 0000",
	social_security_number = "0 00 00 00 000 000 00",
}

M.letters = {
	a = "street_address",
	b = "bic",
	c = "credit_card",
	d = "date_of_birth",
	e = "email_address",
	f = "phone_number_clean",
	i = "iban",
	m = "email_address",
	n = "last_name",
	p = "first_name",
	s = "social_security_number",
	t = "phone_number",
	w = "work_email_address",
}

return M
