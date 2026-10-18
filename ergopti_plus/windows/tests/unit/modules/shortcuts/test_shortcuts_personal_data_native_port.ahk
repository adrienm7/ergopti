; tests/unit/modules/shortcuts/test_shortcuts_personal_data_native_port.ahk

; ==============================================================================
; MODULE: Personal Shortcuts DATA Native Port
; DESCRIPTION:
; The personal DATA frame's native constructor and port keep genuine
; intrinsics and temporal custody, refuse faults and recover exactly.
; ==============================================================================

#Requires AutoHotkey v2.0





; The module bootstrap owns the interpreter-created constructor before this subject.
; Its first own receiver call is hostile; preceding run_all modules may call it too.
_SMB_FrameNativeConstructorRefusal() {
	global _SharedDir, _MenuPopulationBuilding
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\personal_shortcuts_frame.json", "UTF-8"))
	SavedBuilding := _MenuPopulationBuilding
	OriginalCall := Object.Prototype.GetOwnPropDesc.Call(Menu, "Call")
	Factory := OriginalCall.Call
	AssertTrue(Factory is Func, "the real Menu class has its interpreter-created factory")
	OriginalName := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "Name").Get
	OriginalBuiltIn := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "IsBuiltIn").Get
	AssertTrue(OriginalBuiltIn.Call(Factory), "the untouched factory is genuinely interpreter-created")
	AssertEqual("Menu.Call", OriginalName.Call(Factory), "the genuine Menu constructor retains its intrinsic name")
	AssertTrue(OriginalBuiltIn.Call(DllCall), "the different-constructor control uses a real alternative builtin")
	PreviousCritical := Critical("On")
	TeardownPrimary := false
	try {
		_MenuPopulationBuilding := false
		for Fault in ["class lambda", "class other builtin", "class accessor", "factory Call",
			"factory Name", "factory IsBuiltIn", "intrinsic Name getter", "intrinsic IsBuiltIn getter"]
			_SMB_FrameNativeConstructorFault(Fault, Corpus, Factory)
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		_SMB_FrameRunAllCleanup(TeardownPrimary,
			() => _SMB_FrameRestoreOwnDescriptor(Menu, "Call", true, OriginalCall),
			() => _MenuPopulationBuilding := SavedBuilding,
			() => Critical(PreviousCritical),
			() => _SMB_FrameAssertOwnDescriptor(Menu, "Call", true, OriginalCall))
	}
}

