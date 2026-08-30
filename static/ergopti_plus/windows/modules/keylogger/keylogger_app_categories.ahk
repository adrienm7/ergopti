; modules/keylogger/keylogger_app_categories.ahk

; ==============================================================================
; MODULE: Keylogger App Categories
; DESCRIPTION:
; Maintains a user-editable mapping from process names to productivity
; categories (productive / neutral / distracting / unknown). The mapping
; is stored in ``app_categories.json`` inside the metrics dir alongside
; data.sql so it travels with the device's data in Git.
;
; FEATURES & RATIONALE:
; 1. Persistent sidecar — app_categories.json is a flat JSON object:
;    { "chrome.exe": "productive", "Discord.exe": "distracting", … }
;    The file is created with sensible defaults on first run and never
;    auto-overwritten once it exists, so users can customise freely.
; 2. In-memory Map — after load, KLAppCat.categories holds the runtime
;    lookup table. KL_AppCat_Get(app_name) returns the category string in
;    O(1) with a graceful "unknown" fallback.
; 3. Inject into events — KL_FlushBuffer (keylogger.ahk) calls
;    KL_AppCat_Get so the ``app_category`` field lands in every typing
;    flush entry. This lets the dashboard pivot by category without a
;    JOIN — the raw JSONL already carries the value.
; 4. Hot-reload — KL_AppCat_Reload() can be called from the future
;    settings UI or a tray menu item to pick up edits made to the JSON
;    file without restarting the script.
; 5. Auto-learn — when an unknown app is observed for the first time it
;    is added to the file as "unknown". The user can then open the file
;    (or the future category editor UI) and assign a category. This
;    surfaces every app the user has ever used in one place.
;
; CATEGORY VOCABULARY (mirrors RescueTime's model):
;   "productive"    — IDEs, terminals, documents, spreadsheets, design tools
;   "communication" — email, chat, video calls
;   "distracting"   — social media, video streaming, games
;   "neutral"       — OS utilities, file managers, launchers
;   "unknown"       — newly seen apps, not yet classified
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLAppCatConst {
		static FILE_NAME := "app_categories.json"

		; Delay before re-attempting a deferred save that fired while the driver was
		; paused. Matches the original defer window: the write is not urgent, but it
		; must not be dropped — this one-shot is the only path that persists a newly
		; discovered app category.
		static DEFERRED_SAVE_RETRY_MS := 5000

		; Defaults shipped for the most common Windows apps. Keys are the
		; lower-cased process name exactly as WinGetProcessName returns it.
		static DEFAULTS := Map(
				; ── Productive ──────────────────────────────────────────────────
				"code.exe",                  "productive",
				"devenv.exe",                "productive",
				"rider64.exe",               "productive",
				"idea64.exe",                "productive",
				"pycharm64.exe",             "productive",
				"webstorm64.exe",            "productive",
				"sublime_text.exe",          "productive",
				"notepad++.exe",             "productive",
				"notepad.exe",               "productive",
				"wordpad.exe",               "productive",
				"winword.exe",               "productive",
				"excel.exe",                 "productive",
				"powerpnt.exe",              "productive",
				"onenote.exe",               "productive",
				"obsidian.exe",              "productive",
				"notion.exe",                "productive",
				"logseq.exe",                "productive",
				"figma.exe",                 "productive",
				"illustrator.exe",           "productive",
				"photoshop.exe",             "productive",
				"inkscape.exe",              "productive",
				"gimp-2.10.exe",             "productive",
				"blender.exe",               "productive",
				"terminal.exe",              "productive",
				"windowsterminal.exe",       "productive",
				"powershell.exe",            "productive",
				"powershell_ise.exe",        "productive",
				"cmd.exe",                   "productive",
				"wt.exe",                    "productive",
				"git.exe",                   "productive",
				"github desktop.exe",        "productive",
				"sourcetree.exe",            "productive",
				"postman.exe",               "productive",
				"insomnia.exe",              "productive",
				"dbeaver.exe",               "productive",
				"tableplus.exe",             "productive",
				"datagrip64.exe",            "productive",

				; ── Communication ────────────────────────────────────────────────
				"outlook.exe",               "communication",
				"thunderbird.exe",           "communication",
				"teams.exe",                 "communication",
				"teams2.exe",                "communication",
				"zoom.exe",                  "communication",
				"slack.exe",                 "communication",
				"discord.exe",               "communication",
				"signal.exe",                "communication",
				"telegram.exe",              "communication",
				"whatsapp.exe",              "communication",
				"skype.exe",                 "communication",
				"messenger.exe",             "communication",

				; ── Neutral ──────────────────────────────────────────────────────
				"explorer.exe",              "neutral",
				"searchui.exe",              "neutral",
				"startmenuexperiencehost.exe","neutral",
				"taskmgr.exe",               "neutral",
				"regedit.exe",               "neutral",
				"mmc.exe",                   "neutral",
				"control.exe",               "neutral",
				"ms-settings.exe",           "neutral",
				"snippingtool.exe",          "neutral",
				"mspaint.exe",               "neutral",
				"calc.exe",                  "neutral",
				"everything.exe",            "neutral",
				"keypirinha.exe",            "neutral",
				"launchy.exe",               "neutral",
				"flow-launcher.exe",         "neutral",
				"1password.exe",             "neutral",
				"bitwarden.exe",             "neutral",
				"keepassxc.exe",             "neutral",
				"autohotkey64.exe",          "neutral",
				"autohotkey32.exe",          "neutral",
				"taskkill.exe",              "neutral",
				"vlc.exe",                   "neutral",
				"mpc-hc64.exe",              "neutral",

				; ── Distracting ──────────────────────────────────────────────────
				"chrome.exe",                "neutral",   ; browser — refined by URL later
				"firefox.exe",               "neutral",
				"msedge.exe",                "neutral",
				"brave.exe",                 "neutral",
				"opera.exe",                 "neutral",
				"vivaldi.exe",               "neutral",
				"spotify.exe",               "distracting",
				"netflix.exe",               "distracting",
				"steam.exe",                 "distracting",
				"epicgameslauncher.exe",     "distracting",
				"playnite.fullscreenapp.exe","distracting"
		)
}





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLAppCat {
		static categories  := Map()   ; lower(process_name) → category string
		static file_path   := ""
		static dirty       := false   ; new apps were seen and need a save
		static save_fn     := unset   ; bound timer ref for deferred save
}





; =====================================
; ===== 2.1) Initialization guard =====
; =====================================

