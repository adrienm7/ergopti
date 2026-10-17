; static/ergopti_plus/windows/_generated/terminators.ahk
; AUTO-GENERATED from _shared/core/domain/Terminators.spec.js.
; DO NOT EDIT BY HAND — run `npm run codegen:terminators` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; CLASS: Terminators
; DESCRIPTION:
; AHK v2 implementation of the Terminators port contract. Owns the terminator
; catalogue and the O(1) lookup maps used by the hotstring engine. Generated
; from the shared spec so catalogue data is identical across all drivers.
;
; CONTRACT METHODS:
;   isTerminator(char)              — true if char belongs to an enabled slot.
;   isConsumed(char)                — true if the matching slot is consumed.
;   setEnabled(key, enabled)        — enable/disable a slot by key.
;   isEnabled(key)                  — query enabled state of a slot.
;   updateMagicKey(char)            — reassign the magic_key slot character.
;   addCustom(key, chars, label, consumed) — add a user-defined slot.
;   all()                           — return the full catalogue array.
; ==============================================================================




; ==============================
; ==============================
; ======= 1/ Terminators =======
; ==============================
; ==============================

class Terminators {

    ; -----------------------------------------------------------------------
    ; Internal state — catalogue array, enable map, O(1) char lookup maps.
    ; -----------------------------------------------------------------------
    _catalogue  := []
    _enabled    := Map()
    _charsSet   := Map()
    _consumeSet := Map()


