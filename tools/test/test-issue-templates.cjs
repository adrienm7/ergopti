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
 *    triage permission) and blank issues are off;
 * 3. the repository comes from the updater defaults, and a worst-case prefill
 *    (long accented text and emoji in every field) stays within max_url_bytes.
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
	if (!sandbox.window.ErgoptiIssueLink) throw new Error('issue_link.js did not define window.ErgoptiIssueLink');
	return sandbox.window.ErgoptiIssueLink;
})();

const registry = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'issue_templates.json'), 'utf8')
);
const defaults = JSON.parse(fs.readFileSync(path.join(SHARED, 'modules', 'updater', 'defaults.json'), 'utf8'));
const repository = defaults.github;

const failures = [];
let fieldsChecked = 0;

// ── Registry shape ────────────────────────────────────────────────────────
const templateIds = Object.keys(registry.templates || {});
if (templateIds.length < 2) failures.push('the registry declares fewer than the bug and feature templates');
if (!/\{owner\}/.test(registry.issue_new_url || '') || !/\{repo\}/.test(registry.issue_new_url || '')) {
	failures.push('issue_new_url must take the repository from {owner} and {repo}');
}
if (!(registry.max_url_bytes > 0 && registry.max_url_bytes <= 8000)) {
	failures.push(`max_url_bytes ${registry.max_url_bytes} must be positive and under GitHub's ~8 KB limit`);
}

// ── Every template against its form ───────────────────────────────────────
for (const id of templateIds) {
	const template = registry.templates[id];
	const formPath = path.join(FORMS_DIR, template.file);
	if (!fs.existsSync(formPath)) {
		failures.push(`template "${id}" names ${template.file}, which is not in .github/ISSUE_TEMPLATE`);
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
	if (new Set(formIds).size !== formIds.length) failures.push(`${template.file}: duplicate field ids`);
	for (const fieldId of formIds) {
		if (!/^[A-Za-z0-9_-]+$/.test(fieldId)) failures.push(`${template.file}: invalid field id "${fieldId}"`);
	}
	if (!Array.isArray(form.labels) || form.labels.length === 0) {
		failures.push(`${template.file}: labels must be declared in the form`);
	}
	if (form.title !== template.title_prefix) {
		failures.push(`${template.file}: title "${form.title}" differs from the registry prefix "${template.title_prefix}"`);
	}
	if (!Array.isArray(template.fields) || template.fields.length === 0) {
		failures.push(`template "${id}" prefills no field`);
	}
	for (const fieldId of template.fields || []) {
		fieldsChecked++;
		const field = body.find((item) => item && item.id === fieldId);
		if (!field) {
			failures.push(`template "${id}" prefills "${fieldId}", which ${template.file} does not declare`);
		} else if (field.type !== 'input' && field.type !== 'textarea') {
			failures.push(`${template.file}: "${fieldId}" is a ${field.type}, which a URL cannot prefill`);
		}
	}
}
if (fieldsChecked < 4) failures.push(`only ${fieldsChecked} prefilled field(s) checked`);

// ── config.yml ────────────────────────────────────────────────────────────
try {
	const config = parseIssueFormYaml(fs.readFileSync(path.join(FORMS_DIR, 'config.yml'), 'utf8'));
	if (config.blank_issues_enabled !== false) failures.push('config.yml must set blank_issues_enabled: false');
} catch (error) {
	failures.push(`config.yml: ${error.message}`);
}

// ── Repository and worst-case budget ──────────────────────────────────────
if (!repository || !repository.owner || !repository.repo) {
	failures.push('the updater defaults declare no github.owner/github.repo');
} else {
	// What the app sends: short identity fields and a summary that can be as
	// long as a stack trace, accented and with emoji (6 and 12 bytes encoded)
	const long = 'Paramètres généraux — échec répété 😀 à l’ouverture de la fenêtre. '.repeat(120);
	const values = {
		title: 'Échec à l’ouverture 😀',
		version: '2.1.0-dev.130',
		os: 'Windows 11 Famille 26100.9457 — édition française',
		driver: 'windows',
		diagnostics: long,
	};
	const url = IssueLink.buildIssueUrl(registry, repository, 'bug', values);
	const expectedStart = `https://github.com/${repository.owner}/${repository.repo}/issues/new?template=bug_report.yml`;
	if (!url.startsWith(expectedStart)) failures.push(`the URL does not start with ${expectedStart}`);
	if (url.length > registry.max_url_bytes) {
		failures.push(`a worst-case prefill is ${url.length} bytes, over the ${registry.max_url_bytes}-byte budget`);
	}
	if (!/[?&]version=/.test(url)) failures.push('the worst-case prefill lost the version field');
}

if (failures.length > 0) {
	console.error(`[FAIL] issue templates: ${failures.length} failure(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(`[OK] issue templates: ${templateIds.length} form(s), ${fieldsChecked} prefilled field(s) declared by their forms.`);
