--- modules/karabiner/defaults.lua

--- ==============================================================================
--- MODULE: Karabiner Defaults
--- DESCRIPTION:
--- Single source of truth for all user-configurable karabiner defaults.
--- Action IDs reference data/actions.json. Edit this file to change what
--- "Reset to defaults" restores.
--- ==============================================================================

local D = {}

-- Timeouts (milliseconds)
D.tap_hold_timeout_ms        = 1000   -- KE's basic.to_if_alone_timeout_milliseconds
D.sticky_timeout_ms          = 3000   -- One-shot modifier auto-cancel delay
-- Combo activation window: maximum delay between the two keys of a shortcut for
-- Karabiner to fire the combo slot (chord-style activation).
D.simultaneous_threshold_ms  = 100

-- When true, A+B and B+A trigger the same CHORD (combo slot). The chord rule
-- has key_down_order: "strict" stripped so both press orders match. The tap and
-- hold slots remain per-direction (legitimate asymmetry: e.g. rcmd-then-lcmd
-- hold must differ from lcmd-then-rcmd hold because lcmd-first activates the
-- navigation layer).
D.combo_symmetric            = false

-- Tap / hold keys: key_id = { tap_action_id, hold_action_id }
D.tap_hold = {
--                              tap               hold
    escape              = { "none",           "none"      },
    tab                 = { "cmd_tab",        "fn"        },
    caps_lock           = { "return",         "cmd"       },
    left_shift          = { "copy",           "shift"     },
    fn                  = { "paste",          "cmd"       },
    left_control        = { "cut",            "ctrl"      },
    left_option         = { "delete_fwd",     "cmd_shift" },
    left_command        = { "backspace",      "layer"     },
    spacebar            = { "none",           "none"      },
    right_command       = { "tab",            "altgr"     },
    right_option        = { "sticky_shift",   "shift"     },
    right_shift         = { "none",           "none"      },
    return_or_enter     = { "none",           "none"      },
    delete_or_backspace = { "none",           "none"      },
}

