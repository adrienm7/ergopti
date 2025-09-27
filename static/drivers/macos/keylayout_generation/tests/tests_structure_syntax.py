"""Tests for validating the structure and syntax of a keylayout."""

import re

from lxml import etree as lxml_etree
from utilities.logger import logger

LOGS_INDENTATION = "\t\t"


def check_valid_xml_structure(body: str) -> None:
    """
    Checks that the XML is well-formed (all tags opened/closed, no illegal characters, etc.).
    """
    logger.info("%s🔹 Checking XML structure validity…", LOGS_INDENTATION)
    try:
        try:
            parser = lxml_etree.XMLParser(recover=True, resolve_entities=True)
            lxml_etree.fromstring(body.encode("utf-8"), parser)
        except ImportError:
            logger.warning("%slxml is not installed.", LOGS_INDENTATION + "\t")
    except Exception as e:
        logger.error("%sInvalid XML structure: %s", LOGS_INDENTATION + "\t", e)
        raise ValueError("XML structure is not valid.") from e

    logger.success("%sXML structure is valid.", LOGS_INDENTATION + "\t")


def check_keyboard_element_children(body: str) -> None:
    """
    Checks that <keyboard> contains exactly one <layouts>,
    at least one <modifierMap> and <keyMapSet>,
    and at most one <actions> and <terminators>.
    """
    logger.info(
        "%s🔹 Checking <keyboard> element children structure…", LOGS_INDENTATION
    )
    match = re.search(r"<keyboard[^>]*>(.*)</keyboard>", body, flags=re.DOTALL)
    if not match:
        raise ValueError("No <keyboard> block found.")

    inner = match.group(1)
    # Count first-level child tags
    layouts = re.findall(r"<layouts[ >]", inner)
    modifiermaps = re.findall(r"<modifierMap[ >]", inner)
    keymapsets = re.findall(r"<keyMapSet[ >]", inner)
    actions = re.findall(r"<actions[ >]", inner)
    terminators = re.findall(r"<terminators[ >]", inner)

    if len(layouts) != 1:
        raise ValueError(
            f"<keyboard> must contain exactly one <layouts> (found {len(layouts)})"
        )
    if len(modifiermaps) < 1:
        raise ValueError("<keyboard> must contain at least one <modifierMap>.")
    if len(keymapsets) < 1:
        raise ValueError("<keyboard> must contain at least one <keyMapSet>.")
    if len(actions) > 1:
        raise ValueError("<keyboard> must contain at most one <actions>.")
    if len(terminators) > 1:
        raise ValueError("<keyboard> must contain at most one <terminators>.")
    logger.success(
        "%s<keyboard> element children structure is valid.",
        LOGS_INDENTATION + "\t",
    )


def check_required_blocks_presence(body: str) -> None:
    """
    Checks that all required blocks are present.
    """
    logger.info("%s🔹 Checking required blocks presence…", LOGS_INDENTATION)

    required = ["keyMapSet", "actions", "terminators"]
    for block in required:
        if not re.search(rf"<{block}[^>]*>", body):
            logger.error(
                "%sRequired block <%s> missing.", LOGS_INDENTATION + "\t", block
            )
            raise ValueError(f"Required block <{block}> missing.")

    logger.success(
        "%sAll required blocks are present.", LOGS_INDENTATION + "\t"
    )


def check_forbidden_tags_or_attributes(body: str) -> None:
    """
    Checks that no forbidden tag or attribute is present.
    """
    logger.info("%s🔹 Checking forbidden tags or attributes…", LOGS_INDENTATION)
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
        "baseIndex",
        "baseMapSet",
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
            logger.error(
                "%sForbidden tag: <%s>.", LOGS_INDENTATION + "\t", tag[1]
            )
            raise ValueError(f"Forbidden tag: <{tag[1]}>.")
    for attr in re.findall(r"(\w+)=", body):
        if attr not in allowed_attrs:
            logger.error(
                "%sForbidden attribute: %s.", LOGS_INDENTATION + "\t", attr
            )
            raise ValueError(f"Forbidden attribute: {attr}.")

    logger.success(
        "%sNo forbidden tags or attributes.", LOGS_INDENTATION + "\t"
    )


