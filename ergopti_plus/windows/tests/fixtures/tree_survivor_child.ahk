; tests/fixtures/tree_survivor_child.ahk

; ==============================================================================
; MODULE: Tree Survivor Child
; DESCRIPTION:
; Writes its cause and exits while a descendant it launched lives on, as the
; native metrics sender probe does when its deadline fires before the WebView2
; controller resolves: the browser it never supervised keeps the Job alive.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

; The descendant outlives the parent's wait; the parent's Job retires it.
Run(A_ComSpec . " /c ping -n 60 127.0.0.1 >nul", , "Hide")
FileAppend("survivor fixture: deadline before the controller.`n", "**", "UTF-8-RAW")
ExitApp(2)
