#!/usr/bin/env python3
# tools/dev/field-report-redact.py
"""Remove the machine's identity from a field report, or refuse to commit it.

A field report is pushed to a public repository. The day logs go through
field-log-scrub.py, but every other step of a collector captures a command's
raw output: `ls -la` names the file owner, `lsof` the process owner, a path
names the home folder. On a Mac bound to a company directory the owner is the
directory login with its domain (`login@corp.domain`), so one `ls -la` was
enough to publish the employer's account name in every report of the
2026-10-30 to 2026-11-09 field branches.

Two modes:

- `<folder>`: rewrites every text file under the report folder with the
  machine's identity replaced by placeholders, then verifies that nothing of it
  is left. A binary file that holds an identity token is deleted and named on
  stderr: it cannot be rewritten, and publishing it is not an option. Exits 1
  when the verification still finds a token, so the collector commits nothing.
- `--staged`: the pre-commit gate. Reads the lines the index adds and exits 1
  when one holds the home folder, the directory login or its domain, or the
  host name of this machine, whatever file it is in.

The identity is read from this machine when the script runs: the repository
never holds the values it looks for.
"""

import argparse
import getpass
import os
import pathlib
import platform
import re
import socket
import subprocess
import sys

# A token shorter than this would also mask ordinary words of the report.
MIN_TOKEN_LENGTH = 3
# Any e-mail address, a directory login with its domain included. The top
# level label is alphabetic, so a version pin such as `uv@0.5.1` is kept, and
# not a source file extension (`step@Owner.swift` names a code location).
EMAIL = re.compile(
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*"
    r"\.(?!(?:swift|lua|ahk|py|js|cjs|mjs|ts|json|sh|ps1|txt|log|md|toml|plist)\b)[A-Za-z]{2,}\b"
)
# Someone's home folder on any OS, whoever's it is; placeholders and the
# shared folders are not a person.
HOME_PATHS = (
    (re.compile(r"(/Users/)(?!Shared\b|<)[^/\s'\"\\:]+"), r"\1<user>"),
    (re.compile(r"(/home/)(?!<)[^/\s'\"\\:]+"), r"\1<user>"),
    (
        re.compile(
            r"([A-Za-z]:(?:\\\\|\\|/)Users(?:\\\\|\\|/))(?!Public\b|Default\b|<)[^\\/\s'\"]+"
        ),
        r"\1<user>",
    ),
)
PLACEHOLDER_EMAIL = "<email>"
# A placeholder still followed by a domain: a redaction that ran out of order.
LEFTOVER_DOMAIN = re.compile(r"<(?:user|email)>@[A-Za-z0-9.-]+")


def _run(command):
    """Returns one command's stripped output, or an empty string when it fails.

    Args:
        command: The argument list.

    Returns:
        Its standard output, stripped.
    """
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def _posix_accounts():
    """Returns the account names and full names the password database gives.

    Returns:
        A pair of sets: login names, full names.
    """
    try:
        import pwd  # POSIX only
    except ImportError:
        return set(), set()
    logins, names = set(), set()
    uids = {os.getuid()}
    try:
        uids.add(os.stat(pathlib.Path.home()).st_uid)
    except OSError:
        pass
    for uid in uids:
        try:
            entry = pwd.getpwuid(uid)
        except KeyError:
            continue
        logins.add(entry.pw_name)
        names.add(entry.pw_gecos.split(",")[0])
    return logins, names


