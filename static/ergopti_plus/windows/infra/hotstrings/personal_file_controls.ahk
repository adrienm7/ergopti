; infra/hotstrings/personal_file_controls.ahk

; ==============================================================================
; MODULE: Additional Personal TOML Controls
; DESCRIPTION:
; Explicit native adoption, independent file/section gates and conditional source
; metadata publication. Generic TOML provenance never grants this capability.
; ==============================================================================

#Include %A_LineFile%\..\..\..\..\_shared\modules\hotstrings\personal_scope.ahk

/** Owns the current additional-file catalogue and its closed native capabilities. */
class PersonalFileControls {
	static owners := Map()
	static inventory := []

	/** Read physical identity from an open handle, including hard-link aliases. */
	static Physical(Path) {
		File := FileOpen(Path, "r", "UTF-8")
		if !IsObject(File)
			throw Error("The personal hotstring file is unreadable.")
		try {
			Snapshot := FSHandleSnapshot(File.Handle)
			if !Snapshot.Get("ok", false)
				throw Error("The personal hotstring file identity is unavailable.")
			return Snapshot["volume"] . ":" . Snapshot["index_high"] . ":" . Snapshot["index_low"]
		} finally File.Close()
	}

	/** Parsing excludes the UTF-8 BOM; ownership retains it in the exact source receipt. */
	static ParseContent(Content) {
		return SubStr(Content, 1, 1) == Chr(0xFEFF) ? SubStr(Content, 2) : Content
	}

	/** Decode quoted native section identifiers without splitting a literal dotted name. */
	static SectionName(Raw) {
		Parts := TOML_ParseKeyPath(Trim(Raw), true)
		return Parts.Length == 1 ? StrLower(Parts[1]) : StrLower(Trim(Raw))
	}

	/** Build native evidence; no menu rendering or descriptor alone performs adoption. */
	static Scan() {
		Candidates := [], Packs := HS_EnumeratePersonalExtFiles()
		for Pack in Packs {
			Candidate := Map("source", Pack["PersonalSource"], "path", _ConfigWriteLeaseKey(Pack["Path"]))
			try {
				Candidate["physical"] := this.Physical(Pack["Path"])
				Pack["content"] := FSReadUtf8Exact(Pack["Path"])
				if !(Pack["content"] is String) || this.Physical(Pack["Path"]) != Candidate["physical"]
					throw Error("The personal source receipt changed during discovery.")
			}
			catch {
				Pack["unreadable"] := true
			}
			Candidates.Push(Candidate)
		}
		; The primary file has its own gate. An additional hard-link alias cannot
		; acquire metadata authority over that already owned source.
		global ScriptInformation
		Primary := ScriptInformation.Get("PersonalTomlPath", "")
		PrimaryPresent := false
		if Primary != "" {
			Attributes := DllCall("GetFileAttributesW", "wstr", Primary, "uint")
			if Attributes == 0xffffffff {
				if A_LastError != 2 && A_LastError != 3
					throw Error("The primary personal source presence is unavailable.")
			} else
				PrimaryPresent := true
		}
		if PrimaryPresent {
			; Refuse discovery if the already owned primary identity cannot be
			; reserved: skipping this evidence could authorize a hard-link alias.
			Candidates.Push(Map("source", PersonalFileDescribe(["personal_hotstrings.toml"]),
				"path", _ConfigWriteLeaseKey(Primary), "physical", this.Physical(Primary)))
		}
		Inventory := PersonalScopePlanAdoption(Candidates)
		while Inventory.Length > Packs.Length
			Inventory.Pop()
		for Index, Record in Inventory {
			Record["path"] := Packs[Index]["Path"]
			Record["pack"] := Packs[Index]
			if Packs[Index].Get("unreadable", false) {
				Record["admitted"] := false
				Record["exclusive"] := false
				Record["reason"] := "unreadable-source"
			}
			; The historical native parser folds section names. Do not grant a
			; section gate when two original identifiers collapse to that owner.
			Names := Map(), SourceSection := "", SourceCount := 0
			global HS_TOML_SECTION_HEADER_PATTERN, _HOTSTRING_ENTRY_PATTERN, _HOTSTRING_SIMPLE_ENTRY_PATTERN
			ExactContent := Packs[Index].Get("content", "")
			try {
				TOML_ParseDocument(ExactContent, &ParsedRecords, &PhysicalRecords)
				for PhysicalRecord in PhysicalRecords {
					if PhysicalRecord.Kind == "opaque"
						throw Error("The source has an unaddressable TOML record.")
				}
			} catch {
				Record["admitted"] := false
				Record["exclusive"] := false
				Record["reason"] := "malformed-source"
			}
			Record["content"] := ExactContent
			loop parse, this.ParseContent(ExactContent), "`n", "`r" {
				if RegExMatch(TOML_StripInlineComment(Trim(A_LoopField)), HS_TOML_SECTION_HEADER_PATTERN, &Header) {
					Original := Trim(Header[1])
					try Folded := this.SectionName(Original)
					catch {
						Record["admitted"] := false
						Record["exclusive"] := false
						Record["reason"] := "unaddressable-section"
						continue
					}
					if Original == "_meta" || InStr(Original, "_meta.") {
						SourceSection := ""
						continue
					}
					if Names.Has(Folded) && !(Names[Folded] == Original) {
						Record["admitted"] := false
						Record["exclusive"] := false
						Record["reason"] := "ambiguous-section-owner"
					}
					Names[Folded] := Original
					SourceSection := Original
				} else if SourceSection != "" && (RegExMatch(Trim(A_LoopField), _HOTSTRING_ENTRY_PATTERN)
					|| RegExMatch(TOML_StripInlineComment(Trim(A_LoopField)), _HOTSTRING_SIMPLE_ENTRY_PATTERN)) {
					SourceCount += 1
				}
			}
			Record["count"] := SourceCount
			if Candidates[Index].Has("physical")
				Record["physical"] := Candidates[Index]["physical"]
		}
		return Inventory
	}

