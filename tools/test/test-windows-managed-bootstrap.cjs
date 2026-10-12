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
process.stdout.write(
	'Windows managed bootstrap production composition: PASS (portable source checks only).\n'
);