; Returns false and logs an error if KL_AppCat_Init() has not yet been called.
; Guards every public function that reads or writes KLAppCat.categories to
; prevent silent no-ops when the module is used before the metrics dir is ready.
KL_AppCat_RequireInit(func_name) {
	if (KLAppCat.file_path = "") {
		LoggerError("KLAppCat", "'{1}' called before KL_AppCat_Init() — file_path not set.", func_name)
		return false
	}
	return true
}





; ==============================
; ==============================
; ======= 3/ Load / save =======
; ==============================
; ==============================

KL_AppCat_Init(metrics_dir) {
		return KL_AppCat_InitWithIo(metrics_dir)
}

KL_AppCat_InitWithIo(metrics_dir, ReadFn := 0, ExistsFn := 0, CreateFn := 0) {
		if (metrics_dir = "") {
				try LoggerError("KLAppCat", "Initialization requires a metrics directory.")
				return false
		}
		if (KLAppCat.file_path != "") {
				try LoggerError("KLAppCat", "Duplicate initialization refused.")
				return false
		}
		path := metrics_dir . "\" . KLAppCatConst.FILE_NAME
		cats := Map()
		if !KL_AppCat_Load(path, &cats, ReadFn, ExistsFn, CreateFn)
				return false
		KLAppCat.file_path := path
		KLAppCat.categories := cats
		KLAppCat.dirty := false
		return true
}

KL_AppCat_Load(path, &cats, ReadFn := 0, ExistsFn := 0, CreateFn := 0) {
		if !HasMethod(ReadFn, "Call")
				ReadFn := FSRead
		if !HasMethod(ExistsFn, "Call")
				ExistsFn := FSStrictExists
		if !HasMethod(CreateFn, "Call")
				CreateFn := FSWriteCreateDurable

		cats := Map()
		; Start with built-in defaults so every entry is pre-populated
		for k, v in KLAppCatConst.DEFAULTS
				cats[k] := v

		try exists := ExistsFn.Call(path)
		catch as Err {
				try LoggerError("KLAppCat", "Cannot inspect app_categories.json: {1}.", Err.Message)
				return false
		}
		if exists {
				raw := ReadFn.Call(path)
				if !(raw is String) {
						try LoggerError("KLAppCat", "Cannot read existing app_categories.json; original preserved.")
						return false
				}
				try parsed := KL_JsonDecodeObject(raw)
				catch as Err {
						try LoggerError("KLAppCat", "Invalid app_categories.json; original preserved: {1}.", Err.Message)
						return false
				}
				if !(parsed is Map) {
						try LoggerError("KLAppCat", "Invalid app_categories.json shape; original preserved.")
						return false
				}
				for k, v in parsed {
						if !(k is String) || k = "" || !(v is String) || v = "" {
								try LoggerError("KLAppCat", "Invalid app_categories.json entry; original preserved.")
								return false
						}
						cats[StrLower(k)] := v
				}
				return true
		}

		content := KL_JsonEncodeObject(cats)
		if CreateFn.Call(path, content) != 1 {
				try LoggerError("KLAppCat", "Cannot create app_categories.json without replacing an existing path.")
				return false
		}
		return true
}

