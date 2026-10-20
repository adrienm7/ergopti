; tests/unit/modules/llm/servers/test_ollama_managed_bootstrap.ahk

#Requires AutoHotkey v2.0

Test("managed bootstrap: install and start have separate consent (groups247-managed)", _G4B_Consent)
Test("managed bootstrap: existing pinned runtime skips install consent (groups247-managed)", _G4B_Reuse)
Test("managed bootstrap: declined install acquires no mutation (groups247-managed)", _G4B_DeclineInstall)
Test("managed bootstrap: declined start keeps installation without daemon (groups247-managed)", _G4B_DeclineStart)
Test("managed bootstrap: held install consent rejects withdrawn source (groups247-managed)", _G4B_Withdraw)
Test("managed bootstrap: model pull needs separate consent and fresh tags (groups247-managed)", _G4B_Model)
Test("managed bootstrap: missing model after pull fails closed (groups247-managed)", _G4B_MissingAfterPull)
Test("managed bootstrap: unknown tags cannot enable AI (groups247-managed)", _G4B_UnknownTags)
Test("managed bootstrap: configured version mismatch cannot enable AI (groups247-managed)", _G4B_Version)
Test("managed bootstrap: foreign epoch cannot publish readiness (groups247-managed)", _G4B_Epoch)
Test("managed bootstrap: nonBoolean pull retirement retains task (groups247-managed)", _G4B_FalseAck)
Test("managed bootstrap: stale pull callback cannot retire successor (groups247-managed)", _G4B_StalePull)
Test("managed bootstrap: absent terminal proof cannot adopt files (groups247-managed)", _G4B_UnknownTerminal)
Test("managed bootstrap: cancellation keeps private cleanup debt (groups247-managed)", _G4B_CleanupDebt)
Test("managed bootstrap: cancellation does not kill external server (groups247-managed)", _G4B_NoRuntime)
Test("managed bootstrap: held consent cannot revive after endpoint change (groups247-managed)", _G4B_Endpoint)

Test("managed bootstrap: total deadline cannot reset at runtime handoff (groups247-managed)", _G4B_Deadline)
Test("managed bootstrap: READY keeps source withdrawal retirement (groups247-managed)", _G4B_ReadyWithdraw)
Test("managed bootstrap: typed receipt falsehood cannot enable AI (groups247-managed)", _G4B_TypedReceipt)
Test("managed bootstrap: absent latest receipt cannot borrow earlier success (groups247-managed)", _G4B_MissingReceipt)

Test("managed bootstrap: exact committed enable hands off READY source (groups247-managed)", _G4B_EnableHandoff)
Test("managed bootstrap: unauthorized source cannot borrow enable handoff (groups247-managed)", _G4B_EnableHandoffForeign)
Test("managed bootstrap: enable handoff cannot bless another model (groups247-managed)", _G4B_EnableHandoffModel)

_G4B_ReadyMenuPullDeadline() {
	F := _G4B_Fixture()
	Done := 0, Published := 0
	Pull(Target, Model, Callback) {
		Done := Callback
		return true
	}
	try {
		F.Start()
		F.Runtime.PublishReady()
		AssertTrue(F.Flow.Ready)
		F.Now += F.Flow.Plan["deadline_ms"] * 2
		F.Flow.Port["pull"] := Pull
		AssertTrue(F.Flow.PullModel("qwen3:0.6b", (*) => Published += 1))
		AssertTrue(HasMethod(Done, "Call"))
		F.Flow._Tick()
		AssertTrue(F.Flow.Ready, "a new consented pull does not inherit an expired bootstrap clock")
		F.Now += F.Flow.Plan["deadline_ms"]
		F.Flow._Tick()
		AssertTrue(F.Flow.Cancelled, "a READY menu pull reaches the original configured operation deadline")
		AssertFalse(F.Flow.Ready, "expired model work cannot retain READY admission")
		Done.Call(0)
		AssertEqual(0, Published, "late model completion cannot publish after the operation deadline")
		AssertEqual(1, F.ReadyCalls, "the original bootstrap success remains a single terminal callback")
		AssertEqual(0, F.FailedCalls, "a later menu operation does not replay the completed bootstrap failure callback")
	} finally F.Close()
}
Test("managed bootstrap: READY menu pull has a separate captured deadline (groups247-menu-pull-deadline)", _G4B_ReadyMenuPullDeadline)

