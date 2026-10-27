// tools/test/test-linux-shell-messages.cjs

/**
 * ==============================================================================
 * MODULE: Linux Shell Messages Contract
 * DESCRIPTION:
 * The Linux shell scripts print their sentences through linux/install/messages.sh,
 * which reads the catalogue tools/codegen/codegen-linux-shell-messages.cjs
 * generates from the `linux_shell.*` locale keys. This gate runs the real
 * reader under bash and checks the scripts against the real catalogues.
 *
 * ROOT CAUSE ENCODED:
 * install.sh, uninstall.sh, the launcher and the install/ helpers printed 116
 * sentences typed in French or English (no-hardcoded-ui-strings-baseline.json),
 * so a German or Japanese user read the installer in another language, and
 * nothing could translate them: these scripts run before LuaJIT, jq or Python
 * can be assumed, so they cannot read the JSON catalogues.
 *
 * WHAT IS CHECKED:
 * 1. Language selection: LC_ALL, then LC_MESSAGES, then LANG; C, POSIX and an
 *    unset environment select English, the source; nb and nn select no; a
 *    language with no catalogue selects English by name.
 * 2. Placeholders {1}..{9} take the arguments verbatim: an argument holding
 *    `{2}`, `&`, `$` or a backslash is not expanded again.
 * 3. Fail fast: an unknown key, or a placeholder with no argument, prints
 *    nothing on stdout and returns 2 naming it; a missing catalogue stops the
 *    script that sources the reader.
 * 4. Every ergopti_msg / ergopti_msg_with / ergopti_text call of a shell script
 *    names a key of the English catalogue, and every catalogue key is used, so
 *    a renamed key fails here instead of on the user's terminal.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const LINUX = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const READER = path.join(LINUX, 'install', 'messages.sh');
const CATALOGUES = path.join(LINUX, '_generated', 'shell_messages');
const SCRIPT_ROOTS = ['install.sh', 'uninstall.sh', 'bin', 'install'];
// The reader's three calls, and install.sh's two wrappers around them (a
// section title, a --help option line).
const CALL =
	/(?:\bergopti_(?:msg_with\s+(?:"[^"]*"|'[^']*'|\S+)|msg|text)|\b_section|\b_help_option\s+(?:"[^"]*"|\S+))\s+([a-z0-9_]+\.[a-z0-9_.]+)/g;

/**
 * Builds a throwaway driver tree holding the real reader and given catalogues.
 * @param {Object<string,string>|null} catalogues Locale code -> file body; null for none.
 * @returns {string} The fake driver root.
 */
function fakeDriver(catalogues) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-shell-messages-'));
	fs.mkdirSync(path.join(root, 'install'));
	fs.copyFileSync(READER, path.join(root, 'install', 'messages.sh'));
	if (catalogues) {
		const dir = path.join(root, '_generated', 'shell_messages');
		fs.mkdirSync(dir, { recursive: true });
		for (const [code, body] of Object.entries(catalogues))
			fs.writeFileSync(path.join(dir, `${code}.msg`), body);
	}
	return root;
}

/**
 * Sources the reader of a fake driver and runs a snippet under bash.
 * @param {string} root Fake driver root.
 * @param {string} snippet Bash run after sourcing.
 * @param {Object<string,string>} env Locale variables; every other one is unset.
 * @returns {{status: number, stdout: string, stderr: string}}
 */
