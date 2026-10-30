// tools/test/test-issue-templates.cjs

/**
 * ==============================================================================
 * MODULE: GitHub Issue Forms And Their Registry
 * DESCRIPTION:
 * The app opens the forms of .github/ISSUE_TEMPLATE/ and prefills them by
 * field id from static/ergopti_plus/_shared/modules/diagnostics/issue_templates.json.
 * GitHub silently ignores a prefill whose id the form does not declare, so a
 * renamed field would leave every report without its version or diagnostics
 * and nothing would fail. This test holds the registry and the forms together:
 * 1. every template names an existing form, and every prefilled id is a field
 *    of that form;
 * 2. the forms carry their labels (the URL's labels= only works for users with
 *    triage permission), each one a label the repository has, and blank
 *    issues are off;
 * 3. the repository comes from the updater defaults, and a worst-case prefill
 *    (long accented text and emoji in every field) stays within max_url_bytes,
 *    the report field is cut with the marker and the truncation note;
 * 4. the bug form has the optional day log textarea (never prefilled) and no
 *    consent checkbox.
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
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'issue_templates.json'), 'utf8')
);
const defaults = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'updater', 'defaults.json'), 'utf8')
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
// Measured anonymously on github.com on 2026-10-30, with synthetic values: a
// request URL over about 7015 bytes answers 500, and over about 8200 bytes 414.
// A signed-out click goes through /login?return_to=<the URL encoded again>, where
// each %XX grows to %25XX: 4199 bytes of %XX still reached the login page (6996
// bytes), 4298 answered 500, and from about 5000 the redirect dropped return_to,
// losing the prefill. So the budget holds with the whole URL percent-encoded.
const GITHUB_REQUEST_URL_LIMIT = 7000;
const LOGIN_REDIRECT_PREFIX = 'https://github.com/login?return_to=';
const percentDenseUrl = (bytes) => {
	const base = 'https://github.com/owner/repo/issues/new?template=bug_report.yml&diagnostics=';
	return base + '%20'.repeat(Math.ceil((bytes - base.length) / 3));
};
if (!(registry.max_url_bytes > 0)) {
	failures.push(`max_url_bytes ${registry.max_url_bytes} must be positive`);
}
{
	const redirected =
		LOGIN_REDIRECT_PREFIX + encodeURIComponent(percentDenseUrl(registry.max_url_bytes));
	if (redirected.length > GITHUB_REQUEST_URL_LIMIT) {
		failures.push(
			`max_url_bytes ${registry.max_url_bytes} becomes a ${redirected.length}-byte login redirect, over GitHub's ${GITHUB_REQUEST_URL_LIMIT}-byte request limit`
		);
	}
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
	// The consent box is gone: no checkboxes, nothing required beyond the facts
	if (body.some((item) => item && item.type === 'checkboxes'))
		failures.push(`${bug.file}: the consent checkbox must stay removed`);
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
		driver: 'windows',
		diagnostics: long
	};
	const note = 'The full report is on the clipboard and in the saved file.';
	const url = IssueLink.buildIssueUrl(registry, repository, 'bug', values, {
		[registry.templates.bug.report_field]: note
	});
	const expectedStart = `https://github.com/${repository.owner}/${repository.repo}/issues/new?template=bug_report.yml`;
	if (!url.startsWith(expectedStart)) failures.push(`the URL does not start with ${expectedStart}`);
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
