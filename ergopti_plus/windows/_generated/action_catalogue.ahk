; _generated/action_catalogue.ahk
; AUTO-GENERATED from _shared/modules/actions/actions.toml.
; DO NOT EDIT BY HAND — run `npm run codegen:action-catalogue` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Action Catalogue (Windows)
; DESCRIPTION:
; Every action the Windows driver offers, already filtered to its platform:
; the picker order with heading levels and locale keys, the modifier-chord
; block the driver expands from its own chord registry, and per-action
; metadata (label key, parameter kind, confirmation). A data function rather
; than a global, so include order cannot matter, and no TOML is parsed to
; build the picker.
; ==============================================================================

GestureActionCatalogueData() {
	Catalogue := { Platform: "ahk", SgItems: [], AxItems: [], Actions: Map() }
	Items := Catalogue.SgItems
	Items.Push({ Kind: "action", Id: "none" })
	Items.Push({ Kind: "heading", Level: 1, Key: "sg_actions.sg_order.header.grp_input" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.mouse_nav" })
	Items.Push({ Kind: "action", Id: "left_click_toggle" })
	Items.Push({ Kind: "action", Id: "right_click_toggle" })
	Items.Push({ Kind: "action", Id: "app_switcher" })
	Items.Push({ Kind: "action", Id: "alt_tab_windows" })
	Items.Push({ Kind: "action", Id: "alt_tab_monitor" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.edition" })
	Items.Push({ Kind: "action", Id: "copy" })
	Items.Push({ Kind: "action", Id: "paste" })
	Items.Push({ Kind: "action", Id: "paste_plain" })
	Items.Push({ Kind: "action", Id: "cut" })
	Items.Push({ Kind: "action", Id: "undo" })
	Items.Push({ Kind: "action", Id: "redo" })
	Items.Push({ Kind: "action", Id: "select_all" })
	Items.Push({ Kind: "action", Id: "find" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.keys" })
	Items.Push({ Kind: "action", Id: "enter" })
	Items.Push({ Kind: "action", Id: "tab" })
	Items.Push({ Kind: "action", Id: "escape" })
	Items.Push({ Kind: "action", Id: "backspace" })
	Items.Push({ Kind: "action", Id: "delete" })
	Items.Push({ Kind: "action", Id: "send_key" })
	Items.Push({ Kind: "action", Id: "send_shortcut" })
	Items.Push({ Kind: "action", Id: "send_text" })
	Items.Push({ Kind: "heading", Level: 1, Key: "sg_actions.sg_order.header.grp_windows" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.tabs" })
	Items.Push({ Kind: "action", Id: "tab_new" })
	Items.Push({ Kind: "action", Id: "tab_close" })
	Items.Push({ Kind: "action", Id: "tab_prev" })
	Items.Push({ Kind: "action", Id: "tab_next" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.navigation" })
	Items.Push({ Kind: "action", Id: "nav_back" })
	Items.Push({ Kind: "action", Id: "nav_forward" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.windows" })
	Items.Push({ Kind: "action", Id: "win_prev" })
	Items.Push({ Kind: "action", Id: "win_next" })
	Items.Push({ Kind: "action", Id: "win_app_prev" })
	Items.Push({ Kind: "action", Id: "win_app_next" })
	Items.Push({ Kind: "action", Id: "close_window" })
	Items.Push({ Kind: "action", Id: "fullscreen" })
	Items.Push({ Kind: "action", Id: "snap_left" })
	Items.Push({ Kind: "action", Id: "snap_right" })
	Items.Push({ Kind: "action", Id: "maximize" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.spaces" })
	Items.Push({ Kind: "action", Id: "desktop_prev" })
	Items.Push({ Kind: "action", Id: "desktop_next" })
	Items.Push({ Kind: "action", Id: "desktop_prev_wrap" })
	Items.Push({ Kind: "action", Id: "desktop_next_wrap" })
	Items.Push({ Kind: "action", Id: "desktop_new" })
	Items.Push({ Kind: "action", Id: "desktop_close" })
	Items.Push({ Kind: "action", Id: "task_view" })
	Items.Push({ Kind: "action", Id: "minimize_all" })
	Items.Push({ Kind: "heading", Level: 1, Key: "sg_actions.sg_order.header.grp_text" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.cursor" })
	Items.Push({ Kind: "action", Id: "arrow_up" })
	Items.Push({ Kind: "action", Id: "arrow_down" })
	Items.Push({ Kind: "action", Id: "arrow_left" })
	Items.Push({ Kind: "action", Id: "arrow_right" })
	Items.Push({ Kind: "action", Id: "word_prev" })
	Items.Push({ Kind: "action", Id: "word_next" })
	Items.Push({ Kind: "action", Id: "line_up" })
	Items.Push({ Kind: "action", Id: "line_down" })
	Items.Push({ Kind: "action", Id: "line_start" })
	Items.Push({ Kind: "action", Id: "line_end" })
	Items.Push({ Kind: "action", Id: "para_prev" })
	Items.Push({ Kind: "action", Id: "para_next" })
	Items.Push({ Kind: "action", Id: "doc_start" })
	Items.Push({ Kind: "action", Id: "doc_end" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.selection" })
	Items.Push({ Kind: "action", Id: "sel_up" })
	Items.Push({ Kind: "action", Id: "sel_down" })
	Items.Push({ Kind: "action", Id: "sel_left" })
	Items.Push({ Kind: "action", Id: "sel_right" })
	Items.Push({ Kind: "action", Id: "sel_word_prev" })
	Items.Push({ Kind: "action", Id: "sel_word_next" })
	Items.Push({ Kind: "action", Id: "select_word" })
	Items.Push({ Kind: "action", Id: "select_line" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.text_transform" })
	Items.Push({ Kind: "action", Id: "selection_uppercase" })
	Items.Push({ Kind: "action", Id: "selection_lowercase" })
	Items.Push({ Kind: "action", Id: "selection_titlecase" })
	Items.Push({ Kind: "action", Id: "uppercase_selection" })
	Items.Push({ Kind: "action", Id: "titlecase_selection" })
	Items.Push({ Kind: "action", Id: "wrap_selection" })
	Items.Push({ Kind: "action", Id: "surround_parens" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.ai" })
	Items.Push({ Kind: "action", Id: "llm_generate_prediction" })
	Items.Push({ Kind: "action", Id: "llm_prompt_prediction" })
	Items.Push({ Kind: "action", Id: "llm_predict_raw" })
	Items.Push({ Kind: "action", Id: "llm_predict_basic" })
	Items.Push({ Kind: "action", Id: "llm_predict_advanced" })
	Items.Push({ Kind: "action", Id: "llm_predict_batch_advanced" })
	Items.Push({ Kind: "action", Id: "llm_predict_rewrite" })
	Items.Push({ Kind: "action", Id: "llm_predict_tone_familiar" })
	Items.Push({ Kind: "action", Id: "llm_predict_tone_neutral" })
	Items.Push({ Kind: "action", Id: "llm_predict_tone_formal" })
	Items.Push({ Kind: "action", Id: "llm_predict_tone_very_formal" })
	Items.Push({ Kind: "action", Id: "llm_predict_translate_en" })
	Items.Push({ Kind: "action", Id: "llm_predict_translate_ja" })
	Items.Push({ Kind: "action", Id: "llm_tone_more_formal" })
	Items.Push({ Kind: "action", Id: "llm_tone_more_familiar" })
	Items.Push({ Kind: "action", Id: "llm_tone_more_formal_cycle" })
	Items.Push({ Kind: "action", Id: "llm_tone_more_familiar_cycle" })
	Items.Push({ Kind: "action", Id: "llm_live_prompt_toggle" })
	Items.Push({ Kind: "action", Id: "llm_screen_region" })
	Items.Push({ Kind: "action", Id: "llm_screen_full" })
	Items.Push({ Kind: "action", Id: "llm_screen_error" })
	Items.Push({ Kind: "action", Id: "llm_translate_context" })
	Items.Push({ Kind: "action", Id: "llm_translate_selection" })
	Items.Push({ Kind: "action", Id: "llm_agent_selection" })
	Items.Push({ Kind: "action", Id: "llm_agent_command" })
	Items.Push({ Kind: "action", Id: "llm_agent_auto_toggle" })
	Items.Push({ Kind: "heading", Level: 1, Key: "sg_actions.sg_order.header.modifier_chords" })
	Items.Push({ Kind: "modifier_chords", Level: 2, GroupKey: "sg_actions.sg_order.header.modifier_chord_group" })
	Items.Push({ Kind: "heading", Level: 1, Key: "sg_actions.sg_order.header.grp_media" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.media" })
	Items.Push({ Kind: "action", Id: "vol_up" })
	Items.Push({ Kind: "action", Id: "vol_down" })
	Items.Push({ Kind: "action", Id: "mute" })
	Items.Push({ Kind: "action", Id: "brightness_up" })
	Items.Push({ Kind: "action", Id: "brightness_down" })
	Items.Push({ Kind: "action", Id: "track_play" })
	Items.Push({ Kind: "action", Id: "track_next" })
	Items.Push({ Kind: "action", Id: "track_prev" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.screenshot" })
	Items.Push({ Kind: "action", Id: "screenshot_window_clipboard" })
	Items.Push({ Kind: "action", Id: "screenshot_window_save" })
	Items.Push({ Kind: "action", Id: "screenshot_region_clipboard" })
	Items.Push({ Kind: "action", Id: "screenshot_region_save" })
	Items.Push({ Kind: "action", Id: "screenshot_fullscreen_clipboard" })
	Items.Push({ Kind: "action", Id: "screenshot_fullscreen_save" })
	Items.Push({ Kind: "action", Id: "screen_record" })
	Items.Push({ Kind: "heading", Level: 1, Key: "sg_actions.sg_order.header.grp_system" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.system" })
	Items.Push({ Kind: "action", Id: "lock_screen" })
	Items.Push({ Kind: "action", Id: "notification_center" })
	Items.Push({ Kind: "action", Id: "show_desktop" })
	Items.Push({ Kind: "action", Id: "sleep_displays" })
	Items.Push({ Kind: "action", Id: "toggle_dark_mode" })
	Items.Push({ Kind: "action", Id: "mic_mute_toggle" })
	Items.Push({ Kind: "action", Id: "clear_clipboard" })
	Items.Push({ Kind: "action", Id: "center_mouse" })
	Items.Push({ Kind: "action", Id: "open_app" })
	Items.Push({ Kind: "action", Id: "run_program" })
	Items.Push({ Kind: "action", Id: "quit_frontmost_app" })
	Items.Push({ Kind: "action", Id: "force_quit_frontmost" })
	Items.Push({ Kind: "action", Id: "empty_trash" })
	Items.Push({ Kind: "action", Id: "eject_all_disks" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.file_actions" })
	Items.Push({ Kind: "action", Id: "unblock_file_selection" })
	Items.Push({ Kind: "action", Id: "open_terminal_here" })
	Items.Push({ Kind: "action", Id: "new_text_file_here" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.system_actions" })
	Items.Push({ Kind: "action", Id: "screen_capture" })
	Items.Push({ Kind: "action", Id: "screen_capture_instant" })
	Items.Push({ Kind: "action", Id: "ocr_screenshot" })
	Items.Push({ Kind: "action", Id: "open_url" })
	Items.Push({ Kind: "action", Id: "open_downloads" })
	Items.Push({ Kind: "action", Id: "open_file_manager" })
	Items.Push({ Kind: "action", Id: "open_system_settings" })
	Items.Push({ Kind: "action", Id: "pick_color" })
	Items.Push({ Kind: "action", Id: "open_emoji_picker" })
	Items.Push({ Kind: "action", Id: "take_note" })
	Items.Push({ Kind: "action", Id: "activity_simulation" })
	Items.Push({ Kind: "action", Id: "search_web" })
	Items.Push({ Kind: "action", Id: "copy_selected_path" })
	Items.Push({ Kind: "action", Id: "teleport_mouse" })
	Items.Push({ Kind: "action", Id: "spotlight_mouse" })
	Items.Push({ Kind: "action", Id: "toggle_capslock" })
	Items.Push({ Kind: "action", Id: "microsoft_bold" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.tapholds" })
	Items.Push({ Kind: "action", Id: "one_shot_shift" })
	Items.Push({ Kind: "action", Id: "caps_word" })
	Items.Push({ Kind: "action", Id: "ctrl_backspace" })
	Items.Push({ Kind: "action", Id: "ctrl_delete" })
	Items.Push({ Kind: "action", Id: "space" })
	Items.Push({ Kind: "action", Id: "caps_lock" })
	Items.Push({ Kind: "heading", Level: 1, Key: "sg_actions.sg_order.header.grp_app" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.ui" })
	Items.Push({ Kind: "action", Id: "open_metrics_typing" })
	Items.Push({ Kind: "action", Id: "open_metrics_apps" })
	Items.Push({ Kind: "action", Id: "open_hotstrings_editor" })
	Items.Push({ Kind: "action", Id: "open_paths_editor" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.files" })
	Items.Push({ Kind: "action", Id: "open_script_source" })
	Items.Push({ Kind: "action", Id: "open_personal_shortcuts" })
	Items.Push({ Kind: "action", Id: "open_personal_hotstrings" })
	Items.Push({ Kind: "action", Id: "open_personal_info" })
	Items.Push({ Kind: "action", Id: "open_config" })
	Items.Push({ Kind: "action", Id: "open_logs_folder" })
	Items.Push({ Kind: "action", Id: "open_today_log" })
	Items.Push({ Kind: "action", Id: "open_error_log" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.script" })
	Items.Push({ Kind: "action", Id: "script_pause_toggle" })
	Items.Push({ Kind: "action", Id: "script_reload" })
	Items.Push({ Kind: "action", Id: "script_save_reload" })
	Items.Push({ Kind: "action", Id: "script_quit" })
	Items.Push({ Kind: "heading", Level: 2, Key: "sg_actions.sg_order.header.debug" })
	Items.Push({ Kind: "action", Id: "open_window_spy" })
	Items.Push({ Kind: "action", Id: "open_list_vars" })
	Items.Push({ Kind: "action", Id: "open_key_history" })
	Actions := Catalogue.Actions
	Actions["activity_simulation"] := { Family: "sg", LabelKey: "sg_actions.activity_simulation", Parameter: "", Confirm: false }
	Actions["alt_tab_monitor"] := { Family: "sg", LabelKey: "sg_actions.alt_tab_monitor", Parameter: "", Confirm: false }
	Actions["alt_tab_windows"] := { Family: "sg", LabelKey: "sg_actions.alt_tab_windows", Parameter: "", Confirm: false }
	Actions["app_switcher"] := { Family: "sg", LabelKey: "sg_actions.app_switcher", Parameter: "", Confirm: false }
	Actions["arrow_down"] := { Family: "sg", LabelKey: "sg_actions.arrow_down", Parameter: "", Confirm: false }
	Actions["arrow_left"] := { Family: "sg", LabelKey: "sg_actions.arrow_left", Parameter: "", Confirm: false }
	Actions["arrow_right"] := { Family: "sg", LabelKey: "sg_actions.arrow_right", Parameter: "", Confirm: false }
	Actions["arrow_up"] := { Family: "sg", LabelKey: "sg_actions.arrow_up", Parameter: "", Confirm: false }
	Actions["backspace"] := { Family: "sg", LabelKey: "sg_actions.backspace", Parameter: "", Confirm: false }
	Actions["brightness_down"] := { Family: "sg", LabelKey: "sg_actions.brightness_down", Parameter: "", Confirm: false }
	Actions["brightness_up"] := { Family: "sg", LabelKey: "sg_actions.brightness_up", Parameter: "", Confirm: false }
	Actions["caps_lock"] := { Family: "sg", LabelKey: "sg_actions.caps_lock", Parameter: "", Confirm: false }
	Actions["caps_word"] := { Family: "sg", LabelKey: "sg_actions.caps_word", Parameter: "", Confirm: false }
	Actions["center_mouse"] := { Family: "sg", LabelKey: "sg_actions.center_mouse", Parameter: "", Confirm: false }
	Actions["clear_clipboard"] := { Family: "sg", LabelKey: "sg_actions.clear_clipboard", Parameter: "", Confirm: false }
	Actions["close_window"] := { Family: "sg", LabelKey: "sg_actions.close_window", Parameter: "", Confirm: false }
	Actions["copy"] := { Family: "sg", LabelKey: "sg_actions.copy", Parameter: "", Confirm: false }
	Actions["copy_selected_path"] := { Family: "sg", LabelKey: "sg_actions.copy_selected_path", Parameter: "", Confirm: false }
	Actions["ctrl_backspace"] := { Family: "sg", LabelKey: "sg_actions.ctrl_backspace", Parameter: "", Confirm: false }
	Actions["ctrl_delete"] := { Family: "sg", LabelKey: "sg_actions.ctrl_delete", Parameter: "", Confirm: false }
	Actions["cut"] := { Family: "sg", LabelKey: "sg_actions.cut", Parameter: "", Confirm: false }
	Actions["delete"] := { Family: "sg", LabelKey: "sg_actions.delete", Parameter: "", Confirm: false }
	Actions["desktop_close"] := { Family: "sg", LabelKey: "sg_actions.desktop_close", Parameter: "", Confirm: false }
	Actions["desktop_new"] := { Family: "sg", LabelKey: "sg_actions.desktop_new", Parameter: "", Confirm: false }
	Actions["desktop_next"] := { Family: "sg", LabelKey: "sg_actions.desktop_next", Parameter: "", Confirm: false }
	Actions["desktop_next_wrap"] := { Family: "sg", LabelKey: "sg_actions.desktop_next_wrap", Parameter: "", Confirm: false }
	Actions["desktop_prev"] := { Family: "sg", LabelKey: "sg_actions.desktop_prev", Parameter: "", Confirm: false }
	Actions["desktop_prev_wrap"] := { Family: "sg", LabelKey: "sg_actions.desktop_prev_wrap", Parameter: "", Confirm: false }
	Actions["doc_end"] := { Family: "sg", LabelKey: "sg_actions.doc_end", Parameter: "", Confirm: false }
	Actions["doc_start"] := { Family: "sg", LabelKey: "sg_actions.doc_start", Parameter: "", Confirm: false }
	Actions["eject_all_disks"] := { Family: "sg", LabelKey: "sg_actions.eject_all_disks", Parameter: "", Confirm: false }
	Actions["empty_trash"] := { Family: "sg", LabelKey: "sg_actions.empty_trash", Parameter: "", Confirm: true }
	Actions["enter"] := { Family: "sg", LabelKey: "sg_actions.enter", Parameter: "", Confirm: false }
	Actions["escape"] := { Family: "sg", LabelKey: "sg_actions.escape", Parameter: "", Confirm: false }
	Actions["find"] := { Family: "sg", LabelKey: "sg_actions.find", Parameter: "", Confirm: false }
	Actions["force_quit_frontmost"] := { Family: "sg", LabelKey: "sg_actions.force_quit_frontmost", Parameter: "", Confirm: true }
	Actions["fullscreen"] := { Family: "sg", LabelKey: "sg_actions.fullscreen", Parameter: "", Confirm: false }
	Actions["left_click_toggle"] := { Family: "sg", LabelKey: "sg_actions.left_click_toggle", Parameter: "", Confirm: false }
	Actions["line_down"] := { Family: "sg", LabelKey: "sg_actions.line_down", Parameter: "", Confirm: false }
	Actions["line_end"] := { Family: "sg", LabelKey: "sg_actions.line_end", Parameter: "", Confirm: false }
	Actions["line_start"] := { Family: "sg", LabelKey: "sg_actions.line_start", Parameter: "", Confirm: false }
	Actions["line_up"] := { Family: "sg", LabelKey: "sg_actions.line_up", Parameter: "", Confirm: false }
	Actions["llm_agent_auto_toggle"] := { Family: "sg", LabelKey: "sg_actions.llm_agent_auto_toggle", Parameter: "", Confirm: false }
	Actions["llm_agent_command"] := { Family: "sg", LabelKey: "sg_actions.llm_agent_command", Parameter: "", Confirm: false }
	Actions["llm_agent_selection"] := { Family: "sg", LabelKey: "sg_actions.llm_agent_selection", Parameter: "", Confirm: false }
	Actions["llm_generate_prediction"] := { Family: "sg", LabelKey: "sg_actions.llm_generate_prediction", Parameter: "", Confirm: false }
	Actions["llm_live_prompt_toggle"] := { Family: "sg", LabelKey: "sg_actions.llm_live_prompt_toggle", Parameter: "llm_prompt", Confirm: false }
	Actions["llm_predict_advanced"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_advanced", Parameter: "", Confirm: false }
	Actions["llm_predict_basic"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_basic", Parameter: "", Confirm: false }
	Actions["llm_predict_batch_advanced"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_batch_advanced", Parameter: "", Confirm: false }
	Actions["llm_predict_raw"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_raw", Parameter: "", Confirm: false }
	Actions["llm_predict_rewrite"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_rewrite", Parameter: "", Confirm: false }
	Actions["llm_predict_tone_familiar"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_tone_familiar", Parameter: "", Confirm: false }
	Actions["llm_predict_tone_formal"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_tone_formal", Parameter: "", Confirm: false }
	Actions["llm_predict_tone_neutral"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_tone_neutral", Parameter: "", Confirm: false }
	Actions["llm_predict_tone_very_formal"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_tone_very_formal", Parameter: "", Confirm: false }
	Actions["llm_predict_translate_en"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_translate_en", Parameter: "", Confirm: false }
	Actions["llm_predict_translate_ja"] := { Family: "sg", LabelKey: "sg_actions.llm_predict_translate_ja", Parameter: "", Confirm: false }
	Actions["llm_prompt_prediction"] := { Family: "sg", LabelKey: "sg_actions.llm_prompt_prediction", Parameter: "llm_prompt", Confirm: false }
	Actions["llm_screen_error"] := { Family: "sg", LabelKey: "sg_actions.llm_screen_error", Parameter: "llm_vision", Confirm: false }
	Actions["llm_screen_full"] := { Family: "sg", LabelKey: "sg_actions.llm_screen_full", Parameter: "llm_vision", Confirm: false }
	Actions["llm_screen_region"] := { Family: "sg", LabelKey: "sg_actions.llm_screen_region", Parameter: "llm_vision", Confirm: false }
	Actions["llm_tone_more_familiar"] := { Family: "sg", LabelKey: "sg_actions.llm_tone_more_familiar", Parameter: "", Confirm: false }
	Actions["llm_tone_more_familiar_cycle"] := { Family: "sg", LabelKey: "sg_actions.llm_tone_more_familiar_cycle", Parameter: "", Confirm: false }
	Actions["llm_tone_more_formal"] := { Family: "sg", LabelKey: "sg_actions.llm_tone_more_formal", Parameter: "", Confirm: false }
	Actions["llm_tone_more_formal_cycle"] := { Family: "sg", LabelKey: "sg_actions.llm_tone_more_formal_cycle", Parameter: "", Confirm: false }
	Actions["llm_translate_context"] := { Family: "sg", LabelKey: "sg_actions.llm_translate_context", Parameter: "llm_language", Confirm: false }
	Actions["llm_translate_selection"] := { Family: "sg", LabelKey: "sg_actions.llm_translate_selection", Parameter: "llm_language", Confirm: false }
	Actions["lock_screen"] := { Family: "sg", LabelKey: "sg_actions.lock_screen", Parameter: "", Confirm: false }
	Actions["maximize"] := { Family: "sg", LabelKey: "sg_actions.maximize", Parameter: "", Confirm: false }
	Actions["mic_mute_toggle"] := { Family: "sg", LabelKey: "sg_actions.mic_mute_toggle", Parameter: "", Confirm: false }
	Actions["microsoft_bold"] := { Family: "sg", LabelKey: "sg_actions.microsoft_bold", Parameter: "", Confirm: false }
	Actions["minimize_all"] := { Family: "sg", LabelKey: "sg_actions.minimize_all", Parameter: "", Confirm: false }
	Actions["mute"] := { Family: "sg", LabelKey: "sg_actions.mute", Parameter: "", Confirm: false }
	Actions["nav_back"] := { Family: "sg", LabelKey: "sg_actions.nav_back", Parameter: "", Confirm: false }
	Actions["nav_forward"] := { Family: "sg", LabelKey: "sg_actions.nav_forward", Parameter: "", Confirm: false }
	Actions["new_text_file_here"] := { Family: "sg", LabelKey: "sg_actions.new_text_file_here", Parameter: "", Confirm: false }
	Actions["none"] := { Family: "sg", LabelKey: "sg_actions.none", Parameter: "", Confirm: false }
	Actions["notification_center"] := { Family: "sg", LabelKey: "sg_actions.notification_center", Parameter: "", Confirm: false }
	Actions["ocr_screenshot"] := { Family: "sg", LabelKey: "sg_actions.ocr_screenshot", Parameter: "", Confirm: false }
	Actions["one_shot_shift"] := { Family: "sg", LabelKey: "sg_actions.one_shot_shift", Parameter: "", Confirm: false }
	Actions["open_app"] := { Family: "sg", LabelKey: "sg_actions.open_app", Parameter: "app", Confirm: false }
	Actions["open_config"] := { Family: "sg", LabelKey: "sg_actions.open_config", Parameter: "", Confirm: false }
	Actions["open_downloads"] := { Family: "sg", LabelKey: "sg_actions.open_downloads", Parameter: "", Confirm: false }
	Actions["open_emoji_picker"] := { Family: "sg", LabelKey: "sg_actions.open_emoji_picker", Parameter: "", Confirm: false }
	Actions["open_error_log"] := { Family: "sg", LabelKey: "sg_actions.open_error_log", Parameter: "", Confirm: false }
	Actions["open_file_manager"] := { Family: "sg", LabelKey: "sg_actions.open_file_manager", Parameter: "", Confirm: false }
	Actions["open_hotstrings_editor"] := { Family: "sg", LabelKey: "sg_actions.open_hotstrings_editor", Parameter: "", Confirm: false }
	Actions["open_key_history"] := { Family: "sg", LabelKey: "sg_actions.open_key_history", Parameter: "", Confirm: false }
	Actions["open_list_vars"] := { Family: "sg", LabelKey: "sg_actions.open_list_vars", Parameter: "", Confirm: false }
	Actions["open_logs_folder"] := { Family: "sg", LabelKey: "sg_actions.open_logs_folder", Parameter: "", Confirm: false }
	Actions["open_metrics_apps"] := { Family: "sg", LabelKey: "sg_actions.open_metrics_apps", Parameter: "", Confirm: false }
	Actions["open_metrics_typing"] := { Family: "sg", LabelKey: "sg_actions.open_metrics_typing", Parameter: "", Confirm: false }
	Actions["open_paths_editor"] := { Family: "sg", LabelKey: "sg_actions.open_paths_editor", Parameter: "", Confirm: false }
	Actions["open_personal_hotstrings"] := { Family: "sg", LabelKey: "sg_actions.open_personal_hotstrings", Parameter: "", Confirm: false }
	Actions["open_personal_info"] := { Family: "sg", LabelKey: "sg_actions.open_personal_info", Parameter: "", Confirm: false }
	Actions["open_personal_shortcuts"] := { Family: "sg", LabelKey: "sg_actions.open_personal_shortcuts", Parameter: "", Confirm: false }
	Actions["open_script_source"] := { Family: "sg", LabelKey: "sg_actions.open_script_source", Parameter: "", Confirm: false }
	Actions["open_system_settings"] := { Family: "sg", LabelKey: "sg_actions.open_system_settings", Parameter: "", Confirm: false }
	Actions["open_terminal_here"] := { Family: "sg", LabelKey: "sg_actions.open_terminal_here", Parameter: "", Confirm: false }
	Actions["open_today_log"] := { Family: "sg", LabelKey: "sg_actions.open_today_log", Parameter: "", Confirm: false }
	Actions["open_url"] := { Family: "sg", LabelKey: "sg_actions.open_url", Parameter: "url", Confirm: false }
	Actions["open_window_spy"] := { Family: "sg", LabelKey: "sg_actions.open_window_spy", Parameter: "", Confirm: false }
	Actions["para_next"] := { Family: "sg", LabelKey: "sg_actions.para_next", Parameter: "", Confirm: false }
	Actions["para_prev"] := { Family: "sg", LabelKey: "sg_actions.para_prev", Parameter: "", Confirm: false }
	Actions["paste"] := { Family: "sg", LabelKey: "sg_actions.paste", Parameter: "", Confirm: false }
	Actions["paste_plain"] := { Family: "sg", LabelKey: "sg_actions.paste_plain", Parameter: "", Confirm: false }
	Actions["pick_color"] := { Family: "sg", LabelKey: "sg_actions.pick_color", Parameter: "", Confirm: false }
	Actions["quit_frontmost_app"] := { Family: "sg", LabelKey: "sg_actions.quit_frontmost_app", Parameter: "", Confirm: false }
	Actions["redo"] := { Family: "sg", LabelKey: "sg_actions.redo", Parameter: "", Confirm: false }
	Actions["right_click_toggle"] := { Family: "sg", LabelKey: "sg_actions.right_click_toggle", Parameter: "", Confirm: false }
	Actions["run_program"] := { Family: "sg", LabelKey: "sg_actions.run_program", Parameter: "program", Confirm: false }
	Actions["screen_capture"] := { Family: "sg", LabelKey: "sg_actions.screen_capture", Parameter: "", Confirm: false }
	Actions["screen_capture_instant"] := { Family: "sg", LabelKey: "sg_actions.screen_capture_instant", Parameter: "", Confirm: false }
	Actions["screen_record"] := { Family: "sg", LabelKey: "sg_actions.screen_record", Parameter: "", Confirm: false }
	Actions["screenshot_fullscreen_clipboard"] := { Family: "sg", LabelKey: "sg_actions.screenshot_fullscreen_clipboard", Parameter: "", Confirm: false }
	Actions["screenshot_fullscreen_save"] := { Family: "sg", LabelKey: "sg_actions.screenshot_fullscreen_save", Parameter: "", Confirm: false }
	Actions["screenshot_region_clipboard"] := { Family: "sg", LabelKey: "sg_actions.screenshot_region_clipboard", Parameter: "", Confirm: false }
	Actions["screenshot_region_save"] := { Family: "sg", LabelKey: "sg_actions.screenshot_region_save", Parameter: "", Confirm: false }
	Actions["screenshot_window_clipboard"] := { Family: "sg", LabelKey: "sg_actions.screenshot_window_clipboard", Parameter: "", Confirm: false }
	Actions["screenshot_window_save"] := { Family: "sg", LabelKey: "sg_actions.screenshot_window_save", Parameter: "", Confirm: false }
	Actions["script_pause_toggle"] := { Family: "sg", LabelKey: "sg_actions.script_pause_toggle", Parameter: "", Confirm: false }
	Actions["script_quit"] := { Family: "sg", LabelKey: "sg_actions.script_quit", Parameter: "", Confirm: false }
	Actions["script_reload"] := { Family: "sg", LabelKey: "sg_actions.script_reload", Parameter: "", Confirm: false }
	Actions["script_save_reload"] := { Family: "sg", LabelKey: "sg_actions.script_save_reload", Parameter: "", Confirm: false }
	Actions["search_web"] := { Family: "sg", LabelKey: "sg_actions.search_web", Parameter: "search_url", Confirm: false }
	Actions["sel_down"] := { Family: "sg", LabelKey: "sg_actions.sel_down", Parameter: "", Confirm: false }
	Actions["sel_left"] := { Family: "sg", LabelKey: "sg_actions.sel_left", Parameter: "", Confirm: false }
	Actions["sel_right"] := { Family: "sg", LabelKey: "sg_actions.sel_right", Parameter: "", Confirm: false }
	Actions["sel_up"] := { Family: "sg", LabelKey: "sg_actions.sel_up", Parameter: "", Confirm: false }
	Actions["sel_word_next"] := { Family: "sg", LabelKey: "sg_actions.sel_word_next", Parameter: "", Confirm: false }
	Actions["sel_word_prev"] := { Family: "sg", LabelKey: "sg_actions.sel_word_prev", Parameter: "", Confirm: false }
	Actions["select_all"] := { Family: "sg", LabelKey: "sg_actions.select_all", Parameter: "", Confirm: false }
	Actions["select_line"] := { Family: "sg", LabelKey: "sg_actions.select_line", Parameter: "", Confirm: false }
	Actions["select_word"] := { Family: "sg", LabelKey: "sg_actions.select_word", Parameter: "", Confirm: false }
	Actions["selection_lowercase"] := { Family: "sg", LabelKey: "sg_actions.selection_lowercase", Parameter: "", Confirm: false }
	Actions["selection_titlecase"] := { Family: "sg", LabelKey: "sg_actions.selection_titlecase", Parameter: "", Confirm: false }
	Actions["selection_uppercase"] := { Family: "sg", LabelKey: "sg_actions.selection_uppercase", Parameter: "", Confirm: false }
	Actions["send_key"] := { Family: "sg", LabelKey: "sg_actions.send_key", Parameter: "key", Confirm: false }
	Actions["send_shortcut"] := { Family: "sg", LabelKey: "sg_actions.send_shortcut", Parameter: "shortcut", Confirm: false }
	Actions["send_text"] := { Family: "sg", LabelKey: "sg_actions.send_text", Parameter: "text", Confirm: false }
	Actions["show_desktop"] := { Family: "sg", LabelKey: "sg_actions.show_desktop", Parameter: "", Confirm: false }
	Actions["sleep_displays"] := { Family: "sg", LabelKey: "sg_actions.sleep_displays", Parameter: "", Confirm: false }
	Actions["snap_left"] := { Family: "sg", LabelKey: "sg_actions.snap_left", Parameter: "", Confirm: false }
	Actions["snap_right"] := { Family: "sg", LabelKey: "sg_actions.snap_right", Parameter: "", Confirm: false }
	Actions["space"] := { Family: "sg", LabelKey: "sg_actions.space", Parameter: "", Confirm: false }
	Actions["spotlight_mouse"] := { Family: "sg", LabelKey: "sg_actions.spotlight_mouse", Parameter: "", Confirm: false }
	Actions["surround_parens"] := { Family: "sg", LabelKey: "sg_actions.surround_parens", Parameter: "", Confirm: false }
	Actions["tab"] := { Family: "sg", LabelKey: "sg_actions.tab", Parameter: "", Confirm: false }
	Actions["tab_close"] := { Family: "sg", LabelKey: "sg_actions.tab_close", Parameter: "", Confirm: false }
	Actions["tab_new"] := { Family: "sg", LabelKey: "sg_actions.tab_new", Parameter: "", Confirm: false }
	Actions["tab_next"] := { Family: "sg", LabelKey: "sg_actions.tab_next", Parameter: "", Confirm: false }
	Actions["tab_prev"] := { Family: "sg", LabelKey: "sg_actions.tab_prev", Parameter: "", Confirm: false }
	Actions["take_note"] := { Family: "sg", LabelKey: "sg_actions.take_note", Parameter: "", Confirm: false }
	Actions["task_view"] := { Family: "sg", LabelKey: "sg_actions.task_view", Parameter: "", Confirm: false }
	Actions["teleport_mouse"] := { Family: "sg", LabelKey: "sg_actions.teleport_mouse", Parameter: "", Confirm: false }
	Actions["titlecase_selection"] := { Family: "sg", LabelKey: "sg_actions.titlecase_selection", Parameter: "", Confirm: false }
	Actions["toggle_capslock"] := { Family: "sg", LabelKey: "sg_actions.toggle_capslock", Parameter: "", Confirm: false }
	Actions["toggle_dark_mode"] := { Family: "sg", LabelKey: "sg_actions.toggle_dark_mode", Parameter: "", Confirm: false }
	Actions["track_next"] := { Family: "sg", LabelKey: "sg_actions.track_next", Parameter: "", Confirm: false }
	Actions["track_play"] := { Family: "sg", LabelKey: "sg_actions.track_play", Parameter: "", Confirm: false }
	Actions["track_prev"] := { Family: "sg", LabelKey: "sg_actions.track_prev", Parameter: "", Confirm: false }
	Actions["unblock_file_selection"] := { Family: "sg", LabelKey: "sg_actions.unblock_file_selection", Parameter: "", Confirm: true }
	Actions["undo"] := { Family: "sg", LabelKey: "sg_actions.undo", Parameter: "", Confirm: false }
	Actions["uppercase_selection"] := { Family: "sg", LabelKey: "sg_actions.uppercase_selection", Parameter: "", Confirm: false }
	Actions["vol_down"] := { Family: "sg", LabelKey: "sg_actions.vol_down", Parameter: "", Confirm: false }
	Actions["vol_up"] := { Family: "sg", LabelKey: "sg_actions.vol_up", Parameter: "", Confirm: false }
	Actions["win_app_next"] := { Family: "sg", LabelKey: "sg_actions.win_app_next", Parameter: "", Confirm: false }
	Actions["win_app_prev"] := { Family: "sg", LabelKey: "sg_actions.win_app_prev", Parameter: "", Confirm: false }
	Actions["win_next"] := { Family: "sg", LabelKey: "sg_actions.win_next", Parameter: "", Confirm: false }
	Actions["win_prev"] := { Family: "sg", LabelKey: "sg_actions.win_prev", Parameter: "", Confirm: false }
	Actions["word_next"] := { Family: "sg", LabelKey: "sg_actions.word_next", Parameter: "", Confirm: false }
	Actions["word_prev"] := { Family: "sg", LabelKey: "sg_actions.word_prev", Parameter: "", Confirm: false }
	Actions["wrap_selection"] := { Family: "sg", LabelKey: "sg_actions.wrap_selection", Parameter: "wrap_pair", Confirm: false }
	return Catalogue
}
