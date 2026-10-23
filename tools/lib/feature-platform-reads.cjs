// tools/lib/feature-platform-reads.cjs

/**
 * Finds driver code that reads a feature the manifest does not declare for that
 * driver. A key declared for other platforms reaches no menu, no default and no
 * template on this one, so the read either fails or silently sees nothing; the
 * declaration is what the generated manifests, the config templates and the
 * onboarding catalogue are built from.
 *
 * Three spellings of a read are recognised in non-comment lines: the full path
 * as a string literal ("llm.trigger.disabled_apps"), the AutoHotkey write batch
 * ({ Section: "llm.trigger", Key: "disabled_apps" }) and the AutoHotkey nested
 * lookup (["llm.trigger"]["disabled_apps"]), plus the macOS preference rows
 * ({ sec = "metrics", key = "menubar_colors" }).
 */
'use strict';

const PLATFORMS = ['ahk', 'hs', 'linux'];

/**
 * Resolves the platforms of one flattened manifest entry, inheriting from its
 * enclosing sections.
 * @param {object} manifest Parsed manifest (needs `sections`).
 * @param {{section: string, platforms?: string[]}} entry One flattened entry.
 * @returns {string[]} Effective platforms.
 */
function entryPlatforms(manifest, entry) {
	if (Array.isArray(entry.platforms) && entry.platforms.length > 0) return entry.platforms;
	const parts = entry.section.split('.');
	while (parts.length > 0) {
		let node = manifest.sections;
		for (const part of parts) node = node?.[part];
		if (Array.isArray(node?.platforms) && node.platforms.length > 0) return node.platforms;
		parts.pop();
	}
	return PLATFORMS;
}

/** Drops full-line comments of Lua, AutoHotkey and JavaScript. */
function codeLines(source) {
	return source
		.split('\n')
		.filter((line) => {
			const trimmed = line.trimStart();
			return !trimmed.startsWith('--') && !trimmed.startsWith(';') && !trimmed.startsWith('//');
		})
		.join('\n');
}

/** @param {string} text Literal text. @returns {string} Regular-expression source. */
function escapeRegExp(text) {
	return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Lists every read of a feature by a driver the feature is not declared for.
 * @param {object} manifest Parsed manifest with a flattened `entries` array.
 * @param {Array<{driver: string, rel: string, source: string}>} sources Driver
 *   code, one record per file, `driver` being a platform id (ahk, hs, linux).
 * @returns {string[]} One message per offending read.
 */
function platformReadViolations(manifest, sources) {
	const violations = [];
	const prepared = sources.map(({ driver, rel, source }) => ({
		driver,
		rel,
		text: codeLines(source)
	}));
	for (const entry of manifest.entries) {
		const platforms = entryPlatforms(manifest, entry);
		const path = `${entry.section}.${entry.id}`;
		const section = escapeRegExp(entry.section);
		const id = escapeRegExp(entry.id);
		const patterns = [
			new RegExp(`["']${escapeRegExp(path)}["']`),
			new RegExp(`Section:\\s*"${section}",\\s*Key:\\s*"${id}"`),
			new RegExp(`\\["${section}"\\]\\["${id}"\\]`),
			new RegExp(`sec\\s*=\\s*"${section}"[^}\\n]*key\\s*=\\s*"${id}"`)
		];
		for (const { driver, rel, text } of prepared) {
			if (platforms.includes(driver) || !text.includes(entry.id)) continue;
			if (patterns.some((pattern) => pattern.test(text)))
				violations.push(
					`${driver} reads ${path} (${rel}) but the manifest declares it for ${platforms.join(', ')}`
				);
		}
	}
	return violations;
}

module.exports = { PLATFORMS, entryPlatforms, platformReadViolations };
