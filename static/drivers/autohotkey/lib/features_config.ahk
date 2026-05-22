; drivers/autohotkey/lib/features_config.ahk

#Include tap_hold_config.ahk

; ==============================================================================
; MODULE: Features Configuration
; DESCRIPTION:
; Thin wrapper that materialises the legacy v1 ``Features`` Map from the
; canonical feature manifest. Replaces the 385-line hardcoded literal that
; used to live here — the manifest at ``_shared/features/manifest.toml`` is
; the single source of truth for the v1 menu structure as well as the v2
; FeaturesV2 Map.
;
; FEATURES & RATIONALE:
; 1. ``BuildLegacyFeaturesFromManifest`` (lib/legacy_features_builder.ahk)
;    walks the manifest entries and produces the same v1-shape Map shape
;    that the tray-menu builder + legacy helpers expect — PascalCase ids,
;    ``.Enabled`` / ``.Letter`` / ``.Link`` properties, ``__Order`` arrays
;    with virtual headers / separators.
; 2. Per-feature runtime state on ``Features[X].Enabled / .Letter / ...``
;    is no longer the source of truth after slice 6 — the tray menu reads
;    those via ``GetFeatureV2State`` against FeaturesV2 directly. The
;    defaults emitted here only need to preserve the Map shape for the
;    remaining v1 consumers (RegisterPersonalFeature's mutation of
;    Features["Shortcuts"]["Personal"], the manifest-miss fallbacks
;    inside GetMenuTitleByPath / _ResolveMenuItemEnabled for runtime
;    Personal entries).
; 3. TapHolds keeps its own dedicated literal in ``tap_hold_config.ahk``
;    — that subsystem isn't modelled in the manifest.
; ==============================================================================

global Features := BuildLegacyFeaturesFromManifest()
