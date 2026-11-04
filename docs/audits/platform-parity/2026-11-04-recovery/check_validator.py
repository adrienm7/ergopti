import copy, importlib.util, pathlib, contextlib, io, json

path = pathlib.Path(__file__).resolve().with_name("validate.py")
spec = importlib.util.spec_from_file_location("audit_validation", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original = module.load
baseline_output = io.StringIO()
with contextlib.redirect_stdout(baseline_output):
    module.main()
cases = []


def check(name, corrupt):
    def load(p):
        data = copy.deepcopy(original(p))
        return corrupt(p, data)

    module.load = load
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            module.main()
    except AssertionError:
        cases.append({"case": name, "refused": True})
    else:
        raise AssertionError("negative control accepted " + name)
    finally:
        module.load = original


def bad_sha(p, data):
    if p.name == "index.json":
        data["audited_sha"] = "not-a-commit"
    return data


check("invalid-source-identity", bad_sha)


def duplicate_scope(p, data):
    if p.name == "index.json":
        data["scopes"][1] = copy.deepcopy(data["scopes"][0])
    return data


check("duplicate-os-module-scope", duplicate_scope)


def bad_property(p, data):
    if p.name == "findings.json" and p.parent.name == "macos-migration":
        row = next(x for x in data["findings"] if x["id"] == "MFM-002")
        row["guarantees"] = []
        row.pop("confidentiality", None)
        row.pop("additional_property", None)
    return data


check("unclassified-additional-property", bad_property)


def missing_evidence(p, data):
    if p.name == "capabilities.json":
        data["capabilities"][0]["evidence_reports"] = ["missing/report.md"]
    return data


check("missing-evidence-report", missing_evidence)


def malformed_property_list(p, data):
    if p.name == "findings.json" and p.parent.name == "linux-migration":
        data["findings"][0]["additional_properties"] = {"wrong": "container"}
    return data


check("malformed-additional-property-container", malformed_property_list)

print(
    json.dumps(
        {
            "baseline": baseline_output.getvalue().strip(),
            "mutation_scope": "Parser return values only; no real files changed",
            "negative_controls": cases,
        },
        indent=2,
    )
)
