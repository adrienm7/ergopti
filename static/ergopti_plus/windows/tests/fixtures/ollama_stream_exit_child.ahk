; tests/fixtures/ollama_stream_exit_child.ahk

#Requires AutoHotkey v2.0

; Emit a complete synthetic provider frame before the requested transport status.
FileAppend('{"message":{"content":"native answer"},"done":true}' . "`n", A_Args[1], "UTF-8-RAW")
ExitApp(Integer(A_Args[2]))
