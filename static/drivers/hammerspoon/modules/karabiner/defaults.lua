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
D.tap_hold_timeout_ms = 1000   -- KE's basic.to_if_alone_timeout_milliseconds
D.sticky_timeout_ms   = 3000   -- One-shot modifier auto-cancel delay

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
    right_option        = { "none",           "none"      },
    right_shift         = { "none",           "none"      },
    return_or_enter     = { "none",           "none"      },
    delete_or_backspace = { "none",           "none"      },
}

-- Modifier combos: combo_id = { tap_action_id, hold_action_id }
D.combos = {
    -- Échap
    esc_tab                  = { "none", "none" },
    esc_caps                 = { "none", "none" },
    esc_lshift               = { "none", "none" },
    esc_fn                   = { "none", "none" },
    esc_lctrl                = { "none", "none" },
    esc_lopt                 = { "none", "none" },
    esc_lcmd                 = { "none", "none" },
    esc_space                = { "none", "none" },
    esc_rcmd                 = { "none", "none" },
    esc_ropt                 = { "none", "none" },
    esc_rshift               = { "none", "none" },
    esc_ret                  = { "none", "none" },
    esc_bsp                  = { "none", "none" },

    -- Tab
    tab_esc                  = { "none", "none" },
    tab_caps                 = { "none", "none" },
    tab_lshift               = { "none", "none" },
    tab_fn                   = { "none", "none" },
    tab_lctrl                = { "none", "none" },
    tab_lopt                 = { "none", "none" },
    tab_lcmd                 = { "none", "none" },
    tab_space                = { "none", "none" },
    tab_rcmd                 = { "none", "none" },
    tab_ropt                 = { "none", "none" },
    tab_rshift               = { "none", "none" },
    tab_ret                  = { "none", "none" },
    tab_bsp                  = { "none", "none" },

    -- CapsLock
    caps_esc                 = { "none", "none" },
    caps_tab                 = { "none", "none" },
    caps_lshift              = { "none", "none" },
    caps_fn                  = { "none", "none" },
    caps_lctrl               = { "none", "none" },
    caps_lopt                = { "none", "none" },
    caps_lcmd                = { "none", "none" },
    caps_space               = { "none", "none" },
    caps_rcmd                = { "none", "none" },
    caps_ropt                = { "none", "none" },
    caps_rshift              = { "none", "none" },
    caps_ret                 = { "none", "none" },
    caps_bsp                 = { "none", "none" },

    -- Shift gauche
    lshift_esc               = { "none", "none" },
    lshift_tab               = { "none", "none" },
    lshift_caps              = { "none", "none" },
    lshift_fn                = { "none", "none" },
    lshift_lctrl             = { "none", "none" },
    lshift_lopt              = { "none", "none" },
    lshift_lcmd              = { "none", "none" },
    lshift_space             = { "none", "none" },
    lshift_rcmd              = { "none", "none" },
    lshift_ropt              = { "none", "none" },
    lshift_rshift            = { "none", "none" },
    lshift_ret               = { "none", "none" },
    lshift_bsp               = { "none", "none" },

    -- Fn
    fn_esc                   = { "none", "none" },
    fn_tab                   = { "none", "none" },
    fn_caps                  = { "none", "none" },
    fn_lshift                = { "none", "none" },
    fn_lctrl                 = { "none", "none" },
    fn_lopt                  = { "none", "none" },
    fn_lcmd                  = { "none", "none" },
    fn_space                 = { "none", "none" },
    fn_rcmd                  = { "none", "none" },
    fn_ropt                  = { "none", "none" },
    fn_rshift                = { "none", "none" },
    fn_ret                   = { "none", "none" },
    fn_bsp                   = { "none", "none" },

    -- Ctrl gauche
    lctrl_esc                = { "none", "none" },
    lctrl_tab                = { "none", "none" },
    lctrl_caps               = { "none", "none" },
    lctrl_lshift             = { "none", "none" },
    lctrl_fn                 = { "none", "none" },
    lctrl_lopt               = { "none", "none" },
    lctrl_lcmd               = { "none", "none" },
    lctrl_space              = { "none", "none" },
    lctrl_rcmd               = { "none", "none" },
    lctrl_ropt               = { "none", "none" },
    lctrl_rshift             = { "none", "none" },
    lctrl_ret                = { "none", "none" },
    lctrl_bsp                = { "none", "none" },

    -- Option gauche
    lopt_esc                 = { "none", "none" },
    lopt_tab                 = { "none", "none" },
    lopt_caps                = { "none", "none" },
    lopt_lshift              = { "none", "none" },
    lopt_fn                  = { "none", "none" },
    lopt_lctrl               = { "none", "none" },
    lopt_lcmd                = { "none", "none" },
    lopt_space               = { "none", "none" },
    lopt_rcmd                = { "none", "none" },
    lopt_ropt                = { "none", "none" },
    lopt_rshift              = { "none", "none" },
    lopt_ret                 = { "none", "none" },
    lopt_bsp                 = { "none", "none" },

    -- Cmd gauche
    lcmd_esc                 = { "none", "none" },
    lcmd_tab                 = { "none", "none" },
    lcmd_caps                = { "none", "none" },
    lcmd_lshift              = { "none", "none" },
    lcmd_fn                  = { "none", "none" },
    lcmd_lctrl               = { "none", "none" },
    lcmd_lopt                = { "none", "none" },
    lcmd_space               = { "none", "none" },
    lcmd_rcmd                = { "none", "none" },
    lcmd_ropt                = { "none", "none" },
    lcmd_rshift              = { "none", "none" },
    lcmd_ret                 = { "none", "none" },
    lcmd_bsp                 = { "none", "none" },

    -- Espace
    space_esc                = { "none", "none" },
    space_tab                = { "none", "none" },
    space_caps               = { "none", "none" },
    space_lshift             = { "none", "none" },
    space_fn                 = { "none", "none" },
    space_lctrl              = { "none", "none" },
    space_lopt               = { "none", "none" },
    space_lcmd               = { "none", "none" },
    space_rcmd               = { "none", "none" },
    space_ropt               = { "none", "none" },
    space_rshift             = { "none", "none" },
    space_ret                = { "none", "none" },
    space_bsp                = { "none", "none" },

    -- Cmd droit
    rcmd_esc                 = { "none", "none" },
    rcmd_tab                 = { "none", "none" },
    rcmd_caps                = { "none", "none" },
    rcmd_lshift              = { "none", "none" },
    rcmd_fn                  = { "none", "none" },
    rcmd_lctrl               = { "none", "none" },
    rcmd_lopt                = { "none", "none" },
    rcmd_lcmd                = { "none", "none" },
    rcmd_space               = { "none", "none" },
    rcmd_ropt                = { "none", "none" },
    rcmd_rshift              = { "none", "none" },
    rcmd_ret                 = { "none", "none" },
    rcmd_bsp                 = { "none", "none" },

    -- Option droit
    ropt_esc                 = { "none", "none" },
    ropt_tab                 = { "none", "none" },
    ropt_caps                = { "none", "none" },
    ropt_lshift              = { "none", "none" },
    ropt_fn                  = { "none", "none" },
    ropt_lctrl               = { "none", "none" },
    ropt_lopt                = { "none", "none" },
    ropt_lcmd                = { "none", "none" },
    ropt_space               = { "none", "none" },
    ropt_rcmd                = { "none", "none" },
    ropt_rshift              = { "none", "none" },
    ropt_ret                 = { "none", "none" },
    ropt_bsp                 = { "none", "none" },

    -- Shift droit
    rshift_esc               = { "none", "none" },
    rshift_tab               = { "none", "none" },
    rshift_caps              = { "none", "none" },
    rshift_lshift            = { "none", "none" },
    rshift_fn                = { "none", "none" },
    rshift_lctrl             = { "none", "none" },
    rshift_lopt              = { "none", "none" },
    rshift_lcmd              = { "none", "none" },
    rshift_space             = { "none", "none" },
    rshift_rcmd              = { "none", "none" },
    rshift_ropt              = { "none", "none" },
    rshift_ret               = { "none", "none" },
    rshift_bsp               = { "none", "none" },

    -- Entrée
    ret_esc                  = { "none", "none" },
    ret_tab                  = { "none", "none" },
    ret_caps                 = { "none", "none" },
    ret_lshift               = { "none", "none" },
    ret_fn                   = { "none", "none" },
    ret_lctrl                = { "none", "none" },
    ret_lopt                 = { "none", "none" },
    ret_lcmd                 = { "none", "none" },
    ret_space                = { "none", "none" },
    ret_rcmd                 = { "none", "none" },
    ret_ropt                 = { "none", "none" },
    ret_rshift               = { "none", "none" },
    ret_bsp                  = { "none", "none" },

    -- BackSpace
    bsp_esc                  = { "none", "none" },
    bsp_tab                  = { "none", "none" },
    bsp_caps                 = { "none", "none" },
    bsp_lshift               = { "none", "none" },
    bsp_fn                   = { "none", "none" },
    bsp_lctrl                = { "none", "none" },
    bsp_lopt                 = { "none", "none" },
    bsp_lcmd                 = { "none", "none" },
    bsp_space                = { "none", "none" },
    bsp_rcmd                 = { "none", "none" },
    bsp_ropt                 = { "none", "none" },
    bsp_rshift               = { "none", "none" },
    bsp_ret                  = { "none", "none" },
}

return D