KL_AppCat_Reload(ReadFn := 0, ExistsFn := 0, CreateFn := 0) {
		if !KL_AppCat_RequireInit("KL_AppCat_Reload")
				return false
		cats := Map()
		if !KL_AppCat_Load(KLAppCat.file_path, &cats, ReadFn, ExistsFn, CreateFn)
				return false
		KLAppCat.categories := cats
		KLAppCat.dirty := false
		return true
}

_KL_AppCat_SnapshotContent() {
		PreviousCritical := Critical("On")
		try {
				Snapshot := Map()
				for Key, Value in KLAppCat.categories
						Snapshot[Key] := Value
				return KL_JsonEncodeObject(Snapshot)
		} finally {
				Critical(PreviousCritical)
		}
}

_KL_AppCat_ScheduleDeferredSave() {
		if !KLAppCat.HasOwnProp("save_fn") || !IsObject(KLAppCat.save_fn)
				return false
		try {
				SetTimer(KLAppCat.save_fn, -KLAppCatConst.DEFERRED_SAVE_RETRY_MS)
				return true
		} catch as Err {
				try LoggerError("KLAppCat",
						"Could not schedule deferred category persistence: {1}.", Err.Message)
				return false
		}
}

KL_AppCat_Save(WriteFn := 0) {
		if (KLAppCat.file_path = "")
				return false
		if !IsObject(WriteFn)
				WriteFn := KL_WriteAtomic
		try {
				Content := _KL_AppCat_SnapshotContent()
				WriteFn.Call(KLAppCat.file_path, Content)
				PreviousCritical := Critical("On")
				try {
						Pending := _KL_AppCat_SnapshotContent() != Content
						KLAppCat.dirty := Pending
				} finally {
						Critical(PreviousCritical)
				}
				if Pending {
						_KL_AppCat_ScheduleDeferredSave()
						return false
				}
				return true
		} catch as e {
				try LoggerError("KLAppCat", "Failed to persist app_categories.json: {1}", e.Message)
				; dirty stays true, but that alone retries NOTHING: the deferred save is
				; a one-shot timer, and its only other arm site (KL_AppCat_Get) arms
				; BEFORE registering the app key, so once the key exists that path is
				; unreachable for the same app. Without re-arming here, a transient lock
				; lost the newly discovered category permanently. Guarded because
				; KL_AppCat_Reload can reach this before save_fn has ever been bound.
				if (KLAppCat.HasOwnProp("save_fn") && IsObject(KLAppCat.save_fn))
						_KL_AppCat_ScheduleDeferredSave()
				return false
		}
}

; Cancel the lazy timer and transfer every pending category to its durable owner
; while lifecycle shutdown is still reversible. A refused write keeps dirty=true
; and re-arms the normal retry, so the caller can reject exit without losing the
; discovery or permanently disabling future saves.
KL_AppCat_PrepareShutdown(WriteFn := 0) {
		if KLAppCat.HasOwnProp("save_fn") && IsObject(KLAppCat.save_fn)
				try SetTimer(KLAppCat.save_fn, 0)
		if !KLAppCat.dirty
				return true
		return KL_AppCat_Save(WriteFn)
}

