// tools/test/test-editor-format-on-save.cjs

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const readJson = (relativePath) =>
	JSON.parse(fs.readFileSync(path.resolve(ROOT, relativePath), 'utf8'));

const vscode = readJson('.vscode/settings.json');
const extensions = readJson('.vscode/extensions.json');
const zed = readJson('.zed/settings.json');
const pkg = readJson('package.json');
const prettierConfig = readJson('.prettierrc');

const vscodeLanguages = [
	'javascript',
	'javascriptreact',
	'typescript',
	'typescriptreact',
	'json',
	'jsonc',
	'css',
	'scss',
	'less',
	'html',
	'markdown',
	'yaml',
	'svelte'
];

assert.ok(vscodeLanguages.length >= 10, 'the VS Code contract must cover the repository formats');
assert.strictEqual(
	vscode['editor.formatOnSave'],
	false,
	'VS Code formatting must be opt-in by language'
);
assert.strictEqual(vscode['files.eol'], '\n', 'VS Code must create and save text files with LF');
assert.strictEqual(
	vscode['prettier.resolveGlobalModules'],
	false,
	'VS Code must not select a global Prettier'
);

for (const language of vscodeLanguages) {
	assert.deepStrictEqual(
		vscode[`[${language}]`],
		{
			'editor.defaultFormatter': 'esbenp.prettier-vscode',
			'editor.formatOnSave': true,
			'editor.formatOnSaveMode': 'modificationsIfAvailable'
		},
		`VS Code ${language} files must use the repository Prettier on save`
	);
}

const configuredPrettier = fs.realpathSync(path.resolve(ROOT, vscode['prettier.prettierPath']));
const installedPrettier = fs.realpathSync(path.dirname(require.resolve('prettier')));
assert.strictEqual(
	configuredPrettier,
	installedPrettier,
	"VS Code must resolve this checkout's Prettier module"
);

assert.ok(
	extensions.recommendations.includes('esbenp.prettier-vscode'),
	'the Prettier VS Code extension must be recommended'
);
assert.ok(
	extensions.recommendations.includes('svelte.svelte-vscode'),
	'the Svelte language extension must be recommended'
);

const zedLanguages = [
	'JavaScript',
	'TypeScript',
	'TSX',
	'JSON',
	'CSS',
	'SCSS',
	'LESS',
	'HTML',
	'Markdown',
	'YAML',
	'Svelte'
];

assert.ok(zedLanguages.length >= 10, 'the Zed contract must cover the repository formats');
assert.strictEqual(zed.format_on_save, 'off', 'Zed formatting must be opt-in by language');
assert.strictEqual(
	zed.line_ending,
	'prefer_lf',
	'Zed must prefer LF for new files without rewriting existing line endings'
);
for (const language of zedLanguages) {
	assert.deepStrictEqual(
		zed.languages[language],
		{ format_on_save: 'modifications_if_available', formatter: 'prettier' },
		`Zed ${language} files must use the repository Prettier on save`
	);
}

for (const language of ['Lua', 'AutoHotkey', 'AutoHotkey v2']) {
	assert.notStrictEqual(
		zed.languages[language]?.format_on_save,
		'on',
		`${language} must stay outside automatic formatting until a canonical formatter exists`
	);
}

assert.ok(
	pkg.devDependencies?.prettier,
	'the repository must declare the Prettier engine used by both editors'
);
assert.ok(
	pkg.devDependencies?.['prettier-plugin-svelte'],
	'Svelte formatting requires the local plugin'
);
assert.ok(
	prettierConfig.plugins.includes('prettier-plugin-svelte'),
	'the shared Prettier config must load the Svelte plugin'
);
assert.ok(
	!Object.hasOwn(prettierConfig, 'pluginSearchDirs'),
	'Prettier 3 must not receive the removed pluginSearchDirs option'
);
assert.strictEqual(pkg.scripts.lint, 'prettier --check . && eslint .');
assert.strictEqual(pkg.scripts.format, 'prettier --write .');

console.log('OK: VS Code and Zed use the repository Prettier only for supported formats');
