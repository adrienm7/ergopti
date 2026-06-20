# tools/lib/paths.py

"""
==============================================================================
MODULE: Tooling Shared-Tree Paths (Python)
DESCRIPTION:
The single source of truth for the cross-platform shared/ tree location used by
Python dev tools (data compaction, TOML formatting, locale checks). Tools used
to each hardcode the literal "static/ergopti_plus/shared/..." string; this module
centralises it so a repo-layout rename (shared/ -> _shared/) only needs editing
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
# repo-relative — a shared/ -> _shared/ rename is a one-token edit here.
SHARED_REL: str = "static/ergopti_plus/shared"

# Absolute path to the shared/ tree.
SHARED_DIR: Path = REPO_ROOT / SHARED_REL


def shared(*parts: str) -> Path:
	"""Resolves an absolute path inside the shared/ tree.

	Args:
		*parts: Path segments under shared/, e.g. "data", "db", "schema.sql".

	Returns:
		Absolute filesystem path.
	"""
	return SHARED_DIR.joinpath(*parts)


def shared_rel(*parts: str) -> str:
	"""Resolves a repo-relative (forward-slash) path inside the shared/ tree.

	Args:
		*parts: Path segments under shared/.

	Returns:
		Repo-relative path string, e.g. "static/ergopti_plus/shared/locales".
	"""
	return "/".join((SHARED_REL, *parts))