_G4B_ReadyMenuPullSuccessor() {
	F := _G4B_Fixture()
	Callbacks := [], Published := 0
	Pull(Target, Model, Callback) {
		F.Pulls += 1
		Callbacks.Push(Callback)
		return true
	}
	try {
		F.Start()
		F.Runtime.PublishReady()
		F.Model := "qwen3:0.6b"
		F.Flow.Port["pull"] := Pull
		ConsentCount := F.Consents.Length
		AssertTrue(F.Flow.PullModel(F.Model, (*) => Published += 1))
		AssertFalse(F.Flow.PullModel(F.Model), "an unfinished request refuses another consent and dispatch")
		AssertEqual(ConsentCount + 1, F.Consents.Length)
		AssertEqual(1, Callbacks.Length)
		Callbacks[1].Call(0)
		AssertEqual(1, Published)
		AssertTrue(F.Flow.Ready)
		AssertEqual(0, F.Runtime.Stops)
		AssertTrue(F.Flow.PullModel(F.Model, (*) => Published += 1))
		Successor := F.Flow.MenuPull
		Callbacks[1].Call(0)
		AssertTrue(F.Flow.MenuPull == Successor, "the retired callback cannot settle its replacement")
		AssertEqual(1, Published)
		F.Flow.Cancel()
		Callbacks[2].Call(0)
		AssertEqual(1, Published, "cancelled requests cannot publish a late fresh-tags response")
	} finally F.Close()
}
Test("managed bootstrap: READY menu callbacks retain exact request custody (groups247-menu-pull-deadline)", _G4B_ReadyMenuPullSuccessor)

_G4B_ReadyMenuPullDebt() {
	F := _G4B_Fixture()
	Done := 0
	Pull(Target, Model, Callback) {
		Done := Callback
		return true
	}
	try {
		F.Start()
		F.Runtime.PublishReady()
		F.Flow.Port["pull"] := Pull
		AssertTrue(F.Flow.PullModel("qwen3:0.6b"))
		CapturedBudget := F.Flow.Plan["deadline_ms"]
		F.Flow.Plan["deadline_ms"] := CapturedBudget * 10
		Owner := Map("task", {requestTerminate: (*) => "true"}, "building", false,
			"accepted", true, "terminal", 0, "callback", Done)
		F.Flow.PullTask := Owner
		F.Now += CapturedBudget
		F.Flow._Tick()
		AssertTrue(F.Flow.Cancelled, "changing later policy cannot extend the captured request budget")
		AssertTrue(F.Flow.PullTask == Owner, "a string ACK cannot release native task ownership")
		AssertFalse(F.Flow.CanReplace(), "unknown physical retirement blocks a new bootstrap")
		F.Flow._Pulled(Owner, 0)
		AssertTrue(F.Flow.CanReplace(), "only exact task completion releases the retained request")
		AssertEqual(1, F.ReadyCalls)
		AssertEqual(0, F.FailedCalls)
	} finally F.Close()
}
Test("managed bootstrap: READY menu deadline preserves unknown native retirement (groups247-menu-pull-deadline)", _G4B_ReadyMenuPullDebt)