	/** Adopt every unambiguous discovered route once for this registration generation. */
	static Refresh() {
		global ConfigurationFile
		Inventory := this.Scan(), Owners := Map()
		Stored := TOML_ParseFreshFileTyped(ConfigurationFile)
		if TOML_ReadFailed(ConfigurationFile)
			throw Error("The personal-file activation configuration is unreadable.")
		for Record in Inventory {
			if Record["admitted"] && Record["exclusive"] {
				Owner := PersonalFileAdoptedOwner(Record, Stored)
				Owners[Record["owner"]] := Owner
			}
		}
		this.inventory := Inventory, this.owners := Owners
	}

	/** Return only a capability that belongs to the currently adopted generation. */
	static IsCurrent(Owner) {
		return Owner is PersonalFileAdoptedOwner && this.owners.Has(Owner.id)
			&& this.owners[Owner.id] == Owner
	}

	/** Resolve an internal ID to its exact native route without using display labels. */
	static Path(Id) {
		return this.owners.Has(Id) ? this.owners[Id].path : ""
	}

	/** The menu uses the already adopted snapshot; actions separately rescan admission. */
	static ForPath(Path) {
		Wanted := _ConfigWriteLeaseKey(Path)
		for Id, Owner in this.owners {
			if _ConfigWriteLeaseKey(Owner.path) == Wanted
				return Owner
		}
		return 0
	}

	/** Count active adopted mappings without filesystem I/O in a menu build. */
	static ActiveCount() {
		Count := 0
		for Id, Owner in this.owners
			Count += Owner.ActiveCount()
		; Sources without an exclusive gate retain their generic registration.
		for Record in this.inventory {
			if !this.owners.Has(Record["owner"])
				Count += Record.Get("count", 0)
		}
		return Count
	}

	/** Load real native mappings through an explicit owner, retaining generic unavailable packs. */
	static Register() {
		this.Refresh()
		for Record in this.inventory {
			Pack := Record["pack"]
			if this.owners.Has(Record["owner"])
				LoadExtTomlFile(Pack["Path"], Pack["Label"], "", Pack["PersonalSource"], this.owners[Record["owner"]])
			else
				LoadExtTomlFile(Pack["Path"], Pack["Label"], "", Pack["PersonalSource"])
		}
	}

	/** Project auxiliary previews through the same adopted runtime owner. */
	static BuildPreview(Index, TriggerSet) {
		for Record in this.inventory {
			Pack := Record["pack"]
			if this.owners.Has(Record["owner"])
				_RegisterExtPackTriggers(Pack["Path"], Pack["Label"], Index, TriggerSet, "", Pack["PersonalSource"], this.owners[Record["owner"]])
			else
				_RegisterExtPackTriggers(Pack["Path"], Pack["Label"], Index, TriggerSet, "", Pack["PersonalSource"])
		}
	}
}

