--- infra/native_presentation.lua

--- ==============================================================================
--- MODULE: Native Presentation Receiving
--- DESCRIPTION:
--- Issues opaque bare-caption receipts from the real generated policy and live
--- locale cohort. Callers retain the original native dialog/notification owner.
--- The receiver is the shared one (native_presentation.receiver); this driver
--- only names its platform tag and its translation owners.
--- ==============================================================================

return require("native_presentation").receiver({
	platform = "linux",
	name = "infra.native_presentation",
	i18n = { name = "infra.i18n", module = require("infra.i18n") },
	locale = { name = "infra.locale", module = require("infra.locale") },
	core = { name = "locale.core", module = require("locale.core") },
})
