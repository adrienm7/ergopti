// tools/build/render-appimage-libc-preflight.cjs

/**
 * ==============================================================================
 * MODULE: AppImage C Library Preflight
 * DESCRIPTION:
 * Writes the POSIX shell file AppRun sources before anything linked against
 * glibc runs: it refuses, in the user's language, a system whose C library
 * cannot load the image.
 *
 * FEATURES & RATIONALE:
 * 1. The image bundles its own libraries but uses the recipient's glibc, since
 *    the tray loads the host GTK into the daemon and a bundled glibc would have
 *    to be at least as new as every host library. On glibc 2.31 (Ubuntu 20.04,
 *    Debian 11) the bundled luajit died with "version `GLIBC_2.34' not found";
 *    on Alpine, AppRun itself died with "No such file or directory" because
 *    musl systems ship no bash and cannot run glibc programs at all. Both now
 *    get a sentence that names the cause.
 * 2. The required version is GLIBC_CEILING, the same constant the packager
 *    proves every bundled ELF file stays under: a system at that version runs
 *    the image, an older one is refused before its loader fails.
 * 3. `getconf GNU_LIBC_VERSION` is answered by glibc itself, which ships
 *    getconf on every glibc distribution; musl's getconf has no such variable.
 * 4. The text comes from the shared locale catalogue at build time, because no
 *    parser can run on a system that cannot load the bundled interpreter. The
 *    language follows LC_ALL, LC_MESSAGES and LANG; an unshipped language reads
 *    English, the catalogue's canonical locale.
 *
 * Usage:
 *   node tools/build/render-appimage-libc-preflight.cjs <output file>
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const { GLIBC_CEILING } = require('./check-elf-glibc-ceiling.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DATA_DIR = path.join(ROOT, 'static/ergopti_plus/_shared/data');

/** The catalogue every other locale mirrors, read for an unshipped language. */
const CANONICAL_LOCALE = 'en';
/** sysexits EX_UNAVAILABLE: the system lacks what the program needs to run. */
const REFUSAL_EXIT = 69;
/** The catalogue keys of the refusal, by the role the preflight gives them. */
const MESSAGE_KEYS = {
	title: 'startup.linux_appimage_libc_title',
	musl: 'startup.linux_appimage_musl_body',
	old: 'startup.linux_appimage_old_glibc_body'
};
/** The shell variable holding the version the system reports, for {2}. */
const FOUND_VARIABLE = 'ergopti_glibc_found';

/**
 * Quotes a string for a POSIX shell word.
 * @param {string} text Any text.
 * @returns {string} The single-quoted word.
 */
function shellQuote(text) {
	return `'${text.replaceAll("'", "'\\''")}'`;
}

/**
 * Turns a catalogue sentence into one shell word: {1} becomes the required
 * version now, {2} the version the system reports at run time.
 * @param {string} text Catalogue text.
 * @param {string} ceiling Required glibc version.
 * @returns {string} A shell word.
 */
function shellText(text, ceiling) {
	return text.replaceAll('{1}', ceiling).split('{2}').map(shellQuote).join(`"$${FOUND_VARIABLE}"`);
}

/**
 * Reads the shipped locales and the refusal texts of each.
 * @param {string} dataDir The shared data directory.
 * @returns {{code: string, texts: Record<string, string>}[]} In the canonical order.
 */
function readLocales(dataDir = DATA_DIR) {
	const order = JSON.parse(fs.readFileSync(path.join(dataDir, 'locale_order.json'), 'utf8')).order;
	if (!Array.isArray(order) || order.length === 0) {
		throw new Error('locale_order.json declares no locale order');
	}
	return order.map((code) => {
		if (!/^[a-z]{2}$/.test(code)) throw new Error(`Invalid locale code: ${JSON.stringify(code)}`);
		const catalogue = JSON.parse(
			fs.readFileSync(path.join(dataDir, 'locales', `${code}.json`), 'utf8')
		);
		const texts = {};
		for (const [role, key] of Object.entries(MESSAGE_KEYS)) {
			if (typeof catalogue[key] !== 'string' || catalogue[key] === '') {
				throw new Error(`${code}.json has no ${key}`);
			}
			texts[role] = catalogue[key];
		}
		return { code, texts };
	});
}

