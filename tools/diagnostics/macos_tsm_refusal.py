#!/usr/bin/env python3
# tools/diagnostics/macos_tsm_refusal.py
"""Name a native keyboard-source refusal caused by the text-input UI server.

TISSelectInputSource returns noErr, but the selection is applied only after
HIToolbox reaches com.apple.tsm.uiserver, the port TextInputMenuAgent serves.
When that agent does not answer, HIToolbox prints one line per message,

    TSMSendMessageToUIServer: CFMessagePortSendRequest FAILED(-1) to send to
    port com.apple.tsm.uiserver

Every hosted refusal seen so far (a selection deadline, an unresolved cleanup,
then "unavailable" for every later case) followed such lines. Stopping
TextInputMenuAgent, or TextInputSwitcher behind it, prints them too, but the
cohort then still passes (probe run 43189848716 on Intel), so an unanswered
server is the state the refusals share, not a proven cause on its own.

This owner reads the cohort transcript and the agent snapshot taken around it
(macos_text_input_agents.sh) and writes a receipt whose state is one of:

- tsm_uiserver_unanswered: a fixture refusal follows an unanswered message;
- fixture_refusal_unclassified: a fixture refusal without that line;
- no_fixture_refusal: the cohort holds no selection refusal.

It never changes the cohort verdict: the selected-receipt judge still fails the
step. It prints a GitHub error annotation naming the state, so a failed run
says what the text-input services were doing instead of only that a deadline
passed.
"""

import argparse
import json
import re
import sys
from pathlib import Path

UNANSWERED = re.compile(
    r"TSMSendMessageToUIServer: CFMessagePortSendRequest FAILED\((-?\d+)\) "
    r"to send to port com\.apple\.tsm\.uiserver"
)
CASE_STARTED = re.compile(r"^Test Case '(.+)' started\.")
# The refusal lines KeyboardSourceSelectionFixture and NumberRowSourceProbeTests write.
REFUSALS = (
    "Native selection was not observed before the fixture deadline",
    "Temporary source cleanup remains unresolved",
    'caught error: "unavailable"',
    "The captured current source must be enabled and selected",
)
AGENT = "com.apple.TextInputMenuAgent"
AGENT_FIELDS = re.compile(r"^\s*(state|pid|runs|last exit code|last terminating signal) = (.+)$")


def method(identity):
    """The bare test method of an XCTest case identity."""
    match = re.search(r"(test\w+)\]?$", identity)
    return match.group(1) if match else identity


def agent_phases(snapshot):
    """TextInputMenuAgent's launchd fields for each snapshot phase, in order."""
    phases = []
    current = None
    in_agent = False
    for line in snapshot.splitlines():
        phase = re.match(r"^phase=(\S+) ", line)
        if phase:
            current = {"phase": phase.group(1)}
            phases.append(current)
            in_agent = False
            continue
        if line.startswith("## "):
            in_agent = line.rstrip().endswith("/" + AGENT)
            continue
        if in_agent and current is not None:
            field = AGENT_FIELDS.match(line)
            if field:
                current[field.group(1).replace(" ", "_")] = field.group(2).strip()
    return phases


def evaluate(transcript, snapshot=""):
    """Classify one cohort transcript; see the module docstring for the states."""
    case = None
    unanswered = []
    refusals = []
    for line in transcript.replace("\r\n", "\n").splitlines():
        started = CASE_STARTED.match(line)
        if started:
            case = method(started.group(1))
            continue
        message = UNANSWERED.search(line)
        if message:
            unanswered.append({"case": case, "status": int(message.group(1)), "line": line})
            continue
        if any(refusal in line for refusal in REFUSALS):
            refusals.append({"case": case, "line": line})
    if not refusals:
        state = "no_fixture_refusal"
    elif unanswered and transcript.find(unanswered[0]["line"]) < transcript.find(
        refusals[0]["line"]
    ):
        state = "tsm_uiserver_unanswered"
    else:
        state = "fixture_refusal_unclassified"
    return {
        "schema": 1,
        "state": state,
        "unanswered_count": len(unanswered),
        "first_unanswered": unanswered[0] if unanswered else None,
        "refusal_count": len(refusals),
        "first_refusal": refusals[0] if refusals else None,
        "agent": agent_phases(snapshot),
    }


def annotation(receipt):
    """The GitHub error line of a refused cohort, or None when nothing was refused."""
    if receipt["state"] == "no_fixture_refusal":
        return None
    refusal = receipt["first_refusal"]
    if receipt["state"] == "tsm_uiserver_unanswered":
        first = receipt["first_unanswered"]
        return (
            "::error::Native keyboard-source refusal: tsm_uiserver_unanswered. "
            f"com.apple.tsm.uiserver (TextInputMenuAgent) did not answer (status {first['status']}, "
            f"{receipt['unanswered_count']} messages, first in {first['case']}) before the "
            f"selection in {refusal['case']} was refused. An unanswered server alone does not "
            "refuse a selection, so this names the runner state, not a proven cause."
        )
    return (
        "::error::Native keyboard-source refusal: fixture_refusal_unclassified. "
        f"{refusal['case']} was refused without an unanswered com.apple.tsm.uiserver message."
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--agents", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args(argv)
    snapshot = args.agents.read_text(encoding="utf-8", errors="replace")
    receipt = evaluate(args.log.read_text(encoding="utf-8", errors="replace"), snapshot)
    with args.receipt.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(receipt, stream, sort_keys=True)
        stream.write("\n")
    line = annotation(receipt)
    if line is not None:
        print(line)
    print(f"text-input refusal receipt: state={receipt['state']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
