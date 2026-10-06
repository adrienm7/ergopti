; _shared/modules/llm/local_server_menu.ahk

; ==============================================================================
; MODULE: Shared Local Server Menu Rows
; DESCRIPTION:
; AHK consumer of the existing shared Lua catalogue-ordered row policy. Native
; drivers supply translated strings, live state and acknowledged action owners.
; No credential, discovery or HTTP resource is acquired by this view policy.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Shared View Policy =======
; =====================================
; =====================================

/** @returns {String} Configured server authority, retaining its spelling. */
LocalServerMenuHost(BaseUrl) {
	if RegExMatch(BaseUrl, "^[A-Za-z][A-Za-z0-9+.-]*://([^/]+)", &Found)
		return Found[1]
	return BaseUrl
}

/**
 * @param {Map} Options Catalogue, cached verdicts, translations and action ports.
 * @returns {Array} Rows equivalent to shared llm/local_server_menu.lua.
 */
LocalServerMenuRows(Options) {
	Tr := Options["tr"], Fmt := Options["format"]
	Paused := Options["paused"], Actions := Options["actions"]
	Rows := [Map("separator", true), Map("label", Tr.Call("menu.llm.local_servers.header"), "disabled", true)]
	Result := Options["result"]
	for Id in Options["detected"] {
		Verdict := Result.Call(Id)
		Label := Options["servers"][Id]["label"] . " 🖥️ — " . LocalServerMenuHost(Verdict["base_url"])
		if Verdict["status"] == "needs_key"
			Label := Fmt.Call("menu.llm.local_servers.needs_key", Label)
		Active := Options["active"]
		Rows.Push(Map("label", Label,
			"checked", Options["backend"] == "api" && Active is Map && Active.Get("provider", "") == Id,
			"items", _LocalServerMenuItems(Options, Id, Verdict)))
	}
	if Options["detected"].Length == 0 {
		Labels := ""
		for Id in Options["order"]
			Labels .= (Labels == "" ? "" : ", ") . Options["servers"][Id]["label"]
		Key := Options["sweeping"] ? "menu.llm.local_servers.searching" : "menu.llm.local_servers.none"
		Rows.Push(Map("label", Fmt.Call(Key, Labels), "disabled", true))
	}
	Rescan := Map("label", Tr.Call("menu.llm.local_servers.rescan"), "disabled", Paused)
	if !Paused
		Rescan["action"] := Actions["rescan"]
	Rows.Push(Rescan)
	Others := []
	for Id in Options["order"] {
		Row := Map("label", Options["servers"][Id]["label"], "disabled", Paused)
		if !Paused
			Row["action"] := _LocalServerMenuAction(Actions["address"], Id)
		Others.Push(Row)
	}
	Rows.Push(Map("label", Tr.Call("menu.llm.local_servers.other_address"), "items", Others))
	return Rows
}

_LocalServerMenuItems(Options, Id, Verdict) {
	Tr := Options["tr"], Fmt := Options["format"]
	Paused := Options["paused"], Actions := Options["actions"], Items := []
	if Verdict["status"] == "needs_key" {
		Items.Push(_LocalServerMenuRow(Tr.Call("menu.llm.local_servers.api_key"), Paused, Actions["key"], Id))
	} else if Verdict["models"].Length == 0 {
		Items.Push(Map("label", Tr.Call("menu.llm.local_servers.no_models"), "disabled", true))
	}
	for Model in Verdict["models"] {
		Active := Options["active"]
		Row := _LocalServerMenuRow(Model, Paused, Actions["select"], Id, Model)
		Row["checked"] := Options["backend"] == "api" && Active is Map
			&& Active.Get("provider", "") == Id && Active.Get("model", "") == Model
		Items.Push(Row)
	}
	Items.Push(Map("separator", true))
	Items.Push(_LocalServerMenuRow(Fmt.Call("menu.llm.local_servers.address", LocalServerMenuHost(Verdict["base_url"])),
		Paused, Actions["address"], Id))
	if Verdict["status"] == "up"
		Items.Push(_LocalServerMenuRow(Tr.Call("menu.llm.local_servers.api_key"), Paused, Actions["key"], Id))
	return Items
}

_LocalServerMenuRow(Label, Paused, Action, Id, Model?) {
	Row := Map("label", Label, "disabled", Paused)
	if !Paused
		Row["action"] := IsSet(Model) ? _LocalServerMenuAction(Action, Id, Model) : _LocalServerMenuAction(Action, Id)
	return Row
}

; Each helper invocation owns its parameter cells; no callback captures a loop.
_LocalServerMenuAction(Action, Id, Model?) {
	if IsSet(Model)
		return (*) => Action.Call(Id, Model)
	return (*) => Action.Call(Id)
}
