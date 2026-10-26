// tools/test/test-app-cloner-log-isolation.cjs

/**
 * ============================================================================
 * MODULE: App Cloner Log Isolation - Behavioral and Source Guard
 * DESCRIPTION:
 * Proves that an unwritable diagnostic sink cannot prevent osascript launch,
 * and that every generated App Cloner surface uses a private, mode-077 log.
 * Exercises standalone locale resolution through the actual launcher boundary.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const APP_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'apps', 'App Cloner.app');
const LAUNCHER_PATH = path.join(APP_ROOT, 'Contents', 'MacOS', 'AppCloner');
const CLONE_PATH = path.join(APP_ROOT, 'Contents', 'Resources', 'clone_app.sh');
const BUILDER_PATH = path.join(APP_ROOT, 'Contents', 'Resources', 'ShortcutBuilder.applescript');
const PY_CANDIDATES = ['python3', 'python'];
const results = [];

function test(name, ok, detail = '') {
	results.push({ name, ok, detail });
}

function resolvePython() {
	for (const candidate of PY_CANDIDATES) {
		const probe = spawnSync(candidate, ['--version'], { encoding: 'utf8' });
		if (!probe.error && probe.status === 0) return candidate;
	}
	return null;
}

const python = resolvePython();
if (!python) {
	console.error(`No Python interpreter found (tried ${PY_CANDIDATES.join(', ')}).`);
	process.exit(1);
}

const harness = String.raw`
import builtins
import importlib.machinery
import importlib.util
import json
import os
import sys
import types

launcher_path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("appcloner_fixture", launcher_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
subject = importlib.util.module_from_spec(spec)
loader.exec_module(subject)

events = []
created_logs = []
real_open = builtins.open
real_os_open = subject.os.open
real_run = subject.subprocess.run
real_create_log_path = getattr(subject, "create_log_path", None)

def tracked_create_log_path():
    result = real_create_log_path()
    created_logs.append(result)
    return result

def rejecting_open(file, *args, **kwargs):
    spelling = os.fspath(file)
    if "appcloner" in spelling.lower() and spelling != os.devnull:
        raise PermissionError("injected unwritable App Cloner log")
    return real_open(file, *args, **kwargs)

def rejecting_os_open(file, *args, **kwargs):
    spelling = os.fspath(file)
    if "appcloner" in spelling.lower() and spelling != os.devnull:
        raise PermissionError("injected unwritable App Cloner log")
    return real_os_open(file, *args, **kwargs)

def fake_run(argv, *args, **kwargs):
    events.append(list(argv))
    return types.SimpleNamespace(returncode=0, stdout="", stderr="")

builtins.open = rejecting_open
subject.os.open = rejecting_os_open
subject.subprocess.run = fake_run
if real_create_log_path:
    subject.create_log_path = tracked_create_log_path
try:
    subject.main()
finally:
    builtins.open = real_open
    subject.os.open = real_os_open
    subject.subprocess.run = real_run
    if real_create_log_path:
        subject.create_log_path = real_create_log_path
    for run_dir, _log_path in created_logs:
        if run_dir:
            subject.shutil.rmtree(run_dir, ignore_errors=True)

print(json.dumps(events))
`;

const behavior = spawnSync(python, ['-c', harness, LAUNCHER_PATH], {
	cwd: ROOT,
	encoding: 'utf8',
	maxBuffer: 4 * 1024 * 1024
});
let events = [];
try {
	events = JSON.parse((behavior.stdout || '').trim());
} catch {
	// The assertions below report the full child result.
}
const behaviorDetail = JSON.stringify({
	status: behavior.status,
	error: behavior.error && behavior.error.message,
	stdout: behavior.stdout,
	stderr: behavior.stderr
});
test(
	'an unwritable diagnostic log cannot prevent osascript launch',
	behavior.status === 0 && events.some((argv) => argv[0] === 'osascript'),
	behaviorDetail
);

// Exercise the actual launcher through the osascript boundary. Menu launches
// inject the locale path, while Finder launches must resolve the shipped tree.
const localeHarness = String.raw`
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import types

launcher_path = Path(sys.argv[1])
locales = Path(sys.argv[2])
loader = importlib.machinery.SourceFileLoader("appcloner_locale_fixture", str(launcher_path))
spec = importlib.util.spec_from_loader(loader.name, loader)
subject = importlib.util.module_from_spec(spec)
loader.exec_module(subject)
original_env = dict(os.environ)
original_run = subject.subprocess.run
original_file = subject.__file__
events = []

def observe_run(argv, *args, **kwargs):
    if argv[0] == "osascript":
        events.append({"argv": argv, "env": dict(kwargs.get("env", {}))})
    return types.SimpleNamespace(returncode=0, stdout="", stderr="")

def launch(file_path, override=None, locale="en"):
    events.clear()
    subject.__file__ = str(file_path)
    os.environ.pop("ERGOPTI_LOCALES_DIR", None)
    os.environ.pop("ERGOPTI_LOCALE", None)
    os.environ["LANG"] = locale + "_XX.UTF-8"
    if override is not None:
        os.environ["ERGOPTI_LOCALES_DIR"] = override
    subject.main()
    if len(events) != 1:
        raise AssertionError("the launcher did not dispatch exactly one UI")
    env = events[0]["env"]
    resolved = env["ERGOPTI_LOCALES_DIR"]
    file = Path(resolved) / (locale + ".json") if resolved else None
    catalog = json.loads(file.read_text()) if file and file.is_file() else {}
    payload_path = Path(events[0]["argv"][1])
    payload = payload_path.read_text() if payload_path.is_file() else ""
    first_picker = payload.split("if step = 1 then", 1)[1].split("set rc to panel's runModal()", 1)[0] if "if step = 1 then" in payload else ""
    return {"locales_dir": resolved, "locale": env["ERGOPTI_LOCALE"],
            "choose": catalog.get("apps.cloner.btn_choose"),
            "cancel": catalog.get("button.cancel"), "first_picker": first_picker}

try:
    subject.subprocess.run = observe_run
    source = launch(launcher_path)
    french = launch(launcher_path, locale="fr")
    with tempfile.TemporaryDirectory(prefix="ergopti-cloner-locales-") as fixture:
        root = Path(fixture)
        installed = root / "ErgoptiPlus.app/Contents/Resources/static/ergopti_plus"
        staged_launcher = installed / "macos/apps/App Cloner.app/Contents/MacOS/AppCloner"
        staged_launcher.parent.mkdir(parents=True)
        shutil.copyfile(launcher_path, staged_launcher)
        staged_locales = installed / "_shared/data/locales"
        staged_locales.mkdir(parents=True)
        for name in ("en.json", "fr.json"):
            shutil.copyfile(locales / name, staged_locales / name)
        staged = launch(staged_launcher)
        override = launch(staged_launcher, str(locales))
        shutil.rmtree(staged_locales)
        missing = launch(staged_launcher)
        print(json.dumps({"source": source, "french": french, "staged": staged,
                          "expected_staged": str(staged_locales),
                          "override": override, "missing": missing}))
finally:
    subject.subprocess.run = original_run
    subject.__file__ = original_file
    os.environ.clear()
    os.environ.update(original_env)
`;
const localesDirectory = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales');
const localeRun = spawnSync(python, ['-c', localeHarness, LAUNCHER_PATH, localesDirectory], {
	cwd: ROOT,
	encoding: 'utf8',
	maxBuffer: 4 * 1024 * 1024
});
let localeEvents = {};
try {
	localeEvents = JSON.parse((localeRun.stdout || '').trim());
} catch {
	// Assertions retain the child diagnostics when observation fails.
}
const localeDetail = JSON.stringify({
	status: localeRun.status,
	stdout: localeRun.stdout,
	stderr: localeRun.stderr
});
const chooseLabel = JSON.parse(fs.readFileSync(path.join(localesDirectory, 'en.json'), 'utf8'))[
	'apps.cloner.btn_choose'
];
test(
	'Finder launch resolves the canonical locale catalog in a source checkout',
	localeRun.status === 0 &&
		localeEvents.source?.locales_dir === localesDirectory &&
		localeEvents.source?.locale === 'en' &&
		localeEvents.source?.choose === chooseLabel,
	localeDetail
);
test(
	'Finder launch resolves the same catalog in the installed bundle layout',
	localeRun.status === 0 &&
		localeEvents.staged?.locales_dir === localeEvents.expected_staged &&
		localeEvents.staged?.choose === chooseLabel,
	localeDetail
);
test(
	'the injected menu locale directory keeps precedence over bundle resolution',
	localeRun.status === 0 &&
		localeEvents.override?.locales_dir === localesDirectory &&
		localeEvents.override?.choose === chooseLabel,
	localeDetail
);
test(
	'an absent standalone catalog is reported as unavailable',
	localeRun.status === 0 && localeEvents.missing?.locales_dir === '',
	localeDetail
);

// The actual main chooses the physical catalogue and hands this exact payload
// to osascript. Native XCTest independently executes its AppKit construction.
for (const [locale, choose, cancel] of [
	['en', 'Choose', 'Cancel'],
	['fr', 'Choisir', 'Annuler']
]) {
	const observation = locale === 'en' ? localeEvents.source : localeEvents.french;
	test(
		`the actual ${locale} launch selects its shipped picker catalogue`,
		localeRun.status === 0 &&
			observation?.locale === locale &&
			observation.choose === choose &&
			observation.cancel === cancel,
		localeDetail
	);
	if (locale !== 'en') continue;
	test(
		`the ${locale} launch payload binds the first picker to the selected catalogue`,
		localeRun.status === 0 &&
			observation?.first_picker?.includes("panel's setPrompt:(btn_choose of u)") &&
			observation.first_picker.includes(
				'panel\'s setValue:(btn_cancel of u) forKey:"cancelButtonTitle"'
			) &&
			observation.first_picker.includes("panel's setMessage:(msg_choose_source of u)"),
		localeDetail
	);
}

const launcher = fs.readFileSync(LAUNCHER_PATH, 'utf8');
const clone = fs.readFileSync(CLONE_PATH, 'utf8');
const builder = fs.readFileSync(BUILDER_PATH, 'utf8');
const combined = `${launcher}\n${clone}\n${builder}`;

// Resolve actual local calls across the entire delivered script, including the
// post-clone branches that the first-picker native observation never reaches.
function unresolvedBuilderCalls(source) {
	const executable = source.replace(/^\s*--.*$/gm, '');
	const definitions = new Set(
		[...executable.matchAll(/^on\s+([A-Za-z_]\w*)\s*\(/gm)].map((match) => match[1])
	);
	const calls = [...executable.matchAll(/\bmy\s+([A-Za-z_]\w*)\s*\(/g)].map((match) => match[1]);
	return [...new Set(calls.filter((name) => !definitions.has(name)))];
}

test(
	'every actual App Cloner handler call remains defined after the catalogue refactor',
	unresolvedBuilderCalls(builder).length === 0 &&
		!/\bjson_get\s*\(/.test(builder) &&
		!/\bhardcoded_fr_strings\s*\(/.test(builder),
	JSON.stringify(unresolvedBuilderCalls(builder))
);

// Each previously bypassed wizard surface must both load its canonical key and
// consume that exact field in executable code. An unused translated declaration
// cannot conceal a reintroduced literal at its caller.
const wizardFields = [
	'msg_choose_source',
	'msg_clone_name',
	'msg_pwa_recommended',
	'msg_pwa_optional',
	'msg_pwa_url',
	'title_invalid_url',
	'msg_native_open_optional',
	'msg_url_path',
	'prompt_choose_folder',
	'title_empty_input',
	'msg_empty_input',
	'title_invalid_input',
	'msg_icon_style',
	'prompt_choose_icon',
	'mode_native',
	'mode_pwa',
	'summary_source',
	'summary_name',
	'summary_mode',
	'summary_icon',
	'summary_url',
	'err_open_empty',
	'err_path_missing',
	'err_url_format',
	'err_teams_url',
	'err_pwa_required',
	'err_pwa_scheme',
	'menu_edit',
	'menu_cut',
	'menu_copy',
	'menu_paste',
	'menu_select_all',
	'menu_undo',
	'menu_redo',
	'default_clone_name',
	'diagnostic_log_path'
];

const executableBuilder = builder.replace(/^\s*--.*$/gm, '');
function connectedWizardField(source, field) {
	const binding = `${field}: my ui_string(catalogue, "apps.cloner.${field}")`;
	// A record label and its canonical key contribute two references. Every
	// field has one real caller, except Edit's two menu objects and the two
	// default-name entry paths. Count all of them to catch a missed sibling.
	const expected = ['menu_edit', 'default_clone_name'].includes(field) ? 4 : 3;
	const references = [...source.matchAll(new RegExp(`\\b${field}\\b`, 'g'))];
	return source.includes(binding) && references.length === expected;
}
for (const field of wizardFields) {
	const binding = `${field}: my ui_string(catalogue, "apps.cloner.${field}")`;
	const references = [...executableBuilder.matchAll(new RegExp(`\\b${field}\\b`, 'g'))];
	test(
		`the wizard loads and consumes its canonical ${field} message`,
		connectedWizardField(executableBuilder, field) &&
			!connectedWizardField(
				executableBuilder.replace(`${field} of u`, '"injected literal"'),
				field
			),
		`canonical binding=${executableBuilder.includes(binding)} references=${references.length}`
	);
}

const missingStringHandler = builder
	.replace(/^on ui_string\(/m, 'on removed_ui_string(')
	.replace(/^end ui_string$/m, 'end removed_ui_string');
test(
	'the handler ownership oracle rejects an undefined catalogue reader mutant',
	unresolvedBuilderCalls(missingStringHandler).includes('ui_string')
);

test(
	'the fixed cross-user /tmp App Cloner log is absent from every surface',
	!combined.includes('/tmp/appcloner.log')
);
test(
	'the failure dialog opens only the exact private log exported by the launcher',
	!combined.includes('/tmp/clone_diag.log') &&
		builder.includes('my format_ui(diagnostic_log_path of u, appLogPath)') &&
		builder.includes('quoted form of appLogPath') &&
		builder.includes('if appLogPath is not "" then') &&
		launcher.includes('env["ERGOPTI_APPCLONER_LOG"] = log_path or ""')
);
test(
	'the bundle launcher creates a private per-run log with mode-077 defaults',
	launcher.includes('os.umask(0o077)') &&
		launcher.includes('tempfile.mkdtemp(prefix="ergopti-appcloner-")') &&
		launcher.includes('env["ERGOPTI_APPCLONER_LOG"] = log_path or ""')
);
test(
	'clone generation accepts only its owned regular log or falls back safely',
	clone.includes('DIAG="${8:-/dev/null}"') &&
		clone.includes('! -L "$DIAG"') &&
		clone.includes('DIAG=/dev/null')
);
test(
	'each generated PWA launch owns a private mode-077 diagnostic path',
	clone.includes('PWA_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-pwa.XXXXXXXX")"') &&
		(clone.match(/umask 077/g) || []).length >= 2 &&
		clone.includes('ERGOPTI_PWA_LOG="$PWA_LOG_DIR/pwa.log"')
);
test(
	'generated PWA diagnostics never persist the authenticated URL',
	!clone
		.split('\n')
		.some(
			(line) =>
				line.includes('_log(') && (line.includes('{OPEN_ARG') || line.includes('+ OPEN_ARG'))
		)
);

const literalMutant = `${launcher}\n${clone}\n${builder}\n_LOG_PATH = "/tmp/appcloner.log"`;
test(
	'the source contract rejects reintroducing the fixed shared log literal',
	literalMutant.includes('/tmp/appcloner.log') && !combined.includes('/tmp/appcloner.log')
);

console.log('TAP version 14');
console.log(`1..${results.length}`);
results.forEach((result, index) => {
	console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
	if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
});
console.log(`# passed: ${results.filter((result) => result.ok).length}/${results.length}`);
if (results.some((result) => !result.ok)) process.exitCode = 1;
