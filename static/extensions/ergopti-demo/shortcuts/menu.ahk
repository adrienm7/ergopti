; static/extensions/ergopti-demo/shortcuts/menu.ahk
;
; Ergopti extension shortcut menu — AHK driver.
; This file is loaded in a sandboxed context. The variable `ExtMenu` is a
; pre-created AHK Menu object; populate it freely. `ExtName` holds the
; extension display name. `t` (i18n) and Logger* functions are available.

ExtMenu.Add(t("ext.demo.open_demo_gui"), _ErgoptiDemo_OpenGui)
ExtMenu.Add(t("ext.demo.show_info"),     _ErgoptiDemo_ShowInfo)
ExtMenu.Add()   ; separator
ExtMenu.Add(t("ext.demo.visit_docs"),    _ErgoptiDemo_VisitDocs)

_ErgoptiDemo_OpenGui(*) {
    MsgBox(t("ext.demo.gui_message"), "Ergopti Demo", "OK")
}

_ErgoptiDemo_ShowInfo(*) {
    MsgBox("Extension : Ergopti Demo`nVersion : 1.0.0`nAuteur : Ergopti", "Info", "OK")
}

_ErgoptiDemo_VisitDocs(*) {
    Run("https://github.com/ergopti/ergopti")
}
