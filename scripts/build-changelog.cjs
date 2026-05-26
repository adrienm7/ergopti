// scripts/build-changelog.cjs

/**
 * ==============================================================================
 * MODULE: Changelog Builder
 * DESCRIPTION:
 * Generates a CHANGELOG.md from the full git history using Conventional Commits.
 *
 * FEATURES & RATIONALE:
 * 1. Keep-a-Changelog format: sections per version tag plus an "Unreleased" block,
 *    so readers can track changes across releases at a glance.
 * 2. Scope grouping: within each type section, entries are sub-grouped by scope
 *    to make large changelogs scannable.
 * 3. No external dependencies: uses only Node.js built-ins and git CLI so the
 *    script works in any environment without a separate install step.
 * 4. Idempotent: every run overwrites CHANGELOG.md from scratch, which prevents
 *    stale entries from accumulating if commits are rewritten.
 * ==============================================================================
 */

"use strict";

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");




// ==========================================
// ==========================================
// ======= 1/ Constants and metadata =======
// ==========================================
// ==========================================

// Ordered list of Conventional Commits types — features visible first.
const TYPES = ["feat", "fix", "perf", "refactor", "style", "docs", "test", "chore"];

const HEADINGS = {
	feat:     "Features",
	fix:      "Bug Fixes",
	perf:     "Performance",
	refactor: "Refactoring",
	style:    "Style",
	docs:     "Documentation",
	test:     "Tests",
	chore:    "Chores",
};

// Captures type, optional scope, optional breaking-change marker, and subject.
const TYPE_RE = /^([a-z]+)(?:\(([^)]+)\))?(!)?:\s+(.+)$/;

const REPO_URL = "https://github.com/AdrienMoyaux/ergopti";

const OUTPUT_PATH = path.resolve(__dirname, "..", "CHANGELOG.md");




// =========================================
// =========================================
// ======= 2/ Git helpers ==================
// =========================================
// =========================================

/**
 * Runs a git command and returns trimmed stdout, or "" on failure.
 * @param {string} cmd - The full git command string.
 * @returns {string} Stdout of the command.
 */
