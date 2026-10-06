; _shared/modules/actions/program_providers.ahk

; ==============================================================================
; MODULE: Program Provider Policy
; DESCRIPTION:
; Mirrors the shared Lua session contract for the native AHK driver. Bundled
; provider data stays canonical; native adapters supply directory and file
; identities, tool eligibility and exact resource-retirement receipts.
; ==============================================================================

/** Owns one bounded discovery session; page choices contain no absolute paths. */
class ProgramProviderSession {
	static MAX_SCAN := 256
	static MAX_CHOICES := 64
	static MAX_PATH_BYTES := 16384
	static MAX_PATH_DIRECTORIES := 128
	static MAX_ARGUMENT_BYTES := 1048576
	static MAX_CATALOGUE_BYTES := 65536

	__New(Raw, Ports) {
		this.Providers := ProgramProviderCatalogue(Raw)
		if !(this.Providers is Array) || !(Ports is Map)
			throw TypeError("Program discovery requires a valid catalogue and native ports.")
		for Name in ["route", "identity", "interpreter", "list", "retire"]
			if !HasMethod(Ports.Get(Name, 0), "Call")
				throw TypeError("Program discovery requires all native ownership ports.")
		this.Ports := Ports.Clone()
		this.Generation := 0
		this.Current := 0
		this.Busy := false
	}

	Invalidate() {
		this.Generation += 1
		this.Current := 0
		try Receipt := this.Ports["retire"].Call()
		catch Any
			return false
		return (Receipt is Integer) && Receipt == true
	}

	Discover() {
		if this.Busy
			return false
		this.Busy := true
		try {
			Result := this._Discover()
			if !(Result is Map)
				this.Current := 0
			return Result
		}
		catch Any {
			this.Current := 0
			return false
		} finally this.Busy := false
	}

	_Route() {
		Value := this.Ports["route"].Call()
		return ProgramProviderAbsolute(Value) ? RTrim(Value, "\/") : false
	}

	_Identity(Path) {
		Value := this.Ports["identity"].Call(Path)
		if !(Value is Map) || !ProgramProviderClean(Value.Get("token", 0))
				|| Value["token"] == ""
			return false
		Kind := Value.Get("kind", 0)
		if !(Kind == "missing" || Kind == "other" || Kind == "directory" || Kind == "file")
			return false
		if Kind == "file" && (!(Value.Get("readable", 0) is Integer)
				|| !(Value.Get("executable", 0) is Integer)
				|| !(Value["readable"] == 0 || Value["readable"] == 1)
				|| !(Value["executable"] == 0 || Value["executable"] == 1))
			return false
		return Value.Clone()
	}

	_Guard(Snapshot) {
		if this.Current != Snapshot || this.Generation != Snapshot["generation"]
				|| this._Route() != Snapshot["route"]
			return false
		Observed := this._Identity(Snapshot["route"])
		if !(Observed is Map) || Observed["kind"] != "directory"
				|| Observed["token"] != Snapshot["directory"]
			return false
		Route := this._Route()
		return this.Current == Snapshot && this.Generation == Snapshot["generation"]
			&& Route == Snapshot["route"]
	}

