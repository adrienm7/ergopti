; tests/unit/modules/llm/menu/test_llm_menu_backend_model_labels.ahk

; ==============================================================================
; MODULE: LLM Menu Model Button Labels
; DESCRIPTION:
; The tray's one model button (maintainer, 2026-10-27) reads the backend's
; emoji, then the model: "🦙 qwen3:4b", "🌐 OpenAI/gpt-4o-mini". The emoji
; comes from _shared/modules/llm/backends.json and the API form names the
; provider by its display name. The shown model follows the active backend:
; with backend api it is the selected entry, never the stale Ollama tag. The
; model the page adds is validated against the shared identifier corpus.
; ==============================================================================

#Requires AutoHotkey v2.0



_LBMD_ModelDisplayText() {
	global _LLM_Menu, LLM_API_PROVIDERS
	Assert(_DriverFuncBody("_LLM_Menu_ModelDisplayText") != "",
		"_LLM_Menu_ModelDisplayText must exist in menu_models.ahk")
	Assert(_DriverFuncBody("_LLM_Menu_ApiEntryDisplayName") != "",
		"_LLM_Menu_ApiEntryDisplayName must exist in menu_models.ahk")
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("backend", "api", "model", "stale-ollama-tag",
			"api_entry_id", "e1",
			"api_entries", [Map("Id", "e1", "Name", "Cerebras",
				"Provider", "cerebras", "BaseUrl", "https://b.invalid/v1",
				"Token", "sekret", "Model", "qwen-3.8-27b")])
		AssertEqual("cerebras/qwen-3.8-27b", _LLM_Menu_ModelDisplayText(),
			"with backend api the row shows the entry's automatic name, not its stored one")
		AssertEqual("cerebras/qwen-3.8-27b",
			_LLM_Menu_ApiEntryDisplayName(_LLM_Menu["api_entries"][1]))
		_LLM_Menu["api_entries"][1]["Model"] := ""
		AssertEqual("cerebras/" . LLM_API_PROVIDERS["cerebras"]["DefaultModel"],
			_LLM_Menu_ModelDisplayText(),
			"an entry without a model is named after the provider default")
		_LLM_Menu["api_entry_id"] := "ghost"
		AssertEqual("", _LLM_Menu_ModelDisplayText(),
			"an unknown entry never resurrects the stale ollama tag")
		_LLM_Menu["backend"] := "ollama"
		_LLM_Menu["api_entry_id"] := "e1"
		AssertEqual("stale-ollama-tag", _LLM_Menu_ModelDisplayText(),
			"with backend ollama the preserved slot shows untouched")
	} finally _LLM_Menu := SavedMenu
}
Test("llm menu: model row follows the active backend (llm-menu-model-label)",
	_LBMD_ModelDisplayText)


; model-button-emoji-first: each backend form, with the emoji read from the
; shared file independently of the driver's loader.
_LBMD_SelectorCaptionForms() {
	global _LLM_Menu, LLM_API_PROVIDERS, _SharedDir
	Shared := JsonParse(FileRead(_SharedDir . "\modules\llm\backends.json", "UTF-8"))["backends"]
	AssertEqual(Shared["ollama"]["emoji"] . " qwen3:4b", LLM_ModelSelectorCaption("ollama", "qwen3:4b"))
	AssertEqual(Shared["mlx"]["emoji"] . " Qwen3-4B", LLM_ModelSelectorCaption("mlx", "Qwen3-4B"))
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("backend", "api", "model", "stale-ollama-tag", "api_entry_id", "e1",
			"api_entries", [Map("Id", "e1", "Name", "Mine", "Provider", "cerebras",
				"BaseUrl", "https://b.invalid/v1", "Token", "sekret", "Model", "qwen-3.8-27b")])
		Label := LLM_API_PROVIDERS["cerebras"]["Label"]
		AssertEqual(Label . "/qwen-3.8-27b", _LLM_Menu_ModelCaptionText(),
			"the API button names the provider's display name, then the model")
		AssertEqual(Shared["api"]["emoji"] . " " . Label . "/qwen-3.8-27b",
			LLM_ModelSelectorCaption("api", _LLM_Menu_ModelCaptionText()))
		_LLM_Menu["api_entries"][1]["Model"] := ""
		AssertEqual(Label . "/" . LLM_API_PROVIDERS["cerebras"]["DefaultModel"], _LLM_Menu_ModelCaptionText(),
			"an entry without a model is named after the model its requests use")
		_LLM_Menu["backend"] := "ollama"
		AssertEqual("stale-ollama-tag", _LLM_Menu_ModelCaptionText(), "a local backend shows its model")
	} finally _LLM_Menu := SavedMenu
	Refused := false
	try LLM_ModelSelectorCaption("kanata", "x")
	catch ValueError
		Refused := true
	AssertTrue(Refused, "an unknown backend is refused")
	Refused := false
	try LLM_ModelSelectorCaption("ollama", "")
	catch ValueError
		Refused := true
	AssertTrue(Refused, "an empty model text is refused")
}
Test("model-button-emoji-first: each backend form starts with the shared emoji",
	_LBMD_SelectorCaptionForms)

