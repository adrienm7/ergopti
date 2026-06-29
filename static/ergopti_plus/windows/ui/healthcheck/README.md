# healthcheck (AHK)

## Purpose

Runtime diagnostic probe accessible from the Debug menu. Snapshots the driver state (adapter presence, port validation, OS information, uptime, last 50 WARNING/ERROR log entries) and presents it in a WebView2 window. Falls back to a native read-only Edit control when WebView2 is absent. Intended for diagnosing deployment issues without attaching a debugger.

## Key files

| File      | Description                                                                  |
| --------- | ---------------------------------------------------------------------------- |
| `init.ahk`| Entry: `HealthCheck_Show()` — collects diagnostics and opens the window       |

## Usage

```ahk
HealthCheck_Show()  ; called from the Debug tray-menu item
```

The window is non-blocking (opened via `SetTimer` at delay 0 to stay off the hotkey thread). All diagnostic data is collected synchronously before the window opens; there is no live refresh.
