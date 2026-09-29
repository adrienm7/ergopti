// tools/test/test-input-source-enabled-list-edit.cjs

/**
 * ==============================================================================
 * MODULE: macOS Enabled Input-Source List Edit - Behavioral Guard
 * DESCRIPTION:
 * Executes the exact Python program the Hammerspoon input-source adapter runs
 * to add a .keylayout to, or remove one from, the user's enabled input sources
 * (AppleEnabledInputSources), with the defaults/launchctl children and the
 * plist codec replaced by doubles. The layout manager relies on it for any
 * registry layout, so the entry format and what each mode leaves untouched
 * are pinned here, where a Mac is not needed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const INPUT_SOURCES = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'modules',
	'keymap',
	'input_sources.lua'
);

let failures = 0;
let passes = 0;

function check(name, fn) {
	try {
		fn();
		passes += 1;
		console.log(`  ok   ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${String(err.message).split('\n').join('\n       ')}`);
	}
}

function resolvePython() {
	for (const candidate of ['python3', 'python']) {
		const probe = spawnSync(candidate, ['--version'], { encoding: 'utf8' });
		if (!probe.error && probe.status === 0) return candidate;
	}
	return null;
}

const source = fs.readFileSync(INPUT_SOURCES, 'utf8');
const match = source.match(/^local ENABLED_LIST_SCRIPT = \[\[([\s\S]*?)\n\]\]$/m);
if (!match) {
	console.error('input_sources.lua declares no ENABLED_LIST_SCRIPT.');
	process.exit(1);
}
const SCRIPT = match[1];

/**
 * Runs the script in one mode against a starting enabled list.
 * @param {string} python
 * @param {string} mode - enable or disable.
 * @param {string} target - .keylayout path or KeyboardLayout Name.
 * @param {object[]} sources - AppleEnabledInputSources before the edit.
 * @returns {{exit: number, written: object[]|null, printed: string[]}}
 */