; The identifiers the page lets the user add, against the corpus the page,
; macOS and Linux validate too.
_LBMD_ModelIdentifierCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\model_identifiers.json", "UTF-8"))
	for Backend in ["ollama", "mlx"] {
		for Id in Corpus[Backend]["valid"]
			AssertTrue(LLM_ValidModelIdentifier(Backend, Id), Backend . " accepts '" . Id . "'")
		for Id in Corpus[Backend]["invalid"]
			AssertFalse(LLM_ValidModelIdentifier(Backend, Id), Backend . " refuses '" . Id . "'")
	}
	AssertFalse(LLM_ValidModelIdentifier("api", "gpt-4o"), "only local backends add models")
}
Test("model-selector-page: added model identifiers follow the shared corpus",
	_LBMD_ModelIdentifierCorpus)


; model-selector-api-listing: the API rows follow the shared listing corpus the
; macOS and Linux suites replay through _shared/lua/llm/api_model_listing.lua.
_LBMD_ApiListingCorpus() {
	global _SharedDir, LLM_API_LISTING_MAX_MODELS, LLM_API_LISTING_MAX_ID_LENGTH, LLM_API_LISTING_MAX_ENTRIES
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\api_model_listing_vectors.json", "UTF-8"))
	AssertEqual(Corpus["max_models"], LLM_API_LISTING_MAX_MODELS, "the listing bound is the shared one")
	AssertEqual(Corpus["max_id_length"], LLM_API_LISTING_MAX_ID_LENGTH, "the id bound is the shared one")
	AssertEqual(Corpus["max_entries"], LLM_API_LISTING_MAX_ENTRIES, "the page bound is the shared one")
	for Vector in Corpus["ids"] {
		Result := LLM_ApiListingIds(Vector["format"], Vector["body"])
		if (Vector["expect"] == JSON_NULL) {
			AssertEqual(Vector["reason"], Result.Get("reason", ""), Vector["name"])
			continue
		}
		Joined := "", Expected := ""
		for Id in Result["ids"]
			Joined .= (Joined == "" ? "" : ",") . Id
		for Id in Vector["expect"]
			Expected .= (Expected == "" ? "" : ",") . Id
		AssertEqual(Expected, Joined, Vector["name"])
	}
	for Vector in Corpus["names"] {
		Parts := LLM_ApiListingNameParts(Vector["name"], Vector["model"])
		AssertEqual(Vector["base"], Parts[1], Vector["name"])
		AssertEqual(Vector["suffix"], Parts[2], Vector["name"])
	}
	for Vector in Corpus["plans"] {
		Listing := Vector["listing"] == JSON_NULL ? 0 : Vector["listing"]
		Plan := LLM_ApiListingPlan(Vector["view"], Listing)
		Expect := Vector["expect"]
		AssertEqual(Expect["models"].Length, Plan["models"].Length, Vector["name"] . ": row count")
		for Index, Row in Expect["models"] {
			AssertEqual(Row["model"], Plan["models"][Index]["model"], Vector["name"] . ": row " . Index)
			AssertEqual(Row["listed"] ? 1 : 0, Plan["models"][Index]["listed"] ? 1 : 0, Vector["name"] . ": listed " . Index)
		}
		AssertEqual(Expect["typed"] == JSON_NULL ? "" : Expect["typed"]["hint_key"], Plan["typed_hint"],
			Vector["name"] . ": typed hint")
	}
	Overlong := ""
	loop LLM_API_LISTING_MAX_ID_LENGTH + 1
		Overlong .= "x"
	Data := [Map("id", Overlong)]
	loop LLM_API_LISTING_MAX_MODELS + 5
		Data.Push(Map("id", Format("m{:03}", A_Index)))
	Ids := LLM_ApiListingIds("openai", Map("data", Data))["ids"]
	AssertEqual(LLM_API_LISTING_MAX_MODELS, Ids.Length, "a listing keeps at most the shared bound")
	AssertEqual("m001", Ids[1], "an overlong id is dropped")
}
Test("model-selector-api-listing: listing ids, names and plans follow the shared corpus",
	_LBMD_ApiListingCorpus)

