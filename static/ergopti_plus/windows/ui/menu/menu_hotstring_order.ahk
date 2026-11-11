; ui/menu/menu_hotstring_order.ahk

; ==============================================================================
; MODULE: Hotstring Section Menu Order
; DESCRIPTION:
; Applies the shared section-order contract to native menu rows and commits a
; per-category preference to config.toml before repainting the tray. Exact source
; admission keeps a stale menu from overwriting an intervening configuration edit.
; ==============================================================================

/** Accepts only dense text lists, including an empty saved override. */
_HS_OrderValid(Value) {
	if !(Value is Array)
		return false
	Loop Value.Length {
		if !Value.Has(A_Index) || !(Value[A_Index] is String)
			return false
	}
	return true
}

/** Resolves discovered names and saved names without mutating either list. */
_HS_OrderResolve(Source, Override := unset) {
	if !_HS_OrderValid(Source) || IsSet(Override) && !_HS_OrderValid(Override)
		return false
	Known := Map(), Seen := Map(), Result := []
	Known.CaseSense := true, Seen.CaseSense := true
	for Name in Source {
		if Name != "-"
			Known[Name] := true
	}
	Append(Name) {
		if Name == "-" {
			if Result.Length && Result[Result.Length] != "-"
				Result.Push(Name)
		} else if Known.Has(Name) && !Seen.Has(Name) {
			Result.Push(Name)
			Seen[Name] := true
		}
	}
	for Name in IsSet(Override) ? Override : Source
		Append(Name)
	if IsSet(Override) {
		for Name in Source {
			if Name != "-"
				Append(Name)
		}
	}
	if Result.Length && Result[Result.Length] == "-"
		Result.Pop()
	return Result
}

/** Swaps named positions across the previous/next section, retaining separators. */
_HS_OrderMove(Order, Name, Delta) {
	if !_HS_OrderValid(Order) || Name == "-" || (Delta != -1 && Delta != 1)
		return false
	Selected := 0, Result := Order.Clone()
	for Index, Entry in Order {
		if Entry == Name
			Selected := Index
	}
	if !Selected
		return false
	Neighbour := Selected + Delta
	while Neighbour >= 1 && Neighbour <= Result.Length && Result[Neighbour] == "-"
		Neighbour += Delta
	if Neighbour < 1 || Neighbour > Result.Length
		return false
	Result[Selected] := Result[Neighbour]
	Result[Neighbour] := Name
	return Result
}

/**
 * The id one menu category's order is stored under, the group id macOS and
 * Linux key it by. A language category is "<language>_<stem>", never the stem
 * of its file: French « autocorrection.toml » would otherwise share the
 * neutral category's list. Any other category is its lowercased name, the
 * stem of its root file.
 */
_HS_OrderCategoryId(Category) {
	if !(Category is String) || Category == ""
		throw ValueError("A hotstring section order needs a category name.")
	for _, Pack in HotstringsLanguageCategories() {
		for _, Cat in Pack["categories"] {
			if Cat["v1"] == Category || Cat["v2"] == Category
				return Cat["v2"]
		}
	}
	return StrLower(Category)
}

/** Captures the source used by one category's native menu. */
_HS_OrderSnapshot(Category, Path := unset) {
	global ConfigurationFile
	Path := IsSet(Path) ? Path : ConfigurationFile
	try {
		Presence := FSStrictExists(Path)
		Content := Presence ? FSReadUtf8Exact(Path) : ""
		if !(Content is String)
			throw TypeError("Section-order source is not readable.")
		Document := TOML_ParseDocumentShared(Content)
		Read := _TOML_DocumentLookup(Document, ["hotstrings", ConfigLeaf.ORDER_OVERRIDES, Category])
		if Read["blocked"] || Read["found"] && !_HS_OrderValid(Read["value"])
			throw TypeError("Section order is not a text list.")
		Snapshot := Map("path", Path, "content", Content, "presence", Presence, "category", Category)
		if Read["found"]
			Snapshot["order"] := Read["value"].Clone()
		return Snapshot
	} catch Error as Err {
		LoggerError("HotstringsMenu", "Section order could not be read: {1}.", Err.Message)
		return false
	}
}

/** Writes only against the exact source behind the menu, under the config lease. */
_HS_OrderWrite(Snapshot, Path, Updates) {
	; Configuration roots can contain dotted metadata and inline tables; only
	; the semantic writer retains those namespaces and their schema generation.
	return TOML_ConfigBatchWrite(Path, Updates, [], 0, Snapshot["content"], Snapshot["presence"])
}