; Every observer closes over this fresh case parameter, never an AHK loop variable.
_SMB_FrameNativeConstructorFault(Fault, Corpus, Factory) {
	global _MenuDispatchCallbacks
	Calls := Map("provider", 0, "foreign", 0, "actions", 0)
	Callback := (*) => Calls["actions"] += 1
	Data := []
	for Label in Corpus["registered_labels"]
		Data.Push(Map("label", Label, "action", Callback))
	Provider := () => (Calls["provider"] += 1, Data)
	Binding := Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered",
		"provider", Provider)
	Native := Menu()
	RegisterMenuItem(Native, "Original constructor destination", Callback)
	Before := _MR_FrameDestinationSnapshot(Native)
	if InStr(Fault, "class ", true) == 1 {
		Owner := Menu, Name := "Call"
		if Fault == "class other builtin"
			Replacement := {Call: DllCall}
		else if Fault == "class accessor"
			Replacement := {Get: (*) => (Calls["foreign"] += 1, Factory)}
		else
			Replacement := {Call: (*) => (Calls["foreign"] += 1, false)}
	} else if InStr(Fault, "factory ", true) == 1 {
		Owner := Factory, Name := SubStr(Fault, 9)
		if Name == "Call"
			Replacement := {Call: (*) => (Calls["foreign"] += 1, false)}
		else
			Replacement := {Get: (*) => (Calls["foreign"] += 1, Name == "Name" ? "Menu.Call" : true)}
	} else {
		Owner := Func.Prototype, Name := Fault == "intrinsic Name getter" ? "Name" : "IsBuiltIn"
		Replacement := {Get: (*) => (Calls["foreign"] += 1, Name == "Name" ? "Menu.Call" : true)}
	}
	HadProperty := Object.Prototype.HasOwnProp.Call(Owner, Name)
	SavedDescriptor := HadProperty ? Object.Prototype.GetOwnPropDesc.Call(Owner, Name) : false
	TeardownPrimary := false
	try {
		Object.Prototype.DefineProp.Call(Owner, Name, Replacement)
		if Fault == "class accessor" {
			WithdrawnDescriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
			AssertTrue(Object.Prototype.HasOwnProp.Call(WithdrawnDescriptor, "Get"),
				"the real native class fault installed an actual hostile getter")
			AssertTrue(WithdrawnDescriptor.Get == Replacement.Get,
				"the accessor descriptor retains its exact observer without executing it")
			AssertTrue(Object.Prototype.HasOwnProp.Call(WithdrawnDescriptor, "Call") && WithdrawnDescriptor.Call == Factory,
				"the actual DefineProp API merges Get while retaining the original native Call")
		}
		try Refused := MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted)
		finally {
			_SMB_FrameRestoreOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor)
		}
		_SMB_FrameAssertOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor)
		AssertEqual(0, Refused, Fault . ": the real receiver refuses the withdrawn native factory cohort")
		AssertFalse(Admitted, Fault . ": constructor withdrawal cannot be acknowledged as an intentional skip")
		AssertEqual(0, Calls["provider"], Fault . ": refusal precedes actual DATA provider execution")
		AssertEqual(0, Calls["foreign"], Fault . ": foreign factory and metadata observers never execute")
		AssertTrue(_MR_FrameNativeImageEqual(Before, _MR_FrameDestinationSnapshot(Native)),
			Fault . ": actual retained destination flags, callbacks and child handles remain unchanged")
		AssertEqual(1, TrayMenuItemCount(Native))
		AssertTrue(_MR_FrameNativeConstructorCurrent(Menu),
			Fault . ": exact saved descriptor fields restore genuine constructor admission")
		AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted),
			Fault . ": exact original descriptor/presence repair restores the real native constructor")
		AssertTrue(Admitted)
		AssertEqual(1, Calls["provider"], "the repaired original factory receives the same genuine DATA provider once")
		AssertEqual(0, Calls["foreign"], "repair does not run a withdrawn observer")
		AssertEqual(3, TrayMenuItemCount(Native))
		AssertTrue(TrayMenuIsSeparatorAt(Native, 1))
		ChildHandle := TrayMenuSubmenuHandle(Native.Handle, 2)
		AssertTrue(ChildHandle != 0, "the repaired interpreter-created factory publishes an actual native child")
		Child := MenuFromHandle(ChildHandle)
		AssertEqual(Corpus["registered_labels"].Length, TrayMenuItemCount(Child))
		for Index, Label in Corpus["registered_labels"] {
			AssertEqual(Label, TrayMenuItemCaption(Child, Index - 1), "the untouched independent original labels reach the native child")
			Id := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", Index - 1, "uint")
			AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == Callback,
				"the repaired real child retains the original actual callback")
		}
		AssertEqual(0, Calls["actions"], "refusal, actual constructor repair and publication never invoke DATA actions")
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		_SMB_FrameRunAllCleanup(TeardownPrimary,
			() => _SMB_FrameRestoreOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor),
			() => _CTC_ReleaseMenu(Native),
			() => _SMB_FrameAssertOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor),
			() => AssertTrue(_MR_FrameNativeConstructorCurrent(Menu), "native teardown preserves the exact repaired constructor cohort"))
	}
}

