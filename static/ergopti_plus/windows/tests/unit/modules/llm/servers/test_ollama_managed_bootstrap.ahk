; tests/unit/modules/llm/servers/test_ollama_managed_bootstrap.ahk

#Requires AutoHotkey v2.0

Test("managed bootstrap: install and start have separate consent (groups247-managed)", _G4B_Consent)
Test("managed bootstrap: existing pinned runtime skips install consent (groups247-managed)", _G4B_Reuse)
Test("managed bootstrap: declined install acquires no mutation (groups247-managed)", _G4B_DeclineInstall)
Test("managed bootstrap: declined start keeps installation without daemon (groups247-managed)", _G4B_DeclineStart)
Test("managed bootstrap: held install consent rejects withdrawn source (groups247-managed)", _G4B_Withdraw)
Test("managed bootstrap: model pull needs separate consent and fresh tags (groups247-managed)", _G4B_Model)
Test("managed bootstrap: missing model after pull fails closed (groups247-managed)", _G4B_MissingAfterPull)
Test("managed bootstrap: a Windows-login relay refuses the pull with its reason (owned-ollama-proxy)", _G4B_PullProxyLogin)
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
		this.PullExit := 0
		; Each pull's [exit code, output], in order; 0 keeps PullExit for every pull.
		this.PullScript := 0
		this.Files := _G4B_Files(this)
		this.Runtime := _G4B_Runtime(this)
	}
	Start(Silent := false) {
		Plan := Map("ManagedRoot", "C:\managed", "CataloguePath", "C:\catalogue.json",
			"CatalogueSha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"AssetId", "windows-amd64", "port", 23456, "version", "0.24.0", "deadline_ms", 9000,
			"download", Map("ManagedRoot", "C:\managed"))
		Port := Map("plan", Plan, "files", this.Files, "runtime", this.Runtime,
			"current", (*) => this.CurrentValue, "clock", (*) => this.Now,
			"consent", ObjBindMethod(this, "Consent"), "models", ObjBindMethod(this, "Models"),
			"version", ObjBindMethod(this, "VersionReceipt"), "pull", ObjBindMethod(this, "Pull"))
		this.Flow := OllamaManagedBootstrap(this.Model, 9101,
			(*) => this.ReadyCalls += 1, (*) => this.FailedCalls += 1, Port, Silent)
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
		if this.PullScript is Array {
			Row := this.PullScript[this.Pulls]
			Done.Call(Row[1], Row[2])
			return true
		}
		Done.Call(this.PullExit)
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

; A relay that demands a Windows login was kept from the owned daemon: the
; pull refuses with its own exit code, and the user reads why, not a generic
; repair failure.
_G4B_PullProxyLogin() {
	global LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT, _LLM_Deps_FailureMessage
	SavedMessage := _LLM_Deps_FailureMessage
	F := _G4B_Fixture()
	try {
		F.Model := "qwen3:0.6b"
		F.PullExit := LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(F.Pulls, 1)
		AssertEqual(F.ReadyCalls, 0)
		AssertEqual(F.FailedCalls, 1, "a refused pull fails the bootstrap")
		AssertEqual(t("network.failure.proxy_windows_login"), _LLM_Deps_FailureMessage,
			"the failure names the Windows-login relay")
		AssertTrue(t("network.failure.proxy_windows_login") != t("ollama.runtime_repair_failed"),
			"the named reason is not the generic one")
	} finally {
		F.Close()
		_LLM_Deps_FailureMessage := SavedMessage
	}
}

; A sign-in relay refusal reaches the user as the relay's own message, the login
; message only when no relay could answer.
_G4B_PullRelayRefusalNamesItself() {
	global LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT, _LLM_Deps_FailureMessage
	SavedMessage := _LLM_Deps_FailureMessage
	F := _G4B_Fixture()
	try {
		F.Model := "qwen3:0.6b"
		F.PullScript := [[LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT, "Managed model pull refused: proxy_relay sign_in_rejected`n"]]
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(1, F.FailedCalls)
		AssertEqual(t("network.relay.sign_in_rejected"), _LLM_Deps_FailureMessage)
	} finally {
		F.Close()
		_LLM_Deps_FailureMessage := SavedMessage
	}
	AssertEqual("network.failure.proxy_windows_login", LLM_OllamaPullRefusalKey("Managed model pull refused: proxy_windows_login"))
	AssertEqual("network.relay.failed", LLM_OllamaPullRefusalKey("Managed model pull refused: proxy_relay not_a_reason"),
		"an unknown reason is the relay that did not answer by contract")
}
Test("managed bootstrap: a relay refusal names its own message (proxy-auth-relay)", _G4B_PullRelayRefusalNamesItself)

; The launcher compares the relay's image with what this returns, so a value read
; from the file itself would admit any binary placed at the path.
_G4B_RelayDigestComesFromItsManifest() {
	Path := A_Temp . "\ergopti-g4-relay-" . A_TickCount . ".json"
	Digest := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	try {
		FileAppend('{"schema_version":1,"exe_sha256":"' . Digest . '"}', Path, "UTF-8-RAW")
		AssertEqual(Digest, LLM_OllamaProxyRelayDigest(Path))
		FileDelete(Path)
		FileAppend('{"schema_version":1,"exe_sha256":"not a digest"}', Path, "UTF-8-RAW")
		AssertThrows(() => LLM_OllamaProxyRelayDigest(Path), "a manifest naming no digest is refused")
		FileDelete(Path)
		AssertThrows(() => LLM_OllamaProxyRelayDigest(Path), "a binary without its manifest is refused")
		; The bundled pair agrees: this is what a real launch compares.
		Published := LLM_OllamaProxyRelayDigest(_VendorDir . "\" . LLM_OLLAMA_PROXY_RELAY_MANIFEST)
		AssertEqual(Published, CryptoSha256Bytes(FSReadBytesStrict(_VendorDir . "\" . LLM_OLLAMA_PROXY_RELAY_EXECUTABLE)))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("managed bootstrap: the relay digest is its manifest's, never the file's own (proxy-relay-e2e)", _G4B_RelayDigestComesFromItsManifest)

; The closing line of a pull whose fresh layer failed its sha256 check, after the
; progress frames that always say "pulling manifest".
_G4B_DigestOutput() {
	return "pulling manifest`rpulling 6a07: 100%`nError: digest mismatch, file must be downloaded again: want sha256:a, got sha256:b`n"
}

_G4B_DigestRetrySucceeds() {
	F := _G4B_Fixture()
	try {
		F.Model := "qwen3:0.6b"
		F.PullScript := [[1, _G4B_DigestOutput()], [0, ""]]
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(2, F.Pulls, "a digest mismatch is pulled once more")
		AssertEqual(1, F.ReadyCalls, "the second pull completes the bootstrap")
		AssertEqual(0, F.FailedCalls)
	} finally F.Close()
}
Test("managed bootstrap: a digest mismatch is pulled once more (ollama-digest-mismatch)", _G4B_DigestRetrySucceeds)

_G4B_DigestRetryFails() {
	global _LLM_Deps_FailureMessage
	SavedMessage := _LLM_Deps_FailureMessage
	F := _G4B_Fixture()
	try {
		F.Model := "qwen3:0.6b"
		F.PullScript := [[1, _G4B_DigestOutput()], [1, _G4B_DigestOutput()], [0, ""]]
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(2, F.Pulls, "only one automatic retry")
		AssertEqual(1, F.FailedCalls)
		AssertEqual(StrReplace(t("ollama.digest_mismatch"), "%s", F.Model), _LLM_Deps_FailureMessage,
			"the failure names the mismatch and the model")
	} finally {
		F.Close()
		_LLM_Deps_FailureMessage := SavedMessage
	}
}
Test("managed bootstrap: a second digest mismatch names itself (ollama-digest-mismatch)", _G4B_DigestRetryFails)

_G4B_OtherPullErrorNotRetried() {
	F := _G4B_Fixture()
	try {
		F.Model := "qwen3:0.6b"
		F.PullScript := [[1, "pulling manifest`nError: pull model manifest: file does not exist`n"], [0, ""]]
		F.Start()
		F.Runtime.PublishReady()
		AssertEqual(1, F.Pulls, "only a digest mismatch removed the layer it would download again")
		AssertEqual(1, F.FailedCalls)
	} finally F.Close()
}
Test("managed bootstrap: another pull error is not retried (ollama-digest-mismatch)", _G4B_OtherPullErrorNotRetried)

_G4B_MenuDigestRetry(Script, ExpectedPulls, ExpectedPublished) {
	F := _G4B_Fixture()
	Published := 0
	try {
		F.Start()
		F.Runtime.PublishReady()
		AssertTrue(F.Flow.Ready)
		F.Model := "qwen3:0.6b"
		F.PullScript := Script
		F.Flow.PullModel(F.Model, (*) => Published += 1)
		AssertEqual(ExpectedPulls, F.Pulls)
		AssertEqual(ExpectedPublished, Published)
		AssertEqual(ExpectedPublished == 1, F.Flow.Ready, "only the completed retry keeps the runtime")
	} finally F.Close()
}
_G4B_MenuDigestRetrySucceeds() {
	_G4B_MenuDigestRetry([[1, _G4B_DigestOutput()], [0, ""]], 2, 1)
}
Test("managed bootstrap: a menu pull retries a digest mismatch once (ollama-digest-mismatch)", _G4B_MenuDigestRetrySucceeds)
_G4B_MenuDigestRetryFails() {
	_G4B_MenuDigestRetry([[1, _G4B_DigestOutput()], [1, _G4B_DigestOutput()], [0, ""]], 2, 0)
}
Test("managed bootstrap: a menu pull stops at the second digest mismatch (ollama-digest-mismatch)", _G4B_MenuDigestRetryFails)

_G4B_PullErrorClasses() {
	for Row in [["Error: digest mismatch, file must be downloaded again", "digest_mismatch"],
			["Error: write: no space left on device", "no_space"], ["Error: open: permission denied", "permission_denied"],
			["Error: context canceled", "cancelled"], ["Error: max retries exceeded", "max_retries"],
			["Error: pull model manifest: file does not exist", "manifest"], ["Error: something new", "other"],
			["Error: pull model manifest: Get: context deadline exceeded", "timeout"],
			["Error: pull model manifest: tls: handshake failure", "certificate"],
			["Error: pull model manifest: dial tcp: lookup host: no such host", "dns"],
			["Error: pull model manifest: read: connection reset by peer", "connection"],
			["Error: pull model manifest: 429: too many requests", "rate_limited"],
			["Error: open blob: file does not exist", "not_found"],
			["pulling manifest`npulling 6a07: 100%`nsuccess", ""], ["", ""]]
		AssertEqual(Row[2], LLM_OllamaPullErrorClass(Row[1]), Row[1])
	; The vocabulary is the macOS worker's; a drift shows here, marker and class alike.
	global _SharedDir, LLM_OLLAMA_PULL_ERROR_CLASSES
	Source := FileRead(_SharedDir . "\..\macos\modules\llm\managed_ollama_pull.py", "UTF-8")
	AssertTrue(RegExMatch(Source, "s)ERROR_CLASSES = \((.*?)\n\)", &Block), "the macOS worker must declare its classes")
	Position := 1, Index := 0
	while RegExMatch(Block[1], '\("([^"]+)", "([^"]+)"\)', &Found, Position) {
		Index += 1
		AssertEqual(Found[1], LLM_OLLAMA_PULL_ERROR_CLASSES[Index][1])
		AssertEqual(Found[2], LLM_OLLAMA_PULL_ERROR_CLASSES[Index][2])
		Position := Found.Pos + Found.Len
	}
	AssertEqual(LLM_OLLAMA_PULL_ERROR_CLASSES.Length, Index, "every class of the macOS worker")
}
Test("managed bootstrap: the pull output classes are the macOS vocabulary (ollama-digest-mismatch)", _G4B_PullErrorClasses)

; The CLI writes its closing Error line to stderr: the real tree-owned capture must
; hold it, or the classifier above reads nothing on a real pull.
_G4B_RealCaptureHoldsStderr() {
	Done := false, Code := -1, Output := ""
	OnDone(ExitCode, Stdout, Stderr := "") {
		Code := ExitCode, Output := Stdout, Done := true
	}
	Task := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
		["-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
			"[Console]::Error.WriteLine('Error: digest mismatch, file must be downloaded again'); exit 7"],
		OnDone, , , LLM_OLLAMA_PULL_CAPTURE_BYTES, true, true)
	AssertTrue(Task.start(), "the real child must start")
	Deadline := A_TickCount + 20000
	while !Done && A_TickCount < Deadline
		Sleep(20)
	AssertTrue(Done, "the real child must finish")
	AssertEqual(7, Code)
	AssertEqual("digest_mismatch", LLM_OllamaPullErrorClass(Output), "the capture holds stderr: " . Output)
}
Test("managed bootstrap: the real pull capture holds the CLI's stderr (ollama-digest-mismatch)", _G4B_RealCaptureHoldsStderr)

; Past its ceiling the shell runner reads no body and reports exit 63, so a pull
; of a few minutes would fail after it succeeded.
_G4B_PullCaptureHoldsHoursOfFrames() {
	global LLM_OLLAMA_PULL_CAPTURE_BYTES
	FramesPerHour := 36000, FrameBytes := 200
	AssertTrue(LLM_OLLAMA_PULL_CAPTURE_BYTES >= 8 * FramesPerHour * FrameBytes, "eight hours of frames fit")
	F := _G4B_Fixture()
	Captured := 0
	Spawn(Executable, Arguments, Done, Chunk := 0, Adopt := 0, MaxOutputBytes := 0, *) {
		Captured := MaxOutputBytes
		throw Error("Synthetic spawn refusal after reading its ceiling")
	}
	try {
		F.Start()
		F.Flow.Plan["directory"] := "C:\managed-workers"
		F.Flow.Plan["helper"] := "C:\managed-workers\ollama_managed_files.ps1"
		F.Flow.Plan["helper_sha256"] := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		F.Flow.Plan["environment"] := "C:\captured\managed_ollama_environment.json"
		F.Flow.Plan["environment_sha256"] := "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
		F.Flow.Sources["C:\managed-workers\ollama-runtime-launch.ps1"] := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		F.Runtime.PublishReady()
		F.Flow.Target["ready_file_identity"] := "34567890:3456789012345678"
		F.Flow.Target["ready_image_sha256"] := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		F.Flow._NativePull("qwen3:0.6b", (*) => 0, Spawn)
		AssertEqual(LLM_OLLAMA_PULL_CAPTURE_BYTES, Captured, "the native pull spawns with the pull's own ceiling")
	} finally F.Close()
}
Test("managed bootstrap: a pull's capture holds hours of progress frames (ollama-digest-mismatch)", _G4B_PullCaptureHoldsHoursOfFrames)

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

#Include test_ollama_runtime_terminal_delivery.ahk

#Include test_ollama_failure_epoch_publication.ahk


; This scope owns no file task, daemon or external callback. The native timer
; identity is the real bound production method, not the fixture scheduler.
_G4L_Deleted(Counter, This) {
	Counter.Deleted += 1
}
_G4L_CancelLifetime() {
	Counter := {Deleted: 0}, Control := {Deleted: 0}
	Acyclic := {}
	Acyclic.DefineProp("__Delete", {Call: _G4L_Deleted.Bind(Control)})
	Acyclic := 0
	AssertEqual(1, Control.Deleted, "the runtime synchronously destroys an acyclic owned object")
	Port := Map("plan", Map(), "files", {HasOwner: (*) => false},
		"runtime", {Stop: (*) => true, HasOwner: (*) => false})
	Flow := OllamaManagedBootstrap("", 0, 0, 0, Port)
	Flow.DefineProp("__Delete", {Call: _G4L_Deleted.Bind(Counter)})
	Callback := Flow.Timer
	try {
		AssertTrue(TimerSetCallback(Callback, -60000), "the real scheduler owns the captured production timer")
		AssertTrue(Flow.Cancel(), "no external file or runtime owner prevents cancellation")
		AssertTrue(Flow.Cancelled)
		AssertTrue(Flow.CanReplace(), "the canceled flow has no retained native debt")
	} finally {
		AssertTrue(TimerSetCallback(Callback, 0), "the exact native callback is retired before local references are released")
	}
	Callback := 0
	Flow := 0
	_TestPrint("# MANAGED_BOOTSTRAP_LIFETIME " . KL_JsonEncode(Map(
		"acyclic_deleted", Control.Deleted, "owner_deleted", Counter.Deleted)))
	AssertEqual(1, Counter.Deleted, "a canceled replaceable bootstrap must release its bound polling callback")
}
Test("managed bootstrap: canceled replaceable owner releases its actual timer (managed-bootstrap-lifetime)", _G4L_CancelLifetime)

; Real production port objects retain the bootstrap through their terminal
; observer slots, even with no native task. A timer-only fixture cannot see it.
_G4LG_BindProductionPorts(Flow, State) {
	Files := OllamaInstallFilesPort(Map("helper", "C:\owned\files.ps1",
		"powershell", "C:\owned\powershell.exe", "capture_bytes", 4096,
		"spawn", _G4LG_Spawn.Bind(State),
		"on_physical", ObjBindMethod(Flow, "_Physical"), "on_error", ObjBindMethod(Flow, "_Error")))
	Runtime := OllamaRuntimeOwner(Map("launcher", "C:\bundled\runtime.ps1", "helper", "C:\bundled\files.ps1",
		"helper_sha256", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"environment", "C:\bundled\managed_ollama_environment.json",
		"environment_sha256", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
		"proxy", _ORT_Proxy(), "on_retired", ObjBindMethod(Flow, "_RuntimeRetired"),
		"on_error", ObjBindMethod(Flow, "_Error")))
	Flow.Files := Files, Flow.Runtime := Runtime
	return [Files, Runtime]
}
_G4LG_Spawn(State, Exe, Args, Done, Adopt, Capture) {
	Task := {start: (*) => true, requestTerminate: (*) => State.StopAck}
	State.Done := Done, State.Task := Task
	AssertTrue(Adopt.Call(Task), "the real file port must adopt the exact passive IO task")
	return Task
}
_G4LG_Case(Mode) {
	global _LLM_Deps_Epoch, _LLM_Deps_State, _LLM_Deps_Checking, _LLM_Deps_FailureMessage
	AssertFalse(OllamaNativeIdentityHasDebt(), "the idle graph cannot borrow another native identity debt")
	Saved := [_LLM_Deps_State, _LLM_Deps_Checking, _LLM_Deps_FailureMessage]
	Priority := DllCall("GetPriorityClass", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt")
	AssertTrue(Priority != 0, "the scope must capture its actual native priority")
	Counter := {Deleted: 0, Ready: 0}, State := {StopAck: false, Done: 0, Task: 0}
	Flow := 0, Callback := 0
	PreviousCritical := Critical("On")
	try {
		Port := Map("plan", Map(), "files", {HasOwner: (*) => false},
			"runtime", {Stop: (*) => true, HasOwner: (*) => false}, "current", (*) => true)
		Flow := OllamaManagedBootstrap("", _LLM_Deps_Epoch, (*) => Counter.Ready += 1, (*) => true, Port)
		Flow.DefineProp("__Delete", {Call: _G4L_Deleted.Bind(Counter)})
		Roots := _G4LG_BindProductionPorts(Flow, State)
		Callback := Flow.Timer
		AssertTrue(TimerSetCallback(Callback, -60000))
		if Mode == "ready" {
			AssertTrue(Flow._Complete(), "the actual ready branch publishes its callback")
			AssertEqual(1, Counter.Ready)
			AssertTrue(Flow.Ready)
		} else if Mode == "failed" {
			AssertFalse(Flow._Fail("lifetime-fixture"))
			AssertTrue(Flow.Failed)
		} else if Mode == "file-debt" {
			AssertTrue(Roots[1].Run("inspect", Map(),
				Map("authorize", (*) => true, "is_current", (*) => true), (*) => true))
			AssertFalse(Flow.Cancel(), "a refused passive task retirement remains genuine file-port debt")
			AssertFalse(Flow.CanReplace())
			AssertTrue(Roots[1].HasOwner())
			AssertTrue(Flow.Timer == Callback, "debt retains the existing callback for later cleanup")
			AssertTrue(HasMethod(Roots[1].Options["on_physical"], "Call"))
			AssertTrue(HasMethod(Roots[2].Options["on_retired"], "Call"))
			; This is the captured IO completion, not a forged file-port record or
			; an invented quiescence ACK. The real port adopts its physical proof.
			State.Done.Call(0, '{"ok":true}', "")
			AssertFalse(Roots[1].HasOwner())
		}
		AssertTrue(Flow.Cancel())
		AssertTrue(Flow.Cancel(), "terminal callback release must remain idempotent")
		AssertTrue(Flow.CanReplace())
		AssertTrue(TimerSetCallback(Callback, 0))
		Callback := 0
		Flow := 0
		; A late physical receipt schedules the real one-shot Cancel callback.
		; Let that independent native reference finish before testing collection.
		Critical("Off")
		Started := A_TickCount
		while Counter.Deleted == 0 && TickElapsed64(Started) < 1000
			Sleep(10)
		_TestPrint("# MANAGED_BOOTSTRAP_GRAPH mode=" . Mode . " owner_deleted=" . Counter.Deleted)
		AssertEqual(1, Counter.Deleted, "no terminal production observer may retain the canceled bootstrap")
	} finally {
		if IsObject(Callback)
			TimerSetCallback(Callback, 0)
		if IsObject(Flow)
			Flow.Cancel()
		try {
			_LLM_Deps_State := Saved[1], _LLM_Deps_Checking := Saved[2], _LLM_Deps_FailureMessage := Saved[3]
			AssertTrue(DllCall("SetPriorityClass", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt", Priority, "Int") != 0,
				"failure publication must restore this fixture's exact native priority")
		} finally Critical(PreviousCritical)
	}
}
for _G4LG_Mode in ["cancel", "ready", "failed", "file-debt"]
	Test("managed bootstrap lifetime: " . _G4LG_Mode . " retires the actual file/runtime observer graph (managed-bootstrap-graph-lifetime)",
		_G4LG_Case.Bind(_G4LG_Mode))

class _G4LG_InlineRuntime extends _G4B_Runtime {
	Start(Target, Authority, Ready, Exit) {
		Accepted := super.Start(Target, Authority, Ready, Exit)
		if Accepted
			this.PublishReady()
		return Accepted
	}
}
_G4LG_CancelReady(State, Fixture, This, Value) {
	State.Calls += 1
	return Fixture.Flow.Cancel()
}
_G4LG_InlineCancel() {
	Fixture := _G4B_Fixture(), State := {Calls: 0}
	Fixture.Runtime := _G4LG_InlineRuntime(Fixture)
	; Start installs Flow before any actual runtime callback is delivered.
	Fixture.DefineProp("ReadyCalls", {Get: (*) => State.Calls, Set: _G4LG_CancelReady.Bind(State, Fixture)})
	try {
		Fixture.Start()
		AssertEqual(1, State.Calls)
		AssertTrue(Fixture.Flow.Cancelled)
		AssertTrue(Fixture.Flow.CanReplace())
		AssertFalse(IsObject(Fixture.Flow.Timer), "the returning Start frame must not rearm its retired callback")
	} finally {
		Fixture.Close()
		Fixture.Runtime.Ready := 0
		Fixture.DeleteProp("ReadyCalls")
		Fixture.ReadyCalls := State.Calls
	}
}
Test("managed bootstrap lifetime: inline READY cancellation cannot rearm the returning Start frame (managed-bootstrap-timer-control)",
	_G4LG_InlineCancel)

; Closing logical observers is terminal for the exact port, while ordinary
; Stop/Cancel remain usable and cannot mistake a live record for a closed one.
_G4LOR_CallbackRetirementContract() {
	global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL, _LLM_Deps_Epoch
	AssertFalse(OllamaNativeIdentityHasDebt())
	State := {StopAck: false, Done: 0, Task: 0}
	Port := Map("plan", Map(), "files", {HasOwner: (*) => false},
		"runtime", {Stop: (*) => true, HasOwner: (*) => false})
	Flow := OllamaManagedBootstrap("", _LLM_Deps_Epoch, 0, 0, Port)
	Roots := _G4LG_BindProductionPorts(Flow, State)
	RuntimeFixture := _ORT_Fixture()
	PreviousCritical := Critical("On")
	try {
		AssertTrue(Roots[1].Run("inspect", Map(),
			Map("authorize", (*) => true, "is_current", (*) => true), (*) => true))
		Observer := Roots[1].Options["on_physical"]
		AssertFalse(Roots[1].RetireCallbacks(), "a live file task keeps its physical observer")
		AssertTrue(Roots[1].HasOwner())
		AssertTrue(Roots[1].Options["on_physical"] == Observer)
		State.Done.Call(0, '{"ok":true}', "")
		AssertFalse(Roots[1].HasOwner())
		AssertTrue(Flow.Cancel())
		AssertTrue(Flow.Cancel(), "the bootstrap's repeated cancellation still acknowledges retirement")
		AssertTrue(Flow.CanReplace(), "closed logical observers leave replacement admission intact")
		State.Task := 0
		AssertFalse(Roots[1].Run("inspect", Map(),
			Map("authorize", (*) => true, "is_current", (*) => true), (*) => true),
			"a permanently retired file port must not acquire a new task")
		AssertEqual(0, State.Task, "closed-port refusal happens before the native spawn port")
		AssertTrue(Roots[1].Cancel())
		AssertFalse(Roots[1].HasOwner())

		; The real runtime record, task and strict retirement observer are owned
		; by the existing passive native-IO fixture, never injected as Records.
		AssertTrue(RuntimeFixture.Run())
		Runtime := RuntimeFixture.Owner
		Record := Runtime.Record, Observer := Runtime.Options["on_retired"]
		AssertFalse(Runtime.RetireCallbacks(), "a live runtime retains exact lease retirement authority")
		AssertTrue(Runtime.Record == Record && Runtime.HasOwner())
		AssertTrue(Runtime.Options["on_retired"] == Observer)
		AssertTrue(Runtime.Stop())
		AssertFalse(Runtime.HasOwner())
		AssertTrue(Runtime.RetireCallbacks(&Retired))
		AssertTrue(Retired is Array && Retired.Length == 2)
		AssertTrue(Retired[1] == Observer, "the caller can retain the exact callbacks through an outer RAM claim")
		AssertTrue(Runtime.RetireCallbacks(), "observer retirement is idempotent")
		Starts := RuntimeFixture.Starts
		AssertFalse(Runtime.Start(RuntimeFixture.Target, RuntimeFixture.Authority))
		AssertEqual(Starts, RuntimeFixture.Starts, "a closed runtime never reacquires its native task")
		AssertTrue(Runtime.Stop())
		AssertFalse(Runtime.HasOwner())

		SavedBootstrap := _LLM_ManagedBootstrap
		try {
			_LLM_ManagedBootstrap := Flow
			AssertEqual(LLM_OLLAMA_BASE_URL, LLM_OllamaRequestOrigin(),
				"a retired bootstrap still resolves the ordinary configured origin")
		} finally _LLM_ManagedBootstrap := SavedBootstrap
	} finally {
		try {
			if Roots[1].HasOwner() && HasMethod(State.Done, "Call")
				State.Done.Call(0, '{"ok":true}', "")
			Flow.Cancel()
			RuntimeFixture.Owner.Stop()
		} finally Critical(PreviousCritical)
	}
}
Test("managed bootstrap observers: live debt, closed-port refusal and ordinary APIs remain exact (managed-bootstrap-observer-retirement)",
	_G4LOR_CallbackRetirementContract)

; Runtime diagnostics are optional in the genuine constructor contract.
_G4LOR_NoErrorObserver() {
	AssertFalse(OllamaNativeIdentityHasDebt())
	Fixture := _ORT_Fixture()
	Options := Fixture.Owner.Options.Clone()
	Options.Delete("on_error")
	Owner := OllamaRuntimeOwner(Options)
	try {
		AssertFalse(Owner.Options.Has("on_error"), "the genuine constructor accepts an absent diagnostic observer")
		AssertFalse(Owner.HasOwner())
		AssertTrue(Owner.RetireCallbacks(&Retired))
		AssertTrue(Retired is Array && Retired.Length == 2)
		AssertEqual(0, Retired[2], "absence of the optional observer contributes no retained callback")
		AssertTrue(Owner.RetireCallbacks(), "an idle owner without diagnostics still retires idempotently")
		AssertTrue(Owner.Stop())
		AssertFalse(Owner.Start(Fixture.Target, Fixture.Authority))
		AssertEqual(0, Fixture.Starts, "the retired owner cannot reach its native spawn port")
		AssertFalse(Owner.HasOwner())
	} finally Owner.Stop()
}
Test("managed bootstrap observers: valid runtime without optional diagnostics still retires (managed-bootstrap-observer-retirement)",
	_G4LOR_NoErrorObserver)


; Constructor-failure witnesses hold no callback, partial object or timer root.
; No Begin call occurs: the refused endpoint precedes source/native acquisition.
class _G4CF_AcyclicFailure {
	__New(Counter) {
		this.DefineProp("__Delete", {Call: _G4L_Deleted.Bind(Counter)})
		throw ValueError("acyclic-constructor-lifetime-control")
	}
}

class _G4CF_ObservedBootstrap extends OllamaManagedBootstrap {
	__New(Counter, Arguments*) {
		this.DefineProp("__Delete", {Call: _G4L_Deleted.Bind(Counter)})
		; Delegate the complete genuine constructor, with no overridden source,
		; scheduler, cancellation, native factory or method implementation.
		super.__New(Arguments*)
	}
}

_G4CF_Case(Mode) {
	global LLM_OLLAMA_BASE_URL, _LLM_Deps_Epoch
	Counter := {Deleted: 0}, Thrown := false, Observed := ""
	PreviousEndpoint := LLM_OLLAMA_BASE_URL
	PreviousCritical := Critical("On")
	try {
		if Mode == "acyclic" {
			try CtorUnreachable :=  _G4CF_AcyclicFailure(Counter)
			catch ValueError as CtorFailure {
				Thrown := true
				Observed := CtorFailure.Message
			}
			AssertTrue(Thrown && Observed == "acyclic-constructor-lifetime-control",
				"The actual AHK constructor-failure path must release its acyclic object synchronously")
		} else {
			LLM_OLLAMA_BASE_URL := "https://invalid-managed-endpoint.example"
			try CtorUnreachable :=  _G4CF_ObservedBootstrap(Counter, "", _LLM_Deps_Epoch, 0, 0)
			catch ValueError as CtorFailure {
				Thrown := true
				Observed := CtorFailure.Message
			}
			AssertTrue(Thrown && Observed == "Managed runtime requires the selected loopback Ollama endpoint.",
				"Only the genuine pre-acquisition endpoint refusal qualifies this constructor-failure witness")
		}
		_TestPrint("# MANAGED_CONSTRUCTOR_LIFETIME mode=" . Mode . " threw=" . Thrown . " owner_deleted=" . Counter.Deleted)
		AssertEqual(1, Counter.Deleted,
			"A failed constructor with no acquired native task, armed timer or external callback must not retain its partial owner")
	} finally {
		LLM_OLLAMA_BASE_URL := PreviousEndpoint
		Critical(PreviousCritical)
	}
}
for _G4CF_Mode in ["acyclic", "endpoint"]
	Test("managed bootstrap constructor lifetime: " . _G4CF_Mode . " releases an unowned failed construction (managed-bootstrap-constructor-failure-lifetime)",
		_G4CF_Case.Bind(_G4CF_Mode))


; Genuine constructor fault boundaries. None calls Begin or starts a native task.
_G4CX_Throw(Stage) {
	throw Error("managed-constructor-cutpoint:" . Stage)
}
_G4CX_FilesAssigned(State, Owner, Value) {
	State.FilesConstructed := Value is OllamaInstallFilesPort && !Value.HasOwner()
	; Retain no owner or port in the witness. Publish the exact genuine value.
	Owner.DefineProp("Files", {Value: Value})
	return Value
}
class _G4CX_ObservedBootstrap extends OllamaManagedBootstrap {
	__New(Counter, State, Arguments*) {
		this.DefineProp("__Delete", {Call: _G4L_Deleted.Bind(Counter)})
		this.CtorWitness := State
		if State.Mode == "timings" || State.Mode == "postports"
			this.DefineProp("Files", {Set: _G4CX_FilesAssigned.Bind(State)})
		super.__New(Arguments*)
	}
	_PublishConstructionObservers() {
		State := this.CtorWitness
		if State.Mode == "postports" {
			State.RuntimeConstructed := this.Runtime is OllamaRuntimeOwner && !this.Runtime.HasOwner()
			State.Neutral := this.Files.Options["on_physical"] == OllamaManagedBootstrap._UnstartedObserver
				&& this.Runtime.Options["on_retired"] == OllamaManagedBootstrap._UnstartedObserver
				&& !IsObject(this.Timer)
			_G4CX_Throw("postports")
		}
		return super._PublishConstructionObservers()
	}
}
_G4CX_BorrowedRetirement(State, *) {
	State.BorrowedRetirements += 1
	return true
}

_G4CX_CaseWithTimingsReady(Mode) {
	global LLM_OLLAMA_BASE_URL, ConfigurationFile, _TimingsCache, _LLM_Deps_Epoch
	AssertFalse(OllamaNativeIdentityHasDebt(), "The constructor witness cannot borrow another owner's native identity debt")
	Counter := {Deleted: 0}
	State := {Mode: Mode, FilesConstructed: false, RuntimeConstructed: false, Neutral: false, BorrowedRetirements: 0}
	SavedEndpoint := LLM_OLLAMA_BASE_URL, SavedConfig := ConfigurationFile, SavedTimings := _TimingsCache
	PreviousCritical := Critical("Off")
	Directory := "", Created := false, Returned := 0, Thrown := false, Message := ""
	try {
		if Mode == "timings" || Mode == "postports" {
			Directory := A_Temp . "\ergopti_ctor_capture_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
			Creation := FSCreateDirectoryExclusiveStrict(Directory)
			AssertTrue(Creation is Integer && Creation == 1)
			Created := true
			ConfigPath := Directory . "\source.toml"
			AssertTrue(FSWriteCreateDurable(ConfigPath, "[llm]`nenabled = false`n") != 0)
		}
		Critical(Mode == "timings" || Mode == "postports" ? "Off" : "On")
		LLM_OLLAMA_BASE_URL := "http://127.0.0.1:11434"
		if Mode == "read-source" || Mode == "menu-intent" {
			Borrowed := {HasOwner: (*) => false, Stop: (*) => true, RetireCallbacks: _G4CX_BorrowedRetirement.Bind(State)}
			Port := Map("plan", Map(), "files", Borrowed, "runtime", Borrowed,
				"read_source", Mode == "read-source" ? _G4CX_Throw.Bind(Mode) : ((*) => Map()),
				"menu_intent", Mode == "menu-intent" ? _G4CX_Throw.Bind(Mode) : ((*) => Map()),
				"aux_generation", (*) => 0)
			try Returned := _G4CX_ObservedBootstrap(Counter, State, "", _LLM_Deps_Epoch, 0, 0, Port)
			catch Error as CtorFault {
				Thrown := true, Message := CtorFault.Message
			}
			AssertTrue(Thrown && Message == "managed-constructor-cutpoint:" . Mode,
				"Only the actual borrowed constructor reader failure qualifies this boundary")
			AssertEqual(0, State.BorrowedRetirements, "A failed constructor cannot retire caller-borrowed ports")
		} else {
			ConfigurationFile := ConfigPath
			if Mode == "timings" {
				AssertTrue(_TimingsCache is Map && _TimingsCache.Has("adapters") && _TimingsCache["adapters"] is Map)
				Replacement := _TimingsCache.Clone()
				Replacement["adapters"] := _TimingsCache["adapters"].Clone()
				AssertTrue(Replacement["adapters"].Has("proxy_relay_dial_timeout_ms"))
				Replacement["adapters"].Delete("proxy_relay_dial_timeout_ms")
				_TimingsCache := Replacement
			}
			try Returned := _G4CX_ObservedBootstrap(Counter, State, "", _LLM_Deps_Epoch, 0, 0)
			catch Error as CtorFault {
				Thrown := true, Message := CtorFault.Message
			}
			if Mode == "timings"
				AssertTrue(Thrown && InStr(Message, "proxy_relay_dial_timeout_ms") > 0 && State.FilesConstructed,
					"The real TimingsGet refusal must follow construction of the actual idle file port")
			else
				AssertTrue(Thrown && Message == "managed-constructor-cutpoint:postports"
					&& State.FilesConstructed && State.RuntimeConstructed && State.Neutral,
					"Both actual idle ports must remain acyclic until the final observer publication boundary")
		}
		if Mode == "postports" {
			; The same real capture must also return a fully wired native owner
			; when this deliberate observation refusal is absent.
			ControlCounter := {Deleted: 0}
			ControlState := {Mode: "native-control", FilesConstructed: false, RuntimeConstructed: false, Neutral: false}
			Returned := _G4CX_ObservedBootstrap(ControlCounter, ControlState, "", _LLM_Deps_Epoch, 0, 0)
			AssertTrue(Returned.Files is OllamaInstallFilesPort && Returned.Runtime is OllamaRuntimeOwner
				&& !Returned.Files.HasOwner() && !Returned.Runtime.HasOwner() && IsObject(Returned.Timer),
				"The ordinary full constructor must publish its actual idle ports and polling capability")
			AssertTrue(HasMethod(Returned.Files.Options["on_physical"], "Call")
				&& Returned.Files.Options["on_physical"] != OllamaManagedBootstrap._UnstartedObserver
				&& HasMethod(Returned.Runtime.Options["on_retired"], "Call")
				&& Returned.Runtime.Options["on_retired"] != OllamaManagedBootstrap._UnstartedObserver,
				"Normal constructor success must replace every provisional physical observer before returning")
			AssertTrue(Returned.Cancel(), "No native task was started; the actual owner must acknowledge ordinary retirement")
			Returned := 0
			AssertEqual(1, ControlCounter.Deleted, "The ordinary full constructor remains destructible after real cancellation")
		}
		_TestPrint("# MANAGED_CONSTRUCTOR_CUTPOINT mode=" . Mode . " threw=" . Thrown . " files=" . State.FilesConstructed
			. " runtime=" . State.RuntimeConstructed . " neutral=" . State.Neutral . " owner_deleted=" . Counter.Deleted)
		AssertEqual(1, Counter.Deleted, "A failed unstarted constructor cannot retain timer or native observer cycles")
	} finally {
		try {
			if IsObject(Returned)
				AssertTrue(Returned.Cancel(), "An unexpected successful unstarted constructor must retire its exact callbacks")
			Returned := 0
		} finally {
			Critical("On")
			LLM_OLLAMA_BASE_URL := SavedEndpoint, ConfigurationFile := SavedConfig, _TimingsCache := SavedTimings
			Critical("Off")
			try {
				if Created
					DirDelete(Directory, true)
			} finally Critical(PreviousCritical)
		}
	}
}
; Filtered tests do not execute the timing-loader test. Use the genuine boot
; loaders and restore all seven timing leaves, including a previously unset one.
_G4CX_Case(Mode) {
	global _TimingsCache, _LLM_Menu
	global LLM_OLLAMA_POLL_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_POLL_MS
	global LLM_INSTALLED_CACHE_TTL_MS, LLM_DEPS_POLL_TIMEOUT_MS, LLM_REMOTE_READY_PING_DEADLINE_MS, LLM_OLLAMA_DELETE_TIMEOUT_MS
	if Mode != "timings" && Mode != "postports"
		return _G4CX_CaseWithTimingsReady(Mode)
	SavedCache := _TimingsCache
	Previous := [IsSet(LLM_OLLAMA_POLL_MS) ? LLM_OLLAMA_POLL_MS : unset,
		IsSet(LLM_REMOTE_TIMEOUT_MS) ? LLM_REMOTE_TIMEOUT_MS : unset,
		IsSet(LLM_REMOTE_POLL_MS) ? LLM_REMOTE_POLL_MS : unset,
		IsSet(LLM_INSTALLED_CACHE_TTL_MS) ? LLM_INSTALLED_CACHE_TTL_MS : unset,
		IsSet(LLM_DEPS_POLL_TIMEOUT_MS) ? LLM_DEPS_POLL_TIMEOUT_MS : unset,
		IsSet(LLM_REMOTE_READY_PING_DEADLINE_MS) ? LLM_REMOTE_READY_PING_DEADLINE_MS : unset,
		IsSet(LLM_OLLAMA_DELETE_TIMEOUT_MS) ? LLM_OLLAMA_DELETE_TIMEOUT_MS : unset]
	PreviousCritical := Critical("Off")
	try {
		TimingsLoadShared()
		LLMApiLoadTimings()
		AssertTrue(_TimingsCache is Map && LLM_DEPS_POLL_TIMEOUT_MS > 0,
			"Native constructor captures require the genuine loaded boot timings")
		AssertTrue(_LLM_Menu is Map && LLM_AuxGeneration() is Integer,
			"Use the genuine run_all menu and auxiliary initial state")
		return _G4CX_CaseWithTimingsReady(Mode)
	} finally {
		Critical("On")
		_TimingsCache := SavedCache
		LLM_OLLAMA_POLL_MS := Previous.Has(1) ? Previous[1] : unset
		LLM_REMOTE_TIMEOUT_MS := Previous.Has(2) ? Previous[2] : unset
		LLM_REMOTE_POLL_MS := Previous.Has(3) ? Previous[3] : unset
		LLM_INSTALLED_CACHE_TTL_MS := Previous.Has(4) ? Previous[4] : unset
		LLM_DEPS_POLL_TIMEOUT_MS := Previous.Has(5) ? Previous[5] : unset
		LLM_REMOTE_READY_PING_DEADLINE_MS := Previous.Has(6) ? Previous[6] : unset
		LLM_OLLAMA_DELETE_TIMEOUT_MS := Previous.Has(7) ? Previous[7] : unset
		Critical(PreviousCritical)
	}
}
for _G4CX_Mode in ["read-source", "menu-intent", "timings", "postports"]
	Test("managed bootstrap constructor cutpoint: " . _G4CX_Mode . " retains no unstarted cycle (managed-bootstrap-constructor-cutpoints)",
		_G4CX_Case.Bind(_G4CX_Mode))