def identity():
    """Collects what names this machine and its user.

    Returns:
        A dict of sets: `homes`, `logins` (with any `login@domain` form),
        `domains`, `hosts` and `names` (full names).
    """
    logins, names = _posix_accounts()
    for variable in ("USER", "LOGNAME", "USERNAME"):
        logins.add(os.environ.get(variable, ""))
    try:
        logins.add(getpass.getuser())
    except (OSError, KeyError):
        pass
    if platform.system() == "Darwin":
        names.add(_run(["id", "-F"]))
        # `ls -l` asks the directory for the owner, which can answer with the
        # domain the local account name lacks.
        logins.add(_run(["stat", "-f", "%Su", str(pathlib.Path.home())]))
    domains = {os.environ.get("USERDOMAIN", ""), os.environ.get("USERDNSDOMAIN", "")}
    for login in list(logins):
        if "@" in login:
            local, _, domain = login.partition("@")
            logins.add(local)
            domains.add(domain)
        if "\\" in login:
            domain, _, local = login.partition("\\")
            logins.add(local)
            domains.add(domain)
    hosts = {os.environ.get("COMPUTERNAME", ""), socket.gethostname(), socket.getfqdn()}
    if platform.system() == "Darwin":
        for key in ("ComputerName", "LocalHostName", "HostName"):
            hosts.add(_run(["scutil", "--get", key]))
    hosts |= {host.split(".")[0] for host in hosts}
    homes = {
        str(pathlib.Path.home()),
        os.environ.get("HOME", ""),
        os.environ.get("USERPROFILE", ""),
    }
    # A generic machine or account name names nobody, and masking it would
    # rewrite ordinary words of the report (REPO_ROOT, "user").
    generic = {
        "localhost",
        "localhost.localdomain",
        "local",
        "workgroup",
        "root",
        "user",
        "admin",
        "administrator",
        "runner",
        "guest",
    }

    def keep(values):
        return {v for v in values if v and len(v) >= MIN_TOKEN_LENGTH and v.lower() not in generic}

    return {
        "homes": keep(homes),
        "logins": keep(logins),
        "domains": keep(domains),
        "hosts": keep(hosts),
        "names": keep(names),
    }


def _spellings(value):
    """Returns a value as text and as a JSON or Lua string escapes it.

    Args:
        value: One identity token.

    Returns:
        The set of its spellings.
    """
    return {value, value.replace("/", "\\/"), value.replace("\\", "\\\\")}


def replacements(ident):
    """Builds the ordered (pattern, placeholder) list of one identity.

    The home folder goes first, as `~`, then the longest tokens: a login with
    its domain is replaced whole, before its parts.

    Args:
        ident: The identity() dict.

    Returns:
        A list of (compiled pattern, placeholder) pairs.
    """
    pairs = []
    for home in sorted(ident["homes"], key=len, reverse=True):
        for spelling in _spellings(home):
            pairs.append((re.compile(re.escape(spelling), re.IGNORECASE), "~"))
    tokens = [(v, "<user>") for v in ident["logins"]]
    tokens += [(v, "<domain>") for v in ident["domains"]]
    tokens += [(v, "<host>") for v in ident["hosts"]]
    tokens += [(v, "<name>") for v in ident["names"]]
    for value, placeholder in sorted(tokens, key=lambda pair: len(pair[0]), reverse=True):
        # Bounded by non-word characters: the login `ana` leaves `banana`.
        pattern = r"(?<![A-Za-z0-9])" + re.escape(value) + r"(?![A-Za-z0-9])"
        pairs.append((re.compile(pattern, re.IGNORECASE), placeholder))
    return pairs


def redact_text(text, pairs):
    """Returns text without the identity, the e-mail addresses or home paths.

    Args:
        text: The text to rewrite.
        pairs: The replacements() list.

    Returns:
        The rewritten text.
    """
    # The generic forms first: replacing the login alone would leave its
    # domain behind (`<user>@corp.domain`), which no later pattern matches.
    text = EMAIL.sub(PLACEHOLDER_EMAIL, text)
    for pattern, placeholder in pairs:
        text = pattern.sub(placeholder, text)
    for pattern, placeholder in HOME_PATHS:
        text = pattern.sub(placeholder, text)
    return text