; Each case enters the genuine native receipt and the original production DATA receiver.
; A poisoned cleanup callable has bounded residue until exact repair; it is not retired.
_SMB_FrameNativePortLifecycle() {
	global _MenuPopulationBuilding
	SavedBuilding := _MenuPopulationBuilding
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\personal_shortcuts_frame.json", "UTF-8"))
	PreviousCritical := Critical("On")
	try {
		; Native names are observed before and after the actual retained nested guards.
		NameGetter := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "Name").Get
		Factory := Object.Prototype.GetOwnPropDesc.Call(Menu, "Call").Call
		AssertTrue(NameGetter is Func && ObjGetBase(NameGetter) == Func.Prototype)
		AssertEqual("DllCall", NameGetter.Call(DllCall), "the genuine DLL intrinsic has its interpreter-created name")
		AssertEqual("Menu.Call", NameGetter.Call(Factory), "the genuine factory has its interpreter-created name")
		AssertTrue(TrayMenuFrameNative("current"), "the actual adapter retains its native cohort without clobbering the observed DLL name")
		AssertTrue(TrayMenuFrameNative("current"), "repeated actual guard evaluation preserves DLL result custody")
		AssertTrue(_MR_FrameNativeConstructorCurrent(Menu), "the actual constructor preserves its observed intrinsic name")
		AssertEqual("DllCall", NameGetter.Call(DllCall))
		AssertEqual("Menu.Call", NameGetter.Call(Factory))
		for Fault in ["before dll Call", "before handle intrinsic Call", "before delete intrinsic Call",
			"before adapter Call", "before metadata intrinsic Call", "after adapter Call", "after dll Call",
			"after constructor Call", "after provider Call", "after child Handle", "after child Delete",
			"after registry", "after primary"]
			_SMB_FrameNativePortFault(Fault, Corpus)
	} finally {
		_MenuPopulationBuilding := SavedBuilding
		Critical(PreviousCritical)
	}
}
Test("personal DATA native port: genuine intrinsics, temporal custody, refusal and exact recovery", _SMB_FrameNativePortLifecycle)

