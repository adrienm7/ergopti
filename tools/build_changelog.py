#!/usr/bin/env python3
"""
==============================================================================
MODULE: Release Changelog Builder
DESCRIPTION:
Aggregates every commit between the previous release tag and the current one,
groups them by Conventional Commits type, and emits a markdown changelog block
that goes above the platform install instructions on the GitHub release page.

FEATURES & RATIONALE:
1. Unified across channels: the only thing that changes between dev pushes
	and main releases is the "previous tag" lookup; the rest of the rendering
	logic is identical so both channels produce comparable changelogs.
2. Body inclusion: each commit's body is rendered indented under its bullet
	so the rationale the developer wrote in the commit message surfaces on
	the release page — no need to click each commit to read why something
	changed.
3. Conventional Commits grouping: commits sort into Features / Fix /
	Performance / Refactoring / Style / Documentation / Tests / Chores in a
	fixed order so the reader scanning for value sees Features first.
4. Robustness: pure Python, no bash escape gymnastics. Replaces the previous
	bash implementation that surfaced quoting and ``set -e`` failure modes
	on the GitHub Actions runner.
==============================================================================
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from collections import defaultdict




# ============================================
# ============================================
# ======= 1/ Constants =======================
# ============================================
# ============================================

# Conventional Commits type → human heading. Order matches the section order
# the user wants the changelog to read in: features first (most visible to
# the reader who is here for what's new), then fixes, then the rest.
TYPES = ["feat", "fix", "perf", "refactor", "style", "docs", "test", "chore"]

HEADINGS = {
	"feat":     "Features",
	"fix":      "Fix",
	"perf":     "Performance",
	"refactor": "Refactoring",
	"style":    "Style",
	"docs":     "Documentation",
	"test":     "Tests",
	"chore":    "Chores",
}

# Pattern: ``type(scope)?!?: subject``. Captures type, scope (without parens),
# breaking-change marker, and the rest of the subject.
TYPE_RE = re.compile(r"^([a-z]+)(?:\(([^)]+)\))?(!)?:\s+(.+)$")

# Co-author trailer pattern. Project rule forbids AI / bot credits, so any
# leftover trailer is stripped from the rendered body.
COAUTHOR_RE = re.compile(r"^Co-[Aa]uthored-[Bb]y:", re.MULTILINE)




# =============================================
# =============================================
# ======= 2/ Git helpers ======================
# =============================================
# =============================================

def run_git(*args: str) -> str:
	"""Run a git command and return its stdout. Returns "" on failure."""
	try:
		return subprocess.check_output(
			("git",) + args,
			stderr=subprocess.DEVNULL,
			text=True,
		)
	except subprocess.CalledProcessError:
		return ""


def previous_tag(event: str, current_tag: str) -> str | None:
	"""Resolve the previous release tag based on the workflow event.

	- ``push`` (dev pushes): most recent tag of any kind reachable from
		the parent of HEAD — so a dev release covers every commit since
		the last dev OR main release, whichever was newer.
	- otherwise (release / workflow_dispatch on a vX.Y.Z): most recent
		``vX.Y.Z`` tag excluding the current one.

	Returns ``None`` when no prior tag exists (first release ever).
	"""
	if event == "push":
		tag = run_git("describe", "--tags", "--abbrev=0", "HEAD^").strip()
		return tag or None

	# Stable channel: sorted SemVer tags, drop the current one, take the head.
	listed = run_git("tag", "--list", "v[0-9]*.[0-9]*.[0-9]*", "--sort=-v:refname")
	for raw in listed.splitlines():
		line = raw.strip()
		if line and line != current_tag:
			return line
	return None


def collect_commits(prev_tag: str, current_tag: str) -> list[dict[str, str]]:
	"""Return one dict per commit in ``prev_tag..current_tag`` with
	``sha`` / ``subject`` / ``body``. Uses ASCII unit / record separators so
	commit bodies containing newlines, tabs, parentheses or quotes survive
	the shell parsing unscathed.
	"""
	fmt = "%H%x1f%s%x1f%b%x1e"
	out = run_git(
		"log",
		f"{prev_tag}..{current_tag}",
		"--no-merges",
		f"--pretty=format:{fmt}",
	)
	commits: list[dict[str, str]] = []
	for record in out.split("\x1e"):
		record = record.strip("\n")
		if not record:
			continue
		parts = record.split("\x1f", 2)
		if len(parts) < 3:
			continue
		sha, subject, body = parts
		commits.append({"sha": sha, "subject": subject, "body": body})
	return commits




# ====================================================
# ====================================================
# ======= 3/ Rendering helpers ========================
# ====================================================
# ====================================================

def clean_body(body: str) -> str:
	"""Drop Co-Authored-By trailers, strip leading / trailing blank lines,
	then indent every remaining line by 2 spaces so it renders as prose under
	its parent bullet in markdown.
	"""
	lines = body.splitlines()
	# Strip Co-Authored-By trailers (project rule: no AI / bot credits).
	lines = [ln for ln in lines if not COAUTHOR_RE.match(ln)]
	# Strip leading blanks.
	while lines and not lines[0].strip():
		lines.pop(0)
	# Strip trailing blanks.
	while lines and not lines[-1].strip():
		lines.pop()
	if not lines:
		return ""
	return "\n".join("  " + ln for ln in lines)


def classify(commit: dict[str, str]) -> tuple[str | None, str]:
	"""Return ``(type, bullet_line)``. ``type`` is ``None`` for commits whose
	subject does not match the Conventional Commits pattern — those land in
	the ``Other`` section so nothing silently disappears.
	"""
	m = TYPE_RE.match(commit["subject"])
	if not m:
		return None, f"- {commit['subject']}"
	ctype, scope, breaking, rest = m.groups()
	if breaking:
		rest = f"⚠️ {rest}"
	if scope:
		rest = f"**{scope}:** {rest}"
	return ctype, f"- {rest}"


def render(prev_tag: str | None, commits: list[dict[str, str]]) -> str:
	"""Compose the full changelog markdown block."""
	groups: dict[str, list[str]] = defaultdict(list)
	other: list[str] = []
	for commit in commits:
		ctype, bullet = classify(commit)
		body_block = clean_body(commit["body"])
		entry = bullet + (("\n" + body_block) if body_block else "")
		entry += "\n"
		if ctype and ctype in HEADINGS:
			groups[ctype].append(entry)
		else:
			other.append(entry)

	repo = os.environ.get("GITHUB_REPOSITORY", "")
	out_lines: list[str] = ["## Changelog", ""]
	if prev_tag:
		out_lines.append(
			f"_Commits since "
			f"[`{prev_tag}`](https://github.com/{repo}/releases/tag/{prev_tag})._"
		)
		out_lines.append("")

	for t in TYPES:
		entries = groups.get(t)
		if not entries:
			continue
		out_lines.append(f"### {HEADINGS[t]}")
		out_lines.append("")
		out_lines.append("".join(entries))

	if other:
		out_lines.append("### Other")
		out_lines.append("")
		out_lines.append("".join(other))

	out_lines.append("---")
	out_lines.append("")
	return "\n".join(out_lines)


def render_first_release(sha: str) -> str:
	"""Fallback when no prior tag exists — surface the single commit's title
	and body verbatim so the release page is never empty.
	"""
	subject = run_git("log", "-1", "--pretty=format:%s", sha).strip()
	body = run_git("log", "-1", "--pretty=format:%b", sha).strip()
	out = ["## Changelog", "", f"### {subject}", ""]
	if body:
		out.append(body)
		out.append("")
	out.append("---")
	out.append("")
	return "\n".join(out)




# ======================================
# ======================================
# ======= 4/ Entry point ===============
# ======================================
# ======================================

def main() -> int:
	event = os.environ.get("EVENT", "")
	tag = os.environ.get("TAG", "")
	sha = os.environ.get("SHA", "")

	prev_tag = previous_tag(event, tag)
	if not prev_tag:
		sys.stdout.write(render_first_release(sha))
		return 0

	commits = collect_commits(prev_tag, tag)
	if not commits:
		# Tag exists but no commits between it and HEAD — emit an empty block
		# so the next step's concatenation is a no-op.
		return 0

	sys.stdout.write(render(prev_tag, commits))
	return 0


if __name__ == "__main__":
	sys.exit(main())
