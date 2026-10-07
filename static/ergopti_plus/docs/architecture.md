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
        LINUX_application_notifier["ApplicationNotifier.lua"]
        LINUX_atspi_focus["AtspiFocus.lua"]
        LINUX_atspi_native_identity["AtspiNativeIdentity.lua"]
        LINUX_clipboard["Clipboard.lua"]
        LINUX_crypto["Crypto.lua"]
        LINUX_evdev_reader["EvdevReader.lua"]
        LINUX_event_loop["EventLoop.lua"]
        LINUX_file_digest["FileDigest.lua"]
        LINUX_file_system["FileSystem.lua"]
        LINUX_graphics_renderer["GraphicsRenderer.lua"]
        LINUX_http_client["HttpClient.lua"]
        LINUX_keyboard_hook["KeyboardHook.lua"]
        LINUX_keyboard_layout["KeyboardLayout.lua"]
        LINUX_modifier_broker["ModifierBroker.lua"]
        LINUX_notifier["Notifier.lua"]
        LINUX_owned_process["OwnedProcess.lua"]
        LINUX_process_lifecycle["ProcessLifecycle.lua"]
        LINUX_process_runner["ProcessRunner.lua"]
        LINUX_program_providers["ProgramProviders.lua"]
        LINUX_program_runner["ProgramRunner.lua"]
        LINUX_screen_capture["ScreenCapture.lua"]
        LINUX_secure_field_detector["SecureFieldDetector.lua"]
        LINUX_shell_runner["ShellRunner.lua"]
        LINUX_storage["Storage.lua"]
        LINUX_timer_scheduler["TimerScheduler.lua"]
        LINUX_tray_menu["TrayMenu.lua"]
        LINUX_uinput_writer["UinputWriter.lua"]
        LINUX_user_hotstring_destination["UserHotstringDestination.lua"]
        LINUX_window_info["WindowInfo.lua"]
        LINUX_window_switch["WindowSwitch.lua"]
        LINUX_wpm_surface["WpmSurface.lua"]
        LINUX_xkb_capture["XkbCapture.lua"]
        LINUX_xkb_source_probe["XkbSourceProbe.lua"]
    end

    subgraph MACOS_Adapters["macOS (Hammerspoon) Adapters — macos/adapters/"]
        MACOS_accessibility_permission["AccessibilityPermission.lua"]
        MACOS_app_launcher["AppLauncher.lua"]
        MACOS_apple_shortcuts["AppleShortcuts.lua"]
        MACOS_apple_shortcuts_native["AppleShortcutsNative.lua"]
        MACOS_application_notifier["ApplicationNotifier.lua"]
        MACOS_boot_fatal["BootFatal.lua"]
        MACOS_boot_journal["BootJournal.lua"]
        MACOS_clipboard["Clipboard.lua"]
        MACOS_crypto["Crypto.lua"]
        MACOS_event_provenance["EventProvenance.lua"]
        MACOS_file_system["FileSystem.lua"]
        MACOS_graphics_renderer["GraphicsRenderer.lua"]
        MACOS_hotkey_registrar["HotkeyRegistrar.lua"]
        MACOS_http_client["HttpClient.lua"]
        MACOS_input_source_broker["InputSourceBroker.lua"]
        MACOS_json_codec["JsonCodec.lua"]
        MACOS_key_state["KeyState.lua"]
        MACOS_keyboard_hook["KeyboardHook.lua"]
        MACOS_keyboard_source_probe["KeyboardSourceProbe.lua"]
        MACOS_log_transport["LogTransport.lua"]
        MACOS_modifier_injector["ModifierInjector.lua"]
        MACOS_mouse_control["MouseControl.lua"]
        MACOS_network_info["NetworkInfo.lua"]
        MACOS_notifier["Notifier.lua"]
        MACOS_one_shot_shift["OneShotShift.lua"]
        MACOS_owned_program_runner["OwnedProgramRunner.lua"]
        MACOS_physical_shortcut_hook["PhysicalShortcutHook.lua"]
        MACOS_process_lifecycle["ProcessLifecycle.lua"]
        MACOS_program_providers["ProgramProviders.lua"]
        MACOS_python_interpreter["PythonInterpreter.lua"]
        MACOS_screen_capture["ScreenCapture.lua"]
        MACOS_secure_field_detector["SecureFieldDetector.lua"]
        MACOS_shell_runner["ShellRunner.lua"]
        MACOS_storage["Storage.lua"]
        MACOS_synthetic_input["SyntheticInput.lua"]
        MACOS_system_info["SystemInfo.lua"]
        MACOS_system_switcher_input["SystemSwitcherInput.lua"]
        MACOS_system_switcher_runtime["SystemSwitcherRuntime.lua"]
        MACOS_system_switcher_sampler["SystemSwitcherSampler.lua"]
        MACOS_task_environment["TaskEnvironment.lua"]
        MACOS_task_lifecycle["TaskLifecycle.lua"]
        MACOS_tcc_grant["TccGrant.lua"]
        MACOS_text_sender["TextSender.lua"]
        MACOS_timer_scheduler["TimerScheduler.lua"]
        MACOS_toml_cache["TomlCache.lua"]
        MACOS_tooltip_renderer["TooltipRenderer.lua"]
        MACOS_tray_menu["TrayMenu.lua"]
        MACOS_update_launcher["UpdateLauncher.lua"]
        MACOS_wake_watcher["WakeWatcher.lua"]
        MACOS_webview_result["WebviewResult.lua"]
        MACOS_window_info["WindowInfo.lua"]
        MACOS_window_manager["WindowManager.lua"]
    end

    subgraph WINDOWS_Adapters["Windows (AutoHotkey) Adapters — windows/adapters/"]
        WINDOWS_app_launcher["AppLauncher.ahk"]
        WINDOWS_boot_clock["BootClock.ahk"]
        WINDOWS_clipboard["Clipboard.ahk"]
        WINDOWS_console_window["ConsoleWindow.ahk"]
        WINDOWS_crash_report_worker["CrashReportWorker.ahk"]
        WINDOWS_crypto["Crypto.ahk"]
        WINDOWS_editor_replace["EditorReplace.ahk"]
        WINDOWS_file_system["FileSystem.ahk"]
        WINDOWS_graphics_renderer["GraphicsRenderer.ahk"]
        WINDOWS_hotkey_registrar["HotkeyRegistrar.ahk"]
        WINDOWS_http_client["HttpClient.ahk"]
        WINDOWS_key_state["KeyState.ahk"]
        WINDOWS_keyboard_hook["KeyboardHook.ahk"]
        WINDOWS_llm_nav_event_owner["LlmNavEventOwner.ahk"]
        WINDOWS_mouse_control["MouseControl.ahk"]
        WINDOWS_native_folder_picker["NativeFolderPicker.ahk"]
        WINDOWS_native_number["NativeNumber.ahk"]
        WINDOWS_network_info["NetworkInfo.ahk"]
        WINDOWS_notifier["Notifier.ahk"]
        WINDOWS_process_lifecycle["ProcessLifecycle.ahk"]
        WINDOWS_program_providers["ProgramProviders.ahk"]
        WINDOWS_screen_brightness["ScreenBrightness.ahk"]
        WINDOWS_secure_field_detector["SecureFieldDetector.ahk"]
        WINDOWS_shell_runner["ShellRunner.ahk"]
        WINDOWS_storage["Storage.ahk"]
        WINDOWS_system_control["SystemControl.ahk"]
        WINDOWS_text_sender["TextSender.ahk"]
        WINDOWS_timer_scheduler["TimerScheduler.ahk"]
        WINDOWS_tooltip_renderer["TooltipRenderer.ahk"]
        WINDOWS_tray_menu["TrayMenu.ahk"]
        WINDOWS_tray_startup_click["TrayStartupClick.ahk"]
        WINDOWS_tray_startup_commands["TrayStartupCommands.ahk"]
        WINDOWS_uia_worker["UiaWorker.ahk"]
        WINDOWS_user_hotstrings_native["UserHotstringsNative.ahk"]
        WINDOWS_webview_profiles["WebviewProfiles.ahk"]
        WINDOWS_window_info["WindowInfo.ahk"]
        WINDOWS_window_manager["WindowManager.ahk"]
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
    P_Crypto -->|implements| LINUX_crypto
    P_FileSystem -->|implements| LINUX_file_system
    P_GraphicsRenderer -->|implements| LINUX_graphics_renderer
    P_HttpClient -->|implements| LINUX_http_client
    P_KeyboardHook -->|implements| LINUX_keyboard_hook
    P_Notifier -->|implements| LINUX_notifier
    P_ProcessLifecycle -->|implements| LINUX_process_lifecycle
    P_SecureFieldDetector -->|implements| LINUX_secure_field_detector
    P_Storage -->|implements| LINUX_storage
    P_TimerScheduler -->|implements| LINUX_timer_scheduler
    P_TrayMenu -->|implements| LINUX_tray_menu
    P_WindowInfo -->|implements| LINUX_window_info

    %% Port implementations: macOS (Hammerspoon)
    P_AppLauncher -->|implements| MACOS_app_launcher
    P_Clipboard -->|implements| MACOS_clipboard
    P_Crypto -->|implements| MACOS_crypto
    P_FileSystem -->|implements| MACOS_file_system
    P_GraphicsRenderer -->|implements| MACOS_graphics_renderer
    P_HotkeyRegistrar -->|implements| MACOS_hotkey_registrar
    P_HttpClient -->|implements| MACOS_http_client
    P_KeyState -->|implements| MACOS_key_state
    P_KeyboardHook -->|implements| MACOS_keyboard_hook
    P_MouseControl -->|implements| MACOS_mouse_control
    P_NetworkInfo -->|implements| MACOS_network_info
    P_Notifier -->|implements| MACOS_notifier
    P_ProcessLifecycle -->|implements| MACOS_process_lifecycle
    P_SecureFieldDetector -->|implements| MACOS_secure_field_detector
    P_Storage -->|implements| MACOS_storage
    P_TextSender -->|implements| MACOS_text_sender
    P_TimerScheduler -->|implements| MACOS_timer_scheduler
    P_TooltipRenderer -->|implements| MACOS_tooltip_renderer
    P_TrayMenu -->|implements| MACOS_tray_menu
    P_WindowInfo -->|implements| MACOS_window_info
    P_WindowManager -->|implements| MACOS_window_manager

    %% Port implementations: Windows (AutoHotkey)
    P_AppLauncher -->|implements| WINDOWS_app_launcher
    P_Clipboard -->|implements| WINDOWS_clipboard
    P_Crypto -->|implements| WINDOWS_crypto
    P_FileSystem -->|implements| WINDOWS_file_system
    P_GraphicsRenderer -->|implements| WINDOWS_graphics_renderer
    P_HotkeyRegistrar -->|implements| WINDOWS_hotkey_registrar
    P_HttpClient -->|implements| WINDOWS_http_client
    P_KeyState -->|implements| WINDOWS_key_state
    P_KeyboardHook -->|implements| WINDOWS_keyboard_hook
    P_MouseControl -->|implements| WINDOWS_mouse_control
    P_NetworkInfo -->|implements| WINDOWS_network_info
    P_Notifier -->|implements| WINDOWS_notifier
    P_ProcessLifecycle -->|implements| WINDOWS_process_lifecycle
    P_SecureFieldDetector -->|implements| WINDOWS_secure_field_detector
    P_Storage -->|implements| WINDOWS_storage
    P_TextSender -->|implements| WINDOWS_text_sender
    P_TimerScheduler -->|implements| WINDOWS_timer_scheduler
    P_TooltipRenderer -->|implements| WINDOWS_tooltip_renderer
    P_TrayMenu -->|implements| WINDOWS_tray_menu
    P_WindowInfo -->|implements| WINDOWS_window_info
    P_WindowManager -->|implements| WINDOWS_window_manager

    %% Key domain relationships
    D_Expander -->|uses| D_Registry
    D_HotstringMatcher -->|uses| D_Registry
    D_Expander -->|uses| D_Terminators
    D_HotstringMatcher -->|uses| D_Terminators
```
