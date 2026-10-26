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

# This positive log-refusal control requires a real, supported catalogue.
os.environ["ERGOPTI_LOCALE"] = "en"
os.environ.pop("ERGOPTI_LOCALES_DIR", None)
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

// Fault ports retain real files and descriptor ownership. Native XCTest runs
// the same probe against actual regular-file resource refusals on Darwin.
const logIORun = spawnSync(
	python,
	[path.join(__dirname, 'lib', 'app-cloner-log-io-probe.py'), 'portable', LAUNCHER_PATH],
	{
		cwd: ROOT,
		encoding: 'utf8',
		maxBuffer: 4 * 1024 * 1024
	}
);
let logIO = {};
try {
	logIO = JSON.parse((logIORun.stdout || '').trim());
} catch {
	/* Producer failure cannot supply a valid case. */
}
const logIODetail = JSON.stringify({
	status: logIORun.status,
	error: logIORun.error?.message,
	stderr: logIORun.stderr
});
const logCases = new Map((logIO.cases || []).map((entry) => [entry.name, entry]));
for (const [name, entry] of logCases) {
	const normal = entry.events.filter(
		(event) => event.argv[0] === 'osascript' && event.argv[1] !== '-e'
	);
	const dialogs = entry.events.filter(
		(event) => event.argv[0] === 'osascript' && event.argv[1] === '-e'
	);
	const detail = logIODetail + JSON.stringify(entry);
	test(
		`the ${name} log probe retires its exact owned descriptors`,
		logIORun.status === 0 &&
			entry.all_streams_closed === true &&
			entry.descriptor_errors.length === 0 &&
			(entry.open_attempts > 0 || name === 'allocation'),
		detail
	);
	if (name === 'icon-operation') {
		test(
			'diagnostic isolation does not swallow an unrelated icon operation failure',
			entry.error?.type === 'FileNotFoundError' &&
				entry.error.message.includes('injected icon operation refusal') &&
				normal.length === 0,
			detail
		);
		continue;
	}
	if (name === 'invalid-catalogue-write-refusal') {
		test(
			'a failed diagnostic transaction preserves the visible fatal catalogue refusal',
			normal.length === 0 &&
				dialogs.length === 1 &&
				entry.error?.type === 'ValueError' &&
				dialogs[0].argv[5] === 'App Cloner — Locale error' &&
				dialogs[0].argv[4] ===
					'App Cloner cannot start because the selected locale catalogue is unavailable or invalid.\n\nApp Cloner startup locale catalogue is unavailable or invalid.' &&
				entry.warnings.includes('diagnostic log persistence failed'),
			detail
		);
		continue;
	}
	test(
		`the ${name} diagnostic result preserves actual normal UI admission`,
		entry.error === null && normal.length === 1,
		detail
	);
	if (name.startsWith('healthy')) {
		// Windows chmod cannot express POSIX mode bits. Its control still checks
		// real persistence and descriptor ownership; POSIX hosts pin both modes.
		test(
			`the ${name} control exports a persisted private log`,
			normal[0]?.log_path.endsWith('appcloner.log') &&
				normal[0].log_content.includes('[AppCloner] locale=en') &&
				(process.platform === 'win32' ||
					(normal[0].log_mode === 0o600 && normal[0].directory_mode === 0o700)) &&
				entry.warnings === '',
			detail
		);
	} else {
		test(
			`the ${name} refusal is explicit and disables the unusable log`,
			entry.warnings.includes(
				name === 'allocation'
					? 'diagnostic log allocation failed'
					: 'diagnostic log persistence failed'
			) &&
				(name.startsWith('post-ui-')
					? normal[0]?.log_path.endsWith('appcloner.log')
					: normal[0]?.log_path === ''),
			detail
		);
	}
	if (name === 'healthy-ui-error' || name.startsWith('post-ui-')) {
		const body = dialogs[0]?.argv[4];
		test(
			`the ${name} result preserves the original startup error notification`,
			dialogs.length === 1 &&
				(name === 'healthy-ui-error'
					? body ===
							`Original native startup failure.\n\nThe complete diagnostic is in ${normal[0].log_path}` &&
						entry.remaining_logs.some(
							(log) =>
								log.content.includes('[AppCloner] exit=1') &&
								log.content.includes('Original native startup failure.')
						)
					: body === 'Original native startup failure.'),
			detail
		);
	}
}
const expectedLogCases = [
	'healthy',
	'healthy-ui-error',
	'allocation',
	'icon-operation',
	'invalid-catalogue-write-refusal'
];
for (const stage of ['open', 'fdopen', 'write', 'flush', 'close'])
	expectedLogCases.push(`initial-${stage}`, `post-ui-${stage}`);