; Fresh parameter ownership prevents the observer from reading a mutable loop variable.
_SMB_FrameNativePortFault(Fault, Corpus) {
	global _MenuPopulationBuilding, _MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles
	global _MenuDispatchLastFire, _MenuDispatchClickSequences
	SavedBuilding := _MenuPopulationBuilding
	HeldRegistries := [_MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles,
		_MenuDispatchLastFire, _MenuDispatchClickSequences]
	OriginalPort := TrayMenuFrameNative
	HandleGetter := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Handle").Get
	DeleteMethod := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Delete").Call
	NameGetter := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "Name").Get
	FillDescriptor := Object.Prototype.GetOwnPropDesc.Call(MenuPopulation.Prototype, "Fill")
	OriginalFill := FillDescriptor.Call
	Population := MenuPopulation(), Native := Menu(), Foreign := Menu(), Stage := Map()
	Calls := Map("provider", 0, "fill", 0, "foreign", 0, "actions", 0)
	Callback := (*) => Calls["actions"] += 1
	Rows := []
	for Label in Corpus["registered_labels"]
		Rows.Push(Map("label", Label, "action", Callback))
	Provider := () => (Calls["provider"] += 1, Rows)
	Binding := Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered",
		"provider", Provider)
	DescriptorOwner := false, DescriptorName := "", HadDescriptor := false, SavedDescriptor := false
	Primary := Error("Real post-Fill native port fault")
	Primary.DefineProp("Extra", {Get: (*) => (Calls["foreign"] += 1, _SMB_FrameForbiddenExtraRead()),
		Set: (*) => (Calls["foreign"] += 1, _SMB_FrameForbiddenExtraRead())})
	RestoreFault() {
		if !DescriptorOwner
			return
		_SMB_FrameRestoreOwnDescriptor(DescriptorOwner, DescriptorName, HadDescriptor, SavedDescriptor)
	}
	Withdraw(CurrentFault, Child := false) {
		if CurrentFault == "after registry" {
			_MenuDispatchCallbacks := Map(Stage["foreign_id"], Callback)
			return
		}
		if CurrentFault == "after primary"
			throw Primary
		if InStr(CurrentFault, "dll Call", true)
			DescriptorOwner := DllCall, DescriptorName := "Call"
		else if CurrentFault == "before handle intrinsic Call"
			DescriptorOwner := HandleGetter, DescriptorName := "Call"
		else if CurrentFault == "before delete intrinsic Call"
			DescriptorOwner := DeleteMethod, DescriptorName := "Call"
		else if CurrentFault == "before metadata intrinsic Call"
			DescriptorOwner := NameGetter, DescriptorName := "Call"
		else if InStr(CurrentFault, "adapter Call", true)
			DescriptorOwner := OriginalPort, DescriptorName := "Call"
		else if CurrentFault == "after constructor Call"
			DescriptorOwner := Menu, DescriptorName := "Call"
		else if CurrentFault == "after provider Call"
			DescriptorOwner := Provider, DescriptorName := "Call"
		else if CurrentFault == "after child Handle"
			DescriptorOwner := Child, DescriptorName := "Handle"
		else if CurrentFault == "after child Delete"
			DescriptorOwner := Child, DescriptorName := "Delete"
		else
			throw Error("Unknown finite native port fault")
		HadDescriptor := Object.Prototype.HasOwnProp.Call(DescriptorOwner, DescriptorName)
		SavedDescriptor := HadDescriptor ? Object.Prototype.GetOwnPropDesc.Call(DescriptorOwner, DescriptorName) : false
		Replacement := DescriptorName == "Handle" ? {Get: (*) => (Calls["foreign"] += 1, 0)}
			: {Call: (*) => (Calls["foreign"] += 1, false)}
		Object.Prototype.DefineProp.Call(DescriptorOwner, DescriptorName, Replacement)
	}
	ObserveFill(CurrentFault, Owner, Child, Data, ListId, Depth) {
		Result := OriginalFill.Call(Owner, Child, Data, ListId, Depth)
		Calls["fill"] += 1
		Stage["child"] := Child, Stage["handle"] := Child.Handle
		Stage["id"] := DllCall("GetMenuItemID", "ptr", Stage["handle"], "int", 0, "uint")
		Stage["token"] := Map.Prototype.Get.Call(HeldRegistries[2], Stage["id"])
		Stage["entry"] := Population.Pending[Stage["handle"]]
		AssertTrue(Map.Prototype.Get.Call(HeldRegistries[1], Stage["id"]) == Callback,
			"the observer sees the actual first native seed and original dispatch authority")
		Withdraw(CurrentFault, Child)
		return Result
	}
	TeardownPrimary := false
	try {
		_MenuPopulationBuilding := Population
		OriginalFill.Call(Population, Foreign, Rows, "personal_shortcuts_frame", 2)
		Stage["foreign_entry"] := Population.Pending[Foreign.Handle]
		Stage["foreign_id"] := DllCall("GetMenuItemID", "ptr", Foreign.Handle, "int", 0, "uint")
		RegisterMenuItem(Native, "Retained native port destination", Callback)
		Native.Check("Retained native port destination")
		Native.Disable("Retained native port destination")
		Before := _MR_FrameDestinationSnapshot(Native)
		Captured := OriginalPort.Call("capture", Native)
		AssertEqual(Native.Handle, Captured[1], "the native port retains the actual HMENU")
		AssertEqual(1, Captured[2].Length)
		for Field in [1, 2, 3, 4]
			AssertEqual(Before[1][Field], Captured[2][1][Field], "caption, command id, native flags and child handle are genuine")
		Ids := OriginalPort.Call("ids", Native, Native.Handle)
		AssertEqual(1, Ids.Length)
		AssertEqual(Before[1][2], Ids[1], "retirement enumerates the exact receiving command id")
		AssertEqual(1, OriginalPort.Call("count", Native, Native.Handle))
		BeforeProvider := InStr(Fault, "before ", true) == 1
		if BeforeProvider {
			Withdraw(Fault)
			if Fault != "before adapter Call" {
				AssertFalse(OriginalPort.Call("current"), Fault . ": actual native authority is unavailable")
				AssertFalse(OriginalPort.Call("capture", Native), Fault . ": no native receipt from withdrawn intrinsics")
			}
		} else
			MenuPopulation.Prototype.DefineProp("Fill", {Call: _SMB_FrameBindCaseObserver(ObserveFill, Fault)})
		Caught := false, Added := -1
		try Added := MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted)
		catch as Failure
			Caught := Failure
		; Restore before observing native state so no test assertion invokes a poisoned DLL.
		RestoreFault()
		_SMB_FrameRestoreOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDescriptor)
		if DescriptorOwner
			_SMB_FrameAssertOwnDescriptor(DescriptorOwner, DescriptorName, HadDescriptor, SavedDescriptor)
		_SMB_FrameAssertOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDescriptor)
		Residue := Fault == "after adapter Call" || Fault == "after dll Call"
		if Fault == "after primary"
			Assert(Caught == Primary, "the actual primary failure object survives native retirement unchanged")
		else if Residue {
			ExpectedMessage := Fault == "after adapter Call" ? "Owned DATA stage cleanup lost its native cohort"
				: "Owned native menu operation lost its retained intrinsics"
			AssertEqual("Error", Type(Caught), "withdrawing genuine cleanup authority throws its actual Error")
			AssertEqual(ExpectedMessage, Caught.Message, "the exact production cleanup failure propagates without a fallback")
			AssertEqual(-1, Added, "failed cleanup never returns a fabricated success or refusal receipt")
			AssertFalse(Admitted, "native residue cannot be acknowledged as admitted publication")
		} else {
			AssertFalse(Caught, Fault . ": source withdrawal remains a refusal")
			AssertEqual(0, Added)
			AssertFalse(Admitted)
		}
		AssertEqual(BeforeProvider ? 0 : 1, Calls["provider"], "native refusal has the required provider boundary")
		AssertEqual(BeforeProvider ? 0 : 1, Calls["fill"], "post-effect faults follow the actual production Fill")
		AssertEqual(0, Calls["foreign"], "no native callable, metadata, child or provider observer executes")
		AssertEqual(0, Calls["actions"], "receipt, retirement and repair do not execute actions")
		if !BeforeProvider {
			AssertFalse(Population.Pending.Has(Stage["handle"]), "the exact owned pending entry retires independently of native authority")
			if Residue {
				AssertEqual(1, DllCall("GetMenuItemCount", "ptr", Stage["handle"], "int"),
					"withdrawing the cleanup callable leaves honest native residue until exact repair")
				AssertTrue(Map.Prototype.Get.Call(HeldRegistries[1], Stage["id"]) == Callback)
				AssertTrue(Map.Prototype.Get.Call(HeldRegistries[2], Stage["id"]) == Stage["token"],
					"unsafe cleanup does not pretend that the staged registration is retired")
				_MR_FrameReleaseChild(Stage["child"], Stage["handle"], HeldRegistries, [Callback], OriginalPort, MenuDispatcher_PruneMenu)
			}
			AssertEqual(0, DllCall("GetMenuItemCount", "ptr", Stage["handle"], "int"),
				Residue ? "exact repair permits genuine native retirement" : "held native intrinsics automatically retire the unpublished child")
			AssertFalse(Map.Prototype.Has.Call(HeldRegistries[1], Stage["id"]))
			AssertFalse(Map.Prototype.Has.Call(HeldRegistries[2], Stage["id"]))
			AssertFalse(Map.Prototype.Has.Call(HeldRegistries[3], Stage["handle"]))
			if Fault == "after registry" {
				Assert(_MenuDispatchCallbacks != HeldRegistries[1])
				AssertEqual(1, _MenuDispatchCallbacks.Count, "the replacement global registry remains foreign and untouched")
				Assert(_MenuDispatchCallbacks[Stage["foreign_id"]] == Callback)
			}
		}
		_MenuDispatchCallbacks := HeldRegistries[1]
		AssertTrue(_MR_FrameNativeImageEqual(Before, _MR_FrameDestinationSnapshot(Native)),
			"native destination flags, caption, callback and token remain unchanged across real refusal")
		Assert(Population.Pending[Foreign.Handle] == Stage["foreign_entry"], "the previous detached picker retains its exact entry")
		AssertTrue(Map.Prototype.Get.Call(HeldRegistries[1], Stage["foreign_id"]) == Callback)
		AssertTrue(Map.Prototype.Has.Call(HeldRegistries[2], Stage["foreign_id"]))
		AssertEqual(1, TrayMenuItemCount(Foreign))
		AssertTrue(OriginalPort.Call("current"), "exact descriptor repair restores the actual native port")
		AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted))
		AssertTrue(Admitted)
		AssertEqual(3, TrayMenuItemCount(Native))
		AssertTrue(TrayMenuIsSeparatorAt(Native, 1))
		Child := MenuFromHandle(TrayMenuSubmenuHandle(Native.Handle, 2))
		AssertEqual(1, TrayMenuItemCount(Child), "repair publishes the original native seed")
		AssertTrue(Population.Complete(Child.Handle))
		AssertEqual(Corpus["registered_labels"].Length, TrayMenuItemCount(Child))
		CompletedReceipt := OriginalPort.Call("capture", Native)
		AssertEqual(3, CompletedReceipt[2].Length)
		AssertEqual(Child.Handle, CompletedReceipt[2][3][4], "the actual native submenu handle belongs to the published repaired child")
		ChildIds := OriginalPort.Call("ids", Child, Child.Handle)
		AssertEqual(Corpus["registered_labels"].Length, ChildIds.Length)
		AssertEqual(Corpus["registered_labels"].Length, OriginalPort.Call("count", Child, Child.Handle))
		for Index, Label in Corpus["registered_labels"] {
			AssertEqual(Label, TrayMenuItemCaption(Child, Index - 1), "the unchanged independent corpus reaches the repaired native child")
			Id := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", Index - 1, "uint")
			AssertEqual(Id, ChildIds[Index], "the adapter command ID is independently received from Win32")
			Assert(_MenuDispatchCallbacks[Id] == Callback)
			AssertTrue(_MenuDispatchTokens.Has(Id))
		}
		AssertEqual(0, Calls["foreign"])
		AssertEqual(0, Calls["actions"])
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		_SMB_FrameRunAllCleanup(TeardownPrimary,
			RestoreFault,
			() => _SMB_FrameRestoreOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDescriptor),
			() => _MenuDispatchCallbacks := HeldRegistries[1],
			() => Population.Stop(),
			() => Population.Pending.Clear(),
			() => _MenuPopulationBuilding := SavedBuilding,
			() => Stage.Has("child") ? _CTC_ReleaseMenu(Stage["child"]) : false,
			() => _CTC_ReleaseMenu(Native),
			() => _CTC_ReleaseMenu(Foreign),
			() => DescriptorOwner ? _SMB_FrameAssertOwnDescriptor(DescriptorOwner, DescriptorName, HadDescriptor, SavedDescriptor) : false,
			() => _SMB_FrameAssertOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDescriptor))
	}
}