; The page rows of one entry: its provider's listed models, or the known ones
; and a typed-id row whose hint names why the list is missing.
_LBMD_ApiListingRows() {
	global _LLM_Menu, LLM_API_PROVIDERS
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("backend", "api", "model", "", "api_entry_id", "e1",
			"api_entries", [Map("Id", "e1", "Name", "", "Provider", "openai",
				"BaseUrl", "https://api.openai.com/v1", "Token", "sekret", "Model", "gpt-4o")])
		; The rows read the entry's automatic name: "<provider>/<model>".
		Label := LLM_ApiListingNameParts(_LLM_Menu_ApiEntryNameList(_LLM_Menu["api_entries"])[1], "gpt-4o")[1]
		AssertTrue(Label != "", "the entry's automatic name holds its provider")
		Rows := Map(), Models := []
		_LLM_Menu_ApiEntryPageRows(Rows, Models, Map("e1", Map("state", "listed", "ids", ["gpt-4.1", "o3"])))
		for Name in [Label . "/gpt-4o", Label . "/gpt-4.1", Label . "/o3"]
			AssertTrue(Rows.Has("api`n" . Name), "listed row " . Name)
		AssertFalse(Rows.Has("api`n" . Label), "a listed provider has no typed-id row")
		AssertTrue(Rows["api`n" . Label . "/o3"].Has("select"), "a listed model is selectable")
		for Json in Models
			AssertEqual(0, InStr(Json, "sekret"), "the key never reaches the page payload")
		Rows := Map(), Models := []
		_LLM_Menu_ApiEntryPageRows(Rows, Models, Map("e1", Map("state", "failed", "reason", "refused")))
		AssertTrue(Rows.Has("api`n" . Label . "/gpt-4o"), "the configured model stays")
		AssertTrue(Rows.Has("api`n" . Label . "/" . LLM_API_PROVIDERS["openai"]["DefaultModel"]),
			"the provider's known default model is offered")
		AssertTrue(Rows.Has("api`n" . Label), "the typed-id row")
		Typed := Rows["api`n" . Label]
		AssertFalse(Typed.Has("select"), "the typed-id row activates nothing")
		AssertTrue(Typed["row_actions"].Has("other_model"), "the typed-id row asks for an id")
		AssertContains(Typed["json"], "model_browser.hint_api_listing_refused", "the refusal is the hint")
		AssertContains(Typed["json"], "available:false", "the typed-id row is greyed")
		Rows := Map(), Models := []
		_LLM_Menu_ApiEntryPageRows(Rows, Models)
		AssertContains(Rows["api`n" . Label]["json"], "model_browser.hint_api_listing_unavailable",
			"a provider never asked reads unavailable")
		Asked := Map()
		AssertEqual(false, _LLM_Menu_PromptApiPageModel("e1", "gpt-4o",
			(Prompt, Title, Options, Default) => (Asked["default"] := Default, { Result: "Cancel", Value: "" })),
			"a cancelled prompt changes nothing")
		AssertEqual("gpt-4o", Asked.Get("default", ""), "the prompt starts from the configured model")
		AssertEqual(false, _LLM_Menu_SetApiEntryModel("e1", "has space"), "a typed id with a space is refused")
		Candidate := Map("api_entries", [Map("Id", "e1", "Name", "", "Provider", "openai",
			"BaseUrl", "https://api.openai.com/v1", "Token", "sekret", "Model", "gpt-4o")], "api_entry_id", "")
		AssertTrue(_LLM_Menu_SetApiEntryModelCandidate(Candidate, "e1", "o3"), "the candidate takes the model")
		AssertEqual("o3", Candidate["api_entries"][1]["Model"])
		AssertEqual("e1", Candidate["api_entry_id"], "and the entry becomes the active one")
		AssertEqual("gpt-4o", _LLM_Menu["api_entries"][1]["Model"], "the live entry waits for the commit")
		; A second entry whose own model is the first entry's known default
		; keeps that row: an entry's own model wins over a known one.
		Default := LLM_API_PROVIDERS["openai"]["DefaultModel"]
		_LLM_Menu["api_entries"].Push(Map("Id", "e2", "Name", "", "Provider", "openai",
			"BaseUrl", "https://api.openai.com/v1", "Token", "other", "Model", Default))
		Rows := Map(), Models := []
		_LLM_Menu_ApiEntryPageRows(Rows, Models)
		Names := _LLM_Menu_ApiEntryNameList(_LLM_Menu["api_entries"])
		AssertTrue(Rows.Has("api`n" . Names[2]), "the second entry's own row")
		AssertFalse(InStr(Rows["api`n" . Names[2]]["json"], "typed:true"), "its own row is no typed row")
	} finally _LLM_Menu := SavedMenu
}
Test("model-selector-api-listing: one row per listed model, known models and a typed row otherwise",
	_LBMD_ApiListingRows)