function run(python, mode, target, sources) {
	const harness = `
import builtins, json, os, plistlib, signal, subprocess, sys

SCRIPT = ${JSON.stringify(SCRIPT)}
STATE = {"written": None, "printed": []}
REAL_PRINT = builtins.print
START = json.loads(${JSON.stringify(JSON.stringify(sources))})

plistlib.loads = lambda _raw: {"AppleEnabledInputSources": START}
def fake_dumps(value, fmt=None):
    STATE["written"] = value["AppleEnabledInputSources"]
    return b"plist"
plistlib.dumps = fake_dumps
os.getuid = lambda: 501
os.killpg = lambda pid, sig: None
if not hasattr(signal, "SIGKILL"):
    signal.SIGKILL = 9
if not hasattr(signal, "SIG_BLOCK"):
    signal.SIG_BLOCK = 0
if not hasattr(signal, "SIG_SETMASK"):
    signal.SIG_SETMASK = 2
signal.pthread_sigmask = lambda how, mask: set()
signal.signal = lambda sig, handler: None

class FakePopen:
    def __init__(self, args, stdout=None, stderr=None, start_new_session=False):
        self.pid = 4242
        self.returncode = None
    def poll(self):
        return self.returncode
    def communicate(self, timeout=None):
        self.returncode = 0
        return (b"plist", b"")
    def wait(self, timeout=None):
        return 0

subprocess.Popen = FakePopen
builtins.print = lambda *args, **_kwargs: STATE["printed"].append(" ".join(str(a) for a in args))
sys.argv = ["input-source-edit", ${JSON.stringify(mode)}, ${JSON.stringify(target)}, "9"]
code = 0
try:
    exec(compile(SCRIPT, "input-source-edit", "exec"), {})
except SystemExit as exc:
    code = exc.code if isinstance(exc.code, int) else 1
REAL_PRINT(json.dumps({"exit": code, "written": STATE["written"], "printed": STATE["printed"]}))
`;
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-enabled-list-'));
	try {
		const file = path.join(dir, 'harness.py');
		fs.writeFileSync(file, harness, 'utf8');
		const result = spawnSync(python, [file], { encoding: 'utf8' });
		if (result.error || result.status !== 0) {
			throw new Error(`harness failed: ${result.status}\n${result.stdout}${result.stderr}`);
		}
		return JSON.parse(result.stdout.trim().split('\n').pop());
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

const python = resolvePython();
if (!python) {
	console.error('No usable Python interpreter found (tried python3, python).');
	process.exit(1);
}

const FRENCH = {
	InputSourceKind: 'Keyboard Layout',
	'KeyboardLayout ID': 1,
	'KeyboardLayout Name': 'French'
};
const ERGOL = {
	InputSourceKind: 'Keyboard Layout',
	'KeyboardLayout ID': 0,
	'KeyboardLayout Name': 'French (Ergo-L)'
};
const LEGACY = {
	InputSourceKind: 'Keyboard Layout',
	'Bundle ID': 'com.apple.keyboardlayout.ergopti',
	'KeyboardLayout Name': 'X'
};

console.log('Enabled input-source list edit');

const keylayoutDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-keylayout-'));
const keylayout = path.join(keylayoutDir, 'ergol.keylayout');
fs.writeFileSync(
	keylayout,
	'<?xml version="1.1"?>\n<keyboard group="0" id="0" name="French (Ergo-L)" maxout="1">\n',
	'utf8'
);
const nameless = path.join(keylayoutDir, 'nameless.keylayout');
fs.writeFileSync(nameless, '<keyboard group="0" id="7">\n', 'utf8');

try {
	check('enable appends the layout under the id and name its file declares, once', () => {
		const result = run(python, 'enable', keylayout, [FRENCH, ERGOL, LEGACY]);
		if (result.exit !== 0) throw new Error(JSON.stringify(result));
		const names = result.written.map((s) => s['KeyboardLayout Name']);
		if (JSON.stringify(names) !== JSON.stringify(['French', 'French (Ergo-L)'])) {
			throw new Error(`unexpected list ${JSON.stringify(result.written)}`);
		}
		const added = result.written[1];
		if (
			added['KeyboardLayout ID'] !== 0 ||
			added.InputSourceKind !== 'Keyboard Layout' ||
			'Bundle ID' in added
		) {
			throw new Error(`the entry must mirror a built-in layout: ${JSON.stringify(added)}`);
		}
		if (result.printed[result.printed.length - 1] !== 'OK')
			throw new Error(JSON.stringify(result.printed));
	});

	check('disable removes only the named layout', () => {
		const result = run(python, 'disable', 'French (Ergo-L)', [FRENCH, ERGOL, LEGACY]);
		if (result.exit !== 0) throw new Error(JSON.stringify(result));
		if (JSON.stringify(result.written) !== JSON.stringify([FRENCH, LEGACY])) {
			throw new Error(`unexpected list ${JSON.stringify(result.written)}`);
		}
	});

	check('disable of a layout that is not listed writes nothing and says so', () => {
		const result = run(python, 'disable', 'French (Ergo-L)', [FRENCH]);
		if (result.exit !== 0 || result.written !== null || result.printed[0] !== 'ABSENT') {
			throw new Error(JSON.stringify(result));
		}
	});

	check('a layout file without a name, or an unknown mode, is refused before any write', () => {
		const unnamed = run(python, 'enable', nameless, [FRENCH]);
		if (
			unnamed.exit !== 1 ||
			unnamed.written !== null ||
			!unnamed.printed[0].startsWith('PARSE_ERR')
		) {
			throw new Error(JSON.stringify(unnamed));
		}
		const unknown = run(python, 'rename', 'French', [FRENCH]);
		if (unknown.exit !== 2 || unknown.written !== null) throw new Error(JSON.stringify(unknown));
	});
} finally {
	fs.rmSync(keylayoutDir, { recursive: true, force: true });
}

console.log(`\n${passes} passed, ${failures} failed`);
if (failures > 0) process.exit(1);
