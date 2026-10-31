<!-- docs/tooling/windows-native-dll.md -->

# Building `ergopti_nav_owner.dll`

The DLL and its manifest are tracked in `static/ergopti_plus/windows/vendor/`. One
script builds them, locally and in CI: `tools/build/build_windows_nav_owner.ps1`.

## The toolset

| Component                | Pinned version | Visual Studio Installer component                     |
| ------------------------ | -------------- | ----------------------------------------------------- |
| MSVC (Build Tools 16.11) | 14.29.30133    | `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`   |
| Windows SDK              | 10.0.19041.0   | `Microsoft.VisualStudio.Component.Windows10SDK.19041` |

The pin lives in the script (`$pinnedMsvcToolset`, `$pinnedWindowsSdk`) and in the
manifest's `build_recipe`. Install them, from an elevated prompt when the installer
asks for it, with Microsoft's bootstrapper for Visual Studio 2019 Build Tools after
checking its Microsoft signature (`Get-AuthenticodeSignature`):

```
vs_BuildTools.exe --quiet --wait --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows10SDK.19041
```

## The two modes

- **Check** (`build_windows_nav_owner.ps1`, what CI runs): compiles and runs the
  hook-free native tests with whatever MSVC the host has, then checks the tracked
  DLL against its manifest: sources and recipe fingerprint, DLL hash, PE mitigations,
  exports, no dynamic C runtime. It does not compare the bytes it built with the
  tracked ones: `windows-latest` moves to newer compilers on its own.
- **Publish** (`-UpdateTracked`): refuses any toolset but the pinned one, then replaces
  the DLL and the manifest. This is the only way to change them. `/Brepro` and the
  pinned toolset make the bytes reproducible: two checkouts at different paths build
  the same SHA-256.

Any edit of a `.c`, `.h` or `.def` in `native/nav_event_owner/`, of `CMakeLists.txt` or
of the script changes the fingerprint, so CI fails until the pair is published again.
Commit the DLL and the manifest with the source change they come from.

## What ships unsigned

The DLL is not Authenticode-signed, and neither is the exe that extracts it: stable
Windows releases are unsigned by decision until SignPath is on
([application](signpath-foundation-application.md)). Its integrity comes from the hash
in the manifest, not from a signature.
