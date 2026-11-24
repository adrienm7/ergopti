// tools/test/test-issue-templates.cjs

/**
 * ==============================================================================
 * MODULE: GitHub Issue Forms And Their Registry
 * DESCRIPTION:
 * The app opens the forms of .github/ISSUE_TEMPLATE/ and prefills them by
 * field id from static/ergopti_plus/_shared/diagnostics/data/issue_templates.json.
 * GitHub silently ignores a prefill whose id the form does not declare, so a
 * renamed field would leave every report without its version or diagnostics
 * and nothing would fail. This test holds the registry and the forms together:
 * 1. every template names an existing form, and every prefilled id is a field
 *    of that form;
 * 2. the forms carry their labels (the URL's labels= only works for users with
 *    triage permission), each one a label the repository has, and blank
 *    issues are off;
 * 3. the repository comes from the updater defaults, both budgets keep room
 *    under the limits measured on github.com, and a worst-case prefill (long
 *    accented text and emoji in every field) stays within max_url_bytes and
 *    its login redirect within max_redirect_bytes, the report field cut with
 *    the marker and the truncation note;
 * 4. the bug form has the optional day log textarea (never prefilled), the
 *    required full report textarea the user pastes the clipboard into (never
 *    prefilled) and no consent checkbox;
 * 5. the pasted full report is bounded under GitHub's issue body limit with
 *    room for the prefilled fields and the user's own text;
 * 6. the driver field of both forms is a dropdown whose options are exactly
 *    the names the app sends, and the feature form requires only its title and
 *    the proposal.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { parseIssueFormYaml } = require('./support/issue-form-yaml.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const FORMS_DIR = path.join(ROOT, '.github', 'ISSUE_TEMPLATE');
// The builder is a page script (it defines window.ErgoptiIssueLink), so it runs
// in a sandbox exactly as the pages load it
const IssueLink = (() => {
	const file = path.join(SHARED, 'ui', 'issue_link.js');
	const sandbox = { window: {} };
	vm.runInNewContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	if (!sandbox.window.ErgoptiIssueLink)
		throw new Error('issue_link.js did not define window.ErgoptiIssueLink');
	return sandbox.window.ErgoptiIssueLink;
})();

const registry = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'diagnostics', 'data', 'issue_templates.json'), 'utf8')
);
const defaults = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'updater', 'data', 'defaults.json'), 'utf8')
);
const repository = defaults.github;

// The labels the repository has (`gh label list`, GitHub's default set). A form
// label the repository lacks is dropped from the issue without any error, so a
// new label is created in the repository first, then added here.
const REPOSITORY_LABELS = new Set([
	'bug',
	'documentation',
	'duplicate',
	'enhancement',
	'good first issue',
	'help wanted',
	'invalid',
	'question',
	'wontfix'
]);

// The driver dropdown's options: the names share.lua, model.js and report.ahk
// put in fields.driver, which the three suites replay from form_identity_vectors.json
const DRIVER_OPTIONS = Object.values(
	JSON.parse(
		fs.readFileSync(
			path.join(SHARED, 'tests', 'corpus', 'healthcheck', 'form_identity_vectors.json'),
			'utf8'
		)
	).driver_options
);
if (DRIVER_OPTIONS.join() !== 'macOS,Windows,Linux')
	throw new Error('form_identity_vectors.json must name macOS, Windows and Linux in that order');

const failures = [];
let fieldsChecked = 0;
let labelsChecked = 0;

// ── Registry shape ────────────────────────────────────────────────────────
const templateIds = Object.keys(registry.templates || {});
if (templateIds.length < 2)
	failures.push('the registry declares fewer than the bug and feature templates');
if (
	!/\{owner\}/.test(registry.issue_new_url || '') ||
	!/\{repo\}/.test(registry.issue_new_url || '')
) {
	failures.push('issue_new_url must take the repository from {owner} and {repo}');
}
// Measured anonymously on github.com with tools/dev/measure-issue-url-limits.cjs
// on 2026-11-24 (synthetic values, minimal request headers): /issues/new
// answered 302 up to 6440 bytes and 500 from 6460; a signed-out click goes
// through /login?return_to=<the URL encoded again>, where each %XX grows to
// %25XX, and /login answered 200 up to 6497 bytes and 500 from 6505. So a
// 4000-byte URL dense in %XX (a 6670-byte redirect) failed while a letter-dense
// one did not (on 2026-10-30 the limit was about 7000). A browser also sends its
// own headers and cookies, which share GitHub's limit: both budgets keep that
// room under what was measured.
const MEASURED_ISSUE_URL_LIMIT = 6440;
const MEASURED_LOGIN_URL_LIMIT = 6497;
const BROWSER_HEADER_ROOM = 1400;
const LOGIN_REDIRECT_PREFIX = 'https://github.com/login?return_to=';
if (registry.login_redirect_prefix !== LOGIN_REDIRECT_PREFIX) {
	failures.push(`login_redirect_prefix must be GitHub's ${LOGIN_REDIRECT_PREFIX}`);
}
if (
	!(registry.max_url_bytes > 0) ||
	registry.max_url_bytes + BROWSER_HEADER_ROOM > MEASURED_ISSUE_URL_LIMIT
) {
	failures.push(
		`max_url_bytes ${registry.max_url_bytes} leaves under ${BROWSER_HEADER_ROOM} bytes for a browser's headers below the measured ${MEASURED_ISSUE_URL_LIMIT}`
	);
}
if (
	!(registry.max_redirect_bytes >= registry.max_url_bytes) ||
	registry.max_redirect_bytes + BROWSER_HEADER_ROOM > MEASURED_LOGIN_URL_LIMIT
) {
	failures.push(
		`max_redirect_bytes ${registry.max_redirect_bytes} must be at least max_url_bytes and leave ${BROWSER_HEADER_ROOM} bytes for a browser's headers below the measured ${MEASURED_LOGIN_URL_LIMIT}`
	);
}

// GitHub refuses an issue body over 65,536 characters (its documented limit).
// The pasted full report leaves room under it for the prefilled fields (at
// most max_url_bytes, decoded or not), the form's headings and the user's own
// text: the steps, the expected and the observed behaviour.
const GITHUB_ISSUE_BODY_LIMIT = 65536;
const USER_TEXT_ROOM = 4096;
if (registry.max_issue_body_chars !== GITHUB_ISSUE_BODY_LIMIT) {
	failures.push(
		`max_issue_body_chars ${registry.max_issue_body_chars} must be GitHub's ${GITHUB_ISSUE_BODY_LIMIT}`
	);
}
if (
	!(registry.full_report_max_bytes > 0) ||
	registry.full_report_max_bytes + registry.max_url_bytes + USER_TEXT_ROOM >
		registry.max_issue_body_chars
) {
	failures.push(
		`full_report_max_bytes ${registry.full_report_max_bytes} plus max_url_bytes ${registry.max_url_bytes} leaves under ${USER_TEXT_ROOM} characters of an issue body for the user's own text`
	);
}

// ── Every template against its form ───────────────────────────────────────
for (const id of templateIds) {
	const template = registry.templates[id];
	const formPath = path.join(FORMS_DIR, template.file);
	if (!fs.existsSync(formPath)) {
		failures.push(
			`template "${id}" names ${template.file}, which is not in .github/ISSUE_TEMPLATE`
		);
		continue;
	}
	let form;
	try {
		form = parseIssueFormYaml(fs.readFileSync(formPath, 'utf8'));
	} catch (error) {
		failures.push(`${template.file}: ${error.message}`);
		continue;
	}
	const body = Array.isArray(form.body) ? form.body : [];
	const formIds = body.filter((item) => item && item.id).map((item) => item.id);
	if (formIds.length < 3) failures.push(`${template.file}: fewer than 3 fields with an id`);
	if (new Set(formIds).size !== formIds.length)
		failures.push(`${template.file}: duplicate field ids`);
	for (const fieldId of formIds) {
		if (!/^[A-Za-z0-9_-]+$/.test(fieldId))
			failures.push(`${template.file}: invalid field id "${fieldId}"`);
	}
	if (!Array.isArray(form.labels) || form.labels.length === 0) {
		failures.push(`${template.file}: labels must be declared in the form`);
	}
	for (const label of Array.isArray(form.labels) ? form.labels : []) {
		labelsChecked++;
		if (!REPOSITORY_LABELS.has(label)) {
			failures.push(
				`${template.file}: label "${label}" does not exist in the repository, so GitHub drops it`
			);
		}
	}
	if (form.title !== template.title_prefix) {
		failures.push(
			`${template.file}: title "${form.title}" differs from the registry prefix "${template.title_prefix}"`
		);
	}
	if (!Array.isArray(template.fields) || template.fields.length === 0) {
		failures.push(`template "${id}" prefills no field`);
	}
	for (const fieldId of template.fields || []) {
		fieldsChecked++;
		const field = body.find((item) => item && item.id === fieldId);
		if (!field) {
			failures.push(
				`template "${id}" prefills "${fieldId}", which ${template.file} does not declare`
			);
		} else if (field.type === 'dropdown') {
			// A dropdown is prefilled by the exact text of one option: the driver
			// names the app sends (share.lua, model.js, report.ahk), nothing else
			const options = (field.attributes && field.attributes.options) || [];
			if (fieldId !== 'driver' || JSON.stringify(options) !== JSON.stringify(DRIVER_OPTIONS))
				failures.push(
					`${template.file}: dropdown "${fieldId}" must be the driver with the options ${DRIVER_OPTIONS.join(', ')}`
				);
		} else if (field.type !== 'input' && field.type !== 'textarea') {
			failures.push(
				`${template.file}: "${fieldId}" is a ${field.type}, which a URL cannot prefill`
			);
		} else {
			// GitHub's form syntax has no way to lock a field, so a prefilled value is
			// editable by construction; a lock-looking attribute would only mislead
			// the next reader. Whether the web page keeps a user's edit when it is
			// reloaded cannot be shown without a real draft.
			for (const key of Object.keys(field.attributes || {})) {
				if (/^(disabled|readonly|read_only)$/i.test(key))
					failures.push(
						`${template.file}: "${fieldId}" declares "${key}", which GitHub does not define`
					);
			}
		}
	}
	// The host fills report_field with the compact report: the budget cuts the
	// last field first, so any other place would drop the identity fields
	if (template.report_field !== undefined) {
		const fields = template.fields || [];
		if (fields[fields.length - 1] !== template.report_field) {
			failures.push(
				`template "${id}": report_field "${template.report_field}" must be its last field`
			);
		}
	}
}
if (!registry.templates.bug || registry.templates.bug.report_field === undefined) {
	failures.push('the bug template names no report_field for the compact report');
}
// The day log field: an optional textarea the user fills by hand, never prefilled
{
	const bug = registry.templates.bug || {};
	const form = parseIssueFormYaml(fs.readFileSync(path.join(FORMS_DIR, bug.file || ''), 'utf8'));
	const body = Array.isArray(form.body) ? form.body : [];
	const dayLog = body.find((item) => item && item.id === bug.day_log_field);
	if (typeof bug.day_log_field !== 'string' || !dayLog) {
		failures.push('the bug template names no day_log_field that its form declares');
	} else {
		if (dayLog.type !== 'textarea')
			failures.push(`${bug.file}: the day log field must be a textarea`);
		if (dayLog.validations && dayLog.validations.required === true)
			failures.push(`${bug.file}: the day log field must be optional`);
		if ((bug.fields || []).includes(bug.day_log_field))
			failures.push('the day log field must never be prefilled: it is not in fields');
	}
	// The full report field: a required textarea the user pastes the clipboard
	// into, so a report cut to fit the link never loses the rest
	const fullReport = body.find((item) => item && item.id === bug.full_report_field);
	if (typeof bug.full_report_field !== 'string' || !fullReport) {
		failures.push('the bug template names no full_report_field that its form declares');
	} else {
		if (fullReport.type !== 'textarea')
			failures.push(`${bug.file}: the full report field must be a textarea`);
		if (!fullReport.validations || fullReport.validations.required !== true)
			failures.push(`${bug.file}: the full report field must be required`);
		if (!/clipboard/.test((fullReport.attributes || {}).description || ''))
			failures.push(`${bug.file}: the full report field must say the report is on the clipboard`);
		if ((bug.fields || []).includes(bug.full_report_field))
			failures.push('the full report field must never be prefilled: it is not in fields');
		const ids = body.filter((item) => item && item.id).map((item) => item.id);
		if (ids.indexOf(bug.full_report_field) !== ids.indexOf(bug.report_field) + 1)
			failures.push(`${bug.file}: the full report field must follow the report field`);
	}
	// The consent box is gone: no checkboxes, nothing required beyond the facts
	if (body.some((item) => item && item.type === 'checkboxes'))
		failures.push(`${bug.file}: the consent checkbox must stay removed`);
}
// The feature form: the proposal is the only required field besides the title,
// and the driver comes before the system in both forms
{
	const feature = registry.templates.feature || {};
	const form = parseIssueFormYaml(
		fs.readFileSync(path.join(FORMS_DIR, feature.file || ''), 'utf8')
	);
	const required = (Array.isArray(form.body) ? form.body : [])
		.filter((item) => item && item.validations && item.validations.required === true)
		.map((item) => item.id);
	if (JSON.stringify(required) !== JSON.stringify(['proposal']))
		failures.push(
			`${feature.file}: only the proposal may be required, found ${required.join(', ')}`
		);
	for (const id of templateIds) {
		const fields = registry.templates[id].fields || [];
		if (fields.indexOf('driver') < 0 || fields.indexOf('driver') > fields.indexOf('os'))
			failures.push(`template "${id}": the driver must come before the operating system`);
	}
}
if (fieldsChecked < 4) failures.push(`only ${fieldsChecked} prefilled field(s) checked`);
if (labelsChecked < templateIds.length)
	failures.push(`only ${labelsChecked} form label(s) checked`);

// ── Plain YAML scalars ────────────────────────────────────────────────────
// GitHub rejects the whole form when a plain scalar holds ": " or " #": the
// project's own parser is lenient, so the raw lines are checked here.
for (const file of fs.readdirSync(FORMS_DIR).filter((name) => name.endsWith('.yml'))) {
	fs.readFileSync(path.join(FORMS_DIR, file), 'utf8')
		.split('\n')
		.forEach((line, index) => {
			const match = /^\s*(?:- )?[A-Za-z_]+: (.+)$/.exec(line);
			if (!match || /^["'|>\[{]/.test(match[1])) return;
			if (/: |\s#/.test(match[1]))
				failures.push(
					`${file}:${index + 1}: a plain scalar holds ": " or " #", which GitHub refuses`
				);
		});
}

// ── config.yml ────────────────────────────────────────────────────────────
try {
	const config = parseIssueFormYaml(fs.readFileSync(path.join(FORMS_DIR, 'config.yml'), 'utf8'));
	if (config.blank_issues_enabled !== false)
		failures.push('config.yml must set blank_issues_enabled: false');
} catch (error) {
	failures.push(`config.yml: ${error.message}`);
}

// ── Repository and worst-case budget ──────────────────────────────────────
if (!repository || !repository.owner || !repository.repo) {
	failures.push('the updater defaults declare no github.owner/github.repo');
} else {
	// What the app sends: short identity fields and the compact report, far over
	// the budget, accented and with emoji (6 and 12 bytes encoded)
	const long = 'Paramètres généraux — échec répété 😀 à l’ouverture de la fenêtre. '.repeat(120);
	const values = {
		title: 'Échec à l’ouverture 😀',
		version: '2.1.0-dev.130',
		os: 'Windows 11 Famille 26100.9457 — édition française',
		driver: 'Windows',
		diagnostics: long
	};
	const note = 'The full report is on the clipboard and in the saved file.';
	const url = IssueLink.buildIssueUrl(registry, repository, 'bug', values, {
		[registry.templates.bug.report_field]: note
	});
	const expectedStart = `https://github.com/${repository.owner}/${repository.repo}/issues/new?template=bug_report.yml`;
	if (!url.startsWith(expectedStart)) failures.push(`the URL does not start with ${expectedStart}`);
	const redirected = LOGIN_REDIRECT_PREFIX + encodeURIComponent(url);
	if (redirected.length > registry.max_redirect_bytes) {
		failures.push(
			`a worst-case prefill becomes a ${redirected.length}-byte login redirect, over the ${registry.max_redirect_bytes}-byte budget`
		);
	}
	if (url.length > registry.max_url_bytes) {
		failures.push(
			`a worst-case prefill is ${url.length} bytes, over the ${registry.max_url_bytes}-byte budget`
		);
	}
	if (!/[?&]version=/.test(url)) failures.push('the worst-case prefill lost the version field');
	const reportValue = decodeURIComponent(
		(new RegExp(`[?&]${registry.templates.bug.report_field}=([^&]*)`).exec(url) || [])[1] || ''
	);
	if (!reportValue.endsWith(registry.truncation_marker + '\n\n' + note))
		failures.push('the cut report must end with the truncation marker and the note');
	if (/[?&]day_log=/.test(url)) failures.push('the day log field must never be prefilled');
}

if (failures.length > 0) {
	console.error(`[FAIL] issue templates: ${failures.length} failure(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	`[OK] issue templates: ${templateIds.length} form(s), ${fieldsChecked} prefilled field(s) declared by their forms.`
);