class _G4B_Fixture {
	__New() {
		global _LLM_Deps_Epoch, LLM_OLLAMA_BASE_URL, _LLM_Deps_State, _LLM_Deps_Checking
		this.Saved := [_LLM_Deps_Epoch, LLM_OLLAMA_BASE_URL, _LLM_Deps_State, _LLM_Deps_Checking]
		_LLM_Deps_Epoch := 9101
		LLM_OLLAMA_BASE_URL := "http://localhost:23456"
		_LLM_Deps_State := "pending"
		_LLM_Deps_Checking := true
		this.Model := ""
		this.CurrentValue := true
		this.Existing := false
		this.Withdraw := false
		this.ChangeEndpoint := false
		this.Decline := ""
		this.Consents := []
		this.Calls := []
		this.ReadyCalls := 0
		this.FailedCalls := 0
		this.Pulls := 0
		this.Version := "0.24.0"
		this.Now := 1000
		this.UnknownTags := false
		this.MissingAfterPull := false
		this.Files := _G4B_Files(this)
		this.Runtime := _G4B_Runtime(this)
	}
	Start() {
		Plan := Map("ManagedRoot", "C:\managed", "CataloguePath", "C:\catalogue.json",
			"CatalogueSha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"AssetId", "windows-amd64", "port", 23456, "version", "0.24.0", "deadline_ms", 9000,
			"download", Map("ManagedRoot", "C:\managed"))
		Port := Map("plan", Plan, "files", this.Files, "runtime", this.Runtime,
			"current", (*) => this.CurrentValue, "clock", (*) => this.Now,
			"consent", ObjBindMethod(this, "Consent"), "models", ObjBindMethod(this, "Models"),
			"version", ObjBindMethod(this, "VersionReceipt"), "pull", ObjBindMethod(this, "Pull"))
		this.Flow := OllamaManagedBootstrap(this.Model, 9101,
			(*) => this.ReadyCalls += 1, (*) => this.FailedCalls += 1, Port)
		this.Flow.Begin()
	}
	Consent(Kind, Model) {
		global LLM_OLLAMA_BASE_URL
		this.Consents.Push(Kind)
		if this.Withdraw
			this.CurrentValue := false
		if this.ChangeEndpoint
			LLM_OLLAMA_BASE_URL := "http://localhost:23457"
		return Kind != this.Decline
	}
	Models(Done) {
		if this.UnknownTags
			return Done.Call(Map("ok", false, "reason", "model_list_unavailable"))
		Rows := this.Pulls > 0 && !this.MissingAfterPull ? '[{"name":' . JsonStringLiteral(this.Model) . '}]' : '[]'
		Receipt := LLM_LocalModelListReceipt(Map("ok", true, "status", 200, "body", '{"models":' . Rows . '}'))
		AssertTrue(Receipt["names"] is Map, "Use the actual independent production parser's normalized-name set.")
		return Done.Call(Receipt)
	}
	VersionReceipt(Done) {
		return Done.Call(Map("ok", true, "status", 200, "body", '{"version":"' . this.Version . '"}'))
	}
	Pull(Target, Model, Done) {
		this.Pulls += 1
		AssertEqual(Target["origin"], "http://127.0.0.1:23456", "Pull keeps the captured managed origin.")
		AssertEqual(Model, this.Model, "Pull keeps the consented model.")
		Done.Call(0)
		return true
	}
	Close() {
		global _LLM_Deps_Epoch, LLM_OLLAMA_BASE_URL, _LLM_Deps_State, _LLM_Deps_Checking
		if this.HasOwnProp("Flow")
			this.Flow.Cancel()
		_LLM_Deps_Epoch := this.Saved[1]
		LLM_OLLAMA_BASE_URL := this.Saved[2]
		_LLM_Deps_State := this.Saved[3]
		_LLM_Deps_Checking := this.Saved[4]
	}
}

