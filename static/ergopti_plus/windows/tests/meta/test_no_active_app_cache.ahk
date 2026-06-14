; tests/meta/test_no_active_app_cache.ahk

#Requires AutoHotkey v2.0

_NAAC_AssertNoActiveAppCache() {
	if FileExist(A_ScriptDir . "/../lib/active_app_cache.ahk")
		Assert(false, "active_app_cache.ahk must not exist (redundant async state machine removed in audit)")
	
	; Search all ahk files for GetActiveApp
	Loop Files, A_ScriptDir . "/../../*.ahk", "R"
	{
		Content := FileRead(A_LoopFilePath, "UTF-8")
		if InStr(Content, "GetActiveApp()") {
			if InStr(A_LoopFileName, "test_no_active_app_cache")
				continue
			Assert(false, "File " . A_LoopFileName . " contains GetActiveApp() which was removed in audit")
		}
	}
}

Test("meta: active_app_cache redundant state machine is completely removed", _NAAC_AssertNoActiveAppCache)
