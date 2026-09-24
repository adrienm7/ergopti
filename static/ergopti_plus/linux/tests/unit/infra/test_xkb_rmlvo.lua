--- tests/unit/infra/test_xkb_rmlvo.lua

--- ==============================================================================
--- MODULE: Session Layout Names — parser contract
--- DESCRIPTION:
--- Every fixture is the literal text the desktop tool prints or the file it
--- writes, because the fallback these parsers feed is the ONLY keymap source on
--- a libxkbcommon older than 1.8 without XWayland. A parser that returns nil
--- there leaves the daemon without a keyboard.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("xkb_rmlvo: GNOME input sources", function()

	helpers.it("splits layout+variant and keeps the options", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		local desc = R.parse_gnome("[('xkb', 'fr+ergopti'), ('xkb', 'us')]",
			"['compose:ralt', 'caps:escape']")
		helpers.assert_eq(desc.layout, "fr")
		helpers.assert_eq(desc.variant, "ergopti")
		helpers.assert_eq(desc.options, "compose:ralt,caps:escape")
		helpers.assert_eq(desc.source, "gnome")
	end)

	helpers.it("takes a plain layout with no variant", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		local desc = R.parse_gnome("[('xkb', 'de')]", "@as []")
		helpers.assert_eq(desc.layout, "de")
		helpers.assert_eq(desc.variant, "")
		helpers.assert_eq(desc.options, "")
	end)

	helpers.it("skips IBus engines to reach the first XKB layout", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		local desc = R.parse_gnome("[('ibus', 'mozc-jp'), ('xkb', 'jp')]", nil)
		helpers.assert_eq(desc.layout, "jp")
	end)

	helpers.it("answers nil for an empty MRU list so sources can be read next", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		helpers.assert_nil(R.parse_gnome("@a(ss) []", nil))
		helpers.assert_nil(R.parse_gnome("", nil))
	end)

	helpers.it("refuses a name that could not be a layout", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		helpers.assert_nil(R.parse_gnome("[('xkb', 'fr; rm -rf ~')]", nil),
			"names reach a shell command; anything outside XKB's alphabet is refused")
	end)

end)

helpers.describe("xkb_rmlvo: KDE kxkbrc", function()

	local KXKBRC = "[$Version]\nupdate_info=kxkbrc.upd:remove-empty-lists\n\n"
		.. "[Layout]\nDisplayNames=,\nLayoutList=fr,us\nOptions=grp:alt_shift_toggle\n"
		.. "ResetOldOptions=true\nUse=true\nVariantList=ergopti,\n"

	helpers.it("reads the first layout and its aligned variant", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		local desc = R.parse_kxkbrc(KXKBRC)
		helpers.assert_eq(desc.layout, "fr")
		helpers.assert_eq(desc.variant, "ergopti")
		helpers.assert_eq(desc.options, "grp:alt_shift_toggle")
	end)

	helpers.it("keeps an empty first variant empty instead of borrowing the second", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		local desc = R.parse_kxkbrc("[Layout]\nLayoutList=us,fr\nUse=true\nVariantList=,ergopti\n")
		helpers.assert_eq(desc.layout, "us")
		helpers.assert_eq(desc.variant, "", "VariantList is index-aligned with LayoutList")
	end)

	helpers.it("ignores the lists unless Plasma uses them", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		helpers.assert_nil(R.parse_kxkbrc("[Layout]\nLayoutList=fr\nUse=false\n"))
		helpers.assert_nil(R.parse_kxkbrc(nil))
	end)

end)

helpers.describe("xkb_rmlvo: system defaults", function()

	helpers.it("reads localectl status", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		local desc = R.parse_localectl(
			"   System Locale: LANG=fr_FR.UTF-8\n       VC Keymap: fr\n"
			.. "      X11 Layout: fr,us\n     X11 Variant: oss,\n     X11 Options: compose:menu\n")
		helpers.assert_eq(desc.layout, "fr")
		helpers.assert_eq(desc.variant, "oss")
		helpers.assert_eq(desc.options, "compose:menu")
	end)

	helpers.it("answers nil when localectl reports no X11 layout", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		helpers.assert_nil(R.parse_localectl("   System Locale: LANG=C\n       VC Keymap: n/a\n"))
	end)

	helpers.it("reads /etc/default/keyboard", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		local desc = R.parse_keyboard_defaults(
			'XKBMODEL="pc105"\nXKBLAYOUT="fr"\nXKBVARIANT="bepo"\nXKBOPTIONS=""\n\nBACKSPACE="guess"\n')
		helpers.assert_eq(desc.layout, "fr")
		helpers.assert_eq(desc.variant, "bepo")
		helpers.assert_eq(desc.options, "")
	end)

	helpers.it("reads the XKB_DEFAULT variables wlroots compositors honour", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		local env = { XKB_DEFAULT_LAYOUT = "fr,us", XKB_DEFAULT_VARIANT = "ergopti,",
			XKB_DEFAULT_OPTIONS = "lv3:ralt_switch" }
		local desc = R.from_env(function(name) return env[name] end)
		helpers.assert_eq(desc.layout, "fr")
		helpers.assert_eq(desc.variant, "ergopti")
		helpers.assert_eq(desc.options, "lv3:ralt_switch")
		helpers.assert_nil(R.from_env(function() return nil end))
	end)

end)

helpers.describe("xkb_rmlvo: compile command", function()

	helpers.it("names only what the descriptor carries", function()
		local R = helpers.load_module("infra.xkb_rmlvo")
		helpers.assert_eq(R.compile_command({ layout = "fr", variant = "ergopti", options = "" }),
			"xkbcli compile-keymap --layout fr --variant ergopti 2>/dev/null")
		helpers.assert_eq(R.compile_command({ layout = "us", variant = "", options = "caps:escape" }),
			"xkbcli compile-keymap --layout us --options caps:escape 2>/dev/null")
	end)

end)
