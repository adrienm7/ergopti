"""
Generate Alfred snippets for Magic hotstrings and Repeat patterns.

Creates .alfredsnippets files (ZIP archives):
- Magic.alfredsnippets: hotstrings from magicReplacements.json with case handling
- Repeat.alfredsnippets: letter combinations (ab -> abb) with case handling

Configuration:
- Modify MAGIC_CONFIG and REPEAT_CONFIG in main() to customize prefix/suffix
- prefix: text added before each snippet keyword (e.g., "magic_" -> "magic_hello")
- suffix: text added after each snippet keyword (e.g., "★" -> "hello★")

Examples of different configurations:
- No prefix, star suffix: prefix="", suffix="★" -> "hello★"
- Colon prefix, no suffix: prefix=":", suffix="" -> ":hello"
- Magic prefix, exclamation suffix: prefix="m:", suffix="!" -> "m:hello!"
"""

import json
import tempfile
import uuid
import zipfile
from pathlib import Path
from typing import Dict


def generate_uuid() -> str:
    """Generate a UUID in uppercase format matching Alfred's convention."""
    return str(uuid.uuid4()).upper()


def apply_case_to_text(original_trigger: str, target_text: str) -> str:
    """Apply the case pattern from trigger to the target text.

    Args:
        original_trigger: The trigger text that defines the case pattern
        target_text: The text to apply the case pattern to

    Returns:
        The target text with case applied based on the trigger pattern
    """
    if original_trigger.isupper():
        return target_text.upper()
    elif original_trigger.istitle():
        return target_text.capitalize()
    else:
        return target_text.lower()


def create_snippet_json(trigger: str, result: str, uid: str) -> Dict:
    """Create a snippet JSON structure."""
    return {
        "alfredsnippet": {
            "uid": uid,
            "name": f"{trigger} ➜ {result}",
            "keyword": trigger,
            "snippet": result,
        }
    }


def create_info_plist(prefix: str = "", suffix: str = "★") -> str:
    """Create the info.plist content for Alfred snippets.

    Args:
        prefix: The prefix to add before snippet keywords
        suffix: The suffix to add after snippet keywords

    Returns:
        The XML content for info.plist
    """
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>snippetkeywordprefix</key>
	<string>{prefix}</string>
	<key>snippetkeywordsuffix</key>
	<string>{suffix}</string>
