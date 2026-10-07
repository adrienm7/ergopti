# tools/build/remap_runtime_initializer_support.py
"""Execute literal initializer controls with authentic offline portable inputs.

Only the original protected reference, Security/audit leaves and private access
seam are modeled. Actual Asio, dispatcher, request manager and socket FDs run.
This test support grants no native initializer, IOKit readiness or capture proof.
"""

from contextlib import contextmanager
import hashlib
import importlib.util
import sys
from pathlib import Path
import tempfile

BUILD = Path(__file__).resolve().parent
CORPUS = BUILD / "fixtures/remap_runtime_initializer_controls.json"
CORPUS_SHA256 = "0808b6f2a4eb3c0f4fe7ea8237db9ccd712c85329f30360ce29296a2971d6467"
HARNESS_SHA256 = "db23cdb25fbf0a021107765c0e797c61f6fb25f0a3cbfb52deb80722677f928d"
FIXTURE_SHA256 = "a4d62ba7da04436f438248b998a702b89d3b8475de7a2de947270cfbfb088c02"
DELIVERY = (
    "healthy",
    "unbound",
    "bytes_mismatch",
    "empty",
    "noncanonical",
    "error",
    "duplicate",
    "retired",
    "changed_peer",
)
EXTRA = {
    "unknown_response": "UNKNOWN-RESPONSE-CONTROL-BEFORE.cpp",
    "queue_refusal": "QUEUE-REFUSAL-CONTROL-BEFORE.cpp",
    "foreign_debt": "FOREIGN-EXECUTOR-DEBT-CONTROL-BEFORE.cpp",
    "timer_observation": "TIMER-EXECUTOR-OBSERVATION-CONTROL-BEFORE.cpp",
    "empty_refusal": "SHUTDOWN-EMPTY-QUEUE-REFUSAL-CONTROL-AUTHORED-AFTER.cpp",
    "reserved_kind": "RESERVED-KIND-CONTROL-BEFORE.cpp",
    "outbound_wire": "OUTBOUND-WIRE-CONTROL-AUTHORED-AFTER.cpp",
    "pending_cancel": "PENDING-CANCEL-ORDER-CONTROL-BEFORE.cpp",
    "completion_reentry": "COMPLETION-REENTRY-REF-RETIREMENT-CONTROL-AUTHORED-AFTER.cpp",
    "peer_reentry": "ACTUAL-PEER-OBSERVER-REENTRY-CONTROL-AUTHORED-AFTER.cpp",
    "completion_exception": "COMPLETION-EXCEPTION-RETENTION-CONTROL-BEFORE-GUARD.cpp",
}
CASES = (
    "healthy",
    "unbound",
    "bytes_mismatch",
    "empty",
    "noncanonical",
    "error",
    "unknown_response",
    "duplicate",
    "retired",
    "changed_peer",
    "timer",
    "queue_refusal",
    "callback",
    "foreign_debt",
    "timer_observation",
    "empty_refusal",
    "reserved_kind",
    "outbound_wire",
    "pending_cancel",
    "completion_reentry",
    "peer_reentry",
    "completion_exception",
)


def fixed_module(name, path, expected):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError("fixed initializer support source drift")
    spec = importlib.util.spec_from_loader(name, loader=None)
    module = importlib.util.module_from_spec(spec)
    module.__file__ = str(path)
    sys.modules[name] = module
    exec(compile(data, str(path), "exec"), module.__dict__)
    return module


@contextmanager
def prepared(directory):
    """Reuse the unchanged original source harness and reviewed offline fixture."""
    fixture = fixed_module(
        "initializer_offline_fixture", BUILD / "remap_runtime_vhd_fixture.py", FIXTURE_SHA256
    )
    directory = fixture.owner(directory)
    # Read the exported independent corpus through the same ordinary held-FD cut.
    data = fixture.read_owned(CORPUS, 100000, "initializer_corpus")
    fixture.require(hashlib.sha256(data).hexdigest() == CORPUS_SHA256, "initializer_corpus")
    corpus = fixture.json.loads(data)
    fixture.require(corpus["schema"] == 1, "initializer_corpus")
    controls = corpus["controls"]
    fixture.require(
        set(controls) == set(EXTRA.values()) | {"DELIVERY-CONTROLS-ACCESS-SUCCESSOR.cpp"},
        "initializer_corpus",
    )
    for row in controls.values():
        fixture.require(
            type(row["cpp"]) is str
            and hashlib.sha256(row["cpp"].encode()).hexdigest() == row["sha256"],
            "initializer_corpus",
        )
    harness = fixed_module(
        "initializer_original_source_harness", BUILD / "remap_runtime_vhd_test.py", HARNESS_SHA256
    )
    entries = fixture.sources(census=fixture.manifest())
    with tempfile.TemporaryDirectory(prefix="initializer-offline-source-", dir=directory) as tmp:
        root = Path(tmp).resolve(strict=True)
        source, output = root / "source", root / "projection"
        source.mkdir(mode=0o700)
        output.mkdir(mode=0o700)
        fixture.publish_sources(source, entries)
        harness.prepare_inputs(output, source)
        for case in CASES:
            if case in DELIVERY:
                # Only existing literal case-selection defines; entire CPP body stays whole.
                cpp = (
                    f'#define DELIVERY_CASE {case}\n#define DELIVERY_CASE_NAME "{case}"\n'
                    + controls["DELIVERY-CONTROLS-ACCESS-SUCCESSOR.cpp"]["cpp"]
                )
            elif case in ("timer", "callback"):
                cpp = harness.CPP_CONTROLS[case]
            else:
                cpp = controls[EXTRA[case]]["cpp"]
            harness.CPP_CONTROLS["initializer_" + case] = cpp
        yield harness
