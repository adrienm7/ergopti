#!/usr/bin/env python3
"""One-shot repair: rebuild every static/locales/*.json so strict JSON parses.

Two pre-existing bugs in the locale files needed a single coordinated fix:

1. Literal ``\\n``/``\\r``/``\\t`` bytes appear inside JSON string values,
	 which strict JSON parsers reject. The locales were produced by a tool
	 that did not escape multi-line UI labels.

2. A bulk insert that added new keys (e.g. ``menu.llm.subtitle``,
	 ``ollama.deps_step_checking``) left double commas (``,,``) between
	 the new and surrounding entries, producing invalid syntax at several
	 locations per file.

The script walks each file with a small state machine that tracks whether
the cursor is inside a JSON string. It escapes control characters inside
strings and collapses redundant commas outside strings. Everything else
(indentation, BOM, key order, comments-as-keys, trailing newline) is
preserved byte-for-byte.

Run once, verify with strict ``json.loads``, commit, then delete.
"""

from __future__ import annotations

import glob
import json
import sys
from pathlib import Path




# ==================================
# ==================================
# ======= 1/ Repair Routine ========
# ==================================
# ==================================

def repair(src: str) -> str:
	"""Return ``src`` with control chars inside strings escaped and any
	redundant ``,,`` between object entries collapsed to a single comma."""
	out: list[str] = []
	in_string = False
	escape = False
	i = 0
	n = len(src)
	while i < n:
		ch = src[i]
		if in_string:
			if escape:
				out.append(ch)
				escape = False
				i += 1
				continue
			if ch == "\\":
				out.append(ch)
				escape = True
				i += 1
				continue
			if ch == '"':
				out.append(ch)
				in_string = False
				i += 1
				continue
			# Inside a string: escape any literal control character.
			if ch == "\n":
				out.append("\\n")
				i += 1
				continue
			if ch == "\r":
				out.append("\\r")
				i += 1
				continue
			if ch == "\t":
				out.append("\\t")
				i += 1
				continue
			out.append(ch)
			i += 1
		else:
			if ch == '"':
				in_string = True
				out.append(ch)
				i += 1
				continue
			if ch == ",":
				# Look ahead past whitespace; if the next non-whitespace char
				# is another comma, swallow this one (collapse "," + ",,"
				# sequences down to a single ",").
				j = i + 1
				while j < n and src[j] in " \t\r\n":
					j += 1
				if j < n and src[j] == ",":
					# Skip this comma — the next iteration will keep the next.
					i += 1
					continue
				out.append(ch)
				i += 1
				continue
			out.append(ch)
			i += 1
	return "".join(out)




# ==============================
# ==============================
# ======= 2/ Entrypoint ========
# ==============================
# ==============================

def main() -> int:
	repo_root = Path(__file__).resolve().parent.parent
	locale_glob = str(repo_root / "static" / "locales" / "*.json")
	repaired = 0
	already_ok = 0
	failures: list[str] = []
	for path_str in sorted(glob.glob(locale_glob)):
		path = Path(path_str)
		raw = path.read_text(encoding="utf-8")
		bom = ""
		body = raw
		if body.startswith("﻿"):
			bom = "﻿"
			body = body[1:]
		try:
			json.loads(body)
			already_ok += 1
			print(f"{path.name}: already valid")
			continue
		except json.JSONDecodeError:
			pass
		new_body = repair(body)
		try:
			json.loads(new_body)
		except json.JSONDecodeError as err:
			failures.append(f"{path.name}: still invalid after repair — {err}")
			continue
		path.write_text(bom + new_body, encoding="utf-8", newline="\n")
		repaired += 1
		print(f"{path.name}: repaired")
	print(f"---\nrepaired {repaired}, already valid {already_ok}, failed {len(failures)}")
	for line in failures:
		print(line, file=sys.stderr)
	return 0 if not failures else 1


if __name__ == "__main__":
	raise SystemExit(main())
