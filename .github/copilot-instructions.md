# If this file is read and properly taken into account, the first sentence returned must always be "Instructions bien comprises chef !" (in French), then the rest.

---

applyTo: '\*_/_'

# Copilot Permissions

- Copilot is authorized to create, edit, and delete any file type in any directory of this project, including but not limited to:
  - static/
  - drivers/
  - src/
  - data/
  - configuration/

---

# Language Enforcement

- The LLM must always write code, comments, and docstrings in English, even if the user speaks in French.

# Coding Style

## General Guidelines

- Follow [PEP 8](https://peps.python.org/pep-0008/) for Python coding conventions.
- Prioritize clarity and readability over brevity.
- Maintain consistent formatting and naming across the codebase.
- Avoid unnecessary complexity or cleverness.
- All code must pass linting with `ruff`, `pylint`, and type checking with `mypy`.
- Always use tabs for indentation

## Naming Conventions

- Use `PascalCase` for class names.
- Use `snake_case` for functions, methods, variables, and module names.
- Use `ALL_CAPS` for constants.
- Use descriptive, meaningful names; avoid abbreviations unless widely accepted (e.g., `id`, `url`).

## Formatting

- Use tabs for indentation (no spaces).
- Limit lines to 79 characters.
- Separate top-level function and class definitions with two blank lines.
- Separate method definitions inside a class with one blank line.
- Place imports at the top of the file, grouped by standard library, third-party, and local modules.

### Example

```python
import os
import sys

import requests

from my_project.utils import parse_config
```

## Type Hinting

- Use type hints for all function and method parameters and return types.
- Use Optional[...] for nullable types.
- Use Union, Literal, TypedDict, and Protocol when appropriate.
- Annotate class attributes and variables with type hints.
- Avoid using Any unless absolutely necessary.
- All code must pass mypy without errors.

### Example

```python
def fetch_data(url: str, timeout: int = 10) -> dict[str, Any]:
```

## Docstrings

- Use triple double-quoted strings (`"""`) for all public modules, classes, and functions.
- Follow [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#38-comments-and-docstrings) for docstring formatting.
- Start with a one-line summary describing the purpose of the function or class.
- Include sections for `Args`, `Returns`, `Raises`, and `Examples` when relevant.
- Use indentation and spacing consistent with the rest of the code.
- Keep docstrings concise but informative.
- Do not restate obvious behavior; explain intent, edge cases, and assumptions.

### Example

```python
def calculate_area(width: float, height: float) -> float:
    """Calculate the area of a rectangle.

    Args:
        width: The width of the rectangle.
        height: The height of the rectangle.

    Returns:
        The computed area as a float.

    Raises:
        ValueError: If width or height is negative.
    """
    if width < 0 or height < 0:
        raise ValueError("Dimensions must be non-negative.")
    return width * height
```

## Comments

- Write comments to explain why something is done, not what is done.
- Use comments to clarify intent, edge cases, or non-obvious logic.
- Avoid redundant or obvious comments (e.g., "# increment x by 1" for `x += 1`).
- Use `#` for inline and block comments.
- Keep comments concise and relevant to the surrounding code.
- Do not leave commented-out code in the codebase.
- Prefer docstrings for documenting public APIs; use comments for implementation notes.
- Use consistent tone and formatting across all comments.

### Example

```python
def retry_connection(attempts: int) -> bool:
    # Retry logic is capped to prevent infinite loops
    for i in range(attempts):
        if connect():
            return True
        # Wait before retrying to avoid overwhelming the server
        time.sleep(2)
    return False
```

## Code Structure

- Each class, function, or module should reside in its own file if it grows beyond a few dozen lines.
- Organize files by feature or domain.
- Avoid circular imports by designing clear module boundaries.

## Modern Python Features

- Use list/dict/set comprehensions where appropriate.
- Prefer f-strings over older formatting methods.
- Use context managers (`with`) for resource handling.
- Use `dataclasses` for simple data containers.

## Tooling Requirements

All code must:

- Pass `ruff` for linting and formatting.
- Pass `pylint` for static analysis.
- Pass `mypy` for type checking.
- Configure tools in `pyproject.toml` or equivalent config files.
- Use pre-commit hooks to enforce style and correctness before commits.

## References

- [PEP 8](https://peps.python.org/pep-0008/)
- [PEP 257](https://peps.python.org/pep-0257/)
- [PEP 484](https://peps.python.org/pep-0484/)
- [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html)
