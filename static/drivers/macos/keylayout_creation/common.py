import re
from pathlib import Path


def get_file_paths(
    input_path: str = None, directory_path: str = None, suffix: str = ""
):
    overwrite = False
    if directory_path:
        base_dir = Path(directory_path)
    else:
        base_dir = (
            Path(__file__).resolve().parent.parent / "raw_kbdedit_keylayouts"
        ).resolve()

    if input_path:
        file_paths = [base_dir / input_path]
        overwrite = True
    else:
        file_paths = list(base_dir.glob(f"*{suffix}.keylayout"))
    return file_paths, overwrite


def read_file(file_path: Path) -> str:
    print(f"Processing: {file_path}")
    with file_path.open("r", encoding="utf-8") as f:
        return f.read()


def write_file(file_path: Path, content: str):
    with file_path.open("w", encoding="utf-8") as f:
        f.write(content)
    print(f"Modified and saved: {file_path}")


def extract_keymap(content, index):
    match = re.search(
        rf'(<keyMap index="{index}">)(.*?)(</keyMap>)', content, flags=re.DOTALL
    )
    if not match:
        raise ValueError(f'<keyMap index="{index}"> block not found.')
    return match.group(1), match.group(2), match.group(3)


def apply_key_substitutions(content, substitutions):
    for pattern, replacement in substitutions.items():
        content = re.sub(
            rf"\s*<key {pattern}", f"\n\t\t\t{replacement}", content
        )
    return content
