--- static/extensions/ergopti-demo/shortcuts/menu.lua
---
--- Ergopti extension shortcut menu — Hammerspoon driver.
--- This file is loaded in a sandboxed context. The function `add_item(item)`
--- must be called for each menu entry. `ext_name` holds the extension display
--- name. `t` (i18n) and Logger functions are available.

add_item({
	title   = t("ext.demo.open_demo_gui"),
	fn      = function()
		hs.dialog.alert("Ergopti Demo", t("ext.demo.gui_message"), "OK")
	end,
})

add_item({
	title   = t("ext.demo.show_info"),
	fn      = function()
		hs.dialog.alert("Info", "Extension : Ergopti Demo\nVersion : 1.0.0\nAuteur : Ergopti", "OK")
	end,
})

add_item({ title = "-" })   -- separator

add_item({
	title   = t("ext.demo.visit_docs"),
	fn      = function()
		hs.urlevent.openURL("https://github.com/ergopti/ergopti")
	end,
})
