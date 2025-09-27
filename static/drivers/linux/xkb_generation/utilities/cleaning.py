import re


def clean_invalid_xml_chars(xml_text):
    """Remove invalid XML char references (e.g. &#x0008;) except tab, LF, CR."""

    def repl(match):
        val = int(match.group(1), 16)
        if val in (0x09, 0x0A, 0x0D):
            return match.group(0)
        if val < 0x20:
            return ""
        return match.group(0)

    return re.sub(r"&#x([0-9A-Fa-f]{1,6});", repl, xml_text)
