--- infra/native_presentation.lua

--- ==============================================================================
--- MODULE: Native Presentation Receiving
--- DESCRIPTION:
--- Issues opaque bare-caption receipts from the real generated policy and live
--- locale cohort. Callers retain the original native dialog/notification owner.
--- The receiver is the shared one (native_presentation.receiver); this driver
--- only names its platform tag and its translation owners.
--- ==============================================================================

return require("menu.engine.native_presentation_core").receiver({
	platform = "hs",
	name = "infra.native_presentation",
	i18n = { name = "core.i18n.engine.i18n", module = require("core.i18n.engine.i18n") },
	locale = { name = "core.i18n.engine.locale", module = require("core.i18n.engine.locale") },
	core = { name = "core.i18n.engine.core", module = require("core.i18n.engine.core") },
})