; DefineProp updates only supplied dynamic fields. Exact repair first removes the
; withdrawn own property, then reinstates the saved descriptor and verifies it.
_SMB_FrameRestoreOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor) {
	if Object.Prototype.HasOwnProp.Call(Owner, Name)
		Object.Prototype.DeleteProp.Call(Owner, Name)
	if HadProperty
		Object.Prototype.DefineProp.Call(Owner, Name, SavedDescriptor)
}

_SMB_FrameAssertOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor) {
	AssertEqual(HadProperty, Object.Prototype.HasOwnProp.Call(Owner, Name),
		"native fixture repair restores exact own-property presence")
	if !HadProperty
		return
	ActualDescriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
	ExpectedCount := 0, ActualCount := 0
	for Field, Expected in ObjOwnProps(SavedDescriptor) {
		ExpectedCount += 1
		AssertTrue(Object.Prototype.HasOwnProp.Call(ActualDescriptor, Field),
			"native fixture repair retains each original descriptor field")
		AssertTrue(ActualDescriptor.%Field% == Expected,
			"native fixture repair retains exact original getter, setter, method or value identity")
	}
	for Field in ObjOwnProps(ActualDescriptor)
		ActualCount += 1
	AssertEqual(ExpectedCount, ActualCount,
		"native fixture repair removes all omitted hostile descriptor fields")
}

; Test-owned teardown invokes every genuine cleanup operation, even after a failed
; verification or restore. It never reads or replaces a pending primary Error.
_SMB_FrameRunAllCleanup(OriginalFailure, Cleanup*) {
	CleanupFailure := false
	for Operation in Cleanup {
		try Operation.Call()
		catch as Failure {
			if !CleanupFailure
				CleanupFailure := Failure
		}
	}
	if !OriginalFailure && CleanupFailure
		throw CleanupFailure
}