	_Discover() {
		this.Generation += 1
		this.Current := 0
		Epoch := this.Generation
		Directory := this._Route()
		if !(Directory is String)
			return false
		States := [], Targets := Map()
		for Provider in this.Providers {
			Available := Provider["mode"] == "executable"
			if !Available {
				Target := this.Ports["interpreter"].Call(Provider["commands"]["ahk"], Provider["id"])
				if Target is Map {
					if !ProgramProviderAbsolute(Target.Get("executable", 0))
							|| !ProgramProviderClean(Target.Get("token", 0))
						return false
					Info := this._Identity(Target["executable"])
					if !(Info is Map) || Info["kind"] != "file" || !Info["executable"]
							|| Info["token"] != Target["token"]
						return false
					Targets[Provider["id"]] := Target.Clone()
					Available := true
				} else if !(Target is Integer) || Target != 0
					return false
			}
			States.Push(Map("id", Provider["id"], "available", !!Available))
		}
		if this.Generation != Epoch || this._Route() != Directory
			return false
		Info := this._Identity(Directory)
		if !(Info is Map)
			return false
		if this.Generation != Epoch || this._Route() != Directory
			return false
		if Info["kind"] == "missing"
			return Map("choices", [], "providers", States, "truncated", false)
		if Info["kind"] != "directory"
			return false
		Snapshot := Map("generation", Epoch, "route", Directory,
			"directory", Info["token"], "entries", Map())
		this.Current := Snapshot
		Listed := this.Ports["list"].Call(Directory, ProgramProviderSession.MAX_SCAN)
		if !(Listed is Map) || !(Listed.Get("names", 0) is Array)
				|| Listed["names"].Length > ProgramProviderSession.MAX_SCAN
				|| !(Listed.Get("truncated", 0) is Integer)
				|| !(Listed["truncated"] == 0 || Listed["truncated"] == 1)
			return false
		Seen := Map(), Names := []
		Seen.CaseSense := "Off"
		for Name in Listed["names"] {
			if !ProgramProviderClean(Name) || Name == "" || Name == "." || Name == ".."
					|| StrPut(Name, "UTF-8") - 1 > 4096 || RegExMatch(Name, "[\\/:*?]") || Seen.Has(Name)
				return false
			Seen[Name] := true
			Names.Push(Name)
		}
		; Windows names are sorted without handing private names to a process.
		loop Names.Length {
			Index := A_Index
			while Index > 1 && StrCompare(Names[Index - 1], Names[Index], true) > 0 {
				Saved := Names[Index - 1]
				Names[Index - 1] := Names[Index]
				Names[Index] := Saved
				Index--
			}
		}
		Choices := [], Truncated := Listed["truncated"]
		for Name in Names {
			Path := Directory . "\" . Name
			Info := this._Identity(Path)
			if !(Info is Map)
				return false
			if Info["kind"] != "file"
				continue
			SplitPath(Name, , , &Extension)
			Selected := 0, Executable := 0
			for Provider in this.Providers {
				if Provider["mode"] == "executable"
					Executable := Provider
				for Suffix in Provider["extensions"]
					if StrLower(Extension) == Suffix
						Selected := Provider
			}
			if !IsObject(Selected) && Info["executable"]
				Selected := Executable
			if !IsObject(Selected) || (Selected["mode"] == "script"
					&& (!Info["readable"] || !Targets.Has(Selected["id"])))
					|| (Selected["mode"] == "executable" && !Info["executable"])
				continue
			if Choices.Length >= ProgramProviderSession.MAX_CHOICES {
				Truncated := true
				continue
			}
			Key := Epoch . ":" . (Choices.Length + 1)
			Snapshot["entries"][Key] := Map("provider", Selected, "path", Path,
				"token", Info["token"], "target", Targets.Get(Selected["id"], 0))
			Choices.Push(Map("key", Key, "provider", Selected["id"], "label", Name))
		}
		return this._Guard(Snapshot) ? Map("choices", Choices, "providers", States,
			"truncated", Truncated) : false
	}

	Resolve(Key, Arguments) {
		if this.Busy
			return false
		this.Busy := true
		try {
			Snapshot := this.Current
			if !(Key is String) || !(Snapshot is Map) || !Snapshot["entries"].Has(Key)
					|| !(Arguments is Array)
				return false
			Captured := [], Bytes := 0
			for Value in Arguments {
				if !ProgramProviderClean(Value)
					return false
				Bytes += StrPut(Value, "UTF-8") - 1
				if Bytes > ProgramProviderSession.MAX_ARGUMENT_BYTES
					return false
				Captured.Push(Value)
			}
			if !this._Guard(Snapshot)
				return false
			Entry := Snapshot["entries"][Key]
			Info := this._Identity(Entry["path"])
			if !(Info is Map) || Info["kind"] != "file" || Info["token"] != Entry["token"]
				return false
			Provider := Entry["provider"], Executable := Entry["path"], Argv := []
			if Provider["mode"] == "script" {
				if !Info["readable"]
					return false
				Target := Entry["target"]
				Info := this._Identity(Target["executable"])
				if !(Info is Map) || !Info["executable"] || Info["token"] != Target["token"]
					return false
				Fresh := this.Ports["interpreter"].Call(Provider["commands"]["ahk"], Provider["id"])
				if !(Fresh is Map) || Fresh.Get("executable", 0) != Target["executable"]
						|| Fresh.Get("token", 0) != Target["token"]
					return false
				Executable := Target["executable"]
				for Value in Provider["prefix"]
					Argv.Push(Value)
				Argv.Push(Entry["path"])
			} else if !Info["executable"]
				return false
			for Value in Captured
				Argv.Push(Value)
			Scalar := '{"version":1,"executable":' . JsonStringLiteral(Executable)
				. ',"arguments":' . ProgramProviderArrayJson(Argv) . "}"
			FinalFile := this._Identity(Entry["path"])
			if !(FinalFile is Map) || FinalFile["kind"] != "file" || FinalFile["token"] != Entry["token"]
				return false
			if Provider["mode"] == "script" {
				if !FinalFile["readable"]
					return false
				FinalTool := this._Identity(Target["executable"])
				if !(FinalTool is Map) || !FinalTool["executable"] || FinalTool["token"] != Target["token"]
					return false
			}
			return (ProgramParameterParse(Scalar) is Map) && this._Guard(Snapshot) ? Scalar : false
		} catch Any {
			return false
		} finally this.Busy := false
	}
}

