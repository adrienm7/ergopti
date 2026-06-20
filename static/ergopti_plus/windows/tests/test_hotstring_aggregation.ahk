; static/ergopti_plus/windows/tests/test_hotstring_aggregation.ahk
#Requires AutoHotkey v2.0
#Include ../lib/stubs.ahk
#Include ../lib/logger/logger.ahk
#Include ../lib/toml/toml_loader.ahk
#Include ../lib/hotstrings/hotstrings_config.ahk
#Include ../ui/tray_menu.ahk
#Include ../lib/menu_manifest.ahk
#Include ../lib/manifest_reader.ahk
#Include ../lib/hotstrings/hotstring_prefix_watcher.ahk

; Stub global dependencies
global _StaticDir := A_ScriptDir . "/../../../../static"
global _SharedDir := _StaticDir . "/ergopti_plus/_shared"
global Features := Map()
global ScriptInformation := Map(
    "MagicKey", "★",
    "PersonalTomlPath", A_ScriptDir . "/personal_test.toml",
    "PersonalHotstringsDir", A_ScriptDir . "/personal_ext_test"
)

; Mock t() translation function
t(key) => key

; Mock FmtCount
FmtCount(n) => n

; Mock IsCategoryGated
IsCategoryGated(cat) => true

; Test runner
Test(Name, Fn) {
    try {
        Fn()
        FileAppend("PASS: " . Name . "`n", "*")
    } catch as Err {
        FileAppend("FAIL: " . Name . " - " . Err.Message . "`n", "*")
    }
}

; 1. Create a dummy personal TOML
PersonalContent := "
(
[_meta]
sections_order = ["work", "home"]

[[work]]
"email" = { output = "work@example.com", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }
"tel" = { output = "0123456789", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }

[[home]]
"addr" = { output = "123 Home St", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }
)"
FileOpen(ScriptInformation["PersonalTomlPath"], "w").Write(PersonalContent)

; 2. Create a dummy extension folder and TOML
DirCreate(ScriptInformation["PersonalHotstringsDir"])
ExtContent := "
(
[[extra]]
"git" = { output = "git push", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }
)"
FileOpen(ScriptInformation["PersonalHotstringsDir"] . "/extra.toml", "w").Write(ExtContent)

; Setup Features for Personal
Features["hotstrings"] := Map(
    "personal", Map(
        "work", Map("enabled", true),
        "home", Map("enabled", true)
    )
)

Test("Personal hotstring aggregation includes main file", () {
    ; Mock extension scanner
    global _ExtTotalPersonalCounterGlobal := { value: 1 } ; The 1 from extra.toml
    
    Total := _HS_ComputeGrandTotal()
    ; Expected: 2 (work) + 1 (home) + 1 (extra) = 4
    if (Total != 4) {
        throw Error("Expected 4 hotstrings, got " . Total)
    }
})

Test("Common hotstring aggregation (SFBsReduction)", () {
    ; Setup Features for SFBsReduction
    Features["hotstrings"]["sfbs_reduction"] := Map(
        "bu", Map("enabled", true),
        "comma", Map("enabled", false)
    )
    
    ; We need to mock HotstringCategoriesStd
    global HotstringCategoriesStd := ["SFBsReduction"]
    global HotstringCategoriesErgopti := []
    
    ; V1 to V2 map is already in tray_menu.ahk
    
    Total := _HS_ComputeGrandTotal()
    
    ; bu has 12 entries in sfbsreduction.toml (based on my previous read)
    ; comma has many but is disabled.
    ; Total should be at least 12.
    if (Total < 12) {
        throw Error("Expected at least 12 hotstrings for bu, got " . Total)
    }
})

Test("PrefixWatcher respects enabled flags", () {
    ; Reset prefix index
    global _PrefixIndex := Map()
    
    ; Disable bu section
    Features["hotstrings"]["sfbs_reduction"]["bu"]["enabled"] := false
    
    _RegisterCategoryTriggers("sfbsreduction")
    
    ; Triggers like "à★" should NOT be in the index
    if (_PrefixIndex.Has("à")) {
        for _, entry in _PrefixIndex["à"] {
            if (entry.Section == "bu") {
                throw Error("PrefixWatcher indexed disabled section 'bu'")
            }
        }
    }
})

; Cleanup
FileDelete(ScriptInformation["PersonalTomlPath"])
DirDelete(ScriptInformation["PersonalHotstringsDir"], true)