-- Modifier combos: combo_id = { combo_action_id, tap_action_id, hold_action_id }
--   combo : press k1 then k2 within simultaneous_threshold_ms → chord-style fire.
--   tap   : hold k1 + briefly tap k2              → fires once on short release.
--   hold  : hold k1 + hold k2 past tap_hold delay → fires after long press.
D.combos = {
    -- Échap
    esc_tab                  = { "none", "none", "none" },
    esc_caps                 = { "none", "none", "none" },
    esc_lshift               = { "none", "none", "none" },
    esc_fn                   = { "none", "none", "none" },
    esc_lctrl                = { "none", "none", "none" },
    esc_lopt                 = { "none", "none", "none" },
    esc_lcmd                 = { "none", "none", "none" },
    esc_space                = { "none", "none", "none" },
    esc_rcmd                 = { "none", "none", "none" },
    esc_ropt                 = { "none", "none", "none" },
    esc_rshift               = { "none", "none", "none" },
    esc_ret                  = { "none", "none", "none" },
    esc_bsp                  = { "none", "none", "none" },

    -- Tab
    tab_esc                  = { "none", "none", "none" },
    tab_caps                 = { "none", "none", "none" },
    tab_lshift               = { "none", "none", "none" },
    tab_fn                   = { "none", "none", "none" },
    tab_lctrl                = { "none", "none", "none" },
    tab_lopt                 = { "none", "none", "none" },
    tab_lcmd                 = { "none", "none", "none" },
    tab_space                = { "none", "none", "none" },
    tab_rcmd                 = { "none", "none", "none" },
    tab_ropt                 = { "none", "none", "none" },
    tab_rshift               = { "none", "none", "none" },
    tab_ret                  = { "none", "none", "none" },
    tab_bsp                  = { "none", "none", "none" },

    -- CapsLock
    caps_esc                 = { "none", "none", "none" },
    caps_tab                 = { "none", "none", "none" },
    caps_lshift              = { "none", "none", "none" },
    caps_fn                  = { "none", "none", "none" },
    caps_lctrl               = { "none", "none", "none" },
    caps_lopt                = { "none", "none", "none" },
    caps_lcmd                = { "none", "none", "none" },
    caps_space               = { "none", "none", "none" },
    caps_rcmd                = { "none", "none", "none" },
    caps_ropt                = { "none", "none", "none" },
    caps_rshift              = { "none", "none", "none" },
    caps_ret                 = { "none", "none", "none" },
    caps_bsp                 = { "none", "none", "none" },

    -- Shift gauche
    lshift_esc               = { "none", "none", "none" },
    lshift_tab               = { "none", "none", "none" },
    lshift_caps              = { "none", "none", "none" },
    lshift_fn                = { "none", "none", "none" },
    lshift_lctrl             = { "none", "none", "none" },
    lshift_lopt              = { "none", "none", "none" },
    lshift_lcmd              = { "none", "none", "none" },
    lshift_space             = { "none", "none", "none" },
    lshift_rcmd              = { "none", "none", "none" },
    lshift_ropt              = { "none", "none", "none" },
    lshift_rshift            = { "none", "none", "none" },
    lshift_ret               = { "none", "none", "none" },
    lshift_bsp               = { "none", "none", "none" },

    -- Fn
    fn_esc                   = { "none", "none", "none" },
    fn_tab                   = { "none", "none", "none" },
    fn_caps                  = { "none", "none", "none" },
    fn_lshift                = { "none", "none", "none" },
    fn_lctrl                 = { "none", "none", "none" },
    fn_lopt                  = { "none", "none", "none" },
    fn_lcmd                  = { "none", "none", "none" },
    fn_space                 = { "none", "none", "none" },
    fn_rcmd                  = { "none", "none", "none" },
    fn_ropt                  = { "none", "none", "none" },
    fn_rshift                = { "none", "none", "none" },
    fn_ret                   = { "none", "none", "none" },
    fn_bsp                   = { "none", "none", "none" },

    -- Ctrl gauche
    lctrl_esc                = { "none", "none", "none" },
    lctrl_tab                = { "none", "none", "none" },
    lctrl_caps               = { "none", "none", "none" },
    lctrl_lshift             = { "none", "none", "none" },
    lctrl_fn                 = { "none", "none", "none" },
    lctrl_lopt               = { "none", "none", "none" },
    lctrl_lcmd               = { "none", "none", "none" },
    lctrl_space              = { "none", "none", "none" },
    lctrl_rcmd               = { "none", "none", "none" },
    lctrl_ropt               = { "none", "none", "none" },
    lctrl_rshift             = { "none", "none", "none" },
    lctrl_ret                = { "none", "none", "none" },
    lctrl_bsp                = { "none", "none", "none" },

    -- Option gauche
    lopt_esc                 = { "none", "none", "none" },
    lopt_tab                 = { "none", "none", "none" },
    lopt_caps                = { "none", "none", "none" },
    lopt_lshift              = { "none", "none", "none" },
    lopt_fn                  = { "none", "none", "none" },
    lopt_lctrl               = { "none", "none", "none" },
    lopt_lcmd                = { "none", "none", "none" },
    lopt_space               = { "none", "none", "none" },
    lopt_rcmd                = { "none", "none", "none" },
    lopt_ropt                = { "none", "none", "none" },
    lopt_rshift              = { "none", "none", "none" },
    lopt_ret                 = { "none", "none", "none" },
    lopt_bsp                 = { "none", "none", "none" },

    -- Cmd gauche
    lcmd_esc                 = { "none", "none", "none" },
    lcmd_tab                 = { "none", "none", "none" },
    lcmd_caps                = { "none", "none", "none" },
    lcmd_lshift              = { "none", "none", "none" },
    lcmd_fn                  = { "none", "none", "none" },
    lcmd_lctrl               = { "none", "none", "none" },
    lcmd_lopt                = { "none", "none", "none" },
    lcmd_space               = { "none", "none", "none" },
    -- lcmd + rcmd: canonical half of the (lcmd, rcmd) pair.
    --   combo : symmetric chord — fires opt_backspace regardless of press order.
    --   tap   : "none" here. When lcmd is first (layer active) + rcmd pressed,
    --           layer_keys.json's "Layer + Right Command" rule takes over
    --           (emits shift+option modifier). Adding a tap here would pre-empt it.
    --   hold  : "none" — same reason; layer_keys.json handles the lcmd-first hold path.
    lcmd_rcmd                = { "opt_backspace", "none",           "none"         },
    lcmd_ropt                = { "none",         "none",         "none" },
    lcmd_rshift              = { "none", "none", "none" },
    lcmd_ret                 = { "none", "none", "none" },
    lcmd_bsp                 = { "none", "none", "none" },

    -- Espace
    space_esc                = { "none", "none", "none" },
    space_tab                = { "none", "none", "none" },
    space_caps               = { "none", "none", "none" },
    space_lshift             = { "none", "none", "none" },
    space_fn                 = { "none", "none", "none" },
    space_lctrl              = { "none", "none", "none" },
    space_lopt               = { "none", "none", "none" },
    space_lcmd               = { "none", "none", "none" },
    space_rcmd               = { "none", "none", "none" },
    space_ropt               = { "none", "none", "none" },
    space_rshift             = { "none", "none", "none" },
    space_ret                = { "none", "none", "none" },
    space_bsp                = { "none", "none", "none" },

    -- Cmd droit — non-canonical half of each pair (symmetric mode shares the chord
    -- with the canonical half; this entry still drives the per-direction tap/hold).
    -- Slot order: { combo, tap, hold }.
    --   rcmd + caps : CapsWord (combo = tap); tap fires on each press of caps
    --                 while rcmd is held, so it stays valid even if the 100 ms
    --                 simultaneous window is missed.
    --   rcmd + fn   : toggle CapsLock (combo = tap), same rationale.
    --   rcmd + lopt : word-level forward delete (combo = tap), using opt variant
    --                 to avoid conflict with Hammerspoon cmd+delete shortcut.
    --   rcmd + lcmd : word-level backward delete (combo = tap, repeatable on
    --                 key-repeat); hold = option+shift modifier so the combined
    --                 hold works as a shift+option accelerator (no layer activation).
    rcmd_esc                 = { "none",                  "none",           "none"         },
    rcmd_tab                 = { "cycle_windows_in_app", "cycle_windows_in_app",           "none"         },
    rcmd_caps                = { "capsword",       "capsword",       "none"         },
    rcmd_lshift              = { "none",           "none",           "none"         },
    rcmd_fn                  = { "caps_lock",      "caps_lock",      "none"         },
    rcmd_lctrl               = { "none",           "none",           "none"         },
    rcmd_lopt                = { "opt_delete_fwd", "opt_delete_fwd", "none"         },
    rcmd_lcmd                = { "opt_backspace",  "opt_backspace",  "option_shift" },
    rcmd_space               = { "none", "none", "none" },
    rcmd_ropt                = { "none", "none", "none" },
    rcmd_rshift              = { "none", "none", "none" },
    rcmd_ret                 = { "none", "none", "none" },
    rcmd_bsp                 = { "none", "none", "none" },

    -- Option droit
    ropt_esc                 = { "none", "none", "none" },
    ropt_tab                 = { "none", "none", "none" },
    ropt_caps                = { "none", "none", "none" },
    ropt_lshift              = { "none", "none", "none" },
    ropt_fn                  = { "none", "none", "none" },
    ropt_lctrl               = { "none", "none", "none" },
    ropt_lopt                = { "none", "none", "none" },
    ropt_lcmd                = { "none", "none", "none" },
    ropt_space               = { "none", "none", "none" },
    ropt_rcmd                = { "none", "none", "none" },
    ropt_rshift              = { "none", "none", "none" },
    ropt_ret                 = { "none", "none", "none" },
    ropt_bsp                 = { "none", "none", "none" },

    -- Shift droit
    rshift_esc               = { "none", "none", "none" },
    rshift_tab               = { "none", "none", "none" },
    rshift_caps              = { "none", "none", "none" },
    rshift_lshift            = { "none", "none", "none" },
    rshift_fn                = { "none", "none", "none" },
    rshift_lctrl             = { "none", "none", "none" },
    rshift_lopt              = { "none", "none", "none" },
    rshift_lcmd              = { "none", "none", "none" },
    rshift_space             = { "none", "none", "none" },
    rshift_rcmd              = { "none", "none", "none" },
    rshift_ropt              = { "none", "none", "none" },
    rshift_ret               = { "none", "none", "none" },
    rshift_bsp               = { "none", "none", "none" },

    -- Entrée
    ret_esc                  = { "none", "none", "none" },
    ret_tab                  = { "none", "none", "none" },
    ret_caps                 = { "none", "none", "none" },
    ret_lshift               = { "none", "none", "none" },
    ret_fn                   = { "none", "none", "none" },
    ret_lctrl                = { "none", "none", "none" },
    ret_lopt                 = { "none", "none", "none" },
    ret_lcmd                 = { "none", "none", "none" },
    ret_space                = { "none", "none", "none" },
    ret_rcmd                 = { "none", "none", "none" },
    ret_ropt                 = { "none", "none", "none" },
    ret_rshift               = { "none", "none", "none" },
    ret_bsp                  = { "none", "none", "none" },

    -- BackSpace
    bsp_esc                  = { "none", "none", "none" },
    bsp_tab                  = { "none", "none", "none" },
    bsp_caps                 = { "none", "none", "none" },
    bsp_lshift               = { "none", "none", "none" },
    bsp_fn                   = { "none", "none", "none" },
    bsp_lctrl                = { "none", "none", "none" },
    bsp_lopt                 = { "none", "none", "none" },
    bsp_lcmd                 = { "none", "none", "none" },
    bsp_space                = { "none", "none", "none" },
    bsp_rcmd                 = { "none", "none", "none" },
    bsp_ropt                 = { "none", "none", "none" },
    bsp_rshift               = { "none", "none", "none" },
    bsp_ret                  = { "none", "none", "none" },
}

return D
