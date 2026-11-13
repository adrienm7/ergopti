// Sources/ErgoptiPlus/AppDirs.generated.swift
// AUTO-GENERATED from _shared/core/fs/data/paths/app_dirs.toml.
// DO NOT EDIT BY HAND -- run `npm run codegen:app-dirs` to refresh.

// ==============================================================================
// MODULE: Application Folders and Log File Names
// DESCRIPTION:
// The launcher writes launcher.log and the fatal report in the default logs
// folder, names the dated files the Lua runtime reads back, and restricts
// only a folder named after the application to its owner. Generating these
// keeps the native side from becoming a second source for any of them.
// ==============================================================================

/// Folder named after the application on macOS (and Windows).
let kAppFolderName = "Ergopti"

/// Daily unified log: <prefix>yyyy-MM-dd<extension>.
let kLogUnifiedPrefix = "ErgoptiPlus_"

/// Daily WARNING and ERROR mirror: <prefix>yyyy-MM-dd<extension>.
let kLogErrorsPrefix = "ErgoptiPlus_errors_"

/// Topical sub-files: <prefix><name><extension>.
let kLogTopicalPrefix = "ErgoptiPlus_"

/// Extension of every log file.
let kLogFileExtension = ".log"

/// Default logs folder, relative to the home folder.
let kMacOSLogsHomeRelativePath = "Library/Logs/Ergopti"

/// Launcher diagnostic log, always in the default logs folder.
let kLauncherLogFileName = "launcher.log"

/// Per-launch fatal report, beside launcher.log.
let kFatalReportFileName = "hammerspoon-fatal.txt"

/// The paths.toml that may move the configuration folder, relative to the home folder.
let kMacOSPathsFileHomeRelativePath = "Library/Application Support/Ergopti/paths.toml"

/// The Ergopti root (managed runtimes, locks, control), relative to the home folder.
let kMacOSSupportHomeRelativePath = "Library/Application Support/Ergopti"

/// The cache folder, relative to the home folder.
let kMacOSCacheHomeRelativePath = "Library/Caches/Ergopti"

/// Folder name the owned Karabiner runtime is compiled with, kept until its rebuild.
let kMacOSOwnedRuntimeFolderName = "ErgoptiPlus"