; Deferred save — called by timer so rapid new-app discoveries are
; batched into one write rather than one write per app.
KL_AppCat_DeferredSave() {
		; SetTimer callbacks bypass native Suspend() (only Hotkeys/Hotstrings are
		; disarmed). Skipping the write while paused is right, but a bare return
		; LOSES it: this one-shot IS the only write path. Its sole other arm site,
		; KL_AppCat_Get, registers the app key BEFORE arming, so once the key exists
		; that branch is unreachable for the same app — and there is no periodic save
		; and the terminal owner only runs during shutdown. A pause landing inside
		; the 5 s window therefore
		; stranded KLAppCat.dirty forever and the new app never reached the JSON.
		; Re-arm instead of dropping the tick.
		if A_IsSuspended {
				if KLAppCat.dirty {
						; DEBUG, not TRACE: this is a status note about a re-arm, not the
						; start of an operation that completes here, so a lifecycle variant
						; would open a pair nothing in this path can ever close.
						try LoggerDebug("KLAppCat", "Deferred save re-armed — driver paused.")
						_KL_AppCat_ScheduleDeferredSave()
				}
				return
		}
		if KLAppCat.dirty
				KL_AppCat_Save()
}





; =================================
; =================================
; ======= 4/ Runtime lookup =======
; =================================
; =================================

; Returns the category for a process name (case-insensitive).
; If the app is unknown it is registered as "unknown" and a deferred
; save is scheduled so it appears in app_categories.json for the user
; to classify.
KL_AppCat_Get(app_name) {
	if !KL_AppCat_RequireInit("KL_AppCat_Get")
		return "unknown"
		if (app_name = "" or app_name = "Unknown")
				return "unknown"
		key := StrLower(app_name)
		if KLAppCat.categories.Has(key)
				return KLAppCat.categories[key]

		; New app — register and schedule a lazy save
		KLAppCat.categories[key] := "unknown"
		KLAppCat.dirty := true
		if !KLAppCat.HasOwnProp("save_fn") || !IsObject(KLAppCat.save_fn) {
				KLAppCat.save_fn := KL_AppCat_DeferredSave.Bind()
		}
		; Delay 5 s so a burst of new apps is batched into one file write
		_KL_AppCat_ScheduleDeferredSave()
		return "unknown"
}

; Allows the future settings UI or a user script to override a category.
KL_AppCat_Set(app_name, category) {
	if !KL_AppCat_RequireInit("KL_AppCat_Set")
		return
		key := StrLower(app_name)
		KLAppCat.categories[key] := category
		KL_AppCat_Save()
}





; ===============================
; ===============================
; ======= 5/ JSON helpers =======
; ===============================
; ===============================

; Minimal encoder for a flat Map of string→string pairs.
; KL_JsonEncode in keylogger.ahk handles arbitrary depth; this variant
; emits a tidy sorted object for the categories file so diffs are stable.
KL_JsonEncodeObject(obj) {
		if !(obj is Map) || (obj.Count = 0)
				return "{}"

		; Collect and sort keys for deterministic output
		keys := []
		for k, v in obj
				keys.Push(k)
		keys := KL_SortArray(keys)

		parts := []
		for , k in keys {
				v := obj[k]
				parts.Push("  " . KL_JsonStr(k) . ": " . KL_JsonStr(v))
		}
		; KL_JoinArray is defined in keylogger.ahk (no prefix param)
		return "{`n" . KL_JoinArray(parts, ",`n") . "`n}"
}

KL_JsonDecodeObject(raw) {
		; Configuration parsing is strict. KL_JsonDecode deliberately converts any
		; malformed journal line to Map() for skip-safe ingest, which would make a
		; broken config indistinguishable from the valid empty object. Call the
		; strict shared parser directly so its exception remains visible and the
		; original configuration file stays untouched.
		return JsonParse(raw)
}

KL_JsonStr(s) {
		return JsonStringLiteral(s)
}

KL_SortArray(arr) {
		; Bubble sort — the array is at most a few hundred entries; O(n²) is fine.
		; StrCompare (not the ">" operator) is required here: AHK v2's relational
		; operators are numeric-only and THROW "Expected a Number but got a String"
		; when either side is a non-numeric string, so ">" on two ordinary app-name
		; keys (e.g. "chrome.exe" > "code.exe") aborted every KL_AppCat_Save() call
		; as soon as the map held 2+ entries — i.e. on every boot, since DEFAULTS
		; alone ships 80+ keys.
		n := arr.Length
		loop n - 1 {
				i := A_Index
				loop n - i {
						j := A_Index
						if (StrCompare(arr[j], arr[j + 1]) > 0) {
								tmp        := arr[j]
								arr[j]     := arr[j + 1]
								arr[j + 1] := tmp
						}
				}
		}
		return arr
}