/** Commits one order or its reset before repainting; a refused write changes nothing. */
_HS_OrderCommit(Snapshot, Candidate, WriterFn := 0, RebuildFn := 0, NotifyFn := 0) {
	if !(Snapshot is Map) || A_IsSuspended
		return false
	if !(Candidate is Array) && !(Candidate is Integer && Candidate == 0)
		return false
	if Candidate is Array && !_HS_OrderValid(Candidate)
		return false
	Row := { Section: ConfigKey.HOTSTRINGS_ORDER_OVERRIDES, Key: Snapshot["category"] }
	if Candidate is Array
		Row.Value := Candidate
	else
		Row.Delete := true
	if !HasMethod(WriterFn, "Call")
		WriterFn := _HS_OrderWrite.Bind(Snapshot)
	if !ConfigCommitUpdates(Snapshot["path"], [Row], "the hotstring section order", WriterFn, NotifyFn)
		return false
	if HasMethod(RebuildFn, "Call")
		RebuildFn.Call()
	else
		RebuildTrayMenu()
	return true
}

/** Rechecks a captured click before calculating and committing its named move. */
_HS_OrderClick(Snapshot, Order, Name, Delta, *) {
	if A_IsSuspended
		return false
	Candidate := _HS_OrderMove(Order, Name, Delta)
	return Candidate is Array && _HS_OrderCommit(Snapshot, Candidate)
}

/** Builds the declared order submenu using the native section rows' labels. */
_HS_OrderMenu(Snapshot, Order, ByName) {
	Entries := []
	for Name in Order {
		if Name == "-" || !ByName.Has(Name)
			continue
		CanUp := _HS_OrderMove(Order, Name, -1) is Array
		CanDown := _HS_OrderMove(Order, Name, 1) is Array
		Children := MenuRenderer_TemplateRows("hotstring_order_moves",
			Map(MenuCommand.HOTSTRING_ORDER_UP, _HS_OrderClick.Bind(Snapshot, Order, Name, -1),
				MenuCommand.HOTSTRING_ORDER_DOWN, _HS_OrderClick.Bind(Snapshot, Order, Name, 1)),
			Map("hotstring_order_up_ready", ((Ready) => (*) => Ready && !A_IsSuspended)(CanUp),
				"hotstring_order_down_ready", ((Ready) => (*) => Ready && !A_IsSuspended)(CanDown)), Map())
		if !(Children is Array)
			return []
		Entries.Push(Map("label", ByName[Name]["label"], "items", Children))
	}
	if Entries.Length < 2
		return []
	ResetRows := MenuRenderer_TemplateRows("hotstring_order_footer",
		Map(MenuCommand.HOTSTRING_ORDER_RESET, (*) => _HS_OrderCommit(Snapshot, 0)),
		Map("hotstring_order_ready", (*) => !A_IsSuspended), Map())
	if !(ResetRows is Array)
		return []
	for Row in ResetRows
		Entries.Push(Row)
	return MenuRenderer_TemplateRows("hotstring_order_parent", Map(), Map(),
		Map("hotstring_order_children", Entries))
}

/**
 * Orders only tagged sections and strips private tags before native rendering.
 * Category is the menu category; its stored id is resolved here, so no caller
 * can key an order by the file a category happens to load from.
 */
_HS_OrderRows(Category, Rows) {
	Source := [], ByName := Map(), Untagged := [], After := Map(), LastName := ""
	ByName.CaseSense := true, After.CaseSense := true
	for Row in Rows {
		if Row.Get("separator", false) {
			Source.Push("-")
		} else if Row.Has("section_order_id") {
			Name := Row["section_order_id"]
			Clean := Row.Clone()
			Clean.Delete("section_order_id")
			ByName[Name] := Clean
			After[Name] := []
			LastName := Name
			Source.Push(Name)
		} else if LastName != "" {
			After[LastName].Push(Row)
		} else {
			Untagged.Push(Row)
		}
	}
	if ByName.Count == 0
		return Rows
	Snapshot := _HS_OrderSnapshot(_HS_OrderCategoryId(Category))
	Order := Snapshot is Map && Snapshot.Has("order") ? _HS_OrderResolve(Source, Snapshot["order"]) : _HS_OrderResolve(Source)
	Result := Untagged.Clone()
	for Name in Order {
		Result.Push(Name == "-" ? _HS_DeclaredSectionBoundary() : ByName[Name])
		if Name != "-" {
			for Row in After[Name]
				Result.Push(Row)
		}
	}
	if Snapshot is Map {
		for Row in _HS_OrderMenu(Snapshot, Order, ByName)
			Result.Push(Row)
	}
	return Result
}
