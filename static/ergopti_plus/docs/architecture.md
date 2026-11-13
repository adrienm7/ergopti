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
        LINUX_input_source_group_worker["InputSourceGroupWorker.lua"]
        LINUX_input_source_switch["InputSourceSwitch.lua"]
        LINUX_keyboard_layout["KeyboardLayout.lua"]
        LINUX_user_hotstring_destination["UserHotstringDestination.lua"]
        LINUX_window_switch["WindowSwitch.lua"]
        LINUX_wpm_surface["WpmSurface.lua"]
        LINUX_x11_keymap_watch_worker["X11KeymapWatchWorker.lua"]
        LINUX_xkb_capture["XkbCapture.lua"]
        LINUX_xkb_source_probe["XkbSourceProbe.lua"]
    end

    subgraph MACOS_Adapters["macOS (Hammerspoon) Adapters — macos/adapters/"]
        MACOS_accessibility_permission["AccessibilityPermission.lua"]
        MACOS_apple_shortcuts["AppleShortcuts.lua"]
        MACOS_apple_shortcuts_cli["AppleShortcutsCli.lua"]
        MACOS_apple_shortcuts_native["AppleShortcutsNative.lua"]
        MACOS_boot_fatal["BootFatal.lua"]
        MACOS_event_provenance["EventProvenance.lua"]
        MACOS_field_check_ports["FieldCheckPorts.lua"]
        MACOS_field_probe_ports["FieldProbePorts.lua"]
        MACOS_field_run_ports["FieldRunPorts.lua"]
        MACOS_foreign_ledger_snapshot["ForeignLedgerSnapshot.lua"]
        MACOS_input_source_broker["InputSourceBroker.lua"]
        MACOS_input_source_selector["InputSourceSelector.lua"]
        MACOS_installed_physical_source["InstalledPhysicalSource.lua"]
        MACOS_karabiner_coexistence["KarabinerCoexistence.lua"]
        MACOS_keyboard_layout_files["KeyboardLayoutFiles.lua"]
        MACOS_keyboard_source_probe["KeyboardSourceProbe.lua"]
        MACOS_metadata_command_stats["MetadataCommandStats.lua"]
        MACOS_mouse_control["MouseControl.lua"]
        MACOS_one_shot_shift["OneShotShift.lua"]
        MACOS_physical_context_probe["PhysicalContextProbe.lua"]
        MACOS_physical_history_context["PhysicalHistoryContext.lua"]
        MACOS_physical_lifecycle_event["PhysicalLifecycleEvent.lua"]
        MACOS_physical_observation_clock["PhysicalObservationClock.lua"]
        MACOS_physical_shortcut_hook["PhysicalShortcutHook.lua"]
        MACOS_privacy_settings["PrivacySettings.lua"]
        MACOS_reload_breadcrumb["ReloadBreadcrumb.lua"]
        MACOS_runtime_capture_port["RuntimeCapturePort.lua"]
        MACOS_runtime_owner_ports["RuntimeOwnerPorts.lua"]
        MACOS_system_switcher_input["SystemSwitcherInput.lua"]
        MACOS_system_switcher_runtime["SystemSwitcherRuntime.lua"]
        MACOS_system_switcher_sampler["SystemSwitcherSampler.lua"]
        MACOS_tcc_grant["TccGrant.lua"]
        MACOS_update_launcher["UpdateLauncher.lua"]
    end

    subgraph WINDOWS_Adapters["Windows (AutoHotkey) Adapters — windows/adapters/"]
        WINDOWS_console_window["ConsoleWindow.ahk"]
        WINDOWS_crash_report_worker["CrashReportWorker.ahk"]
        WINDOWS_diagnostics_control["DiagnosticsControl.ahk"]
        WINDOWS_keyboard_layout_install["KeyboardLayoutInstall.ahk"]
        WINDOWS_keyboard_layout_switch["KeyboardLayoutSwitch.ahk"]
        WINDOWS_mouse_control["MouseControl.ahk"]
        WINDOWS_registry_notify["RegistryNotify.ahk"]
        WINDOWS_screen_brightness["ScreenBrightness.ahk"]
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

    %% Port implementations: macOS (Hammerspoon)
    P_MouseControl -->|implements| MACOS_mouse_control

    %% Port implementations: Windows (AutoHotkey)
    P_MouseControl -->|implements| WINDOWS_mouse_control

    %% Key domain relationships
    D_Expander -->|uses| D_Registry
    D_HotstringMatcher -->|uses| D_Registry
    D_Expander -->|uses| D_Terminators
    D_HotstringMatcher -->|uses| D_Terminators
```
