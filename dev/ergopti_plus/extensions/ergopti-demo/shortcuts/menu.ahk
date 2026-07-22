; static/extensions/ergopti-demo/shortcuts/menu.ahk
;
; Ergopti Demo extension — AHK shortcuts menu.
; Must define BuildExtMenu_ergopti_demo(ExtMenu, ExtName) which the loader
; calls to populate the extension's submenu in the Shortcuts tray entry.

BuildExtMenu_ergopti_demo(ExtMenu, ExtName) {
    RegisterMenuItem(ExtMenu, t("ext.demo.open_demo_gui"), _ErgoptiDemo_OpenGui)
    RegisterMenuItem(ExtMenu, t("ext.demo.show_info"),     _ErgoptiDemo_ShowInfo)
    ExtMenu.Add()   ; separator
    RegisterMenuItem(ExtMenu, t("ext.demo.visit_docs"),    _ErgoptiDemo_VisitDocs)
}

_ErgoptiDemo_OpenGui(*) {
    MsgBox(t("ext.demo.gui_message"), "Ergopti Demo", "OK")
}

_ErgoptiDemo_ShowInfo(*) {
    MsgBox("Extension : Ergopti Demo`nVersion : 1.0.0`nAuteur : Ergopti", "Info", "OK")
}

_ErgoptiDemo_VisitDocs(*) {
    Run("https://github.com/ergopti/ergopti")
}