/** A captured owner is a generation-bound capability, not a transport descriptor. */
class PersonalFileAdoptedOwner {
	__New(Record, Stored) {
		this.source := PersonalFileDescriptorCopy(Record["source"])
		this.id := Record["owner"], this.path := Record["path"], this.physical := Record["physical"]
		this.content := FSReadUtf8Exact(this.path)
		if !(this.content is String) || !(this.content == Record["content"])
			|| PersonalFileControls.Physical(this.path) != this.physical
			throw Error("The adopted personal source is unreadable.")
		this.parsedContent := PersonalFileControls.ParseContent(this.content)
		this.config := this.ReadMetadata(this.parsedContent)
		this.groups := Stored.Get("hotstrings.groups", Map())
		this.sections := Stored.Get("hotstrings.modules." . TOML_RenderKey(this.id), Map())
		this.sectionNames := Map(), this.counts := Map(), Current := ""
		global HS_TOML_SECTION_HEADER_PATTERN, _HOTSTRING_ENTRY_PATTERN, _HOTSTRING_SIMPLE_ENTRY_PATTERN
		loop parse, this.parsedContent, "`n", "`r" {
			if RegExMatch(TOML_StripInlineComment(Trim(A_LoopField)), HS_TOML_SECTION_HEADER_PATTERN, &Match) {
				Name := PersonalFileControls.SectionName(Match[1])
				if Name != "_meta" && !InStr(Name, "_meta.") {
					this.sectionNames[Name] := true
					this.counts[Name] := this.counts.Get(Name, 0)
					Current := Name
				} else
					Current := ""
			} else if Current != "" && (RegExMatch(Trim(A_LoopField), _HOTSTRING_ENTRY_PATTERN)
				|| RegExMatch(TOML_StripInlineComment(Trim(A_LoopField)), _HOTSTRING_SIMPLE_ENTRY_PATTERN)) {
				this.counts[Current] += 1
			}
		}
	}

	/** Validate both the capability and the exact source/route before granting a loader port. */
	Authorize(Path, Descriptor) {
		return PersonalFileControls.IsCurrent(this) && PersonalFileDescriptorValid(Descriptor)
			&& Descriptor["id"] == this.id && Path == this.path
	}

	/** Native file/section choices are sparse true-by-default; malformed values refuse. */
	Enabled(Section := "") {
		if !PersonalFileControls.IsCurrent(this)
			return false
		return this.Selected("") && (Section == "" || this.Selected(Section))
	}

	/** Preserve a section's own choice while its containing file is disabled. */
	Selected(Section := "") {
		return Section == "" ? this.Gate(this.groups, this.id) : this.Gate(this.sections, Section)
	}

	/** Count only mappings this runtime snapshot can actually register. */
	ActiveCount() {
		Count := 0
		for Section, Available in this.counts {
			if this.Enabled(Section)
				Count += Available
		}
		return Count
	}

	/** TOML Boolean intent is required; numeric/string lookalikes do not enable a file. */
	Gate(Values, Key) {
		if !Values.Has(Key)
			return PersonalFileDefaultEnabled()
		Value := Values[Key]
		return Value is TOML_Bool && Value.Value
	}

	/** Resolve source metadata after adoption; the package tier never derives from its label. */
	Resolve(Section := "") {
		global GLOBAL_DEFAULT_COLOR, HSE_PRIORITY_PACKAGE
		File := this.config
		Sec := File.Sections.Get(Section, { Delay: "", Color: "", ShowTooltip: "", Priority: "" })
		return { Delay: Sec.Delay != "" ? Sec.Delay : (File.Delay != "" ? File.Delay : PersonalFileDefaultDelay()),
			Color: Sec.Color != "" ? Sec.Color : (File.Color != "" ? File.Color : GLOBAL_DEFAULT_COLOR),
			ShowTooltip: Sec.ShowTooltip != "" ? Sec.ShowTooltip : (File.ShowTooltip != "" ? File.ShowTooltip : true),
			Priority: Sec.Priority != "" ? Sec.Priority : (File.Priority != "" ? File.Priority : HSE_PRIORITY_PACKAGE),
			HasOverride: false }
	}

	/** Parse only source metadata, retaining quoted keys and metadata after arrays of tables. */
	ReadMetadata(Content) {
		Config := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
		Parsed := _ParseTomlFileImpl(this.path, false, false, Content, true)
		for Header, Fields in Parsed {
			try Parts := TOML_ParseKeyPath(Header, true)
			catch
				continue
			if Parts.Length == 0 || Parts[1] != "_meta"
				continue
			if Parts.Length == 1
				Target := Config
			else if Parts.Length == 3 && Parts[2] == "sections" {
				Name := StrLower(Parts[3])
				if !Config.Sections.Has(Name)
					Config.Sections[Name] := { Delay: "", Color: "", ShowTooltip: "", Priority: "" }
				Target := Config.Sections[Name]
			} else
				continue
			for Key, Value in Fields {
				if Key == "delay" && TickTryDurationMsFromSeconds(Value, &DelayMs)
					Target.Delay := Value
				else if Key == "priority" && HotstringsTryPriority(Value, &Priority)
					Target.Priority := Priority
				else if Key == "show_tooltip" && Value is TOML_Bool
					Target.ShowTooltip := Value.Value
				else if Key == "color" && Value is String
					Target.Color := Value
			}
		}
		return Config
	}