function git(cmd) {
	try {
		return execSync(`git ${cmd}`, { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim();
	} catch {
		return "";
	}
}

/**
 * Returns all version tags (vX.Y.Z or vX.Y.Z-suffix) sorted newest-first by
 * semver, filtering out the automated dev snapshot tags.
 * @returns {string[]} Sorted array of version tag names.
 */
function getVersionTags() {
	const raw = git("tag --list --sort=-v:refname");
	return raw
		.split("\n")
		.map((t) => t.trim())
		.filter((t) => /^v\d+\.\d+/.test(t));
}

/**
 * Returns the ISO date of a tag or commit reference.
 * @param {string} ref - A tag name or commit SHA.
 * @returns {string} Date in YYYY-MM-DD format, or empty string.
 */
function getDate(ref) {
	const raw = git(`log -1 --format=%ci "${ref}"`);
	return raw ? raw.slice(0, 10) : "";
}

/**
 * Returns all non-merge commits between two refs as structured objects.
 * Uses ASCII unit / record separators to survive bodies with special chars.
 * @param {string} from - Exclusive lower bound (tag or SHA); use "" for all history.
 * @param {string} to   - Inclusive upper bound (tag, SHA, or HEAD).
 * @returns {{ sha: string, subject: string, body: string }[]} Commit list.
 */
function getCommits(from, to) {
	const range = from ? `"${from}".."${to}"` : `"${to}"`;
	const fmt = "%H%x1f%s%x1f%b%x1e";
	const raw = git(`log ${range} --no-merges --pretty=format:${fmt}`);
	if (!raw) return [];

	return raw
		.split("\x1e")
		.map((r) => r.replace(/^\n/, ""))
		.filter(Boolean)
		.map((r) => {
			const parts = r.split("\x1f");
			return {
				sha:     (parts[0] || "").trim(),
				subject: (parts[1] || "").trim(),
				body:    (parts[2] || "").trim(),
			};
		})
		.filter((c) => c.sha);
}




// ==========================================
// ==========================================
// ======= 3/ Rendering helpers =============
// ==========================================
// ==========================================

/**
 * Parses a conventional commit subject into its components.
 * @param {string} subject - The raw commit subject line.
 * @returns {{ type: string|null, scope: string|null, breaking: boolean, description: string }}
 */
function parseSubject(subject) {
	const m = TYPE_RE.exec(subject);
	if (!m) return { type: null, scope: null, breaking: false, description: subject };
	const [, type, scope, bang, description] = m;
	return {
		type,
		scope:    scope || null,
		breaking: !!bang,
		description,
	};
}

/**
 * Builds the markdown bullet line for one commit entry.
 * @param {{ sha: string, subject: string, body: string }} commit
 * @returns {{ type: string|null, scope: string|null, line: string }} Parsed entry.
 */
function buildEntry(commit) {
	const { type, scope, breaking, description } = parseSubject(commit.subject);

	// Capitalise first letter for readability.
	const desc = description.charAt(0).toUpperCase() + description.slice(1);

	let label;
	if (breaking) {
		label = scope ? `**⚠️ BREAKING (${scope}): ${desc}**` : `**⚠️ BREAKING: ${desc}**`;
	} else if (scope) {
		label = `**${scope}:** ${desc}`;
	} else {
		label = desc;
	}

	return { type, scope, line: `- ${label}` };
}

/**
 * Renders one version section (or the Unreleased block) to markdown.
 * @param {string}  heading  - Section heading, e.g. "## [v1.2.0] - 2025-01-15".
 * @param {{ sha: string, subject: string, body: string }[]} commits
 * @returns {string} Markdown block.
 */
function renderSection(heading, commits) {
	if (!commits.length) return "";

	// Group entries by type, then by scope within each type.
	/** @type {Map<string, Map<string, string[]>>} */
	const byType = new Map();
	/** @type {string[]} */
	const other = [];

	for (const commit of commits) {
		const { type, scope, line } = buildEntry(commit);
		if (!type || !HEADINGS[type]) {
			other.push(line);
			continue;
		}
		if (!byType.has(type)) byType.set(type, new Map());
		const byScope = byType.get(type);
		const key = scope || "";
		if (!byScope.has(key)) byScope.set(key, []);
		byScope.get(key).push(line);
	}

	const lines = [heading, ""];

	for (const t of TYPES) {
		if (!byType.has(t)) continue;
		lines.push(`### ${HEADINGS[t]}`, "");
		const byScope = byType.get(t);

		// Scoped entries first (alphabetical scope), then unscoped.
		const scopes = [...byScope.keys()].sort((a, b) => {
			if (a === "") return 1;
			if (b === "") return -1;
			return a.localeCompare(b);
		});

		for (const scope of scopes) {
			for (const line of byScope.get(scope)) {
				lines.push(line);
			}
		}
		lines.push("");
	}

	if (other.length) {
		lines.push("### Other", "");
		for (const line of other) lines.push(line);
		lines.push("");
	}

	return lines.join("\n");
}




// =====================================
// =====================================
// ======= 4/ Entry point ==============
// =====================================
// =====================================

/**
 * Generates CHANGELOG.md from the full git history and writes it to disk.
 * @returns {void}
 */
function main() {
	const tags = getVersionTags();
	const sections = [];

	// Header block — standard Keep-a-Changelog preamble.
	sections.push(
		"# Changelog",
		"",
		"All notable changes to this project will be documented in this file.",
		"",
		"The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)",
		"and this project adheres to [Conventional Commits](https://www.conventionalcommits.org/).",
		"",
	);

	// Unreleased: commits after the most recent version tag (or all commits if none).
	const latestTag = tags[0] || null;
	const unreleasedCommits = getCommits(latestTag, "HEAD");

	if (unreleasedCommits.length) {
		const block = renderSection("## [Unreleased]", unreleasedCommits);
		if (block) sections.push(block);
	}

	// One section per version tag, from newest to oldest.
	for (let i = 0; i < tags.length; i++) {
		const tag = tags[i];
		const prevTag = tags[i + 1] || null;
		const date = getDate(tag);
		const heading = `## [${tag}]${date ? ` — ${date}` : ""}`;
		const commits = getCommits(prevTag, tag);

		if (!commits.length) {
			// Include the heading even for empty ranges so all releases are listed.
			sections.push(heading, "", "_No conventional commits in this release._", "");
			continue;
		}

		const block = renderSection(heading, commits);
		if (block) sections.push(block);
	}

	// Footer: comparison links per Keep-a-Changelog convention.
	sections.push("---", "");
	if (latestTag) {
		sections.push(
			`[Unreleased]: ${REPO_URL}/compare/${latestTag}...HEAD`,
		);
	}
	for (let i = 0; i < tags.length; i++) {
		const tag = tags[i];
		const prev = tags[i + 1];
		if (prev) {
			sections.push(`[${tag}]: ${REPO_URL}/compare/${prev}...${tag}`);
		} else {
			sections.push(`[${tag}]: ${REPO_URL}/releases/tag/${tag}`);
		}
	}
	sections.push("");

	const output = sections.join("\n");
	fs.writeFileSync(OUTPUT_PATH, output, "utf8");
	console.log(`CHANGELOG.md written (${output.split("\n").length} lines).`);
}

main();