; The listing answer maps to the shared states: no answer is unreachable, an
; HTTP refusal is refused, a body without its list is unreadable.
_LBMD_ApiListingAnswers() {
	Got := []
	Collect := (State) => Got.Push(State)
	_LLMRemote_ListingDone("openai", "openai", Collect, false)
	_LLMRemote_ListingDone("openai", "openai", Collect, Map("status", 401, "body", '{"error":{}}'))
	_LLMRemote_ListingDone("openai", "openai", Collect, Map("status", 200, "body", '{"error":{}}'))
	_LLMRemote_ListingDone("gemini", "gemini", Collect, Map("status", 200,
		"body", '{"models":[{"name":"models/gemini-2.0-flash"}]}'))
	AssertEqual(4, Got.Length)
	AssertEqual("unavailable", Got[1]["reason"])
	AssertEqual("refused", Got[2]["reason"])
	AssertEqual("unreadable", Got[3]["reason"])
	AssertEqual("listed", Got[4]["state"])
	AssertEqual("gemini-2.0-flash", Got[4]["ids"][1])
	Refused := []
	LLM_RemoteListModels_Async(Map("Id", "d1", "Provider", "typesafe", "BaseUrl", "", "Token", "k", "Model", "jev"),
		(State) => Refused.Push(State))
	AssertEqual(1, Refused.Length, "a decisions provider is answered at once")
	AssertEqual("unsupported", Refused[1]["reason"])
}
Test("model-selector-api-listing: listing answers map to the shared states", _LBMD_ApiListingAnswers)

; The page asks each entry once per session, bounded and one at a time, and
; draws its rows from those states. Scanned comment-stripped.
_LBMD_ApiListingPageWiring() {
	Ready := _StripFullLineComments(_DriverFuncBody("_LLM_MBW_OnPageReady"))
	Start := _StripFullLineComments(_DriverFuncBody("_LLM_MBW_StartListings"))
	Done := _StripFullLineComments(_DriverFuncBody("_LLM_MBW_ListingDone"))
	Build := _StripFullLineComments(_DriverFuncBody("_LLM_MBW_BuildPayload"))
	for Body in [Ready, Start, Done, Build]
		Assert(Body != "", "the page's listing owners must remain source-visible")
	AssertContains(Ready, "_LLM_MBW_StartListings(ExpectedEpoch)", "the page asks once it is ready")
	AssertContains(Start, "LLM_API_LISTING_MAX_ENTRIES", "the number of entries asked is bounded")
	AssertContains(Start, "LocalServerAuthEntryTokenAllowed(", "an entry without its key is never asked")
	AssertContains(Start, "_LLM_MBW_ListingEpoch == ExpectedEpoch", "one round per page session")
	AssertContains(Done, "ExpectedEpoch != _LLM_MBW_SessionEpoch", "a closed page's answer is dropped")
	AssertContains(Done, "_LLM_MBW_NextListing(ExpectedEpoch)", "the next entry is asked after an answer")
	AssertContains(Build, "_LLM_Menu_ApiEntryPageRows(Rows, Models, _LLM_MBW_Listings)", "the rows read the states")
}
Test("model-selector-api-listing: the page lists each entry once, bounded, one at a time",
	_LBMD_ApiListingPageWiring)