	/** Losslessly patch only the admitted metadata zone, quoting arbitrary section names. */
	PatchMetadata(Section, Field, Value, Content) {
		Target := Section == "" ? ["_meta"] : ["_meta", "sections", Section]
		Header := Section == "" ? "[_meta]" : "[_meta.sections." . TOML_RenderKey(Section) . "]"
		Out := [], InTarget := false, Found := false, Done := false
		for LineNumber, Line in StrSplit(Content, "`n", "`r") {
			; The physical BOM belongs to the exact source/output receipt, but
			; cannot hide the first owned metadata header from lexical recognition.
			Recognition := LineNumber == 1 ? PersonalFileControls.ParseContent(Line) : Line
			Trimmed := Trim(TOML_StripInlineComment(Recognition))
			if RegExMatch(Trimmed, "^\[+([^\[\]]+)\]+$", &Match) {
				if InTarget && !Done
					Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
				try Parts := TOML_ParseKeyPath(Match[1], true)
				catch
					Parts := []
				InTarget := Parts.Length == Target.Length
				if InTarget {
					for Index, Part in Target {
						if !(Parts[Index] == Part)
							InTarget := false
					}
				}
				if InTarget
					Found := true, Done := false
			}
			if InTarget && RegExMatch(Trimmed, "^" . Field . "\s*=") {
				if !Done
					Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
				Done := true
			} else
				Out.Push(Line)
		}
		if InTarget && !Done
			Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
		if !Found {
			Out.Push("")
			Out.Push(Header)
			Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
		}
		Result := ""
		for Index, Line in Out
			Result .= (Index > 1 ? "`n" : "") . Line
		return Result
	}

	/** Recheck discovery, source bytes and physical identity under the scoped publication lease. */
	Recheck() {
		if !PersonalFileControls.IsCurrent(this)
			throw Error("The personal hotstring owner is stale.")
		Admitted := PersonalScopeAdmit(PersonalFileControls.Scan(),
			Map("source", this.source, "owner", this.id, "path", this.path), &Reason)
		if !Admitted || PersonalFileControls.Physical(this.path) != this.physical
			|| !(FSReadUtf8Exact(this.path) == this.content)
			throw Error("The personal hotstring source changed before scoped publication.")
	}

	/** Publish one gate or validated metadata field with the existing compensated journal. */
	Commit(Section, Field, Value, Options := unset) {
		if A_IsCritical {
			Previous := Critical("Off")
			try return this.Commit(Section, Field, Value, IsSet(Options) ? Options : Map())
			finally Critical(Previous)
		}
		if Section != "" && !this.sectionNames.Has(Section)
			throw ValueError("The adopted file does not own this section.")
		if Field == "enabled" {
			if !(Value is Integer) || (Value != 0 && Value != 1)
				throw ValueError("Personal activation requires a Boolean value.")
		} else if !_HCW_IsOverrideField(Field)
			throw ValueError("Invalid personal-file metadata target.")
		else if Field == "delay" && !TickTryDurationMsFromSeconds(Value, &DelayMs)
			throw ValueError("Invalid personal-file delay.")
		else if Field == "priority" && !HotstringsTryPriority(Value, &Priority)
			throw ValueError("Invalid personal-file priority.")
		else if Field == "show_tooltip" && !HotstringsTryBooleanOverride(Value, &Tooltip)
			throw ValueError("Invalid personal-file tooltip preference.")
		else if Field == "color" && (!(Value is String) || !RegExMatch(Value, "^#?[0-9A-Fa-f]{6}$"))
			throw ValueError("Invalid personal-file color.")
		Operations() {
			this.Recheck()
			if Field != "enabled"
				return []
			Row := { Section: Section == "" ? "hotstrings.groups" : "hotstrings.modules." . TOML_RenderKey(this.id),
				Key: Section == "" ? this.id : Section }
			if Value == PersonalFileDefaultEnabled()
				Row.Delete := 1
			else
				Row.Value := TOML_Bool(Value)
			return [Row]
		}
		Files := PersonalFileControlPublication(this, Section, Field, Value)
		return ConfigScopeCommitOperations("hotstrings", "personal_file_preference", Operations,
			IsSet(Options) ? Options : Map(), Files)
	}
}

/** Include the exact source in the lease/cohort without normalizing hotstring rows. */
class PersonalFileControlPublication {
	__New(Owner, Section, Field, Value) {
		this.owner := Owner, this.section := Section, this.field := Field, this.value := Value
		this.paths := [Owner.path]
	}
	Build() {
		this.owner.Recheck()
		Content := this.owner.content
		if this.field != "enabled"
			Content := this.owner.PatchMetadata(this.section, this.field, this.value, Content)
		return [{ path: this.owner.path, image: Map("status", "ok", "kind", "rendered",
			"source_present", true, "source_content", this.owner.content, "content", Content, "force_target", true) }]
	}
}
