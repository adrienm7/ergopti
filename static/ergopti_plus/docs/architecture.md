<!-- static/ergopti_plus/docs/architecture.md -->
<!-- AUTO-GENERATED — do not edit by hand. Run: npm run gen:diagram -->

# Architecture Overview

> Generated on 2026-08-02 from port specs, domain specs, and adapter file listings.

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
        LINUX_crypto["Crypto.lua"]
        LINUX_event_loop["EventLoop.lua"]
        LINUX_file_system["FileSystem.lua"]
        LINUX_http_client["HttpClient.lua"]
        LINUX_keyboard_hook["KeyboardHook.lua"]
        LINUX_process_lifecycle["ProcessLifecycle.lua"]
        LINUX_secure_field_detector["SecureFieldDetector.lua"]
        LINUX_shell_runner["ShellRunner.lua"]
        LINUX_storage["Storage.lua"]
        LINUX_text_sender["TextSender.lua"]
        LINUX_timer_scheduler["TimerScheduler.lua"]
        LINUX_tray_menu["TrayMenu.lua"]
        LINUX_uinput_writer["UinputWriter.lua"]
        LINUX_window_info["WindowInfo.lua"]
    end

    subgraph MACOS_Adapters["macOS (Hammerspoon) Adapters — macos/adapters/"]
        MACOS_app_launcher["AppLauncher.lua"]
        MACOS_clipboard["Clipboard.lua"]
        MACOS_crypto["Crypto.lua"]
        MACOS_event_tap_guard["EventTapGuard.lua"]
        MACOS_file_system["FileSystem.lua"]
        MACOS_graphics_renderer["GraphicsRenderer.lua"]
        MACOS_http_client["HttpClient.lua"]
        MACOS_json_codec["JsonCodec.lua"]
        MACOS_key_state["KeyState.lua"]
        MACOS_keyboard_hook["KeyboardHook.lua"]
        MACOS_mouse_control["MouseControl.lua"]
        MACOS_network_info["NetworkInfo.lua"]
        MACOS_notifier["Notifier.lua"]
        MACOS_process_lifecycle["ProcessLifecycle.lua"]
        MACOS_secure_field_detector["SecureFieldDetector.lua"]
        MACOS_shell_runner["ShellRunner.lua"]
        MACOS_storage["Storage.lua"]
        MACOS_text_sender["TextSender.lua"]
        MACOS_timer_scheduler["TimerScheduler.lua"]
        MACOS_toml_cache["TomlCache.lua"]
        MACOS_tooltip_renderer["TooltipRenderer.lua"]
        MACOS_tray_menu["TrayMenu.lua"]
        MACOS_window_info["WindowInfo.lua"]
        MACOS_window_manager["WindowManager.lua"]
    end

    subgraph WINDOWS_Adapters["Windows (AutoHotkey) Adapters — windows/adapters/"]
        WINDOWS_app_launcher["AppLauncher.ahk"]
        WINDOWS_clipboard["Clipboard.ahk"]
        WINDOWS_crypto["Crypto.ahk"]
        WINDOWS_file_system["FileSystem.ahk"]
        WINDOWS_graphics_renderer["GraphicsRenderer.ahk"]
        WINDOWS_http_client["HttpClient.ahk"]
        WINDOWS_key_state["KeyState.ahk"]
        WINDOWS_keyboard_hook["KeyboardHook.ahk"]
        WINDOWS_mouse_control["MouseControl.ahk"]
        WINDOWS_network_info["NetworkInfo.ahk"]
        WINDOWS_notifier["Notifier.ahk"]
        WINDOWS_process_lifecycle["ProcessLifecycle.ahk"]
        WINDOWS_secure_field_detector["SecureFieldDetector.ahk"]
        WINDOWS_shell_runner["ShellRunner.ahk"]
        WINDOWS_storage["Storage.ahk"]
        WINDOWS_text_sender["TextSender.ahk"]
        WINDOWS_timer_scheduler["TimerScheduler.ahk"]
        WINDOWS_tooltip_renderer["TooltipRenderer.ahk"]
        WINDOWS_tray_menu["TrayMenu.ahk"]
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
    P_Crypto -->|implements| LINUX_crypto
    P_FileSystem -->|implements| LINUX_file_system
    P_HttpClient -->|implements| LINUX_http_client
    P_KeyboardHook -->|implements| LINUX_keyboard_hook
    P_ProcessLifecycle -->|implements| LINUX_process_lifecycle
    P_SecureFieldDetector -->|implements| LINUX_secure_field_detector
    P_Storage -->|implements| LINUX_storage
    P_TextSender -->|implements| LINUX_text_sender
    P_TimerScheduler -->|implements| LINUX_timer_scheduler
    P_TrayMenu -->|implements| LINUX_tray_menu
    P_WindowInfo -->|implements| LINUX_window_info

    %% Port implementations: macOS (Hammerspoon)
    P_AppLauncher -->|implements| MACOS_app_launcher
    P_Clipboard -->|implements| MACOS_clipboard
    P_Crypto -->|implements| MACOS_crypto
    P_FileSystem -->|implements| MACOS_file_system
    P_GraphicsRenderer -->|implements| MACOS_graphics_renderer
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
