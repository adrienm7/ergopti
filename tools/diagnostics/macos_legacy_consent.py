# tools/diagnostics/macos_legacy_consent.py
"""Qualify only confirmed-source cleanup guards on actual disposable Mac files.

Three fixed four-case cohorts retain unchanged25/10/10 and SDK30/35/10.
Owner predicates and interleavings are modeled; native JSON/files/backup/CAS
are genuine. Portable receipt models do not run or qualify the native producer.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import time
import uuid

CASES = (
    "remove_two_signature_conflicts",
    "unchanged_second_request",
    "stale_destination_after_verified_backup",
    "existing_backup_name",
    "backup_readback_changed",
    "invalid_original_refuses",
)
AUTHORITY = {
    "physical_input": "unexecuted",
    "user_backup": "unavailable",
    "ui_confirmation": "unexecuted",
    "lease_initialized": False,
    "installation": False,
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate receipt key")
        result[key] = value
    return result


def read_record(path):
    def finite_float(raw):
        value = float(raw)
        require(math.isfinite(value), "Nonfinite JSON number")
        return value

    path = Path(path)
    require(
        path.is_absolute() and path.parent.resolve(strict=True) == path.parent,
        "Aliased receipt parent",
    )
    info = path.lstat()
    require(
        stat.S_ISREG(info.st_mode)
        and info.st_uid == os.geteuid()
        and info.st_nlink == 1
        and 0 < info.st_size <= 65536,
        "Unsafe receipt",
    )
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        current = os.fstat(descriptor)
        require(
            (
                current.st_dev,
                current.st_ino,
                current.st_size,
                current.st_nlink,
                current.st_uid,
                current.st_mode,
            )
            == (info.st_dev, info.st_ino, info.st_size, info.st_nlink, info.st_uid, info.st_mode),
            "Changed receipt inode",
        )
        data = os.read(descriptor, 65537)
        require(len(data) == current.st_size, "Receipt read incomplete")
        final = os.fstat(descriptor)
        require(
            (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns, final.st_ctime_ns)
            == (
                current.st_dev,
                current.st_ino,
                current.st_size,
                current.st_mtime_ns,
                current.st_ctime_ns,
            ),
            "Receipt changed during read",
        )
    finally:
        os.close(descriptor)
    return json.loads(
        data,
        object_pairs_hook=unique,
        parse_float=finite_float,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite JSON")),
    )


def admit(packet, nonce, pid, version, report, before, after, observed_at, deadline):
    require(
        type(packet) is dict
        and set(packet)
        == {
            "schema",
            "status",
            "runtime",
            "pid",
            "nonce",
            "version",
            "case_results",
            "authority",
        },
        "Unexpected receipt fields",
    )
    require(
        type(packet["schema"]) is int
        and packet["schema"] == 1
        and packet["status"] == "ok"
        and packet["runtime"] == "native Hammerspoon",
        "Native receipt scope differs",
    )
    require(
        type(pid) is int and pid > 0 and type(packet["pid"]) is int and packet["pid"] == pid,
        "Foreign native PID",
    )
    require(
        type(nonce) is str
        and re.fullmatch(r"[0-9a-f]{32}", nonce)
        and packet["nonce"] == nonce
        and type(version) is str
        and version
        and packet["version"] == version,
        "Foreign runtime identity",
    )
    cases = packet["case_results"]
    require(type(cases) is list and len(cases) == len(CASES), "Incomplete case inventory")
    for expected, result in zip(CASES, cases, strict=True):
        require(
            type(result) is dict
            and set(result) == {"id", "passed"}
            and result["id"] == expected
            and result["passed"] is True,
            "Case identity or exact acknowledgement differs",
        )
    authority = packet["authority"]
    require(type(authority) is dict and set(authority) == set(AUTHORITY), "Authority fields differ")
    for key, value in AUTHORITY.items():
        require(
            type(authority[key]) is type(value) and authority[key] == value,
            "Cleanup fixture cannot grant authority",
        )
    clock.validate_owner(report, pid)
    require(
        type(before) is dict and bool(before) and type(after) is dict and before == after,
        "Source ownership changed",
    )
    for key, value in before.items():
        require(
            type(key) is str
            and key
            and type(value) is str
            and re.fullmatch(r"[0-9a-f]{64}", value),
            "Unqualified source identity",
        )
    for value in (observed_at, deadline):
        require(
            type(value) in (int, float)
            and abs(value) <= 1e12
            and math.isfinite(value)
            and value >= 0,
            "Invalid native deadline",
        )
    require(observed_at < deadline, "Native receipt completed after deadline")
    return packet


# fmt: off
def portable():
    import copy

    report = {
        "status": "ok",
        "native_owner": {
            "worker_pid": 42,
            "group_id": 42,
            "closed": True,
            "reservation_lost": False,
            "live_group_members": [],
            "escaped_sessions_managed": False,
        },
    }
    packet = {
        "schema": 1,
        "status": "ok",
        "runtime": "native Hammerspoon",
        "pid": 42,
        "nonce": "0" * 32,
        "version": "1.1.1",
        "case_results": [{"id": name, "passed": True} for name in CASES],
        "authority": dict(AUTHORITY),
    }
    before = {"source": "0" * 64}
    cases = [
        "healthy_six_exact_retired",
        "foreign_pid",
        "foreign_nonce",
        "missing_case",
        "duplicated_case",
        "truthy_fact",
        "unretired_process",
        "late_receipt",
        "source_changed",
        "unexpected_field",
        "duplicate_json_key",
    ]
    for name in cases:
        value, owner, after, end = copy.deepcopy(packet), copy.deepcopy(report), dict(before), 1
        if name == "foreign_pid":
            value["pid"] += 1
        elif name == "foreign_nonce":
            value["nonce"] = "1" * 32
        elif name == "missing_case":
            value["case_results"].pop()
        elif name == "duplicated_case":
            value["case_results"][1] = dict(value["case_results"][0])
        elif name == "truthy_fact":
            value["case_results"][0]["passed"] = 1
        elif name == "unretired_process":
            owner["native_owner"]["closed"] = False
        elif name == "late_receipt":
            end = 3
        elif name == "source_changed":
            after["source"] = "1" * 64
        elif name == "unexpected_field":
            value["unexpected"] = True
        try:
            if name == "duplicate_json_key":
                json.loads('{"pid":42,"p\\u0069d":42}', object_pairs_hook=unique)
            else:
                admit(value, "0" * 32, 42, "1.1.1", owner, before, after, end, 2)
        except ValueError:
            require(name != "healthy_six_exact_retired", "Healthy parser refused")
        else:
            require(
                name == "healthy_six_exact_retired", "Negative parser control accepted: " + name
            )
    print("PASS cleanup portable receipt controls tests=11 failures=0 errors=0 skipped=0")


# fmt: on

FULL_CASES = (
    "confirmed_remove",
    "confirmed_noop",
    "confirmed_raw_changed_before_read",
    "owner_stale_before_read",
    "owner_stale_after_read",
    "owner_stale_before_backup",
    "owner_stale_after_backup",
    "owner_callback_raises",
    "owner_callback_nontrue",
    "confirmed_invalid_json",
    "confirmed_absent_destination",
    "confirmed_destination_changed_after_backup",
)
COHORTS = {"source": FULL_CASES[:4], "owner": FULL_CASES[4:8], "refusal": FULL_CASES[8:]}
CORPUS_PATH = "tools/diagnostics/fixtures/karabiner-legacy-consent-acceptance.json"
CORPUS_SHA256 = "05de415ecc0772a9ad004512218d302fa11570fd45d1ed2e08319904d7d50ee8"
INPUT_PATH = "tools/diagnostics/fixtures/karabiner-legacy-cleanup-acceptance.json"
INPUT_SHA256 = "de9e1b6a6f05e222634b3d2c5b5d7c52048f3773de2d74059b535db7b7927ffb"
BOUNDARY_MODEL = "owner predicate and interleaving only; actual production JSON/files/backup/CAS"
EXTRA_SOURCE_PATHS = (
    "tools/diagnostics/hs_legacy_consent_native.lua",
    CORPUS_PATH,
    "tools/diagnostics/macos_legacy_consent.py",
    "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274LegacyConsentQualificationTests.swift",
)


def load_oracles(repo):
    for path, expected in ((CORPUS_PATH, CORPUS_SHA256), (INPUT_PATH, INPUT_SHA256)):
        file = repo / path
        require(file.resolve(strict=True) == file and file.is_file(), "Aliased frozen oracle")
        require(hashlib.sha256(file.read_bytes()).hexdigest() == expected, "Frozen oracle changed")
    oracle, corpus = read_record(repo / CORPUS_PATH), read_record(repo / INPUT_PATH)
    require(type(oracle) is dict and oracle["schema"] == 1, "Unknown frozen oracle schema")
    require(oracle["case_ids"] == list(FULL_CASES), "Frozen twelve-case inventory differs")
    require(
        tuple(c["id"] for c in oracle["cases"]) == FULL_CASES, "Frozen expectation order differs"
    )
    require(oracle["input_corpus_sha256"] == INPUT_SHA256, "Independent input corpus differs")
    return oracle, corpus


def input_bytes(corpus, oracle, name):
    if name == "absent":
        return None
    variant = oracle["input_variants"].get(name)
    return corpus[variant["base_ref"]] + variant["append"] if variant else corpus[name]


def validate_observations(packet, cohort, oracle, corpus):
    require(type(cohort) is str and cohort in COHORTS, "Unknown fixed native cohort")
    require(
        packet["cohort"] == cohort and packet["full_inventory"] == list(FULL_CASES),
        "Native cohort/inventory differs",
    )
    require(packet["boundary_model"] == BOUNDARY_MODEL, "Native boundary scope differs")
    observations = packet["observations"]
    require(
        type(observations) is list and len(observations) == 4,
        "Incomplete native observation inventory",
    )
    rows = {row["id"]: row for row in oracle["cases"]}
    fields = {
        "id",
        "ok",
        "detail",
        "removed",
        "backup_files",
        "publication_calls",
        "backup_returned",
        "destination_exists",
        "destination_bytes",
        "backup_bytes",
        "destination_reads",
        "current_checks",
        "boundary_reached",
        "methods_restored",
        "owner_modeled",
    }
    for name, observation in zip(COHORTS[cohort], observations, strict=True):
        row = rows[name]
        expected = row["expect"]
        require(
            type(observation) is dict and set(observation) == fields and observation["id"] == name,
            "Native observation identity/fields differ",
        )
        for key in ("ok", "backup_returned"):
            require(
                type(observation[key]) is bool and observation[key] is expected[key],
                "Observation boolean differs",
            )
        for key in ("removed", "backup_files", "publication_calls"):
            require(
                type(observation[key]) is int and observation[key] == expected[key],
                "Observation count differs",
            )
        detail = observation["detail"]
        require(type(detail) is str and len(detail) <= 4096, "Observation detail is unbounded")
        required = expected["detail"]
        require(
            detail.startswith(required[7:])
            if required.startswith("prefix:")
            else detail == required,
            "Observation refusal/outcome differs",
        )
        retained = input_bytes(corpus, oracle, expected["destination_ref"])
        require(
            type(observation["destination_exists"]) is bool
            and observation["destination_exists"] is (retained is not None),
            "Destination existence differs",
        )
        require(
            type(observation["destination_bytes"]) is str
            and observation["destination_bytes"] == (retained or ""),
            "Actual retained destination bytes differ",
        )
        backup = (
            input_bytes(corpus, oracle, expected["backup_ref"])
            if expected["backup_ref"] is not None
            else ""
        )
        require(
            type(observation["backup_bytes"]) is str and observation["backup_bytes"] == backup,
            "Actual retained backup bytes differ",
        )
        for key in ("boundary_reached", "methods_restored", "owner_modeled"):
            require(observation[key] is True, "Missing exact boundary/restoration/scope witness")
        reads, checks = observation["destination_reads"], observation["current_checks"]
        require(
            type(reads) is int and 0 <= reads <= 64 and type(checks) is int and 1 <= checks <= 8,
            "Invalid adapter/predicate witness",
        )
        if name in {"owner_stale_before_read", "owner_callback_raises", "owner_callback_nontrue"}:
            require(reads == 0, "Expired owner read the destination")


def verify_sources(repo, copied, before):
    require(source_inventory(repo) == before, "Live source changed")
    for relative, expected in before.items():
        path = copied / relative
        require(path.resolve(strict=True) == path and path.is_file(), "Copied source alias refused")
        require(hashlib.sha256(path.read_bytes()).hexdigest() == expected, "Copied source changed")


def portable_consent(repo):
    """Modeled receipt controls only; never run the native producer with stubs."""
    import copy
    import tempfile

    oracle, corpus = load_oracles(repo)
    rows = {row["id"]: row for row in oracle["cases"]}
    report = {
        "status": "ok",
        "native_owner": {
            "worker_pid": 42,
            "group_id": 42,
            "closed": True,
            "reservation_lost": False,
            "live_group_members": [],
            "escaped_sessions_managed": False,
        },
    }
    before = {"source": "0" * 64}

    def modeled_packet(cohort):
        observations = []
        for name in COHORTS[cohort]:
            expected = rows[name]["expect"]
            retained = input_bytes(corpus, oracle, expected["destination_ref"])
            backup = (
                input_bytes(corpus, oracle, expected["backup_ref"])
                if expected["backup_ref"] is not None
                else ""
            )
            observations.append(
                {
                    "id": name,
                    "ok": expected["ok"],
                    "detail": expected["detail"][7:] + " modeled parser detail"
                    if expected["detail"].startswith("prefix:")
                    else expected["detail"],
                    "removed": expected["removed"],
                    "backup_files": expected["backup_files"],
                    "publication_calls": expected["publication_calls"],
                    "backup_returned": expected["backup_returned"],
                    "destination_exists": retained is not None,
                    "destination_bytes": retained or "",
                    "backup_bytes": backup,
                    "destination_reads": 0
                    if name
                    in {
                        "owner_stale_before_read",
                        "owner_callback_raises",
                        "owner_callback_nontrue",
                    }
                    else 1,
                    "current_checks": 1,
                    "boundary_reached": True,
                    "methods_restored": True,
                    "owner_modeled": True,
                }
            )
        return {
            "schema": 1,
            "status": "ok",
            "runtime": "native Hammerspoon",
            "pid": 42,
            "nonce": "0" * 32,
            "version": "1.1.1",
            "case_results": [{"id": name, "passed": True} for name in COHORTS[cohort]],
            "authority": dict(AUTHORITY),
            "cohort": cohort,
            "full_inventory": list(FULL_CASES),
            "observations": observations,
            "boundary_model": BOUNDARY_MODEL,
        }

    names = (
        "healthy_source",
        "healthy_owner",
        "healthy_refusal",
        "missing_observation",
        "extra_observation_key",
        "duplicate_observation",
        "truthy_observation",
        "wrong_detail",
        "wrong_removed",
        "wrong_backup_count",
        "wrong_publish_count",
        "wrong_destination_bytes",
        "wrong_backup_bytes",
        "wrong_boundary",
        "early_destination_read",
        "missing_owner_check",
        "wrong_cohort",
        "wrong_full_inventory",
        "missing_authority",
        "unexpected_top_field",
    )
    for name in names:
        cohort = name.removeprefix("healthy_") if name.startswith("healthy_") else "source"
        packet = modeled_packet(cohort)
        first = packet["observations"][0]
        if name == "missing_observation":
            packet["observations"].pop()
        elif name == "extra_observation_key":
            first["extra"] = True
        elif name == "duplicate_observation":
            packet["observations"][1] = copy.deepcopy(first)
        elif name == "truthy_observation":
            first["ok"] = 1
        elif name == "wrong_detail":
            first["detail"] = "removed-unconfirmed"
        elif name == "wrong_removed":
            first["removed"] += 1
        elif name == "wrong_backup_count":
            first["backup_files"] = 0
        elif name == "wrong_publish_count":
            first["publication_calls"] = 0
        elif name == "wrong_destination_bytes":
            first["destination_bytes"] += " "
        elif name == "wrong_backup_bytes":
            first["backup_bytes"] += " "
        elif name == "wrong_boundary":
            first["boundary_reached"] = False
        elif name == "early_destination_read":
            packet["observations"][3]["destination_reads"] = 1
        elif name == "missing_owner_check":
            first["current_checks"] = 0
        elif name == "wrong_cohort":
            packet["cohort"] = "owner"
        elif name == "wrong_full_inventory":
            packet["full_inventory"].pop()
        elif name == "missing_authority":
            packet["authority"].pop("installation")
        elif name == "unexpected_top_field":
            packet["unexpected"] = True
        try:
            admit_consent(
                packet, "0" * 32, 42, "1.1.1", report, before, before, 1, 2, cohort, oracle, corpus
            )
        except ValueError:
            require(not name.startswith("healthy_"), "Healthy modeled consent receipt refused")
        else:
            require(
                name.startswith("healthy_"), "Negative modeled consent receipt accepted: " + name
            )
    require(
        tuple(name for ids in COHORTS.values() for name in ids) == FULL_CASES
        and len(set(FULL_CASES)) == 12
        and all(len(ids) == 4 for ids in COHORTS.values()),
        "Incomplete fixed partition",
    )
    completed = len(names) + 1
    with tempfile.TemporaryDirectory(prefix="consent-source-controls-") as temporary:
        source = Path(temporary).resolve(strict=True) / "source"
        copied = Path(temporary).resolve(strict=True) / "copied"
        for root in (source, copied):
            for directory in (
                "static/ergopti_plus/macos",
                "static/ergopti_plus/_shared",
                "static/layouts",
            ):
                (root / directory).mkdir(parents=True, mode=0o700)
            for relative in SOURCE_EXTRAS:
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                shutil.copyfile(repo / relative, destination)
        identities = source_inventory(source)
        verify_sources(source, copied, identities)
        target = "tools/diagnostics/hs_legacy_consent_native.lua"
        for name in ("actual_source_changed", "actual_copy_changed", "actual_source_alias"):
            selected = copied if name == "actual_copy_changed" else source
            file = selected / target
            original = file.read_bytes()
            alias_target = file.with_name("literal-alias-target.lua")
            if name == "actual_source_alias":
                file.rename(alias_target)
                file.symlink_to(alias_target.name)
            else:
                file.write_bytes(
                    original + b"\n-- Actual private source-currentness negative control.\n"
                )
            try:
                try:
                    verify_sources(source, copied, identities)
                except ValueError:
                    pass
                else:
                    raise ValueError("Actual changed/aliased source was accepted: " + name)
            finally:
                if name == "actual_source_alias":
                    file.unlink()
                    alias_target.rename(file)
                else:
                    file.write_bytes(original)
            verify_sources(source, copied, identities)
            completed += 1
    require(completed == 24, "Portable consent control inventory differs")
    print(
        "PASS consent portable receipt/source controls tests=24 failures=0 errors=0 skipped=0 native=unexecuted"
    )


SOURCE_EXTRAS = (
    "tools/diagnostics/hs_legacy_cleanup_native.lua",
    "tools/diagnostics/fixtures/karabiner-legacy-cleanup-acceptance.json",
    "tools/diagnostics/macos_physical_clock.py",
    "tools/diagnostics/macos_tooltip_canvas.py",
    "tools/diagnostics/macos_owned_process.py",
    "tools/build/build_macos_app.sh",
    ".github/workflows/ci-macos.yml",
    "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274LegacyCleanupQualificationTests.swift",
) + EXTRA_SOURCE_PATHS


def source_inventory(repo):
    files = {}
    extensions = {".lua", ".json", ".toml"}
    for relative in ("static/ergopti_plus/macos", "static/ergopti_plus/_shared", "static/layouts"):
        tree = repo / relative
        require(tree.is_dir() and tree.resolve(strict=True) == tree, "Unsafe source root")
        for path in tree.rglob("*"):
            if any(part in {".build", "node_modules", "__pycache__"} for part in path.parts):
                continue
            if path.suffix not in extensions:
                continue
            require(path.resolve(strict=True) == path and path.is_file(), "Source alias refused")
            files[str(path.relative_to(repo))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for relative in SOURCE_EXTRAS:
        path = repo / relative
        require(path.resolve(strict=True) == path and path.is_file(), "Source alias refused")
        files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return files


def admit_consent(
    packet,
    nonce,
    pid,
    version,
    report,
    before,
    after,
    observed_at,
    deadline,
    cohort,
    oracle,
    corpus,
):
    require(type(cohort) is str and cohort in COHORTS, "Unknown fixed native cohort")
    require(
        type(packet) is dict
        and set(packet)
        == {
            "schema",
            "status",
            "runtime",
            "pid",
            "nonce",
            "version",
            "case_results",
            "authority",
            "cohort",
            "full_inventory",
            "observations",
            "boundary_model",
        },
        "Unexpected receipt fields",
    )
    require(
        type(packet["schema"]) is int
        and packet["schema"] == 1
        and packet["status"] == "ok"
        and packet["runtime"] == "native Hammerspoon",
        "Native receipt scope differs",
    )
    require(
        type(pid) is int and pid > 0 and type(packet["pid"]) is int and packet["pid"] == pid,
        "Foreign native PID",
    )
    require(
        type(nonce) is str
        and re.fullmatch(r"[0-9a-f]{32}", nonce)
        and packet["nonce"] == nonce
        and type(version) is str
        and version
        and packet["version"] == version,
        "Foreign runtime identity",
    )
    cases = packet["case_results"]
    require(type(cases) is list and len(cases) == len(COHORTS[cohort]), "Incomplete case inventory")
    for expected, result in zip(COHORTS[cohort], cases, strict=True):
        require(
            type(result) is dict
            and set(result) == {"id", "passed"}
            and result["id"] == expected
            and result["passed"] is True,
            "Case identity or exact acknowledgement differs",
        )
    authority = packet["authority"]
    require(type(authority) is dict and set(authority) == set(AUTHORITY), "Authority fields differ")
    for key, value in AUTHORITY.items():
        require(
            type(authority[key]) is type(value) and authority[key] == value,
            "Cleanup fixture cannot grant authority",
        )
    clock.validate_owner(report, pid)
    require(
        type(before) is dict and bool(before) and type(after) is dict and before == after,
        "Source ownership changed",
    )
    for key, value in before.items():
        require(
            type(key) is str
            and key
            and type(value) is str
            and re.fullmatch(r"[0-9a-f]{64}", value),
            "Unqualified source identity",
        )
    for value in (observed_at, deadline):
        require(
            type(value) in (int, float)
            and abs(value) <= 1e12
            and math.isfinite(value)
            and value >= 0,
            "Invalid native deadline",
        )
    require(observed_at < deadline, "Native receipt completed after deadline")
    validate_observations(packet, cohort, oracle, corpus)
    return packet


def native(repo, root, cohort):
    require(
        sys.platform == "darwin" and sys.version_info >= (3, 13),
        "Native macOS CPython3.13 required",
    )
    require(type(cohort) is str and cohort in COHORTS, "Unknown fixed native cohort")
    start = time.monotonic()
    deadline = start + 25
    root = clock.ordinary_owner_root(root)
    repo = repo.resolve(strict=True)
    before = source_inventory(repo)
    oracle, corpus = load_oracles(repo)
    output = root / ("legacy-consent-" + cohort)
    output.mkdir(mode=0o700)
    copied = output / "source"
    for relative in before:
        destination = copied / relative
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(repo / relative, destination)
    executable, provisioning = clock.acquire_runtime(
        repo, output, min(deadline, time.monotonic() + 10)
    )
    nonce = uuid.uuid4().hex
    owner.exclusive_receipt(
        output / "configuration.json",
        {
            "source": str(copied),
            "root": str(output),
            "nonce": nonce,
            "version": provisioning["version"],
            "cohort": cohort,
            "case_ids": list(COHORTS[cohort]),
        },
    )
    configuration_hash = hashlib.sha256((output / "configuration.json").read_bytes()).hexdigest()
    config = output / "init.lua"
    # Source/JSON/filesystem are actual; only log/config location recording is modeled.
    config.write_text("""local json = require("hs.json")
