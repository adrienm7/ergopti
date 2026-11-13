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

    subgraph MACOS_Adapters["macOS (Hammerspoon) Adapters — macos/adapters/"]
        MACOS_update_launcher["UpdateLauncher.lua"]
    end

    subgraph WINDOWS_Adapters["Windows (AutoHotkey) Adapters — windows/adapters/"]
        WINDOWS_updater_curl_capture["UpdaterCurlCapture.ahk"]
    end

    subgraph Domain["Domain — shared business logic"]
        D_Expander["Expander"]
        D_GestureRecognizer["GestureRecognizer"]
        D_HotstringMatcher["HotstringMatcher"]
        D_Registry["Registry"]
        D_Terminators["Terminators"]
    end

    %% Port implementations: macOS (Hammerspoon)

    %% Port implementations: Windows (AutoHotkey)

    %% Key domain relationships
    D_Expander -->|uses| D_Registry
    D_HotstringMatcher -->|uses| D_Registry
    D_Expander -->|uses| D_Terminators
    D_HotstringMatcher -->|uses| D_Terminators
```