def leaks(text, pairs):
    """Lists what of the identity a text still holds.

    Args:
        text: The text to check.
        pairs: The replacements() list.

    Returns:
        The matched fragments, empty when the text is clean.
    """
    found = [m.group(0) for pattern, _ in pairs for m in pattern.finditer(text)]
    found += [m.group(0) for m in EMAIL.finditer(text)]
    found += [m.group(0) for m in LEFTOVER_DOMAIN.finditer(text)]
    found += [m.group(0) for pattern, _ in HOME_PATHS for m in pattern.finditer(text)]
    return found


def _binary_leaks(data, pairs):
    """Tells whether binary bytes hold an identity token in UTF-8 or UTF-16.

    Args:
        data: The file's bytes.
        pairs: The replacements() list.

    Returns:
        True when one token is found.
    """
    for encoding in ("utf-8", "utf-16-le"):
        text = data.decode(encoding, errors="ignore")
        if any(pattern.search(text) for pattern, _ in pairs):
            return True
    return False


def redact_folder(folder, pairs):
    """Rewrites a report folder in place, then verifies it.

    Args:
        folder: The report folder.
        pairs: The replacements() list.

    Returns:
        The list of (path, fragment) leaks still found, empty when clean.
    """
    remaining = []
    for path in sorted(p for p in folder.rglob("*") if p.is_file()):
        relative = path.relative_to(folder).as_posix()
        if leaks(relative, pairs):
            path.unlink()
            print(
                f"[field-report-redact] withheld {relative}: its name holds an identity.",
                file=sys.stderr,
            )
            continue
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            if _binary_leaks(data, pairs):
                path.unlink()
                print(
                    f"[field-report-redact] withheld {relative}: a binary file naming the user.",
                    file=sys.stderr,
                )
            continue
        clean = redact_text(text, pairs)
        if clean != text:
            path.write_bytes(clean.encode("utf-8"))
        remaining += [(relative, fragment) for fragment in leaks(clean, pairs)]
    return remaining


def staged_leaks(pairs):
    """Lists the lines the index adds that hold this machine's identity.

    Only the strong tokens count here (home, directory login with its domain,
    domain, host): a short local login or a full name also appears in ordinary
    source, credits and licences.

    Args:
        pairs: The replacements() list of the strong identity.

    Returns:
        A list of (file, fragment) pairs.
    """
    diff = subprocess.run(
        ["git", "diff", "--cached", "--no-color", "--unified=0", "--no-ext-diff", "--text"],
        capture_output=True,
        check=True,
    ).stdout.decode("utf-8", errors="replace")
    found, current = [], None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else line[4:]
        elif line.startswith("+") and current is not None:
            found += [(current, m.group(0)) for p, _ in pairs for m in p.finditer(line[1:])]
    return found


def main():
    """Runs one mode and returns the process exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("folder", nargs="?", type=pathlib.Path, help="the report folder to redact")
    target.add_argument("--staged", action="store_true", help="check the lines the index adds")
    arguments = parser.parse_args()
    ident = identity()
    if arguments.staged:
        strong = dict(
            ident, names=set(), logins={v for v in ident["logins"] if "@" in v or "\\" in v}
        )
        found = staged_leaks(replacements(strong))
        for file, fragment in found:
            print(
                f"[identity-gate] {file}: adds '{fragment}', which names this machine or its user.",
                file=sys.stderr,
            )
        if found:
            print(
                "[identity-gate] Remove or redact it (tools/dev/field-report-redact.py) before committing.",
                file=sys.stderr,
            )
        return 1 if found else 0
    if not arguments.folder.is_dir():
        print(f"[field-report-redact] {arguments.folder} is not a folder.", file=sys.stderr)
        return 2
    remaining = redact_folder(arguments.folder, replacements(ident))
    for relative, fragment in remaining:
        print(f"[field-report-redact] {relative} still holds '{fragment}'.", file=sys.stderr)
    return 1 if remaining else 0


if __name__ == "__main__":
    sys.exit(main())
