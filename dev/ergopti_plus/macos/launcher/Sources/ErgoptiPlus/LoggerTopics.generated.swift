// Sources/ErgoptiPlus/LoggerTopics.generated.swift
// AUTO-GENERATED from _shared/modules/logger/sub_files.toml.
// DO NOT EDIT BY HAND -- run `npm run codegen:logger-sub-files` to refresh.

// ==============================================================================
// MODULE: Native Logger Topical Filename Set
// DESCRIPTION:
// Restricts authenticated logger datagrams to the same canonical filenames
// routed by the Hammerspoon logger. Generating this set prevents the native
// validator from becoming a second source that can reject a newly added topic.
// ==============================================================================

let kLoggerTopicalFileNames: Set<String> = [
	"ErgoptiPlus_gestures.log",
	"ErgoptiPlus_mlx.log",
	"ErgoptiPlus_ollama.log",
	"ErgoptiPlus_llm.log",
	"ErgoptiPlus_hotstrings.log",
	"ErgoptiPlus_keylogger.log",
	"ErgoptiPlus_karabiner.log",
	"ErgoptiPlus_menu.log",
	"ErgoptiPlus_notify.log",
	"ErgoptiPlus_boot.log",
]