function run(root, snippet, env = {}) {
	const script = `set -euo pipefail\nsource "${root}/install/messages.sh"\n${snippet}\n`;
	const result = spawnSync(bashExecutable(), ['-c', script], {
		encoding: 'utf8',
		env: { PATH: process.env.PATH, ...env }
	});
	return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

const FAKE = {
	en: '# header\ngreet=Hello {1}\ntwo=First {1}, then {2}\nonly_en=English only\n',
	fr: 'greet=Bonjour {1}\ntwo=D’abord {1}, puis {2}\nonly_en=Seulement en anglais\n',
	no: 'greet=Hei {1}\ntwo=Først {1}, så {2}\nonly_en=Bare engelsk\n'
};

const failures = [];
const check = (name, fn) => {
	try {
		fn();
	} catch (error) {
		failures.push(`${name}: ${error.message}`);
	}
};

const root = fakeDriver(FAKE);
try {
	const greet = (env) => run(root, 'ergopti_msg greet Ada', env).stdout;
	check('LANG selects its catalogue', () =>
		assert.equal(greet({ LANG: 'fr_FR.UTF-8' }), 'Bonjour Ada\n')
	);
	check('LC_MESSAGES outranks LANG', () =>
		assert.equal(greet({ LANG: 'en_US.UTF-8', LC_MESSAGES: 'fr_CA.UTF-8' }), 'Bonjour Ada\n')
	);
	check('LC_ALL outranks LC_MESSAGES', () =>
		assert.equal(greet({ LC_ALL: 'nb_NO.UTF-8', LC_MESSAGES: 'fr_FR.UTF-8' }), 'Hei Ada\n')
	);
	check('C selects the English source', () =>
		assert.equal(greet({ LANG: 'C', LC_ALL: 'POSIX' }), 'Hello Ada\n')
	);
	check('an unset environment selects English', () => assert.equal(greet({}), 'Hello Ada\n'));
	check('a language without a catalogue selects English', () =>
		assert.equal(greet({ LANG: 'de_DE.UTF-8' }), 'Hello Ada\n')
	);
	check('nn selects the Norwegian catalogue', () =>
		assert.equal(greet({ LANG: 'nn_NO' }), 'Hei Ada\n')
	);
	check('placeholders take arguments in order and verbatim', () => {
		const out = run(root, `ergopti_msg two '{2}&\\$HOME' 'b\\\\c'`, { LANG: 'en' }).stdout;
		assert.equal(out, 'First {2}&\\$HOME, then b\\\\c\n');
	});
	check('a prefix is printed before the message', () => {
		assert.equal(
			run(root, 'ergopti_msg_with "  ✔  " greet Ada', { LANG: 'fr' }).stdout,
			'  ✔  Bonjour Ada\n'
		);
	});
	check('ergopti_text prints no newline', () => {
		assert.equal(
			run(root, 'printf "[%s]" "$(ergopti_text greet Ada)"', { LANG: 'fr' }).stdout,
			'[Bonjour Ada]'
		);
	});
	check('a placeholder without its argument fails', () => {
		const result = run(root, 'ergopti_msg two only-one || echo "status $?"', { LANG: 'en' });
		assert.equal(result.stdout, 'status 2\n');
		assert.match(result.stderr, /argument 2/);
	});
	check('an unknown key fails and names the key', () => {
		const result = run(root, 'ergopti_msg missing_key || echo "status $?"', { LANG: 'fr' });
		assert.equal(result.stdout, 'status 2\n');
		assert.match(result.stderr, /missing_key/);
	});
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}

const empty = fakeDriver(null);
try {
	check('a missing catalogue stops the script that sources the reader', () => {
		const result = run(empty, 'echo reached', { LANG: 'fr' });
		assert.notEqual(result.status, 0);
		assert.equal(result.stdout, '');
		assert.match(result.stderr, /catalogue/);
	});
} finally {
	fs.rmSync(empty, { recursive: true, force: true });
}

/**
 * Every shell file the scripts are made of.
 * @returns {string[]} Absolute paths.
 */
function shellFiles() {
	const out = [];
	const visit = (abs) => {
		const stat = fs.statSync(abs);
		if (stat.isDirectory()) {
			for (const entry of fs.readdirSync(abs)) visit(path.join(abs, entry));
		} else if (abs.endsWith('.sh') || path.dirname(abs).endsWith(path.join('linux', 'bin'))) {
			if (!fs.readFileSync(abs).includes(0)) out.push(abs);
		}
	};
	for (const rel of SCRIPT_ROOTS) visit(path.join(LINUX, rel));
	return out;
}

check('every message call names an English catalogue key, and every key is used', () => {
	const english = new Set(
		fs
			.readFileSync(path.join(CATALOGUES, 'en.msg'), 'utf8')
			.split('\n')
			.filter((line) => line && !line.startsWith('#'))
			.map((line) => line.slice(0, line.indexOf('=')))
	);
	const used = new Set();
	const unknown = [];
	for (const file of shellFiles()) {
		if (file === READER) continue;
		for (const m of fs.readFileSync(file, 'utf8').matchAll(CALL)) {
			used.add(m[1]);
			if (!english.has(m[1])) unknown.push(`${path.relative(ROOT, file)}: ${m[1]}`);
		}
	}
	assert.ok(used.size > 0, 'the call scan found no message call, so it proves nothing');
	assert.deepEqual(unknown, [], 'calls naming a key the catalogue does not hold');
	assert.deepEqual(
		[...english].filter((name) => !used.has(name)),
		[],
		'catalogue keys no script prints (delete them or print them)'
	);
});

check('the shipped reader prints the shipped catalogue', () => {
	const result = spawnSync(
		bashExecutable(),
		['-c', `set -euo pipefail; source "${READER}"; ergopti_msg launcher.driver_missing /x`],
		{ encoding: 'utf8', env: { PATH: process.env.PATH, LANG: 'fr_FR.UTF-8' } }
	);
	assert.equal(result.stdout, 'Erreur : répertoire du driver Linux introuvable : /x\n');
});

check('the self-check rejects a call to an unknown key', () => {
	const sample =
		'ergopti_msg launcher.not_a_key\nergopti_msg_with "  " launcher.other\n' +
		'_section install.title\n_help_option "--prefix <dir>" install.help\n';
	assert.deepEqual(
		[...sample.matchAll(CALL)].map((m) => m[1]),
		['launcher.not_a_key', 'launcher.other', 'install.title', 'install.help']
	);
});

if (failures.length > 0) {
	console.error('\x1b[31m[ERROR] Linux shell messages:\x1b[0m');
	for (const failure of failures) console.error('    ' + failure);
	process.exit(1);
}
console.log('\x1b[32m[OK] Linux shell messages: reader contract and catalogue keys.\x1b[0m');
