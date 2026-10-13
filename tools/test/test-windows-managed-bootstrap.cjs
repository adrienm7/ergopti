// tools/test/test-windows-managed-bootstrap.cjs

// ==============================================================================
// MODULE: Windows Managed Bootstrap Production Composition
// DESCRIPTION:
// Guards source wiring only; these controls confer no Windows native credit.
// ==============================================================================
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../static/ergopti_plus/windows');
const checker = fs.readFileSync(path.join(root, 'modules/llm/ollama_deps_checker.ahk'), 'utf8');
assert.match(
	checker,
	/Installer := HasMethod\(InstallerFn, "Call"\) \? InstallerFn : LLM_Deps_RunManagedInstaller/,
	'Explicit production bootstrap must dispatch managed acquisition instead of winget/browser.'
);
const flow = fs.readFileSync(path.join(root, 'modules/llm/ollama_managed_bootstrap.ahk'), 'utf8');
for (const dependency of [
	'OllamaInstallFilesPort',
	'OllamaRuntimeOwner',
	'OllamaRuntime_HostArchitecture',
	'AppDirsWindowsManagedOllamaFolderName'
]) {
	assert.ok(flow.includes(dependency), `Production composition must consume ${dependency}.`);
}
for (const consent of ['"install"', '"start"', '"model"']) {
	assert.ok(
		flow.includes(`this._Consent(${consent}`),
		`Independent consent required for ${consent}.`
	);
}
assert.doesNotMatch(
	flow,
	/winget|https:\/\/ollama.com\/download|NATIVE_PRODUCTION_QUALIFIED\s*[:=]\s*(?:true|True)/
);
assert.match(flow, /"cleanup_partial"/);
assert.match(flow, /"retire_runtime"/);
assert.match(flow, /LLM_OllamaListModels_Async/);
assert.match(flow, /this\.Runtime\.ObserveReady\(\)/);
assert.match(flow, /CryptoSha256Bytes\(FileRead\(Path, "RAW"\)\)/);
const admission = fs.readFileSync(path.join(root, 'ui/menu/menu_llm/enable_admission.ahk'), 'utf8');
// The production resolver preserves the injected writer's refusal contract.
// The config renderer already returns the complete canonical UTF-8/BOM image;
// copy exactly that image, excluding only StrPut's terminating NUL.
function assertEnableWriterSource(source) {
	assert.match(source, /TOML_BuildConfigUpdatedContent\(Path, Updates\)/);
	assert.match(
		source,
		/Writer := _LLM_Menu_EnablePort\(Request\["port"\], "writer", TOML_ConfigBatchWrite\)/
	);
	assert.match(source, /Written := Writer\.Call\(Path, Updates\)/);
	assert.match(source, /Content := Built\["content"\]\s+Size := StrPut\(Content, "UTF-8"\) - 1/);
	assert.match(source, /Bytes := Buffer\(Size, 0\)/);
	assert.match(
		source,
		/Encoded := Buffer\(Size \+ 1, 0\)\s+StrPut\(Content, Encoded, "UTF-8"\)\s+DllCall\("RtlMoveMemory", "Ptr", Bytes\.Ptr, "Ptr", Encoded\.Ptr, "UPtr", Size\)/
	);
	assert.match(
		source,
		/PrepareEnableHandoff\(Request\["source"\], Map\("path", Path, "bytes", Bytes\)\)/
	);
	assert.doesNotMatch(source, /StrPut\(Chr\(0xFEFF\) \. (?:Built\["content"\]|Content)/);
	assert.doesNotMatch(source, /NumPut\("UChar", 0xEF|Bytes\.Ptr \+ 3|Buffer\(Size \+ 3/);
}
assertEnableWriterSource(admission);
const originalEncoding = 'StrPut(Content, Encoded, "UTF-8")';
const doubledEncoding = 'StrPut(Chr(0xFEFF) . Content, Encoded, "UTF-8")';
const doubledBom = admission.replace(originalEncoding, doubledEncoding);
assert.notEqual(doubledBom, admission, 'The counterfactual must change the actual encoding call.');
assert.throws(
	() => assertEnableWriterSource(doubledBom),
	{ code: 'ERR_ASSERTION' },
	'A prepended second BOM cannot satisfy the complete source/image contract.'
);
assertEnableWriterSource(doubledBom.replace(doubledEncoding, originalEncoding));
assert.match(admission, /PrepareEnableHandoff/);
assert.match(admission, /FinishEnableHandoff/);
for (const file of [
	'modules/llm/api_ollama/ollama_http.ahk',
	'modules/llm/api_ollama/ollama_streaming.ahk',
	'modules/llm/api_ollama/ollama_warmup.ahk',
	'ui/menu/menu_llm/enable_admission.ahk',
	'ui/menu/menu_llm/aux_ownership.ahk'
]) {
	const source = fs.readFileSync(path.join(root, file), 'utf8');
	assert.match(
		source,
		/LLM_OllamaRequestOrigin\(\)/,
		`${file} consumes the admitted native origin.`
	);
	assert.doesNotMatch(source, /LLM_OLLAMA_BASE_URL\s*\.\s*"\/api\//);
}
const launcher = fs.readFileSync(path.join(root, 'modules/llm/ollama-runtime-launch.ps1'), 'utf8');
const worker = fs.readFileSync(path.join(root, 'modules/llm/ollama-model-pull.ps1'), 'utf8');
assert.match(
	launcher,
	/child_created_filetime\s*=\s*\[Ergopti\.Ollama\.RuntimeObservation\]::CreationTime\(\$child\.Handle\)/
);
assert.match(
	worker,
	/Assert-OllamaModelProcess \$server \$receipt\.child_created_filetime \$request\.port/
);
assert.match(worker, /CreationTime\(\$Process\.Handle\)/);
// READY menu requests own their native dispatch failure; completed bootstrap
// callbacks remain available to the initial-bootstrap path. Capture before a
// reentrant native boundary can retire the request. These are source controls.
function assertNativePullFailureScope(source) {
	const native = source.slice(source.indexOf('\n\t_NativePull('), source.indexOf('\n\t_Pulled('));
	assert.ok(
		native.startsWith('\n\t_NativePull('),
		'Inspect the actual production native pull method.'
	);
	assert.match(
		native,
		/MenuOperation := HasMethod\(OnDone, "Call"\) && this\.MenuPull is Map \? this\.MenuPull : 0/
	);
	assert.ok(native.indexOf('MenuOperation :=') < native.indexOf('Owner := Map('));
	assert.match(
		native,
		/Factory := HasMethod\(SpawnFn, "Call"\) \? SpawnFn : ShellRunner_SpawnTreeOwned/
	);
	assert.match(native, /Task := Factory\.Call\(A_WinDir/);
	assert.match(native, /Owner\["task"\] := Task/);
	assert.match(native, /if Accepted\s+return true/);
	assert.match(
		native,
		/if MenuOperation is Map \{\s+try return this\._MenuPullFail\(MenuOperation\)\s+finally this\.Cancel\(\)\s+\}\s+return this\._Fail\("model_dispatch"\)/
	);
}
assertNativePullFailureScope(flow);
const scopedFailure =
	'if MenuOperation is Map {\n\t\t\ttry return this._MenuPullFail(MenuOperation)\n\t\t\tfinally this.Cancel()\n\t\t}\n\t\treturn this._Fail("model_dispatch")';
const bootstrapFailure = 'return this._Fail("model_dispatch")';
const withdrawnFailureScope = flow.replace(scopedFailure, bootstrapFailure);
assert.notEqual(withdrawnFailureScope, flow, 'Withdraw the actual production failure scope.');
assert.throws(() => assertNativePullFailureScope(withdrawnFailureScope), {
	code: 'ERR_ASSERTION'
});
assertNativePullFailureScope(withdrawnFailureScope.replace(bootstrapFailure, scopedFailure));
const nativeCleanup = 'finally this.Cancel()';
const withdrawnCleanup = flow.replace(
	scopedFailure,
	scopedFailure.replace(nativeCleanup, 'finally Sleep(0)')
);
assert.notEqual(withdrawnCleanup, flow, 'Withdraw the actual native-construction cleanup retry.');
assert.throws(() => assertNativePullFailureScope(withdrawnCleanup), { code: 'ERR_ASSERTION' });
assertNativePullFailureScope(withdrawnCleanup.replace('finally Sleep(0)', nativeCleanup));
const nativeCases = fs.readFileSync(
	path.join(root, 'tests/unit/test_ollama_managed_bootstrap.ahk'),
	'utf8'
);
for (const name of [
	'READY native factory throw preserves bootstrap observer',
	'READY native start false preserves bootstrap observer',
	'READY native start throw preserves bootstrap observer',
	'READY native start false retains string retirement debt',
	'READY native start throw retains refused retirement debt',
	'initial native factory throw still notifies failure',
	'initial native start false still notifies failure',
	'initial native start throw still notifies failure',
	'READY reentrant cancellation retains native failure custody'
]) {
	assert.ok(
		nativeCases.includes(`Test("managed bootstrap: ${name} (groups247-native-dispatch)"`),
		name
	);
}
process.stdout.write(
	'Windows managed bootstrap production composition: PASS (portable source checks only).\n'
);

// Missing-model consent must remain bound to the exact admitted origin and
// installer owner. These causal controls are source evidence, not AHK execution.
const modelOffer = fs.readFileSync(path.join(root, 'modules/llm/local_model_offer.ahk'), 'utf8');
function assertModelOfferAffinity(source, managedSource) {
	assert.doesNotMatch(source, /Failure\["base_url"\] != LLM_OLLAMA_BASE_URL/);
	assert.match(source, /return Value is Integer && Value == true/);
	assert.match(
		source,
		/Receipt := Map\("origin", Failure\["base_url"\], "model", Failure\["model"\]/
	);
	assert.match(source, /"generation", LLM_AuxGeneration\(\), "flow", _LLM_ManagedBootstrap/);
	assert.match(source, /Receipt\["flow"\] == _LLM_ManagedBootstrap/);
	assert.match(source, /Receipt\["port"\] == _LLM_LocalModelOfferPort/);
	assert.match(source, /Receipt\["notified"\] == _LLM_LocalModelNotified/);
	assert.match(source, /if !LLM_OllamaOriginMatches\(Receipt\["origin"\]\)/);
	for (const fn of ['confirm', 'notify', 'install']) {
		assert.ok(source.includes(`!= Receipt["${fn}"]`), `Fence captured ${fn} registration.`);
	}
	assert.match(source, /Receipt := _LLM_LocalModelOfferCapture\(Failure, CurrentFn\)/);
	assert.match(
		source,
		/NoticeKey := Receipt\["origin"\] \. "`n" \. LLM_LocalModelNormalize\(Model\)/
	);
	assert.match(
		source,
		/if _LLM_LocalModelTrue\(Accepted\) && _LLM_LocalModelOfferCurrent\(Receipt\)\s+Receipt\["notified"\]\[NoticeKey\] := true/
	);
	assert.match(source, /if !Accepted \|\| !_LLM_LocalModelOfferCurrent\(Receipt\)\s+return true/);
	assert.match(
		source,
		/return Flow\.PullModel\(Receipt\["model"\], _LLM_LocalModelOfferPublished\.Bind\(Receipt\),\s+_LLM_LocalModelOfferCurrent\.Bind\(Receipt\)\)/
	);
	assert.match(
		source,
		/SetTimer\(_LLM_LocalModelOfferPublished\.Bind\(Receipt, Callback\), Delay\)/
	);
	assert.match(
		source,
		/_LLM_LocalModelOfferPublished\(Receipt, Callback := 0, \*\) \{\s+if !_LLM_LocalModelOfferCurrent\(Receipt\)\s+return false/
	);
	assert.match(managedSource, /PullModel\(Model, OnDone := 0, CurrentFn := 0\)/);
	assert.match(managedSource, /"source_current", CurrentFn/);
	assert.match(managedSource, /SourceCurrent := Operation\.Get\("source_current", 0\)/);
	assert.match(
		managedSource,
		/if HasMethod\(SourceCurrent, "Call"\) && !this\._True\(SourceCurrent\.Call\(\)\) \{\s+this\._MenuPullRetire\(Operation\)\s+return false/
	);
	assert.match(
		managedSource,
		/; A source callback may pump a modal or replace the exact operation\.\s+if this\.MenuPull != Operation \|\| Operation\["failed"\]/
	);
	const pull = managedSource.slice(
		managedSource.indexOf('\tPullModel('),
		managedSource.indexOf('\t_MenuPullRetire(')
	);
	assert.match(pull, /this\.MenuPull := Operation\s+if !this\._MenuPullCurrent\(Operation\)/);
	assert.match(
		pull,
		/if !this\._Consent\("model", Tag\)[\s\S]+if !this\._MenuPullCurrent\(Operation\)[\s\S]+Done := ObjBindMethod/
	);
	const completed = managedSource.slice(managedSource.indexOf('\t_MenuPullModels('));
	assert.match(
		completed,
		/if !this\._MenuPullCurrent\(Operation\)[\s\S]+OnDone := Operation\["callback"\]/
	);
}
assertModelOfferAffinity(modelOffer, flow);
const offerControls = [
	['typed ACK', 'return Value is Integer && Value == true', 'return Value == true'],
	[
		'actual origin',
		'LLM_OllamaOriginMatches(Receipt["origin"])',
		'Receipt["origin"] == LLM_OLLAMA_BASE_URL'
	],
	['exact flow', 'Receipt["flow"] == _LLM_ManagedBootstrap', 'true'],
	['exact installer registration', '!= Receipt["install"]', '!= Receipt["confirm"]'],
	[
		'post-notice scope',
		'_LLM_LocalModelTrue(Accepted) && _LLM_LocalModelOfferCurrent(Receipt)',
		'_LLM_LocalModelTrue(Accepted)'
	],
	['post-modal scope', 'if !Accepted || !_LLM_LocalModelOfferCurrent(Receipt)', 'if !Accepted'],
	[
		'captured managed dispatch',
		'return Flow.PullModel(Receipt["model"]',
		'return _LLM_ManagedBootstrap.PullModel(Receipt["model"]'
	],
	[
		'delayed origin scope',
		'SetTimer(_LLM_LocalModelOfferPublished.Bind(Receipt, Callback), Delay)',
		'SetTimer(Callback, Delay)'
	]
];
for (const [name, before, after] of offerControls) {
	const mutant = modelOffer.replace(before, after);
	assert.notEqual(mutant, modelOffer, `Withdraw actual ${name} production guard.`);
	assert.throws(() => assertModelOfferAffinity(mutant, flow), { code: 'ERR_ASSERTION' }, name);
	assertModelOfferAffinity(modelOffer, flow);
}
const flowControls = [
	['second consent', '"source_current", CurrentFn', '"source_current", 0'],
	['typed scoped ACK', '!this._True(SourceCurrent.Call())', '!SourceCurrent.Call()'],
	[
		'operation after callback',
		'; A source callback may pump a modal or replace the exact operation.\n\t\tif this.MenuPull != Operation || Operation["failed"]',
		'; A source callback may pump a modal or replace the exact operation.\n\t\tif false'
	]
];
for (const [name, before, after] of flowControls) {
	const mutant = flow.replace(before, after);
	assert.notEqual(mutant, flow, `Withdraw actual ${name} production guard.`);
	assert.throws(
		() => assertModelOfferAffinity(modelOffer, mutant),
		{ code: 'ERR_ASSERTION' },
		name
	);
	assertModelOfferAffinity(modelOffer, flow);
}
assert.equal((nativeCases.match(/Test\("managed model offer:/g) || []).length, 35);
for (const name of [
	'_G4B_OfferModal',
	'_G4B_OfferSecondConsent',
	'_G4B_OfferNotification',
	'_G4B_OfferCompletion',
	'_G4B_OfferExternal'
]) {
	assert.ok(nativeCases.includes(name), `Retain authored production callback ${name}.`);
}
process.stdout.write(
	'Windows model-offer affinity: PASS (11 causal source inverses; 35 authored AHK cases UNRUN).\n'
);