test(
	'the diagnostic I/O producer executes every admitted scenario',
	logIORun.status === 0 &&
		logCases.size === expectedLogCases.length &&
		logIO.permission_scope ===
			(process.platform === 'win32' ? 'content_and_descriptors_only' : 'posix_mode_bits') &&
		expectedLogCases.every((name) => logCases.has(name)),
	logIODetail
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
    failure = None
    try:
        subject.main()
    except ValueError as error:
        failure = str(error)
    if len(events) != 1:
        raise AssertionError("the launcher did not dispatch exactly one UI")
    fatal = events[0]["argv"][1] == "-e"
    env = events[0]["env"]
    resolved = env["ERGOPTI_LOCALES_DIR"]
    file = Path(resolved) / (locale + ".json") if resolved else None
    catalog = json.loads(file.read_text()) if file and file.is_file() else {}
    payload_path = Path(events[0]["argv"][1])
    payload = payload_path.read_text() if payload_path.is_file() else ""
    first_picker = payload.split("if step = 1 then", 1)[1].split("set rc to panel's runModal()", 1)[0] if "if step = 1 then" in payload else ""
    return {"locales_dir": resolved, "locale": env["ERGOPTI_LOCALE"],
            "choose": catalog.get("apps.cloner.btn_choose"),
            "cancel": catalog.get("button.cancel"), "first_picker": first_picker,
            "failure": failure, "fatal": fatal}

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
        cwd_catalogue = json.loads((locales / "en.json").read_text(encoding="utf-8"))
        cwd_catalogue["apps.cloner.btn_choose"] = "Wrong working-directory catalogue"
        (root / "en.json").write_text(json.dumps(cwd_catalogue), encoding="utf-8")
        original_cwd = os.getcwd()
        try:
            os.chdir(root)
            missing = launch(staged_launcher)
            source_with_cwd = launch(launcher_path)
        finally:
            os.chdir(original_cwd)
        print(json.dumps({"source": source, "source_with_cwd": source_with_cwd, "french": french, "staged": staged,
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
		localeEvents.source?.choose === chooseLabel &&
		localeEvents.source_with_cwd?.choose === chooseLabel &&
		localeEvents.source_with_cwd.fatal === false &&
		localeEvents.source_with_cwd.failure === null,
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
	'an absent standalone catalog is refused visibly without reading a working-directory catalog',
	localeRun.status === 0 &&
		localeEvents.missing?.locales_dir === '' &&
		localeEvents.missing.fatal === true &&
		localeEvents.missing.failure ===
			'App Cloner startup locale catalogue is unavailable or invalid.',
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

// Execute the real error branch with physical locale files. Only the child
// terminal boundary is controlled; the launcher owns decoding and dispatch.
const startupHarness = String.raw`
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types

launcher = Path(sys.argv[1])
locales = Path(sys.argv[2])
loader = importlib.machinery.SourceFileLoader("appcloner_startup_fixture", str(launcher))
spec = importlib.util.spec_from_loader(loader.name, loader)
subject = importlib.util.module_from_spec(spec)
loader.exec_module(subject)
original_env = dict(os.environ)
original_run = subprocess.run
original_temp = tempfile.tempdir
original_umask = os.umask(0o077)
cases = []

with tempfile.TemporaryDirectory(prefix="ergopti-cloner-startup-{1}-") as fixture:
    root = Path(fixture)
    tempfile.tempdir = str(root)
    def run_case(name, locale, status, stderr, stdout="", override=None, expected_failure=None, remove_catalogue=False):
        events = []
        def capture(argv, **kwargs):
            events.append({"argv": list(argv), "environment": kwargs.get("env", {})})
            if argv[0] == "osascript" and argv[1] != "-e":
                if remove_catalogue:
                    (override / (locale + ".json")).unlink()
                return types.SimpleNamespace(returncode=status, stderr=stderr, stdout=stdout)
            return types.SimpleNamespace(returncode=0, stderr="", stdout="")
        os.environ["ERGOPTI_LOCALE"] = locale
        os.environ["ERGOPTI_LOCALES_DIR"] = str(override or locales)
        subprocess.run = capture
        failure = None
        try:
            subject.main()
        except Exception as error:
            failure = {"type": type(error).__name__, "message": str(error)}
        dialogs = [event["argv"] for event in events if event["argv"][0] == "osascript" and event["argv"][1] == "-e"]
        ui = [event for event in events if event["argv"][0] == "osascript" and event["argv"][1] != "-e"]
        cases.append({"name": name, "dialogs": dialogs, "failure": failure,
                      "normal_ui_count": len(ui), "expected_failure": expected_failure,
                      "log_path": next((event["environment"].get("ERGOPTI_APPCLONER_LOG", "") for event in events if event["argv"][0] == "osascript"), "")})
    try:
        hostile = "A \"quote\" C:\\path {1}\n\n--not-an-option 🌍"
        run_case("english", "en", 1, "Native panel operation failed.")
        run_case("french", "fr", 1, "Native panel operation failed.")
        run_case("unknown", "en", 1, "")
        run_case("whitespace", "en", 1, " \n\t", "stdout diagnostic")
        run_case("hostile", "en", 1, hostile)
        run_case("success", "en", 0, "")
        run_case("legacy-negative-status", "en", -128, "Injected negative status.")
        baseline = json.loads((locales / "en.json").read_text(encoding="utf-8"))
        changing = root / "changing-catalogue"
        changing.mkdir()
        (changing / "en.json").write_text(json.dumps(baseline), encoding="utf-8")
        run_case("catalogue-changed-after-ui", "en", 1, "Native panel operation failed.", override=changing, remove_catalogue=True)
        invalid = [("missing-file", None), ("malformed", "{"), ("not-object", "[]")]
        for key in ["apps.cloner.startup_error_title", "apps.cloner.error_unknown", "common.ok", "apps.cloner.diagnostic_log_path"]:
            for kind, value in [("missing", None), ("null", None), ("empty", ""), ("whitespace", " \t\n"), ("number", 7), ("boolean", True), ("array", []), ("object", {})]:
                document = dict(baseline)
                if kind == "missing": document.pop(key, None)
                else: document[key] = value
                invalid.append((kind + ":" + key, json.dumps(document)))
        document = dict(baseline)
        document["apps.cloner.diagnostic_log_path"] = "No placeholder"
        invalid.append(("missing-diagnostic-placeholder", json.dumps(document)))
        document["apps.cloner.diagnostic_log_path"] = "{1} twice {1}"
        invalid.append(("duplicate-diagnostic-placeholder", json.dumps(document)))
        direct_loader_cases = []
        for index, (name, document) in enumerate(invalid):
            directory = root / ("invalid-" + str(index))
            directory.mkdir()
            if document is not None: (directory / "en.json").write_text(document, encoding="utf-8")
            if name in ("missing-file", "malformed"):
                expected = "App Cloner startup locale catalogue is unavailable or invalid."
            elif name == "not-object":
                expected = "App Cloner startup locale catalogue must be a JSON object."
            elif "diagnostic-placeholder" in name:
                expected = "App Cloner diagnostic locale template requires exactly one {1} placeholder."
            else:
                expected = "App Cloner startup locale key must be a nonempty string: " + name.split(":", 1)[1]
            run_case(name, "en", 1, "Native panel operation failed.", override=directory, expected_failure=expected)
            failure = None
            try:
                subject.load_error_ui("en", str(directory))
            except Exception as error:
                failure = {"type": type(error).__name__, "message": str(error)}
            direct_loader_cases.append({"name": name, "failure": failure, "expected": expected})
        (root / "en.json").write_text(json.dumps(baseline), encoding="utf-8")
        original_cwd = os.getcwd()
        failure = None
        try:
            os.chdir(root)
            subject.load_error_ui("en", "")
        except Exception as error:
            failure = {"type": type(error).__name__, "message": str(error)}
        finally:
            os.chdir(original_cwd)
        direct_loader_cases.append({"name": "unresolved-directory-with-cwd-catalogue", "failure": failure,
                                    "expected": "App Cloner startup locale catalogue is unavailable or invalid."})
        print(json.dumps({"cases": cases, "hostile": hostile, "direct_loader_cases": direct_loader_cases}))
    finally:
        subprocess.run = original_run
        tempfile.tempdir = original_temp
        os.environ.clear()
        os.environ.update(original_env)
        os.umask(original_umask)
`;
const startupRun = spawnSync(python, ['-c', startupHarness, LAUNCHER_PATH, localesDirectory], {
	cwd: ROOT,
	encoding: 'utf8',
	maxBuffer: 4 * 1024 * 1024
});
let startup = {};
try {
	startup = JSON.parse((startupRun.stdout || '').trim());
} catch {
	// A failed producer cannot supply passing observations.
}
const startupDetail = JSON.stringify({
	status: startupRun.status,
	error: startupRun.error?.message,
	stderr: startupRun.stderr
});
const startupCases = new Map((startup.cases || []).map((entry) => [entry.name, entry]));
function startupDialog(name) {
	const entry = startupCases.get(name);
	if (startupRun.status !== 0 || entry?.failure || entry?.dialogs.length !== 1) return null;
	const argv = entry.dialogs[0];
	return argv.length === 7 && argv[3] === '--'
		? { source: argv[2], body: argv[4], title: argv[5], button: argv[6], log: entry.log_path }
		: null;
}
for (const [name, locale, diagnostic] of [
	['english', 'en', 'Native panel operation failed.'],
	['french', 'fr', 'Native panel operation failed.'],
	['unknown', 'en', 'Unknown error.'],
	['whitespace', 'en', 'stdout diagnostic'],
	['hostile', 'en', startup.hostile],
	['catalogue-changed-after-ui', 'en', 'Native panel operation failed.']
]) {
	const actual = startupDialog(name);
	const expected = JSON.parse(
		fs.readFileSync(path.join(localesDirectory, `${locale}.json`), 'utf8')
	);
	test(
		`the actual startup ${name} failure dispatches selected text and untrusted data as arguments`,
		actual !== null &&
			actual.title ===
				(locale === 'en' ? 'App Cloner — Startup error' : 'App Cloner — Erreur de démarrage') &&
			actual.button === expected['common.ok'] &&
			actual.body ===
				`${diagnostic}\n\n${expected['apps.cloner.diagnostic_log_path'].replace('{1}', actual.log)}` &&
			actual.source.includes('on run argv') &&
			!actual.source.includes(diagnostic),
		startupDetail + JSON.stringify(actual)
	);
}
for (const name of ['success', 'legacy-negative-status']) {
	const entry = startupCases.get(name);
	test(
		`the actual startup ${name} control dispatches no error dialog`,
		startupRun.status === 0 && entry?.failure === null && entry.dialogs.length === 0,
		startupDetail
	);
}
const invalidStartupCases = (startup.cases || []).slice(8);
test(
	'the actual startup visibly refuses every invalid catalogue before normal UI admission',
	startupRun.status === 0 &&
		invalidStartupCases.length === 37 &&
		invalidStartupCases.every((entry) => {
			const argv = entry.dialogs[0];
			return (
				entry.normal_ui_count === 0 &&
				entry.dialogs.length === 1 &&
				entry.failure?.type === 'ValueError' &&
				entry.failure.message === entry.expected_failure &&
				argv.length === 7 &&
				argv[3] === '--' &&
				argv[5] === 'App Cloner — Locale error' &&
				argv[6] === 'OK' &&
				argv[4] ===
					`App Cloner cannot start because the selected locale catalogue is unavailable or invalid.\n\n${entry.expected_failure}\n\nDiagnostic log: ${entry.log_path}`
			);
		}),
	startupDetail + JSON.stringify(invalidStartupCases)
);
test(
	'the direct startup loader refuses every invalid typed value with its exact developer error',
	startupRun.status === 0 &&
		startup.direct_loader_cases?.length === 38 &&
		startup.direct_loader_cases.every(
			(entry) => entry.failure?.type === 'ValueError' && entry.failure.message === entry.expected
		),
	startupDetail + JSON.stringify(startup.direct_loader_cases)
);

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