def check_forbidden_empty_attribute_values(body: str) -> None:
    """
    Checks that no required attribute is empty (except output).
    """
    logger.info(
        "%s🔹 Checking forbidden empty attribute values…",
        LOGS_INDENTATION,
    )
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
                    logger.error(
                        "%sEmpty value for attribute %s in: %s",
                        LOGS_INDENTATION + "\t",
                        attr,
                        tag.strip(),
                    )
                    raise ValueError(f"Empty value for attribute {attr}.")
                if value.strip() == "" and value != " ":
                    logger.error(
                        "%sEmpty value for attribute %s in: %s",
                        LOGS_INDENTATION + "\t",
                        attr,
                        tag.strip(),
                    )
                    raise ValueError(f"Empty value for attribute {attr}.")

    logger.success(
        "%sNo forbidden empty attribute values.", LOGS_INDENTATION + "\t"
    )


def check_keyboard_id_format(body: str) -> None:
    """
    Check that the keylayout id starts with a minus sign and after that <=8 digits.
    """
    logger.info("%s🔹 Checking <keyboard> id format…", LOGS_INDENTATION)
    match = re.search(r'<keyboard[^>]* id="([^"]+)"', body)
    if not match:
        raise ValueError("No <keyboard id=...> found.")

    kid = match.group(1)
    if not kid.startswith("-"):
        raise ValueError(f"<keyboard> id does not start with '-': {kid}")
    rest = kid[1:]

    if len(rest) > 8:
        raise ValueError(
            f"<keyboard> id part after '-' is too long: {rest} of length {len(rest)} > 8"
        )

    if not rest.isdigit():
        raise ValueError(
            f"<keyboard> id part after '-' is not all digits: {rest}"
        )

    logger.success("%s<keyboard> id format is valid.", LOGS_INDENTATION + "\t")


def check_consistent_attribute_quotes(body: str) -> None:
    """
    Check that all attributes use the same type of quotes (single or double) throughout the file.
    """
    logger.info("%s🔹 Checking consistent attribute quotes…", LOGS_INDENTATION)
    # Extract all quote types used for attribute values
    quotes = re.findall(r'\w+=("|\')', body)
    if quotes:
        if not all(q == quotes[0] for q in quotes):
            logger.error(
                "%sInconsistent attribute quotes detected.",
                LOGS_INDENTATION + "\t",
            )

    logger.success(
        "%sAttribute quotes are consistent.", LOGS_INDENTATION + "\t"
    )


def check_xml_attribute_errors(body: str) -> None:
    """
    Ensure XML attributes are well-formed.
    Raises ValueError if malformed attributes are found.
    Displays the offending lines.
    """
    logger.info("%s🔹 Checking for malformed XML attributes…", LOGS_INDENTATION)

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

            _, value = attr.split("=", 1)
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
        logger.error("%sMalformed XML attributes detected:", LOGS_INDENTATION)
        for line_num, content, reason in errors:
            logger.error(
                "%s— Line %d: %s", LOGS_INDENTATION + "\t", line_num, reason
            )
            logger.error("%s%s", LOGS_INDENTATION + "\t\t", content)
        raise ValueError("Malformed XML attributes found.")
    else:
        logger.success(
            "%sAll XML attributes appear well-formed.",
            LOGS_INDENTATION + "\t",
        )


def check_max_min_code_state_values(body: str) -> None:
    """
    Checks that code and state numeric values are within reasonable bounds.
    """
    logger.info("%s🔹 Checking code/state value ranges…", LOGS_INDENTATION)

    for code in re.findall(r'code=["\'](-?\d+)["\']', body):
        val = int(code)
        if val < 0 or val > 255:
            logger.error(
                "%sCode value out of range: %d", LOGS_INDENTATION + "\t", val
            )
            raise ValueError(f"Code value out of range: {val}")

    for state in re.findall(r'state=["\'](-?\d+)["\']', body):
        val = int(state)
        if val < 0 or val > 1000:
            logger.error(
                "%sState value out of range: %d", LOGS_INDENTATION + "\t", val
            )
            raise ValueError(f"State value out of range: {val}")

    logger.success(
        "%sAll code/state values are in allowed range.",
        LOGS_INDENTATION + "\t",
    )