; model-selector-progress: a managed pull's percentage is read from its own
; output, as the macOS download window reads the same Ollama output.
_LBMD_PullPercentParse() {
	AssertEqual("", LLM_OllamaPullPercent(""), "no output, no percentage")
	AssertEqual("", LLM_OllamaPullPercent("pulling manifest"), "a frame without one")
	AssertEqual(45, LLM_OllamaPullPercent("pulling 6a0746a1ec1a:  45% ▕████    ▏ 2.1 GB/4.7 GB"))
	AssertEqual(46, LLM_OllamaPullPercent("`r 45% ▕██▏`r 46% ▕██▏ 2.2 GB/4.7 GB"), "the last frame wins")
	AssertEqual(7, LLM_OllamaPullPercent("pulling 7% 1.5 GB/s"), "a speed is no percentage")
	AssertEqual("", LLM_OllamaPullPercent("version 1.5% off"), "a decimal is no whole percentage")
}
Test("model-selector-progress: the pull percentage is the last whole one its output printed",
	_LBMD_PullPercentParse)

; The menu pull tells the page each new percentage, then its end; the page
; draws it on the row of that tag and keeps it in the next payload.
class _LBMD_PullProbe extends OllamaManagedBootstrap {
	__New() {
	}
}

_LBMD_PullPercentWiring() {
	global LLM_PULL_PERCENT_LISTENER
	Saved := LLM_PULL_PERCENT_LISTENER
	Told := []
	try {
		LLM_PULL_PERCENT_LISTENER := (Tag, Percent) => Told.Push(Tag . ":" . Percent)
		Frames := ["pulling manifest", "pulling 6a07:  12% ▕█  ▏", "pulling 6a07:  12% ▕█  ▏", "pulling 6a07:  40% ▕███▏"]
		Task := { outputTail: (Self, MaxBytes) => Frames.RemoveAt(1) }
		Probe := _LBMD_PullProbe()
		Operation := Map("tag", "qwen3:4b"), PullOwner := Map("task", Task)
		Probe.MenuPull := Operation, Probe.PullTask := PullOwner
		Last := ""
		loop 4 {
			AssertTrue(Probe._PollMenuPullPercent(Operation, PullOwner, Last), "the running pull keeps polling")
			Last := Told.Length > 0 ? Integer(StrSplit(Told[Told.Length], ":")[3]) : ""
		}
		AssertEqual("qwen3:4b:12,qwen3:4b:40", _LBMD_Join(Told), "each new whole percentage is told once")
		Probe.MenuPull := 0
		AssertFalse(Probe._PollMenuPullPercent(Operation, PullOwner, 40), "a settled pull stops polling")
		AssertEqual("qwen3:4b:", Told[Told.Length], "and tells its end")
	} finally LLM_PULL_PERCENT_LISTENER := Saved
	Page := _StripFullLineComments(_DriverFuncBody("LLM_ModelBrowser_PullPercent"))
	Ready := _StripFullLineComments(_DriverFuncBody("_LLM_MBW_OnPageReady"))
	Row := _StripFullLineComments(_DriverFuncBody("_LLM_MBW_LocalRow"))
	Tail := _StripFullLineComments(_DriverFuncBody("_SR_TreeHandleOutputTail"))
	AssertContains(Page, "injectProgress(", "the page draws the percentage")
	AssertContains(Ready, "LLM_PULL_PERCENT_LISTENER := LLM_ModelBrowser_PullPercent", "the open page observes pulls")
	AssertContains(Row, ",progress:", "a new payload keeps the percentage")
	AssertContains(Tail, 'FileOpen(State["TmpFile"], "r"', "the capture is read, never written")
}
Test("model-selector-progress: a menu pull's percentage reaches the page row of its tag",
	_LBMD_PullPercentWiring)

_LBMD_Join(Items) {
	Text := ""
	for Item in Items
		Text .= (Text == "" ? "" : ",") . Item
	return Text
}

; model-selector-single-json-encoder: a rename of the page's string helper
; turned it into a second JsonStringLiteral definition, which AutoHotkey
; refuses at load ("This function declaration conflicts with an existing
; Func"), so the driver and the page harness could not start. One definition,
; the shared encoder in infra/json.ahk.
_LBMD_OneJsonStringEncoder() {
	Source := _DriverSourceNoComments()
	Count := 0, Pos := 1
	while (Pos := RegExMatch(Source, "m)^JsonStringLiteral\(", &Match, Pos)) {
		Count += 1
		Pos += Match.Len
	}
	AssertEqual(1, Count, "the driver defines JsonStringLiteral exactly once (infra/json.ahk)")
	AssertContains(_DriverFuncBody("JsonStringLiteral"), "escapeHtml", "that one is the shared encoder")
}
Test("model-selector-single-json-encoder: the driver defines one JSON string encoder",
	_LBMD_OneJsonStringEncoder)
