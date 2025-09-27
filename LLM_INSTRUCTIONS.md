# LLM Coding Instructions for Ergopti Project

## Language and Style
- **All code, comments, and docstrings must be written in English.**
- Use clear, concise, and professional language.
- Variable, function, and class names must be in English and descriptive.

## Python Coding Standards
- Use [Google style docstrings](https://google.github.io/styleguide/pyguide.html#38-comments-and-docstrings) for all functions, classes, and modules.
- All functions and methods must include type hints for arguments and return values.
- Use snake_case for function and variable names, PascalCase for class names.
- Imports must be at the top of the file, grouped as: standard library, third-party, local imports.
- Use 4 spaces for indentation.
- Limit lines to 120 characters.
- Use f-strings for string formatting.
- Avoid non-ASCII characters in code and comments unless strictly necessary for functionality.

## Comments
- Write comments in English only.
- Comments must explain why, not just what.
- Prefer docstrings over inline comments for function/class/module documentation.

## Documentation
- Every public function, class, and module must have a Google style docstring.
- Docstrings must include Args, Returns, Raises (if applicable), and Examples (if useful).

## General LLM Instructions
- Never generate code or comments in French or any language other than English.
- If you encounter French, translate it to English.
- If you see code or comments not following these rules, refactor them.
- Always prefer clarity and maintainability over cleverness.
- If a convention is unclear, follow the latest [PEP 8](https://peps.python.org/pep-0008/) and [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html).

## Example Function
```python
from typing import List

def add_numbers(a: int, b: int) -> int:
    """
    Adds two integers.

    Args:
        a (int): The first integer.
        b (int): The second integer.

    Returns:
        int: The sum of a and b.

    Example:
        >>> add_numbers(2, 3)
        5
    """
    return a + b
```

---

**All contributors and LLMs must follow these instructions for all code, comments, and documentation in this repository.**