</dict>
</plist>"""


def create_alfredsnippets_file(
    output_path: Path,
    snippets_data: list,
    collection_name: str,
    prefix: str = "",
    suffix: str = "★",
) -> None:
    """Create a .alfredsnippets file (ZIP archive) from snippets data.

    Args:
        output_path: Directory where to create the .alfredsnippets file
        snippets_data: List of snippet data dictionaries
        collection_name: Name of the collection (used for filename)
        prefix: Prefix for snippet keywords
        suffix: Suffix for snippet keywords
    """
    print(f"Creating {collection_name}.alfredsnippets...")

    # Create a temporary directory
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # Create info.plist with custom prefix and suffix
        info_plist_path = temp_path / "info.plist"
        with open(info_plist_path, "w", encoding="utf-8") as f:
            f.write(create_info_plist(prefix, suffix))

        # Create JSON files for each snippet
        for snippet_data in snippets_data:
            uid = snippet_data["alfredsnippet"]["uid"]
            json_file = temp_path / f"{uid}.json"
            with open(json_file, "w", encoding="utf-8") as f:
                json.dump(snippet_data, f, indent=2, ensure_ascii=False)

        # Create ZIP archive with .alfredsnippets extension
        archive_path = output_path / f"{collection_name}.alfredsnippets"
        with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            # Add all files from temp directory
            for file_path in temp_path.rglob("*"):
                if file_path.is_file():
                    # Use relative path within the archive
                    arcname = file_path.relative_to(temp_path)
                    zipf.write(file_path, arcname)

    print(f"Created {archive_path} with {len(snippets_data)} snippets")


def generate_magic_snippets(
    output_dir: Path,
    replacements: Dict[str, str],
    prefix: str = "",
    suffix: str = "★",
) -> None:
    """Generate Magic hotstring snippets with case sensitivity.

    Args:
        output_dir: Directory where to create the .alfredsnippets file
        replacements: Dictionary of trigger -> replacement mappings
        prefix: Prefix for snippet keywords
        suffix: Suffix for snippet keywords
    """
    print("Generating Magic snippets...")

    snippets_data = []

    for trigger, replacement in replacements.items():
        # Generate case variants
        variants = []

        # Original (lowercase)
        variants.append((trigger, replacement))

        # Title case (first letter uppercase)
        if (
            trigger.lower() != trigger.upper()
        ):  # Skip single letters that don't change
            title_trigger = trigger.capitalize()
            title_replacement = apply_case_to_text(title_trigger, replacement)
            variants.append((title_trigger, title_replacement))

        # Uppercase
        if len(trigger) > 1:  # Only for multi-character triggers
            upper_trigger = trigger.upper()
            upper_replacement = apply_case_to_text(upper_trigger, replacement)
            variants.append((upper_trigger, upper_replacement))

        # Create snippet data for each variant
        for variant_trigger, variant_replacement in variants:
            uid = generate_uuid()
            snippet_data = create_snippet_json(
                variant_trigger, variant_replacement, uid
            )
            snippets_data.append(snippet_data)

    # Create .alfredsnippets file with custom prefix and suffix
    create_alfredsnippets_file(
        output_dir, snippets_data, "Magic", prefix, suffix
    )
    print(f"Generated {len(snippets_data)} Magic snippets")


def generate_repeat_snippets(
    output_dir: Path, prefix: str = "", suffix: str = "★"
) -> None:
    """Generate Repeat snippets (ab -> abb) with case sensitivity.

    Args:
        output_dir: Directory where to create the .alfredsnippets file
        prefix: Prefix for snippet keywords
        suffix: Suffix for snippet keywords
    """
    print("Generating Repeat snippets...")

    snippets_data = []
    alphabet = "abcdefghijklmnopqrstuvwxyz"

    for first_letter in alphabet:
        for second_letter in alphabet:
            if first_letter == second_letter:
                continue  # Skip same letters (aa -> aaa doesn't make sense)

            # Generate case variants
            variants = []

            # lowercase: ab -> abb
            trigger_lower = first_letter + second_letter
            result_lower = first_letter + second_letter + second_letter
            variants.append((trigger_lower, result_lower))

            # Title case: Ab -> Abb
            trigger_title = first_letter.upper() + second_letter
            result_title = first_letter.upper() + second_letter + second_letter
            variants.append((trigger_title, result_title))

            # Uppercase: AB -> ABB
            trigger_upper = first_letter.upper() + second_letter.upper()
            result_upper = (
                first_letter.upper()
                + second_letter.upper()
                + second_letter.upper()
            )
            variants.append((trigger_upper, result_upper))

            # Create snippet data for each variant
            for variant_trigger, variant_result in variants:
                uid = generate_uuid()
                snippet_data = create_snippet_json(
                    variant_trigger, variant_result, uid
                )
                snippets_data.append(snippet_data)

    # Create .alfredsnippets file with custom prefix and suffix
    create_alfredsnippets_file(
        output_dir, snippets_data, "Repeat", prefix, suffix
    )
    print(f"Generated {len(snippets_data)} Repeat snippets")


def main():
    """Main function to generate Alfred snippets."""
    script_dir = Path(__file__).parent
    output_dir = script_dir

    # Configuration for snippet collections
    # You can modify these values to customize prefix/suffix for each collection
    MAGIC_CONFIG = {"prefix": "", "suffix": "★"}

    REPEAT_CONFIG = {"prefix": "", "suffix": "★"}

    magic_replacements_file = (
        script_dir.parent.parent.parent
        / "src"
        / "lib"
        / "keyboard"
        / "data"
        / "magicReplacements.json"
    )

    # Load magic replacements
    if not magic_replacements_file.exists():
        print(f"Error: {magic_replacements_file} not found")
        return

    with open(magic_replacements_file, "r", encoding="utf-8") as f:
        magic_replacements = json.load(f)

    # Clean up old directories if they exist
    old_magic_dir = output_dir / "Magic"
    old_repeat_dir = output_dir / "Repeat"

    if old_magic_dir.exists():
        import shutil

        shutil.rmtree(old_magic_dir)
        print("Removed old Magic directory")

    if old_repeat_dir.exists():
        import shutil

        shutil.rmtree(old_repeat_dir)
        print("Removed old Repeat directory")

    # Generate snippets as .alfredsnippets files with custom configurations
    generate_magic_snippets(
        output_dir,
        magic_replacements,
        prefix=MAGIC_CONFIG["prefix"],
        suffix=MAGIC_CONFIG["suffix"],
    )
    generate_repeat_snippets(
        output_dir,
        prefix=REPEAT_CONFIG["prefix"],
        suffix=REPEAT_CONFIG["suffix"],
    )

    print("Alfred snippet generation complete!")
    print(
        "You can now import Magic.alfredsnippets and Repeat.alfredsnippets into Alfred"
    )
    print(
        f"Magic snippets use: prefix='{MAGIC_CONFIG['prefix']}', suffix='{MAGIC_CONFIG['suffix']}'"
    )
    print(
        f"Repeat snippets use: prefix='{REPEAT_CONFIG['prefix']}', suffix='{REPEAT_CONFIG['suffix']}'"
    )


if __name__ == "__main__":
    main()