class _G4B_Files {
	__New(Fixture) {
		this.Fixture := Fixture
		this.Owned := false
		this.StopValue := true
	}
	HasOwner() {
		return this.Owned
	}
	Cancel() {
		if this.StopValue is Integer && this.StopValue == true
			this.Owned := false
		return this.StopValue
	}
	Run(Action, Request, Authority, Done) {
		F := this.Fixture
		AssertTrue(Authority["authorize"].Call(Action, Request), "Actual flow admits the exact captured request.")
		F.Calls.Push(Action)
		Receipt := Map("ok", true, "ticket", Request.Get("TicketId", "11111111111111111111111111111111"),
			"root_identity", "12345678:1234567890123456", "stage_identity", "23456789:2345678901234567",
			"version_identity", "23456789:2345678901234567",
			"manifest_sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"version_path", "C:\managed\versions\version", "executable", "C:\managed\versions\version\ollama.exe")
		switch Action {
			case "inspect": Receipt["phase"] := F.Existing ? "published" : "missing"
			case "download": Receipt["phase"] := "downloaded", Receipt["archive"] := "C:\managed\archive.zip"
			case "prepare": Receipt["phase"] := "prepared"
			case "publish": Receipt["phase"] := "published"
			default: Receipt["phase"] := "retired"
		}
		F.Flow.LastReceipt := Receipt
		Done.Call(Map("exit", 0, "exit_observed", true, "output_observed", true))
		return true
	}
}

class _G4B_Runtime {
	__New(Fixture) {
		this.Fixture := Fixture
		this.Owned := false
		this.Starts := 0
		this.Stops := 0
		this.LiveIdentity := true
		this.Generation := 1
		this.Record := Map("ready_image_sha256", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	}
	Start(Target, Authority, Ready, Exit) {
		AssertTrue(Authority["authorize"].Call(Target), "Actual flow admits its current captured runtime.")
		this.Target := Target.Clone()
		this.Record["target"] := Target.Clone()
		this.Record["accepted"] := true
		this.Record["ready"] := false
		this.Record["cancelled"] := false
		this.Record["terminal"] := false
		this.Ready := Ready
		this.Starts += 1
		this.Owned := true
		return true
	}
	PublishReady() {
		this.Record["ready"] := true
		this.Ready.Call(this.Target, Map("ready_file_identity", "34567890:3456789012345678"))
	}
	ObserveReady() {
		return false
	}
	Stop() {
		if this.Owned
			this.Stops += 1
		this.Owned := false
		return true
	}
	HasOwner() {
		return this.Owned
	}
	IdentityReady() {
		return this.Owned && this.LiveIdentity
	}
}

_G4B_Consent() {
	F := _G4B_Fixture()
	try {
		F.Start()
		AssertEqual(F.Consents.Length, 2)
		AssertEqual(F.Consents[1], "install")
		AssertEqual(F.Consents[2], "start")
		AssertEqual(F.Runtime.Starts, 1)
		AssertEqual(F.ReadyCalls, 0, "Accepted process launch is not readiness.")
		F.Runtime.PublishReady()
		AssertEqual(F.ReadyCalls, 1)
	} finally F.Close()
}

_G4B_Reuse() {
	F := _G4B_Fixture()
	try {
		F.Existing := true
		F.Start()
		AssertEqual(F.Consents.Length, 1)
		AssertEqual(F.Consents[1], "start")
		AssertEqual(F.Calls.Length, 1, "Reuse performs inspection, never another install.")
	} finally F.Close()
}

_G4B_DeclineInstall() {
	F := _G4B_Fixture()
	try {
		F.Decline := "install"
		F.Start()
		AssertEqual(F.Calls.Length, 1)
		AssertEqual(F.Runtime.Starts, 0)
		AssertEqual(F.ReadyCalls, 0)
	} finally F.Close()
}

_G4B_DeclineStart() {
	F := _G4B_Fixture()
	try {
		F.Decline := "start"
		F.Start()
		AssertEqual(F.Calls[F.Calls.Length], "publish", "The verified install remains available for a future explicit start.")
		AssertEqual(F.Runtime.Starts, 0)
	} finally F.Close()
}

_G4B_Withdraw() {
	F := _G4B_Fixture()
	try {
		F.Withdraw := true
		F.Start()
		AssertEqual(F.Calls.Length, 1, "A dialog acceptance after source withdrawal cannot start a download.")
		AssertEqual(F.Runtime.Starts, 0)
	} finally F.Close()
}

_G4B_Model() {
	F := _G4B_Fixture()
	try {
		F.Model := "qwen3:0.6b"
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(F.Consents.Length, 3)
		AssertEqual(F.Consents[3], "model")
		AssertEqual(F.Pulls, 1)
		AssertEqual(F.ReadyCalls, 1)
	} finally F.Close()
}

_G4B_MissingAfterPull() {
	F := _G4B_Fixture()
	try {
		F.Model := "qwen3:0.6b"
		F.MissingAfterPull := true
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(F.Pulls, 1)
		AssertEqual(F.ReadyCalls, 0)
		AssertEqual(F.FailedCalls, 1, "A successful pull exit alone cannot claim an installed model.")
	} finally F.Close()
}

_G4B_UnknownTags() {
	F := _G4B_Fixture()
	try {
		F.Model := "qwen3:0.6b"
		F.UnknownTags := true
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(F.Pulls, 0)
		AssertEqual(F.ReadyCalls, 0)
		AssertEqual(F.FailedCalls, 1)
	} finally F.Close()
}

_G4B_Version() {
	F := _G4B_Fixture()
	try {
		F.Version := "0.23.0"
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(F.ReadyCalls, 0)
		AssertEqual(F.FailedCalls, 1)
	} finally F.Close()
}

_G4B_Epoch() {
	global _LLM_Deps_Epoch
	F := _G4B_Fixture()
	try {
		F.Start()
		_LLM_Deps_Epoch += 1
		F.Runtime.PublishReady()
		AssertEqual(F.ReadyCalls, 0)
		AssertTrue(F.Flow.Cancelled)
	} finally F.Close()
}

_G4B_FalseAck() {
	F := _G4B_Fixture()
	try {
		F.Decline := "install"
		F.Start()
		Task := {requestTerminate: (*) => "1"}
		Owner := Map("task", Task, "building", false, "accepted", false, "terminal", 0)
		F.Flow.PullTask := Owner
		AssertFalse(F.Flow.Cancel())
		Assert(F.Flow.PullTask == Owner, "A numeric string cannot release the exact process owner.")
		Task.requestTerminate := (*) => true
		AssertTrue(F.Flow.Cancel())
	} finally F.Close()
}

_G4B_StalePull() {
	F := _G4B_Fixture()
	try {
		F.Decline := "install"
		F.Start()
		Old := Map("task", 0, "building", false, "accepted", true, "terminal", 0)
		Successor := Map("task", 0, "building", false, "accepted", false, "terminal", 0)
		F.Flow.PullTask := Successor
		AssertFalse(F.Flow._Pulled(Old, 0))
		Assert(F.Flow.PullTask == Successor, "Stale callbacks retain their originating task identity.")
		AssertEqual(F.ReadyCalls, 0)
	} finally F.Close()
}

_G4B_UnknownTerminal() {
	F := _G4B_Fixture()
	try {
		F.Decline := "install"
		F.Start()
		AssertFalse(F.Flow._Physical("download", Map(), Map("exit", 0, "stdout", '{"ok":true}')))
		AssertFalse(F.Flow._Physical("download", Map(), Map("exit", 0, "stdout", '{"ok":true}',
			"exit_observed", "1", "output_observed", true)))
		AssertFalse(F.Flow._Physical("download", Map(), Map("kind", "native_quiescence",
			"dispatched", false, "exit_observed", false, "output_observed", false)))
	} finally F.Close()
}

_G4B_CleanupDebt() {
	F := _G4B_Fixture()
	try {
		F.Decline := "install"
		F.Start()
		F.Files.Owned := true
		F.Files.StopValue := false
		AssertFalse(F.Flow.Cancel())
		AssertFalse(F.Flow.CanReplace())
		F.Files.StopValue := true
		AssertTrue(F.Flow.Cancel())
	} finally F.Close()
}

_G4B_NoRuntime() {
	F := _G4B_Fixture()
	try {
		F.Decline := "install"
		F.Start()
		AssertTrue(F.Flow.Cancel())
		AssertEqual(F.Runtime.Stops, 0, "No app-owned runtime means no server termination.")
	} finally F.Close()
}

_G4B_Endpoint() {
	F := _G4B_Fixture()
	try {
		F.ChangeEndpoint := true
		F.Start()
		AssertEqual(F.Calls.Length, 1)
		AssertEqual(F.Runtime.Starts, 0)
		AssertEqual(F.ReadyCalls, 0)
	} finally F.Close()
}

_G4B_Deadline() {
	F := _G4B_Fixture()
	try {
		F.Start()
		F.Now := 10000
		F.Flow._Tick()
		AssertEqual(F.FailedCalls, 1)
		AssertEqual(F.Runtime.Stops, 1, "The accepted runtime retires at the originating total deadline.")
		AssertEqual(F.ReadyCalls, 0)
	} finally F.Close()
}

_G4B_ReadyWithdraw() {
	F := _G4B_Fixture()
	try {
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(F.ReadyCalls, 1)
		F.CurrentValue := false
		F.Flow._Tick()
		AssertEqual(F.Runtime.Stops, 1, "Source withdrawal retires the owned daemon after READY.")
		AssertTrue(F.Flow.Cancelled)
		AssertFalse(F.Flow.Ready)
	} finally F.Close()
}

_G4B_TypedReceipt() {
	F := _G4B_Fixture()
	try {
		F.Decline := "install"
		F.Start()
		AssertFalse(F.Flow._Physical("inspect", Map(), Map("exit", 0, "stdout", '{"ok":"1","phase":"missing"}',
			"exit_observed", true, "output_observed", true)))
		F.Flow.Cancelled := false
		F.Flow.Failed := false
		AssertFalse(F.Flow._Success(Map("exit", "0"), Map("ok", true)))
		AssertFalse(F.Flow._Success(Map("exit", 0), Map("ok", "1")))
	} finally F.Close()
}

_G4B_MissingReceipt() {
	F := _G4B_Fixture()
	try {
		F.Decline := "install"
		F.Start()
		F.Flow.Cancelled := false
		F.Flow.LastReceipt := 0
		F.Flow._Inspected(Map("exit", 0))
		AssertEqual(F.FailedCalls, 1)
		AssertEqual(F.Runtime.Starts, 0)
		AssertEqual(F.ReadyCalls, 0)
	} finally F.Close()
}

; Read actual bytes from a private configuration image, while only native
; file/runtime process boundaries are injected. A mock readiness receipt still
; grants no production Windows qualification.
_G4B_EnableFixture(F, Body) {
	Path := A_Temp . "\ergopti-g4-enable-" . A_TickCount . ".toml"
	try {
		AssertTrue(FSWrite(Path, '[llm]`nenabled = false`nmodel = "captured"`n`n[personal]`nvalue = "keep"`n'))
		F.Start()
		F.Flow.Port["read_source"] := (*) => Map("path", Path, "bytes", FSReadBytesStrict(Path))
		Menu := Map("backend", "ollama", "model", "captured", "enabled", false, "api_entry_id", "personal")
		F.Flow.Port["menu_intent"] := (*) => Menu
		F.Flow.Port["aux_generation"] := (*) => 8101
		F.Flow.Source := F.Flow.Port["read_source"].Call()
		F.Flow.MenuIntent := Menu.Clone()
		F.Flow.AuxGeneration := 8101
		F.Flow.OnReady := () => Body.Call(F, Path, Menu)
		F.Runtime.PublishReady()
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

_G4B_EnableCommit(F, Path, Menu, Kind) {
	ExpectedPath := Path . ".expected"
	try {
		AssertTrue(FSWrite(ExpectedPath, StrReplace(FileRead(Path, "UTF-8"), "enabled = false", "enabled = true")))
		Expected := Map("path", Path, "bytes", FSReadBytesStrict(ExpectedPath))
		Token := F.Flow.PrepareEnableHandoff(F.Flow.Source, Expected)
		AssertTrue(Token is Map)
		AssertTrue(FSWrite(Path, FileRead(ExpectedPath, "UTF-8")))
		AssertTrue(F.Flow._Current(), "The borrowed durable writer may finish before RAM publication.")
		Menu["enabled"] := true
		if Kind == "foreign"
			AssertTrue(FSWrite(Path, FileRead(Path, "UTF-8") . "# unowned user edit`n"))
		if Kind == "model"
			Menu["model"] := "another-model"
		if Kind == "exact" {
			AssertTrue(F.Flow.FinishEnableHandoff(Token), "Only exact committed successor bytes are adopted.")
			F.Flow._Tick()
			AssertTrue(F.Flow.Ready)
			AssertEqual(F.Runtime.Stops, 0, "Its own exact enable publication retains the owned runtime.")
			AssertTrue(FSWrite(Path, FileRead(Path, "UTF-8") . "# unrelated later mutation`n"))
		} else
			AssertFalse(F.Flow.FinishEnableHandoff(Token))
		F.Flow._Tick()
		AssertTrue(F.Flow.Cancelled)
		AssertEqual(F.Runtime.Stops, 1, "Unowned bytes/settings still retire the exact owned runtime.")
	} finally {
		if FileExist(ExpectedPath)
			FileDelete(ExpectedPath)
	}
}

_G4B_EnableHandoff() {
	F := _G4B_Fixture()
	try _G4B_EnableFixture(F, (Owner, Path, Menu) => _G4B_EnableCommit(Owner, Path, Menu, "exact"))
	finally F.Close()
}
_G4B_EnableHandoffForeign() {
	F := _G4B_Fixture()
	try _G4B_EnableFixture(F, (Owner, Path, Menu) => _G4B_EnableCommit(Owner, Path, Menu, "foreign"))
	finally F.Close()
}
_G4B_EnableHandoffModel() {
	F := _G4B_Fixture()
	try _G4B_EnableFixture(F, (Owner, Path, Menu) => _G4B_EnableCommit(Owner, Path, Menu, "model"))
	finally F.Close()
}

_G4B_DisplayModelTag() {
	Index := LLM_GetModelIndex()
	for Name, Entry in Index {
		if Entry.Has("ollama") && Entry["ollama"] != "" {
			AssertEqual(LLM_ManagedModelTag(Name), Entry["ollama"], "The catalogue display name becomes its native literal tag.")
			AssertEqual(LLM_ManagedModelTag(Entry["ollama"]), Entry["ollama"], "Raw installed tags stay literal.")
			return
		}
	}
	throw Error("The independent shared model catalogue must expose an Ollama tag.")
}
Test("managed bootstrap: catalogue display names resolve before literal pull (groups247-managed)", _G4B_DisplayModelTag)

_G4B_LiveMenuIntent() {
	global _LLM_Menu
	return Map("backend", _LLM_Menu.Get("backend", ""), "model", _LLM_Menu.Get("model", ""),
		"enabled", _LLM_Menu.Get("enabled", false), "api_entry_id", _LLM_Menu.Get("api_entry_id", ""))
}
_G4B_EnableOwner(State) {
	global _LLM_ManagedBootstrap, ConfigurationFile
	Saved := _LLM_ManagedBootstrap
	F := _G4B_Fixture()
	try {
		F.Start()
		F.Flow.Port["read_source"] := _LLM_Menu_EnableReadSource
		F.Flow.Port["menu_intent"] := _G4B_LiveMenuIntent
		F.Flow.Port["aux_generation"] := LLM_AuxGeneration
		F.Flow.Source := _LLM_Menu_EnableReadSource()
		F.Flow.MenuIntent := _G4B_LiveMenuIntent()
		F.Flow.AuxGeneration := LLM_AuxGeneration()
		F.Runtime.PublishReady()
		AssertTrue(F.Flow.Ready, "Managed readiness must precede enable admission.")
		AssertFalse(F.Flow.MenuIntent["enabled"], "The fixture must capture an OFF enable intent.")
		_LLM_ManagedBootstrap := F.Flow
		State["port"]["writer"] := _G4B_EnableWriter.Bind(State, F.Flow)
		State["port"]["persistence_notify"] := _G4B_EnableNotify.Bind(State)
		AssertTrue(LLM_Menu_OnToggle(State["port"]), "The actual tray enable owner starts its fresh origin probe.")
		_LEA_Answer(State, Map("ok", true, "status", 200, "body", '{"version":"0.24.0"}'))
		AssertTrue(State.Get("handoff_bytes_match", false), "The prepared handoff equals the actual complete writer image. " . State.Get("refusal", ""))
		AssertEqual(State["writes"], 1)
		AssertEqual(State["applies"], 1, "The actual durable source handoff precedes live application.")
		F.Flow._Tick()
		AssertTrue(F.Flow.Ready)
		AssertEqual(F.Runtime.Stops, 0, "Its own actual menu writer does not retire the runtime.")
		AssertTrue(FSWrite(ConfigurationFile, FileRead(ConfigurationFile, "UTF-8") . "# foreign successor`n"))
		F.Flow._Tick()
		AssertFalse(F.Flow.Ready)
		AssertEqual(F.Runtime.Stops, 1)
	} finally {
		F.Close()
		_LLM_ManagedBootstrap := Saved
	}
}

/** Observes exact bytes independently at the actual publication boundary. */
_G4B_EnableWriter(State, Flow, Path, Updates) {
	global _LLM_ManagedBootstrap
	AssertTrue(IsObject(_LLM_ManagedBootstrap) && _LLM_ManagedBootstrap == Flow, "The managed flow still owns writer admission.")
	AssertTrue(Flow.Ready, "Managed readiness survives until writer dispatch.")
	AssertTrue(Flow.EnableHandoff is Map, "Managed writer dispatch requires the prepared handoff.")
	Token := Flow.EnableHandoff
	Written := _LEA_Write(State, Path, Updates)
	State["handoff_bytes_match"] := Token is Map
		&& _LLM_Menu_EnableSourceMatches(Token["source"], _LLM_Menu_EnableReadSource())
	if Token is Map {
		Observed := _LLM_Menu_EnableReadSource()
		AssertEqual(Token["source"]["bytes"].Size, Observed["bytes"].Size, "Complete publication byte sizes agree.")
	}
	return Written
}

/** Retains only this fixture's synthetic transaction refusal for failed assertions. */
_G4B_EnableNotify(State, Message, Options) {
	State["refusal"] := Message
	for Line in LoggerRingBufferSnapshot()
		if InStr(Line, "Could not persist the confirmed LLM enabled-state change")
			State["refusal"] := Line
	return true
}
_G4B_EnableOwnerCase() {
	_LEA_WithFixture(_G4B_EnableOwner)
}
Test("managed bootstrap: actual enable admission preserves exact READY successor (groups247-managed)", _G4B_EnableOwnerCase)

#Include test_ollama_runtime_ready_cancellation.ahk