    ; -----------------------------------------------------------------------
    ; __New — initialise from the generated catalogue.
    ; -----------------------------------------------------------------------
    __New() {
        this._catalogue := [
        Map("key", "space", "chars", [" "], "label_key", "terminators.label_space", "default_enabled", true, "consume", false),
        Map("key", "nbsp", "chars", [" "], "label_key", "terminators.label_nbsp", "default_enabled", false, "consume", false),
        Map("key", "nnbsp", "chars", [" "], "label_key", "terminators.label_nnbsp", "default_enabled", false, "consume", false),
        Map("key", "minus", "chars", ["-"], "label_key", "terminators.label_minus", "default_enabled", false, "consume", false),
        Map("key", "underscore", "chars", ["_"], "label_key", "terminators.label_underscore", "default_enabled", false, "consume", false),
        Map("key", "separator_5", "chars", [], "label", "-", "default_enabled", false, "consume", false, "type", "separator"),
        Map("key", "tab", "chars", ["`t"], "label_key", "terminators.label_tab", "default_enabled", true, "consume", false),
        Map("key", "enter", "chars", ["`r", "`n"], "label_key", "terminators.label_enter", "default_enabled", true, "consume", false),
        Map("key", "star", "chars", ["★"], "label_key", "terminators.label_star", "default_enabled", true, "consume", true),
        Map("key", "separator_9", "chars", [], "label", "-", "default_enabled", false, "consume", false, "type", "separator"),
        Map("key", "comma", "chars", [","], "label_key", "terminators.label_comma", "default_enabled", true, "consume", false),
        Map("key", "semicolon", "chars", [";"], "label_key", "terminators.label_semicolon", "default_enabled", true, "consume", false),
        Map("key", "period", "chars", ["."], "label_key", "terminators.label_period", "default_enabled", true, "consume", false),
        Map("key", "ellipsis", "chars", ["…"], "label_key", "terminators.label_ellipsis", "default_enabled", false, "consume", false),
        Map("key", "exclam", "chars", ["!"], "label_key", "terminators.label_exclam", "default_enabled", true, "consume", false),
        Map("key", "question", "chars", ["?"], "label_key", "terminators.label_question", "default_enabled", true, "consume", false),
        Map("key", "colon", "chars", [":"], "label_key", "terminators.label_colon", "default_enabled", true, "consume", false),
        Map("key", "separator_17", "chars", [], "label", "-", "default_enabled", false, "consume", false, "type", "separator"),
        Map("key", "parenright", "chars", [")"], "label_key", "terminators.label_parenright", "default_enabled", false, "consume", false),
        Map("key", "braceright", "chars", ["}"], "label_key", "terminators.label_braceright", "default_enabled", false, "consume", false),
        Map("key", "bracketright", "chars", ["]"], "label_key", "terminators.label_bracketright", "default_enabled", false, "consume", false),
        Map("key", "anglebracketright", "chars", [">"], "label_key", "terminators.label_anglebracketright", "default_enabled", false, "consume", false),
        Map("key", "separator_22", "chars", [], "label", "-", "default_enabled", false, "consume", false, "type", "separator"),
        Map("key", "apostrophe_typo", "chars", ["’"], "label_key", "terminators.label_apostrophe_typo", "default_enabled", false, "consume", false),
        Map("key", "apostrophe_straight", "chars", ["'"], "label_key", "terminators.label_apostrophe_straight", "default_enabled", false, "consume", false),
        Map("key", "quote", "chars", ["`""], "label_key", "terminators.label_quote", "default_enabled", false, "consume", false),
        Map("key", "equal", "chars", ["="], "label_key", "terminators.label_equal", "default_enabled", false, "consume", false),
        Map("key", "slash", "chars", ["/"], "label_key", "terminators.label_slash", "default_enabled", false, "consume", false),
        Map("key", "backslash", "chars", ["\"], "label_key", "terminators.label_backslash", "default_enabled", false, "consume", false)
        ]
        for entry in this._catalogue {
            this._enabled[entry["key"]] := entry["default_enabled"]
        }
        this._RebuildCache()
    }


    ; -----------------------------------------------------------------------
    ; _RebuildCache — rebuild O(1) lookup maps from the current enabled state.
    ; -----------------------------------------------------------------------
    _RebuildCache() {
        this._charsSet   := Map()
        this._consumeSet := Map()
        for entry in this._catalogue {
            if !this._enabled.Has(entry["key"])
                continue
            if !this._enabled[entry["key"]]
                continue
            for ch in entry["chars"] {
                this._charsSet[ch] := true
                if entry["consume"]
                    this._consumeSet[ch] := true
            }
        }
    }


    ; -----------------------------------------------------------------------
    ; isTerminator(char) — true if char belongs to any enabled slot.
    ; -----------------------------------------------------------------------
    isTerminator(char) {
        return this._charsSet.Has(char) && this._charsSet[char]
    }


    ; -----------------------------------------------------------------------
    ; isConsumed(char) — true if the matching enabled slot is consumed.
    ; -----------------------------------------------------------------------
    isConsumed(char) {
        return this._consumeSet.Has(char) && this._consumeSet[char]
    }


    ; -----------------------------------------------------------------------
    ; setEnabled(key, enabled) — enable or disable a slot by key.
    ; -----------------------------------------------------------------------
    setEnabled(key, enabled) {
        if !this._enabled.Has(key) {
            ; Unknown key — log and return per contract error_behavior
            OutputDebug("[Terminators] setEnabled: unknown key '" key "'")
            return
        }
        this._enabled[key] := enabled
        this._RebuildCache()
    }


    ; -----------------------------------------------------------------------
    ; isEnabled(key) — query the enabled state of a slot.
    ; -----------------------------------------------------------------------
    isEnabled(key) {
        if !this._enabled.Has(key)
            return false
        return this._enabled[key]
    }


    ; -----------------------------------------------------------------------
    ; updateMagicKey(char) — reassign the magic_key slot to a new character.
    ; -----------------------------------------------------------------------
    updateMagicKey(char) {
        for entry in this._catalogue {
            if entry["key"] = "star" {
                entry["chars"] := [char]
                break
            }
        }
        this._RebuildCache()
    }


    ; -----------------------------------------------------------------------
    ; addCustom(key, chars, label, consumed) — add a user-defined terminator.
    ; -----------------------------------------------------------------------
    addCustom(key, chars, label, consumed) {
        if this._enabled.Has(key) {
            ; Key collision — log and return per contract error_behavior
            OutputDebug("[Terminators] addCustom: key collision '" key "'")
            return false
        }
        for candidateChar in chars {
            for entry in this._catalogue {
                for existingChar in entry["chars"] {
                    if existingChar == candidateChar {
                        ; Character collision — one input value has one policy owner
                        OutputDebug("[Terminators] addCustom: character collision")
                        return false
                    }
                }
            }
        }
        local entry := Map(
            "key",             key,
            "chars",           chars,
            "label",           label,
            "default_enabled", true,
            "consume",         consumed
        )
        this._catalogue.Push(entry)
        this._enabled[key] := true
        this._RebuildCache()
        return true
    }


    ; -----------------------------------------------------------------------
    ; all() — return a copy of the full catalogue array.
    ; -----------------------------------------------------------------------
    all() {
        local copy := []
        for entry in this._catalogue
            copy.Push(entry)
        return copy
    }

}
