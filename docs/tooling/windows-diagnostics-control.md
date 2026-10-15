<!-- docs/tooling/windows-diagnostics-control.md -->

# Opening Windows Diagnostics from a local tool

The Windows driver accepts an explicit request to open its existing Diagnostics
window. This also works while the application exposes only its notification-area
icon. Use the x64 Windows PowerShell host and the executable's verified SHA-256:

```powershell
powershell.exe -NoProfile -File tools/diagnostics/open_windows_diagnostics.ps1 `
    -TargetProcessId 1234 `
    -ExpectedExecutableSha256 '<64 hexadecimal characters>'
```

Choose the running driver's actual PID and the hash of the exact received build.
The helper retains that process, checks the executable hash, locates its unique
AutoHotkey main window (including a hidden window), then sends the registered
`Ergopti.Diagnostics.Open.v1` Win32 message. Its payload carries the PID and native
process creation time; the receiver checks both against its own lifetime before
accepting the request. This prevents a recycled window handle from opening a
different compatible receiver.

The endpoint is registered only after driver readiness and retired through the
ordinary shutdown owner. It accepts Diagnostics while the driver is paused.
Window creation runs on a deferred callback, outside the synchronous Win32
message. Duplicate pending requests coalesce. The endpoint never starts a second
driver, injects input, downloads anything, starts a collection or exports data.
This is a local window-control protocol, not an authentication boundary.

A successful JSON response reports `request_accepted: true` and
`window_opened: "UNVERIFIED"`. Verify the actual returned Diagnostics window
separately; acknowledgement proves only that the request was queued. A transport
timeout has an unknown outcome and must not trigger an automatic retry. A build
without this endpoint refuses acknowledgement rather than pretending to open it.

The helper is Windows-only because its transport is Win32 and targets the AHK
driver. It changes no shared Diagnostics actions or macOS/Linux driver behavior.
Their native acceptance remains separate. Collecting Windows diagnostics still
uses the existing Diagnostics action and retains its own consent, guided steps,
source, archive and worker-retirement checks.
