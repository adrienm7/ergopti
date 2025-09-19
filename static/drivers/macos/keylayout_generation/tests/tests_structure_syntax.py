"""Tests for validating a keylayout."""

import re

from lxml import etree as lxml_etree

LOGS_INDENTATION = "\t"


def check_valid_xml_structure(body: str) -> None:
    """
    Checks that the XML is well-formed (all tags opened/closed, no illegal characters, etc.).
    """
    print(f"{LOGS_INDENTATION}\t➡️  Checking XML structure validity…")
    try:
        try:
            parser = lxml_etree.XMLParser(recover=True, resolve_entities=True)
            lxml_etree.fromstring(body.encode("utf-8"), parser)
        except ImportError:
            print(f"{LOGS_INDENTATION}\t⚠️  lxml is not installed.")
    except Exception as e:
        print(f"{LOGS_INDENTATION}\t❌ Invalid XML structure: {e}")
        raise ValueError("XML structure is not valid.")
    print(f"{LOGS_INDENTATION}\t✅ XML structure is valid.")


def check_required_blocks_present(body: str) -> None:
    """
    Checks that all required blocks are present.
    """
    print(f"{LOGS_INDENTATION}\t➡️  Checking required blocks presence…")
    required = ["keyMapSet", "actions", "terminators"]
    for block in required:
        if not re.search(rf"<{block}[^>]*>", body):
            print(f"{LOGS_INDENTATION}\t❌ Required block <{block}> missing.")
            raise ValueError(f"Required block <{block}> missing.")
    print(f"{LOGS_INDENTATION}\t✅ All required blocks are present.")


def check_forbidden_tags_or_attributes(body: str) -> None:
    """
    Checks that no forbidden tag or attribute is present.
    """
    print(f"{LOGS_INDENTATION}\t➡️  Checking forbidden tags or attributes…")
    allowed_tags = {
        "action",
        "actions",
        "key",
        "keyMap",
        "keyMapSelect",
        "keyMapSet",
        "keyboard",
        "layout",
        "layouts",
        "modifier",
        "modifierMap",
        "terminators",
        "when",
    }
    allowed_attrs = {
        "action",
        "code",
        "defaultIndex",
        "encoding",
        "first",
        "group",
        "id",
        "index",
        "keys",
        "last",
        "mapIndex",
        "mapSet",
        "maxout",
        "modifiers",
        "name",
        "next",
        "output",
        "state",
        "version",
    }
    for tag in re.findall(r"<(/?)(\w+)", body):
        if tag[1] not in allowed_tags:
            print(f"{LOGS_INDENTATION}\t❌ Forbidden tag: <{tag[1]}>.")
            raise ValueError(f"Forbidden tag: <{tag[1]}>.")
    for attr in re.findall(r"(\w+)=", body):
        if attr not in allowed_attrs:
            print(f"{LOGS_INDENTATION}\t❌ Forbidden attribute: {attr}.")
            raise ValueError(f"Forbidden attribute: {attr}.")
    print(f"{LOGS_INDENTATION}\t✅ No forbidden tags or attributes.")


def check_forbidden_empty_attribute_values(body: str) -> None:
    """
    Checks that no required attribute is empty (except output).
    """
    print(f"{LOGS_INDENTATION}\t➡️  Checking forbidden empty attribute values…")
    forbidden = ["id", "code", "action", "state"]
    for match in re.finditer(r"<(\w+)[^>]*>", body):
        tag = match.group(0)
        for attr in forbidden:
            # Match attribute value (quotes included)
            attr_match = re.search(rf'{attr}=["\'](.*?)["\']', tag)
            if attr_match:
                value = attr_match.group(1)
                # Allow a single space as a valid value, but not empty or only whitespace
                if value == "":
                    print(
                        f"{LOGS_INDENTATION}\t❌ Empty value for attribute {attr} in: {tag.strip()}"
                    )
                    raise ValueError(f"Empty value for attribute {attr}.")
                if value.strip() == "" and value != " ":
                    print(
                        f"{LOGS_INDENTATION}\t❌ Empty value for attribute {attr} in: {tag.strip()}"
                    )
                    raise ValueError(f"Empty value for attribute {attr}.")
    print(f"{LOGS_INDENTATION}\t✅ No forbidden empty attribute values.")


def check_consistent_attribute_quotes(body: str) -> None:
    """
    Check that all attributes use the same type of quotes (single or double) throughout the file.
    """
    print(f"{LOGS_INDENTATION}\t➡️  Checking consistent attribute quotes…")
    # Extract all quote types used for attribute values
    quotes = re.findall(r'\w+=("|\')', body)
    if quotes:
        if not all(q == quotes[0] for q in quotes):
            print(
                f"{LOGS_INDENTATION}\t❌ Inconsistent attribute quotes detected."
            )
            raise ValueError("Inconsistent attribute quotes in file.")
    print(f"{LOGS_INDENTATION}\t✅ Attribute quotes are consistent.")


def check_xml_attribute_errors(body: str) -> None:
    """
    Ensure XML attributes are well-formed.
    Raises ValueError if malformed attributes are found.
    Displays the offending lines.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking for malformed XML attributes…"
    )  # Needs double space after emoji

    lines = body.splitlines()
    errors = []

    for i, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped:
            continue

        # Find all attribute assignments
        # Match pattern: key = "value" or key = 'value'
        attr_matches = re.findall(r'(\w+\s*=\s*["\'].*?["\']?)', line)
        for attr in attr_matches:
            # Must contain =
            if "=" not in attr:
                errors.append((i, line.strip(), "Missing '=' in attribute"))
                continue

            name, value = attr.split("=", 1)
            value = value.strip()

            # Value must start and end with same quote
            if not (
                (value.startswith('"') and value.endswith('"'))
                or (value.startswith("'") and value.endswith("'"))
            ):
                errors.append(
                    (i, line.strip(), "Attribute value not properly quoted")
                )

        # Check for unclosed quotes anywhere in the line
        # Count total " and ' not escaped
        double_quotes = line.count('"')
        single_quotes = line.count("'")
        if double_quotes % 2 != 0:
            errors.append((i, line.strip(), "Unmatched double quote in line"))
        if single_quotes % 2 != 0:
            errors.append((i, line.strip(), "Unmatched single quote in line"))

    if errors:
        print(f"{LOGS_INDENTATION}\t❌ Malformed XML attributes detected:")
        for line_num, content, reason in errors:
            print(f"{LOGS_INDENTATION}\t\t— Line {line_num}: {reason}")
            print(f"{LOGS_INDENTATION}\t\t\t{content}")
        raise ValueError("Malformed XML attributes found.")

    print(f"{LOGS_INDENTATION}\t✅ All XML attributes appear well-formed.")


def check_max_min_code_state_values(body: str) -> None:
    """
    Checks that code and state numeric values are within reasonable bounds.
    """
    print(f"{LOGS_INDENTATION}\t➡️  Checking code/state value ranges…")
    for code in re.findall(r'code=["\'](-?\d+)["\']', body):
        val = int(code)
        if val < 0 or val > 255:
            print(f"{LOGS_INDENTATION}\t❌ Code value out of range: {val}")
            raise ValueError(f"Code value out of range: {val}")
    for state in re.findall(r'state=["\'](-?\d+)["\']', body):
        val = int(state)
        if val < 0 or val > 1000:
            print(f"{LOGS_INDENTATION}\t❌ State value out of range: {val}")
            raise ValueError(f"State value out of range: {val}")
    print(f"{LOGS_INDENTATION}\t✅ All code/state values are in allowed range.")