/** Validates trusted catalogue shape while leaving invocation data centralized. */
ProgramProviderCatalogue(Raw) {
	try {
		if !ProgramProviderClean(Raw) || StrPut(Raw, "UTF-8") - 1 > ProgramProviderSession.MAX_CATALOGUE_BYTES
			return false
		if !ProgramProviderRawStrings(Raw)
			return false
		Data := JsonParse(Raw)
		if !(Data is Map) || Data.Count != 2 || Data.Get("version", 0) != 1
				|| !(Data.Get("providers", 0) is Array) || !Data["providers"].Length
			return false
		Spans := JsonObjectMemberSpans(Raw)
		if !Spans.Has("version") || !RegExMatch(Spans["version"]["text"],
				"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$")
			return false
		Providers := [], Ids := Map(), Extensions := Map()
		for Provider in Data["providers"] {
			if !(Provider is Map) || Provider.Count != 5
					|| !RegExMatch(Provider.Get("id", ""), "^[a-z_]+$") || Ids.Has(Provider["id"])
					|| !(Provider.Get("extensions", 0) is Array) || !(Provider.Get("prefix", 0) is Array)
					|| !(Provider.Get("commands", 0) is Map)
					|| !(Provider.Get("mode", 0) == "script" || Provider["mode"] == "executable")
				return false
			Ids[Provider["id"]] := true
			for Platform, Commands in Provider["commands"] {
				if !(Platform == "linux" || Platform == "hs" || Platform == "ahk") || !(Commands is Array)
						|| (Provider["mode"] == "script" && !Commands.Length)
					return false
				for Command in Commands
					if !ProgramProviderClean(Command) || !RegExMatch(Command, "^[A-Za-z0-9_.-]+$")
						return false
			}
			for Value in Provider["prefix"]
				if !ProgramProviderClean(Value)
					return false
			for Extension in Provider["extensions"] {
				if !ProgramProviderClean(Extension) || !RegExMatch(Extension, "^[a-z][a-z0-9]*$") || Extensions.Has(Extension)
					return false
				Extensions[Extension] := true
			}
			if Provider["commands"].Has("ahk")
				Providers.Push(Provider)
		}
		return Providers
	} catch Any {
		return false
	}
}

; Native JSON may truncate escaped NUL before decoded metadata can be checked.
; Authenticate each raw string with the same lossless scalar string owner first.
ProgramProviderRawStrings(Raw) {
	try {
		Position := 1
		while Position <= StrLen(Raw) {
			if SubStr(Raw, Position, 1) == '"' {
				Start := Position
				Decoded := _ProgramParameterString(Raw, &Position)
				if !(Decoded is String) || Position <= Start || !ProgramProviderClean(Decoded)
					return false
			} else Position++
		}
		return true
	} catch Any {
		return false
	}
}

ProgramProviderClean(Value) {
	if !(Value is String)
		return false
	Index := 0
	while Index < StrLen(Value) {
		Unit := NumGet(StrPtr(Value), Index * 2, "UShort")
		if Unit == 0
			return false
		if Unit >= 0xD800 && Unit <= 0xDBFF {
			Index++
			if Index >= StrLen(Value)
				return false
			Low := NumGet(StrPtr(Value), Index * 2, "UShort")
			if Low < 0xDC00 || Low > 0xDFFF
				return false
		} else if Unit >= 0xDC00 && Unit <= 0xDFFF
			return false
		Index++
	}
	return true
}

ProgramProviderAbsolute(Value) {
	return ProgramProviderClean(Value) && StrPut(Value, "UTF-8") - 1 <= ProgramProviderSession.MAX_PATH_BYTES
		&& (RegExMatch(Value, "^[A-Za-z]:[/\\]") || RegExMatch(Value, "^\\\\[^\\/]+\\[^\\/]+\\."))
		&& !RegExMatch(Value, "^\\\\[?.]\\")
}

ProgramProviderArrayJson(Values) {
	Json := ""
	for Value in Values
		Json .= (Json == "" ? "" : ",") . JsonStringLiteral(Value)
	return "[" . Json . "]"
}

; Raw member spans preserve NUL rejection before native JSON values can truncate.
ProgramProviderMessage(Msg) {
	try {
		if !ProgramProviderClean(Msg) || StrPut(Msg, "UTF-8") - 1
				> ProgramProviderSession.MAX_ARGUMENT_BYTES * 6 + ProgramProviderSession.MAX_CATALOGUE_BYTES
			return false
		Spans := JsonObjectMemberSpans(Msg)
		if !Spans.Has("providerKey") || !Spans.Has("programArguments")
			return false
		Raw := Spans["providerKey"]["text"], Position := 1
		Key := _ProgramParameterString(Raw, &Position)
		if !(Key is String) || Position <= StrLen(Raw) || !RegExMatch(Key, "^[0-9]+:[0-9]+$")
			return false
		Scalar := '{"version":1,"executable":"C:\\provider.exe","arguments":'
			. Spans["programArguments"]["text"] . "}"
		Parsed := ProgramParameterParse(Scalar)
		return Parsed is Map ? Map("key", Key, "arguments", Parsed["arguments"]) : false
	} catch Any {
		return false
	}
}