local location = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local config = assert(json.read(location .. "/configuration.json"))
package.path = config.source .. "/static/ergopti_plus/macos/?.lua;" .. config.source .. "/static/ergopti_plus/macos/?/init.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local noop = function() end
package.loaded["infra.logger"] = { info=noop, warn=noop, error=noop, debug=noop, start=noop, done=noop, success=noop, trace=noop }
package.loaded["infra.config_paths"] = { get_config_dir=function() return config.root .. "/" end }
local baseline = assert(dofile(config.source .. "/tools/diagnostics/hs_legacy_cleanup_native.lua"))
local scenario = assert(dofile(config.source .. "/tools/diagnostics/hs_legacy_consent_native.lua"))
local corpus = assert(json.read(config.source .. "/tools/diagnostics/fixtures/karabiner-legacy-cleanup-acceptance.json"))
local oracle = assert(json.read(config.source .. "/tools/diagnostics/fixtures/karabiner-legacy-consent-acceptance.json"))
local context = baseline.context(config.source .. "/static/ergopti_plus/macos/platform/remap/data/")
local results, observations = {}, {}
for _, id in ipairs(config.case_ids) do
    local path = config.root .. "/" .. id
    assert(hs.fs.mkdir(path))
    local result, observation = scenario.run_case(path, corpus, oracle, id, context)
    results[#results+1], observations[#observations+1] = result, observation
end
local controller = package.loaded["platform.remap.lease_controller"]
assert(controller == nil or controller.is_initialized() == false)
local packet = {schema=1,status="ok",runtime="native Hammerspoon",pid=hs.processInfo.processID,nonce=config.nonce,version=hs.processInfo.version,case_results=results,authority={physical_input="unexecuted",user_backup="unavailable",ui_confirmation="unexecuted",lease_initialized=false,installation=false},cohort=config.cohort,full_inventory=oracle.case_ids,observations=observations,boundary_model="owner predicate and interleaving only; actual production JSON/files/backup/CAS"}
local encoded = assert(json.encode(packet, true))
local file = assert(io.open(config.root .. "/result.pending", "wb"))
assert(file:write(encoded))
assert(file:close())
assert(os.rename(config.root .. "/result.pending", config.root .. "/result.json"))
""")
    config_hash = hashlib.sha256(config.read_bytes()).hexdigest()
    actual_pid = None

    def unchanged():
        require(
            hashlib.sha256((output / "configuration.json").read_bytes()).hexdigest()
            == configuration_hash,
            "Native configuration changed",
        )
        verify_sources(repo, copied, before)
        require(
            hashlib.sha256(config.read_bytes()).hexdigest() == config_hash, "Native entry changed"
        )
        require(
            hashlib.sha256(executable.read_bytes()).hexdigest()
            == provisioning["executable_sha256"],
            "Native runtime changed",
        )

    def operation(group):
        nonlocal actual_pid
        actual_pid = group.process.pid
        probe_deadline = min(deadline, time.monotonic() + 10)
        while time.monotonic() < probe_deadline:
            require(group.observe_exit() is None, "Exact Hammerspoon child exited before receipt")
            unchanged()
            if (output / "result.json").exists():
                record = read_record(output / "result.json")
                require(
                    group.observe_exit() is None, "Exact Hammerspoon child exited during receipt"
                )
                unchanged()
                require(time.monotonic() < probe_deadline, "Native receipt read deadline")
                return {"native_result": record}
            time.sleep(0.01)
        raise ValueError("Native cleanup observation deadline")

    unchanged()
    report = facade.owned_observation(
        executable, config, output, operation, owner.NativeProcessGroups()
    )
    unchanged()
    after = source_inventory(repo)
    packet = admit_consent(
        report.get("native_result"),
        nonce,
        actual_pid,
        provisioning["version"],
        report,
        before,
        after,
        time.monotonic(),
        deadline,
        cohort,
        oracle,
        corpus,
    )
    result = {
        "status": "ok",
        "cohort": cohort,
        "full_inventory": list(FULL_CASES),
        "qualification": "actual production legacy consent guard private files",
        "native_result": packet,
        "native_owner": report["native_owner"],
        "source_identities": before,
        "provisioning": provisioning,
        "controller_budget_seconds": 25,
        "observation_retirement_seconds": time.monotonic() - start,
    }
    owner.exclusive_receipt(output / "qualification.json", result)
    unchanged()
    require(time.monotonic() < deadline, "Native qualification persistence exceeded deadline")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--portable", action="store_true")
    parser.add_argument("--cohort", choices=tuple(COHORTS))
    args = parser.parse_args()
    repo = args.repo.absolute()
    require(repo.resolve(strict=True) == repo, "Aliased repository")
    here = Path(__file__).absolute()
    require(
        here.resolve(strict=True) == here
        and here == repo / "tools/diagnostics/macos_legacy_consent.py",
        "Controller imported from another source",
    )
    sys.path.insert(0, str(repo / "tools/diagnostics"))
    global clock, owner, facade
    import macos_physical_clock as clock
    import macos_owned_process as owner
    import macos_tooltip_canvas as facade

    clock.validate_imports(repo)
    if args.portable:
        require(args.cohort is None, "Portable controls cannot select a native cohort")
        portable()
        portable_consent(repo)
    else:
        require(args.cohort is not None, "Native execution requires one fixed cohort")
        print(json.dumps(native(repo, args.root, args.cohort), sort_keys=True))


if __name__ == "__main__":
    main()
