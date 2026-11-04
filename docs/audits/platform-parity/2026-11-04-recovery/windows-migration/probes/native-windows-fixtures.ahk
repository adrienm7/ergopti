; UNEXECUTED native Windows/AHK probe. Actual migration owner included below.
; All folder getters and FS ports resolve ONLY to this script's fresh A_Temp tree.
; Does not launch the driver, mutate environment variables or access real user config.
#Requires AutoHotkey v2.0
ProbeRoot := ""
ProbeMode := ""
ProbeLogs := []
for Mode in ["control", "backup-taken", "write-refused", "nested", "quoted-key", "wal"] {
    ProbeRoot := A_Temp . "\ergopti_migration_audit_" . A_TickCount . "_" . Mode
    ProbeMode := Mode
    ProbeLogs := []
    if FileExist(ProbeRoot)
        throw Error("Fixture root must be fresh")
    DirCreate(ProbeRoot)
    Old := AppFoldersBase("USERPROFILE") . "\.config\ergopti_plus"
    New := RTrim(AppFoldersDefaultConfigDir(), "\")
    Legacy := AppFoldersBase("APPDATA") . "\Ergopti\paths.toml"
    Locator := AppFoldersPathsFile()
    ProbeWrite(Old . "\config.toml", "OWNER=PERSONAL`n")
    Value := StrReplace(Old, "\", "/")
    Text := 'ConfigDirPath = "' . Value . '/"' . "`n"
    if Mode == "nested" {
        ProbeWrite(Old . "\profiles\private\config.toml", "OWNER=PRIVATE`n")
        Text := 'ConfigDirPath = "' . Value . '/profiles/private/"' . "`n"
    }
    if Mode == "quoted-key"
        Text := '"ConfigDirPath" = "' . Value . '/"' . "`n"
    ProbeWrite(Legacy, Text)
    if Mode == "backup-taken"
        ProbeWrite(Locator . AppDirsMigrationBackupSuffix(), "foreign backup")
    if Mode == "wal"
        ProbeWrite(Legacy . ".config-transition.wal", "malformed WAL must quarantine if inspected")
    Report := LegacyFolderMigrationRun(Locator)
    if Mode == "control" {
        ProbeAssert(Report["paths_file"] == "rewritten" && FileExist(New . "\config.toml"), Mode)
        ProbeAssert(LegacyFolderMigrationRun(Locator)["paths_file"] == "unchanged", "idempotent")
    } else if Mode == "backup-taken" {
        ProbeAssert(Report["paths_file"] == "backup_refused" && !DirExist(Old)
            && InStr(FileRead(Locator, "UTF-8"), Value), Mode)
    } else if Mode == "write-refused" {
        ProbeAssert(Report["paths_file"] == "backup_refused" && !FileExist(Locator)
            && FileExist(Locator . AppDirsMigrationBackupSuffix()), Mode)
    } else if Mode == "nested" || Mode == "quoted-key" {
        ProbeAssert(Report["paths_file"] == "unchanged" && !DirExist(Old)
            && InStr(FileRead(Locator, "UTF-8"), Value), Mode)
    } else if Mode == "wal" {
        ProbeAssert(FileExist(Legacy . ".config-transition.wal")
            && !FileExist(Locator . ".config-transition.wal"), Mode)
    }
    FileAppend("Observed " . Mode . " in " . ProbeRoot . "`n", "*")
}
ExitApp(0)
ProbeAssert(Value, Label) {
    if !Value
        throw Error("Unexpected observation: " . Label)
}
ProbeWrite(Path, Text) {
    SplitPath(Path, , &Parent)
    DirCreate(Parent)
    FH := FileOpen(Path, "w", "UTF-8-RAW")
    FH.Write(Text)
    FH.Close()
    return true
}
AppFoldersBase(Name) {
    global ProbeRoot
    return ProbeRoot . "\" . Name
}
AppFoldersRoot() => AppFoldersBase("LOCALAPPDATA") . "\Ergopti\"
AppFoldersDefaultConfigDir() => AppFoldersRoot() . "config\"
AppFoldersPathsFile() => AppFoldersRoot() . "paths.toml"
AppFoldersManagedOllamaRoot() => AppFoldersBase("LOCALAPPDATA") . "\Ergopti-ollama"
AppDirsMigrationBackupFolder() => "before-folder-migration"
AppDirsMigrationBackupSuffix() => ".before-folder-migration"
AppDirsMigrationWindowsLegacyPathsFileBaseEnv() => "APPDATA"
AppDirsMigrationWindowsLegacyPathsFileRelative() => "Ergopti\paths.toml"
AppDirsMigrationWindowsLegacyConfigBaseEnv() => "USERPROFILE"
AppDirsMigrationWindowsLegacyConfigRelative() => ".config\ergopti_plus"
AppDirsMigrationWindowsLegacyLocalFolder() => "ergopti_plus"
AppDirsMigrationWindowsLegacyOllamaFolder() => "ergopti_plus_ollama"
AppDirsLogsOverrideKey() => "LogsDirPath"
LoggerDefaultLogsDir() => AppFoldersRoot() . "logs\"
FSReadStrict(Path) => FileRead(Path, "UTF-8")
FSMove(From, To, Overwrite := false) {
    try {
        FileMove(From, To, Overwrite)
        return true
    } catch {
        return false
    }
}
FSCopyCreateVerified(From, To) {
    try {
        FileCopy(From, To, false)
        return FileRead(From, "UTF-8") == FileRead(To, "UTF-8")
    } catch {
        return false
    }
}
FSWrite(Path, Text) {
    global ProbeMode
    if ProbeMode == "write-refused" {
        ProbeWrite(Path, SubStr(Text, 1, 5))
        FileDelete(Path)
        return false
    }
    return ProbeWrite(Path, Text)
}
LoggerInfo(*) => 0
LoggerWarn(*) => 0
#Include /workspace/ergopti/static/ergopti_plus/windows/infra/legacy_folder_migration.ahk
