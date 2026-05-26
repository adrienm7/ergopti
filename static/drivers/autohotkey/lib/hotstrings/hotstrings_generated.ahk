; static/drivers/autohotkey/lib/hotstrings/hotstrings_generated.ahk

; ==============================================================================
; MODULE: Generated Hotstrings Registrar — Entry Point
; DESCRIPTION:
; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.
; Regenerate with ``python tools/compile_hotstrings.py`` from the repo root
; whenever the bundled TOML files under ``static/hotstrings/`` change.
;
; This file is a thin entry-point that ``#Include``s one generated file per
; category. Consumers that already ``#Include`` this file require no change.
; ``LoadHotstringsSection`` consults ``_GENERATED_HOTSTRINGS`` first and only
; falls back to the TOML parser for the ``personal`` category and for sections
; this file does not cover (e.g. a freshly-added TOML file that has not yet
; been recompiled).
; ==============================================================================


#Include generated_distancesreduction.ahk
#Include generated_sfbsreduction.ahk
#Include generated_rolls.ahk
#Include generated_autocorrection.ahk
#Include generated_magickey.ahk





; =====================================================================
; =====================================================================
; ======= 1/ Merge per-category maps into _GENERATED_HOTSTRINGS =======
; =====================================================================
; =====================================================================

global _GENERATED_HOTSTRINGS := Map()
for _k, _v in _GENERATED_HOTSTRINGS_DISTANCESREDUCTION
	_GENERATED_HOTSTRINGS[_k] := _v
for _k, _v in _GENERATED_HOTSTRINGS_SFBSREDUCTION
	_GENERATED_HOTSTRINGS[_k] := _v
for _k, _v in _GENERATED_HOTSTRINGS_ROLLS
	_GENERATED_HOTSTRINGS[_k] := _v
for _k, _v in _GENERATED_HOTSTRINGS_AUTOCORRECTION
	_GENERATED_HOTSTRINGS[_k] := _v
for _k, _v in _GENERATED_HOTSTRINGS_MAGICKEY
	_GENERATED_HOTSTRINGS[_k] := _v
