<!-- static/ergopti_plus/docs/architecture.md -->
<!-- AUTO-GENERATED — do not edit by hand. Run: npm run gen:diagram -->

# Architecture Overview

> Generated from port specs, domain specs, and adapter file listings.

The diagram below shows the three-layer hexagonal architecture:
**Ports** (shared contracts) → **Adapters** (driver-specific implementations) → **Domain** (pure business logic).

```mermaid
graph TD

    subgraph Ports["Ports — shared contracts"]
        P_AppLauncher["AppLauncher"]
        P_Clipboard["Clipboard"]
        P_Crypto["Crypto"]
        P_FileSystem["FileSystem"]
        P_GraphicsRenderer["GraphicsRenderer"]
        P_HotkeyRegistrar["HotkeyRegistrar"]
        P_HttpClient["HttpClient"]
        P_KeyState["KeyState"]
        P_KeyboardHook["KeyboardHook"]
        P_MouseControl["MouseControl"]
        P_NetworkInfo["NetworkInfo"]
        P_Notifier["Notifier"]
        P_ProcessLifecycle["ProcessLifecycle"]
        P_SecureFieldDetector["SecureFieldDetector"]
        P_Storage["Storage"]
        P_TextSender["TextSender"]
        P_TimerScheduler["TimerScheduler"]
        P_TooltipRenderer["TooltipRenderer"]
        P_TrayMenu["TrayMenu"]
        P_WindowInfo["WindowInfo"]
        P_WindowManager["WindowManager"]
    end

    subgraph LINUX_Adapters["Linux (Lua) Adapters — linux/adapters/"]
        LINUX_clipboard["Clipboard.lua"]
        LINUX_clipboard_owner["ClipboardOwner.lua"]
        LINUX_clipboard_owner_worker["ClipboardOwnerWorker.lua"]
        LINUX_desktop_opener["DesktopOpener.lua"]
        LINUX_desktop_opener_worker["DesktopOpenerWorker.lua"]
        LINUX_evdev_reader["EvdevReader.lua"]
        LINUX_input_source_group_worker["InputSourceGroupWorker.lua"]
        LINUX_input_source_switch["InputSourceSwitch.lua"]
        LINUX_keyboard_hook["KeyboardHook.lua"]
        LINUX_keyboard_layout["KeyboardLayout.lua"]
        LINUX_modifier_broker["ModifierBroker.lua"]
        LINUX_notifier["Notifier.lua"]
        LINUX_screen_capture["ScreenCapture.lua"]
        LINUX_selection_transaction["SelectionTransaction.lua"]
        LINUX_tap_to_click_setting["TapToClickSetting.lua"]
        LINUX_tray_menu["TrayMenu.lua"]
        LINUX_uinput_writer["UinputWriter.lua"]
        LINUX_user_hotstring_destination["UserHotstringDestination.lua"]
        LINUX_wayland_selection_counter["WaylandSelectionCounter.lua"]
        LINUX_window_switch["WindowSwitch.lua"]
        LINUX_wpm_surface["WpmSurface.lua"]
        LINUX_x11_keymap_watch_worker["X11KeymapWatchWorker.lua"]
        LINUX_x11_selection_stamp["X11SelectionStamp.lua"]
        LINUX_xkb_capture["XkbCapture.lua"]
        LINUX_xkb_source_probe["XkbSourceProbe.lua"]
    end

    subgraph MACOS_Adapters["macOS (Hammerspoon) Adapters — macos/adapters/"]
        MACOS_accessibility_copies["AccessibilityCopies.lua"]
        MACOS_accessibility_permission["AccessibilityPermission.lua"]
        MACOS_app_launcher["AppLauncher.lua"]
        MACOS_apple_shortcuts["AppleShortcuts.lua"]
        MACOS_apple_shortcuts_cli["AppleShortcutsCli.lua"]
        MACOS_apple_shortcuts_native["AppleShortcutsNative.lua"]
        MACOS_boot_fatal["BootFatal.lua"]
        MACOS_clipboard["Clipboard.lua"]
        MACOS_event_provenance["EventProvenance.lua"]
        MACOS_field_check_ports["FieldCheckPorts.lua"]
        MACOS_field_probe_ports["FieldProbePorts.lua"]
        MACOS_field_run_ports["FieldRunPorts.lua"]
        MACOS_foreign_ledger_snapshot["ForeignLedgerSnapshot.lua"]
        MACOS_hotkey_registrar["HotkeyRegistrar.lua"]
        MACOS_input_source_broker["InputSourceBroker.lua"]
        MACOS_input_source_selector["InputSourceSelector.lua"]
        MACOS_installed_physical_source["InstalledPhysicalSource.lua"]
        MACOS_karabiner_coexistence["KarabinerCoexistence.lua"]
        MACOS_key_state["KeyState.lua"]
        MACOS_keyboard_geometry["KeyboardGeometry.lua"]
        MACOS_keyboard_hook["KeyboardHook.lua"]
        MACOS_keyboard_layout_files["KeyboardLayoutFiles.lua"]
        MACOS_keyboard_source_probe["KeyboardSourceProbe.lua"]
        MACOS_managed_ollama_bootstrap["ManagedOllamaBootstrap.lua"]
        MACOS_managed_ollama_daemon["ManagedOllamaDaemon.lua"]
        MACOS_managed_ollama_hint["ManagedOllamaHint.lua"]
        MACOS_managed_ollama_pull["ManagedOllamaPull.lua"]
        MACOS_metadata_command_stats["MetadataCommandStats.lua"]
        MACOS_modifier_injector["ModifierInjector.lua"]
        MACOS_mouse_control["MouseControl.lua"]
        MACOS_native_bootstrap_pty["NativeBootstrapPty.lua"]
        MACOS_native_python_probe["NativePythonProbe.lua"]
        MACOS_notifier["Notifier.lua"]
        MACOS_one_shot_shift["OneShotShift.lua"]
        MACOS_physical_context_probe["PhysicalContextProbe.lua"]
        MACOS_physical_history_context["PhysicalHistoryContext.lua"]
        MACOS_physical_lifecycle_event["PhysicalLifecycleEvent.lua"]
        MACOS_physical_observation_clock["PhysicalObservationClock.lua"]
        MACOS_physical_shortcut_hook["PhysicalShortcutHook.lua"]
        MACOS_power_source["PowerSource.lua"]
        MACOS_prediction_tooltip_port["PredictionTooltipPort.lua"]
        MACOS_privacy_settings["PrivacySettings.lua"]
        MACOS_python_interpreter["PythonInterpreter.lua"]
        MACOS_reload_breadcrumb["ReloadBreadcrumb.lua"]
        MACOS_runtime_capture_port["RuntimeCapturePort.lua"]
        MACOS_runtime_owner_ports["RuntimeOwnerPorts.lua"]
        MACOS_screen_capture["ScreenCapture.lua"]
        MACOS_synthetic_input["SyntheticInput.lua"]
        MACOS_synthetic_input_loopback_owner["SyntheticInputLoopbackOwner.lua"]
        MACOS_system_info["SystemInfo.lua"]
        MACOS_system_switcher_input["SystemSwitcherInput.lua"]
        MACOS_system_switcher_runtime["SystemSwitcherRuntime.lua"]
        MACOS_system_switcher_sampler["SystemSwitcherSampler.lua"]
        MACOS_tcc_grant["TccGrant.lua"]
        MACOS_text_sender["TextSender.lua"]
        MACOS_tray_menu["TrayMenu.lua"]
        MACOS_unicode_carrier["UnicodeCarrier.lua"]
        MACOS_update_launcher["UpdateLauncher.lua"]
    end

    subgraph WINDOWS_Adapters["Windows (AutoHotkey) Adapters — windows/adapters/"]
        WINDOWS_app_launcher["AppLauncher.ahk"]
        WINDOWS_bundled_apps_native["BundledAppsNative.ahk"]
        WINDOWS_clipboard["Clipboard.ahk"]
        WINDOWS_console_window["ConsoleWindow.ahk"]
        WINDOWS_crash_report_worker["CrashReportWorker.ahk"]
        WINDOWS_diagnostics_control["DiagnosticsControl.ahk"]
        WINDOWS_editor_replace["EditorReplace.ahk"]
        WINDOWS_hotkey_registrar["HotkeyRegistrar.ahk"]
        WINDOWS_input_probe_native["InputProbeNative.ahk"]
        WINDOWS_key_state["KeyState.ahk"]
        WINDOWS_keyboard_hook["KeyboardHook.ahk"]
        WINDOWS_keyboard_layout_install["KeyboardLayoutInstall.ahk"]
        WINDOWS_keyboard_layout_switch["KeyboardLayoutSwitch.ahk"]
        WINDOWS_llm_automation["LlmAutomation.ahk"]
        WINDOWS_llm_nav_event_owner["LlmNavEventOwner.ahk"]
        WINDOWS_mouse_control["MouseControl.ahk"]
        WINDOWS_notifier["Notifier.ahk"]
        WINDOWS_notify_icon["NotifyIcon.ahk"]
        WINDOWS_ollama_identity["OllamaIdentity.ahk"]
        WINDOWS_raw_input["RawInput.ahk"]
        WINDOWS_registry_notify["RegistryNotify.ahk"]
        WINDOWS_screen_brightness["ScreenBrightness.ahk"]
        WINDOWS_screen_capture["ScreenCapture.ahk"]
        WINDOWS_system_control["SystemControl.ahk"]
        WINDOWS_system_locale["SystemLocale.ahk"]
        WINDOWS_system_time_zone["SystemTimeZone.ahk"]
        WINDOWS_text_sender["TextSender.ahk"]
        WINDOWS_tray_menu["TrayMenu.ahk"]
        WINDOWS_tray_startup_click["TrayStartupClick.ahk"]
        WINDOWS_tray_startup_commands["TrayStartupCommands.ahk"]
        WINDOWS_updater_curl_capture["UpdaterCurlCapture.ahk"]
        WINDOWS_user_hotstrings_native["UserHotstringsNative.ahk"]
    end

    subgraph Domain["Domain — shared business logic"]
        D_Expander["Expander"]
        D_GestureRecognizer["GestureRecognizer"]
        D_HotstringMatcher["HotstringMatcher"]
        D_Registry["Registry"]
        D_Terminators["Terminators"]
    end

    %% Port implementations: Linux (Lua)
    P_Clipboard -->|implements| LINUX_clipboard
    P_KeyboardHook -->|implements| LINUX_keyboard_hook
    P_Notifier -->|implements| LINUX_notifier
    P_TrayMenu -->|implements| LINUX_tray_menu

    %% Port implementations: macOS (Hammerspoon)
    P_AppLauncher -->|implements| MACOS_app_launcher
    P_Clipboard -->|implements| MACOS_clipboard
    P_HotkeyRegistrar -->|implements| MACOS_hotkey_registrar
    P_KeyState -->|implements| MACOS_key_state
    P_KeyboardHook -->|implements| MACOS_keyboard_hook
    P_MouseControl -->|implements| MACOS_mouse_control
    P_Notifier -->|implements| MACOS_notifier
    P_TextSender -->|implements| MACOS_text_sender
    P_TrayMenu -->|implements| MACOS_tray_menu

    %% Port implementations: Windows (AutoHotkey)
    P_AppLauncher -->|implements| WINDOWS_app_launcher
    P_Clipboard -->|implements| WINDOWS_clipboard
    P_HotkeyRegistrar -->|implements| WINDOWS_hotkey_registrar
    P_KeyState -->|implements| WINDOWS_key_state
    P_KeyboardHook -->|implements| WINDOWS_keyboard_hook
    P_MouseControl -->|implements| WINDOWS_mouse_control
    P_Notifier -->|implements| WINDOWS_notifier
    P_TextSender -->|implements| WINDOWS_text_sender
    P_TrayMenu -->|implements| WINDOWS_tray_menu

    %% Key domain relationships
    D_Expander -->|uses| D_Registry
    D_HotstringMatcher -->|uses| D_Registry
    D_Expander -->|uses| D_Terminators
    D_HotstringMatcher -->|uses| D_Terminators
```
