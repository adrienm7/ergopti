import copy, importlib.util, pathlib, contextlib, io, json

path = pathlib.Path(__file__).resolve().with_name("validate.py")
spec = importlib.util.spec_from_file_location("audit_validation", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original = module.load
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
    if p.name == "findings.json" and p.parent.name == "macos-crypto":
        row = next(x for x in data["findings"] if x["id"] == "MCR-002")
        row["guarantees"] = []
        row.pop("confidentiality", None)
        row.pop("additional_property", None)
    return data


check("unclassified-additional-property", bad_property)


def missing_evidence(p, data):
    if p.name == "intentional-differences.json":
        data["differences"][0]["evidence_reports"] = ["missing/report.md"]
    return data


check("missing-evidence-report", missing_evidence)
print(
    json.dumps(
        {
            "baseline": "current real campaign validates; mutations isolated in parser return values only",
            "negative_controls": cases,
        },
        indent=2,
    )
)
