# tools/build/core_sdk/installed_cli_frontend.py
"""Bind the installed CLI mode to its existing authenticated capture owner.

The input is the genuine fixed factory's complete CLI output, rather than an
arbitrary upstream file or a caller-supplied readiness declaration. This pure
source transform adds no installation or native execution authority.
"""

import hashlib


LEGACY_CLI_SHA256 = "2bcb6ab2eac56d7c0a051a08edee89492a0e6a8852c6d0e23c0bda8e36e077ef"
CLI_PATH = "src/bin/cli/src/main.cpp"
INSTALLED_OPTION = "installed-physical-capture"


def _replace_once(source, original, successor):
    """Reject drift before replacing one authentic source anchor."""
    if source.count(original) != 1:
        raise ValueError("The fixed CLI source anchor changed")
    return source.replace(original, successor, 1)


def render(source):
    """Preserve every legacy byte while adding the fixed installed entrypoint."""
    if type(source) is not bytes or hashlib.sha256(source).hexdigest() != LEGACY_CLI_SHA256:
        raise ValueError("The genuine source factory CLI changed")
    text = source.decode("utf-8")
    text = _replace_once(
        text,
        '#include "hs274-stream-cli.hpp"\n',
        '#include "hs274-stream-cli.hpp"\n#include "hs274-installed-cli.hpp"\n',
    )
    text = _replace_once(
        text,
        '  options.add_options()("hs274-capture",\n',
        '  options.add_options()("installed-physical-capture",\n'
        '                        "Observe the authenticated installed physical source",\n'
        '                        cxxopts::value<int>(), "polling-interval-in-milliseconds");\n\n'
        '  options.add_options()("hs274-capture",\n',
    )
    text = _replace_once(
        text,
        '    if (parse_result.count("hs274-clock")) {\n',
        '    if (parse_result.count("installed-physical-capture")) {\n'
        "      try {\n"
        "        exit_code = krbn::cli::installed_capture::run(\n"
        '            parse_result["installed-physical-capture"].as<int>());\n'
        "      } catch (const std::exception&) {\n"
        '        std::cerr << "Installed physical source admission refused" << std::endl;\n'
        "        exit_code = 1;\n"
        "      }\n"
        "      goto finish;\n"
        "    }\n\n"
        '    if (parse_result.count("hs274-clock")) {\n',
    )
    return text.encode("utf-8")
