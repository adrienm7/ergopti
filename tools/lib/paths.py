# tools/lib/paths.py

"""
==============================================================================
MODULE: Tooling Shared-Tree Paths (Python)
DESCRIPTION:
The single source of truth for the cross-platform _shared/ tree location used by
Python dev tools (data compaction, TOML formatting, locale checks). Tools used
to each hardcode the literal "static/ergopti_plus/_shared/..." string; this module
centralises it so a future rename of the _shared/ tree only needs editing
SHARED_REL on the one line below.

FEATURES & RATIONALE:
1. One literal: SHARED_REL is the only place the folder name appears across the
   Python toolchain. Everything else derives from it.
2. Both forms: SHARED_DIR (absolute Path) for filesystem access, SHARED_REL
   (repo-relative, forward-slash str) for messages or repo-relative joins.
3. Import-anywhere: scripts add the repo root to sys.path then do
   ``from tools.lib.paths import shared`` (tools/ resolves as a namespace
   package — no __init__.py needed on Python 3.3+).
==============================================================================
"""

from __future__ import annotations

from pathlib import Path

# Repo root is two levels up from tools/lib/ (parents[0]=lib, [1]=tools, [2]=repo).
REPO_ROOT: Path = Path(__file__).resolve().parents[2]

# THE single source of truth for the shared-tree location. Forward-slash,
# repo-relative — a future rename of the _shared/ tree is a one-token edit here.
SHARED_REL: str = "static/ergopti_plus/_shared"

# Absolute path to the _shared/ tree.
SHARED_DIR: Path = REPO_ROOT / SHARED_REL


def shared(*parts: str) -> Path:
	"""Resolves an absolute path inside the _shared/ tree.

	Args:
		*parts: Path segments under _shared/, e.g. "data", "db", "schema.sql".

	Returns:
		Absolute filesystem path.
	"""
	return SHARED_DIR.joinpath(*parts)


def shared_rel(*parts: str) -> str:
	"""Resolves a repo-relative (forward-slash) path inside the _shared/ tree.

	Args:
		*parts: Path segments under _shared/.

	Returns:
		Repo-relative path string, e.g. "static/ergopti_plus/_shared/data/locales".
	"""
	return "/".join((SHARED_REL, *parts))