/**
 * Renders the preflight.
 * @param {{code: string, texts: Record<string, string>}[]} locales From readLocales.
 * @param {string} ceiling Required glibc version, MAJOR.MINOR.
 * @returns {string} The POSIX shell file.
 */
function render(locales, ceiling = GLIBC_CEILING) {
	const [major, minor] = ceiling.split('.');
	if (!/^\d+\.\d+$/.test(ceiling)) throw new Error(`Invalid glibc ceiling: ${ceiling}`);
	if (!locales.some((locale) => locale.code === CANONICAL_LOCALE)) {
		throw new Error(`The ${CANONICAL_LOCALE} catalogue is not shipped`);
	}
	const codes = locales.map((locale) => locale.code).join('|');
	const texts = locales
		.flatMap(({ code, texts: entries }) =>
			Object.keys(MESSAGE_KEYS).map(
				(role) => `\t\t${code}:${role}) printf '%s' ${shellText(entries[role], ceiling)} ;;`
			)
		)
		.join('\n');
	return `# AppDir/usr/lib/ergopti/libc-preflight.sh
# Generated by tools/build/render-appimage-libc-preflight.cjs; do not edit.
# Sourced by AppRun with /bin/sh before anything linked against glibc runs.

ergopti_glibc_required_major=${major}
ergopti_glibc_required_minor=${minor}

# The two-letter language of the session, when the image ships it.
ergopti_libc_language() {
	ergopti_libc_locale="\${LC_ALL:-\${LC_MESSAGES:-\${LANG:-}}}"
	case "\${ergopti_libc_locale%%[_.@]*}" in
		${codes}) printf '%s' "\${ergopti_libc_locale%%[_.@]*}" ;;
		*) printf '%s' ${CANONICAL_LOCALE} ;;
	esac
}

# Prints one refusal text: $1 is title, musl or old; $2 the language.
ergopti_libc_text() {
	case "$2:$1" in
${texts}
	esac
}

# Prints the refusal and stops AppRun. A desktop launch has no terminal, so the
# text also goes to the notification daemon when the session has one; stderr
# already carries it, so a missing notifier changes nothing.
ergopti_libc_refuse() {
	ergopti_libc_lang="$(ergopti_libc_language)"
	ergopti_libc_title="$(ergopti_libc_text title "$ergopti_libc_lang")"
	ergopti_libc_body="$(ergopti_libc_text "$1" "$ergopti_libc_lang")"
	printf '%s\\n%s\\n' "$ergopti_libc_title" "$ergopti_libc_body" >&2
	if { [ -n "\${DISPLAY:-}" ] || [ -n "\${WAYLAND_DISPLAY:-}" ]; } && command -v notify-send >/dev/null 2>&1; then
		notify-send --urgency=critical "$ergopti_libc_title" "$ergopti_libc_body" >/dev/null 2>&1 || :
	fi
	exit ${REFUSAL_EXIT}
}

${FOUND_VARIABLE}="$(getconf GNU_LIBC_VERSION 2>/dev/null || :)"
case "$${FOUND_VARIABLE}" in
	"glibc "[0-9]*.[0-9]*) ${FOUND_VARIABLE}="\${${FOUND_VARIABLE}#glibc }" ;;
	*) ergopti_libc_refuse musl ;;
esac
ergopti_glibc_major="\${${FOUND_VARIABLE}%%.*}"
ergopti_glibc_minor="\${${FOUND_VARIABLE}#*.}"
ergopti_glibc_minor="\${ergopti_glibc_minor%%[!0-9]*}"
if [ "$ergopti_glibc_major" -lt "$ergopti_glibc_required_major" ] || {
	[ "$ergopti_glibc_major" -eq "$ergopti_glibc_required_major" ] &&
		[ "$ergopti_glibc_minor" -lt "$ergopti_glibc_required_minor" ]
}; then
	ergopti_libc_refuse old
fi
`;
}

function main(argv) {
	if (argv.length !== 1) {
		console.error('Usage: node tools/build/render-appimage-libc-preflight.cjs <output file>');
		return 2;
	}
	fs.writeFileSync(argv[0], render(readLocales()), { encoding: 'utf8', mode: 0o644 });
	console.log(`[OK] glibc ${GLIBC_CEILING} preflight written to ${argv[0]}.`);
	return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = {
	CANONICAL_LOCALE,
	MESSAGE_KEYS,
	REFUSAL_EXIT,
	readLocales,
	render
};
