# tools/diagnostics/macos_metrics_apps_page.py
"""Require the real MetricsApps WK page; pure schema examples are never native evidence."""

import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import platform
import re
import secrets
import shutil
import time

import macos_owned_process as owner
from macos_webview_binding import exact, require, revision

CONTRACT = "native.metrics-apps-page"
SCOPE = "actual UiBuilder and MetricsApps page; Host.show, SQLite and native choosers unmeasured"
INPUT_SCOPE = "not attempted; JavaScript DOM click only"
FILTER_SCOPE = (
    "category rename and DOM filter with non-null selection; Host.show and persistence unmeasured"
)
DEPENDENCIES = (
    "static/ergopti_plus/macos/ui/ui_builder.lua",
    "static/ergopti_plus/macos/ui/webview_close_owner.lua",
    "static/ergopti_plus/macos/adapters/timer_scheduler.lua",
    "static/ergopti_plus/macos/infra/deferred_work.lua",
    "static/ergopti_plus/macos/adapters/webview_result.lua",
    "static/ergopti_plus/macos/ui/metrics_apps/init.lua",
    "static/ergopti_plus/_shared/lua/webview/i18n_seed.lua",
    "static/ergopti_plus/_shared/data/locales/fr.json",
)
PAGE = "static/ergopti_plus/_shared/ui/metrics_apps/index.html"
CALLER = "static/ergopti_plus/macos/ui/metrics_apps/init.lua"


class PageAssets(HTMLParser):
    """Read only assets that the actual HTML declares, including its inline owner."""

    def __init__(self):
        super().__init__()
        self.paths = []
        self.scripts = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "script" and "src" in attrs:
            self.scripts.append(attrs["src"])
            self.paths.append(attrs["src"])
        if tag == "link" and attrs.get("rel") == "stylesheet":
            self.paths.append(attrs["href"])


def source_identity(repo):
    """Pin the real factory, caller query, declared assets and native locale seed."""
    page = repo / PAGE
    parser = PageAssets()
    parser.feed(page.read_text(encoding="utf-8"))
    require(
        len(parser.scripts) == 10 and parser.scripts[-1] == "modal.js", "page script census differs"
    )
    require("script.js" not in parser.scripts, "legacy dashboard cannot qualify the loaded page")
    paths = {repo / name for name in (*DEPENDENCIES, PAGE)}
    for name in parser.paths:
        require(not re.match(r"^[a-zA-Z]+:|^/", name), "page asset is not a local declaration")
        declared = page.parent / name
        require(declared.is_file() and not declared.is_symlink(), "declared page asset redirected")
        path = declared.resolve()
        require(path.is_relative_to(repo.resolve()), "page asset escaped source root")
        paths.add(path)
    sources = {}
    for path in sorted(paths):
        require(
            path.is_file() and not path.is_symlink(), "source missing or redirected: " + str(path)
        )
        sources[str(path.relative_to(repo))] = hashlib.sha256(path.read_bytes()).hexdigest()
    encoded = json.dumps(sources, sort_keys=True, separators=(",", ":")).encode()
    return sources, hashlib.sha256(encoded).hexdigest()


def page_contract(repo):
    """Use the actual caller's expression and the actually declared vendor version."""
    source = (repo / CALLER).read_text(encoding="utf-8")
    queries = re.findall(
        r'return submit_javascript\(generation, webview, "(typeof window\.[A-Za-z_$][A-Za-z0-9_$]*)"',
        source,
    )
    require(queries == ["typeof window.publishMetricsAppsData"], "native readiness query differs")
    vendor = repo / "static/ergopti_plus/_shared/ui/vendor/chart.umd.js"
    versions = re.findall(r"Chart\.js v([0-9.]+)", vendor.read_text(encoding="utf-8"))
    require(len(versions) == 1, "actual Chart version unavailable")
    return queries[0], versions[0]


def expected_snapshot(
    editor_ms,
    browser_ms,
    edited=False,
    filtered=False,
    chart_version="4.4.9",
    *,
    empty=False,
    selection=None,
):
    """Independent primitive expectations, not a synthetic native execution receipt."""
    labels = {"Editor": "Mon équipe" if edited else "constructor", "Browser": "toString"}
    times = {} if empty else {"Editor": editor_ms, **({} if filtered else {"Browser": browser_ms})}
    if filtered and selection is None:
        selection = [labels["Editor"]]
    return {
        "row_count": len(times),
        "rows": {
            name: {"category": labels[name], "duration": str(ms // 60000) + "m"}
            for name, ms in times.items()
        },
        "times": times,
        "categories": {
            "Editor": {"type": labels["Editor"], "score": 1 if edited else 0},
            "Browser": {"type": "toString", "score": 0},
        },
        "by_category": {labels[name]: ms for name, ms in times.items()},
        "pie_labels": []
        if empty
        else ([labels["Editor"]] if filtered else ["toString", labels["Editor"]]),
        "pie_hours": (
            []
            if empty
            else (
                [0.02 if editor_ms == 60000 else 0.03]
                if filtered
                else ([0.03, 0.02] if editor_ms == 60000 else [0.07, 0.03])
            )
        ),
        "filter_buttons": {
            label: selection is None or label in selection for label in labels.values()
        },
        "filter_selection": selection,
        "render_error": False,
        "script_errors": 0,
        "same_publishers": True,
        "chart_version": chart_version,
    }


def validate(
    result, pid, version, nonce, source_revision, architecture, source_digest, chart_version
):
    """Refuse absent capabilities, DOM/projection facts, native provenance or cleanup."""
    require(
        type(result) is dict and result.get("status") == "ok", "native page failed: " + str(result)
    )
    fixed = {
        "schema_version": 1,
        "contract": CONTRACT,
        "scope": SCOPE,
        "native_input": INPUT_SCOPE,
        "ucc_userdata_gc": "unmeasured",
        "nonce": nonce,
        "source_revision": source_revision,
        "source_manifest_digest": source_digest,
        "pid": pid,
        "version": version,
        "arch": architecture,
        "status": "ok",
        "errors": [],
        "phase": "complete",
        "navigation_completed": True,
        "native_apis_unmodified": True,
        "filter_scope": FILTER_SCOPE,
        "readiness": {
            "data": "function",
            "categories": "function",
            "ready_state": "complete",
            "dependencies": ["function"] * 4,
            "private_owner_exposed": False,
            "chart_version": chart_version,
        },
        "native_message": {
            "name": "metrics_apps_bridge",
            "webview_type": "userdata",
            "webview_exact": True,
            "main_frame": True,
            "body": {"action": "edit", "app": "Editor", "cat": "constructor", "score": 0},
        },
    }
    require(architecture in ("arm64", "x86_64"), "unsupported native page architecture")
    require(
        result.keys() == fixed.keys() | {"steps", "cleanup"}, "native page receipt schema differs"
    )
    for key, wanted in fixed.items():
        require(exact(result[key], wanted), "native page identity or observation differs: " + key)
    initial = expected_snapshot(60000, 120000, chart_version=chart_version)
    filtered = expected_snapshot(60000, 120000, filtered=True, chart_version=chart_version)
    edited = expected_snapshot(60000, 120000, edited=True, chart_version=chart_version)
    fresh = expected_snapshot(120000, 240000, edited=True, chart_version=chart_version)
    latest = expected_snapshot(120000, 240000, chart_version=chart_version)
    expected = {
        "initial": {"applied": True, "snapshot": initial},
        "filter": {"applied": True, "snapshot": filtered},
        "filter_reset": {"applied": True, "snapshot": initial},
        "category_edit": {"applied": True, "snapshot": edited},
        "newer_manifest": {"applied": True, "snapshot": fresh},
        "stale": {"applied": False, "snapshot": fresh},
        "newer_categories": {"applied": True, "snapshot": latest},
        "select_before_rename": {
            "applied": True,
            "snapshot": expected_snapshot(
                120000, 240000, filtered=True, chart_version=chart_version
            ),
        },
        "rename_selected": {
            "applied": True,
            "snapshot": expected_snapshot(
                120000,
                240000,
                edited=True,
                empty=True,
                selection=["constructor"],
                chart_version=chart_version,
            ),
        },
        "include_renamed": {
            "applied": True,
            "snapshot": expected_snapshot(
                120000,
                240000,
                edited=True,
                filtered=True,
                selection=["Mon équipe", "constructor"],
                chart_version=chart_version,
            ),
        },
        "include_remaining": {"applied": True, "snapshot": fresh},
        "restore_categories": {"applied": True, "snapshot": latest},
    }
    require(
        type(result["steps"]) is dict and result["steps"].keys() == expected.keys(),
        "native page step census differs",
    )
    observed = {}
    for name, raw in result["steps"].items():
        require(
            type(raw) is str and len(raw) <= 8192, "native step JSON result missing or oversized"
        )
        observed[name] = json.loads(raw)
    require(
        exact(observed, expected),
        "native page publication, categories or stale result differs",
    )
    cleanup = result["cleanup"]
    require(type(cleanup) is dict, "native cleanup facts missing")
    baseline = cleanup.get("product_timer_baseline")
    require(type(baseline) is int and baseline >= 0, "native timer baseline unavailable")
    require(
        exact(
            cleanup,
            {
                "callback_detached": True,
                "window_consumed": True,
                "product_timer_baseline": baseline,
                "product_timer_final": baseline,
                "probe_timers_final": 0,
                "evaluation_pending": False,
            },
        ),
        "native page retains cleanup debt",
    )


def check_logs(output):
    """Keep every native diagnostic byte and refuse errors, including the last boundary."""
    for name in ("launch.stdout", "launch.stderr", "console.txt"):
        path = output / name
        require(
            path.is_file() and not path.is_symlink() and path.stat().st_size <= 1024 * 1024,
            "native page log unavailable or oversized: " + name,
        )
        text = path.read_text(encoding="utf-8")
        require(
            re.search(
                r"\b(?:error|exception|ERRRUN)\b|NOREF/REFNIL|C stack overflow|\bNS\w*Exception\b|assertion failure",
                text,
                re.I,
            )
            is None,
            "native page runtime failure in " + name,
        )


def supervise(
    group,
    output,
    version,
    nonce,
    source_revision,
    architecture,
    source_digest,
    chart_version,
    unchanged,
    timeout=50,
):
    """Observe only the exact still-live reserved child; retain the final live interval."""
    deadline = time.monotonic() + timeout
    while True:
        require(group.observe_exit() is None, "native page owner exited before receipt")
        path = output / "result.json"
        if path.exists():
            require(
                not path.is_symlink() and path.stat().st_size <= 65536,
                "native page result redirected or oversized",
            )
            captured = path.read_bytes()
            result = json.loads(captured)
            validate(
                result,
                group.process.pid,
                version,
                nonce,
                source_revision,
                architecture,
                source_digest,
                chart_version,
            )
            check_logs(output)
            unchanged()
            time.sleep(0.5)
            require(
                group.observe_exit() is None, "native page owner exited during final observation"
            )
            require(
                not path.is_symlink() and path.read_bytes() == captured,
                "native page receipt changed",
            )
            check_logs(output)
            unchanged()
            return {
                "native_execution": "executed",
                "native_process_observed": True,
                "result": result,
            }
        require(time.monotonic() < deadline, "native page receipt deadline exceeded")
        time.sleep(0.05)


def validate_retirement(receipt):
    """Use the established exact inherited-PGID terminal facts, never process status alone."""
    native = receipt.get("native_owner")
    require(
        type(native) is dict
        and native.get("closed") is True
        and native.get("reservation_lost") is False
        and native.get("live_group_members") == []
        and type(native.get("worker_pid")) is int
        and native["worker_pid"] > 0
        and type(native.get("group_id")) is int
        and native["group_id"] == native["worker_pid"],
        "native page process retirement incomplete",
    )
    require(
        receipt.get("status") == "ok"
        and receipt.get("native_execution") == "executed"
        and receipt.get("native_process_observed") is True
        and receipt.get("operation_error") is None
        and receipt.get("cleanup_errors") == [],
        "native page observation or cleanup failed",
    )
    return native["worker_pid"]


def qualify(repo, executable, scratch, output, version, unchanged, observe_owned, native):
    """Reuse Tooltip's existing signed-runtime and reserved child owner, without a new workflow."""
    source_revision, architecture = revision(repo), platform.machine()
    require(architecture in ("arm64", "x86_64"), "native page architecture unavailable")
    sources, source_digest = source_identity(repo)
    query, chart_version = page_contract(repo)
    work, destination = scratch / "metrics-apps-page", output / "metrics-apps-page"
    work.mkdir(mode=0o700)
    destination.mkdir(mode=0o700)
    module = work / "macos_metrics_apps_page.lua"
    shutil.copyfile(Path(__file__).with_suffix(".lua"), module)
    context = work / "metrics-page-config.json"
    nonce = secrets.token_hex(16)
    owner.exclusive_receipt(
        context,
        {
            "production_root": str(repo / "static/ergopti_plus"),
            "expected_version": version,
            "nonce": nonce,
            "source_revision": source_revision,
            "source_manifest_digest": source_digest,
            "readiness_query": query,
            "output_dir": str(destination),
        },
    )
    startup = work / "metrics-page-start.lua"
    startup.write_text(
        'local directory=assert(debug.getinfo(1,"S").source:match("^@(.+)/[^/]+$"))\n'
        'local json=require("hs.json")\n'
        'local config=assert(json.read(directory.."/metrics-page-config.json"))\n'
        'dofile(directory.."/macos_metrics_apps_page.lua").run(config,function(result,evaluations,message)\n'
        " local output=assert(config.output_dir)\n"
        ' local file=assert(io.open(output.."/console.txt","wb")); assert(file:write(hs.console.getConsole())); assert(file:close())\n'
        ' assert(json.write(evaluations,output.."/evaluations.json",true,true))\n'
        ' local raw=assert(io.open(output.."/native-message.txt","wb")); assert(raw:write(message or "unobserved")); assert(raw:close())\n'
        ' assert(json.write(result,output.."/result.json.tmp",true,true)); assert(os.rename(output.."/result.json.tmp",output.."/result.json"))\n'
        "end)\n",
        encoding="utf-8",
    )
    payload = {
        path: hashlib.sha256(path.read_bytes()).hexdigest() for path in (module, context, startup)
    }

    def frozen():
        unchanged()
        require(
            revision(repo) == source_revision and source_identity(repo) == (sources, source_digest),
            "native page production source changed",
        )
        require(
            all(
                not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == digest
                for path, digest in payload.items()
            ),
            "native page diagnostic payload changed",
        )

    receipt = {}
    try:
        frozen()
        receipt = observe_owned(
            executable,
            startup,
            destination,
            lambda group: supervise(
                group,
                destination,
                version,
                nonce,
                source_revision,
                architecture,
                source_digest,
                chart_version,
                frozen,
            ),
            native,
        )
        pid = validate_retirement(receipt)
        validate(
            receipt.get("result"),
            pid,
            version,
            nonce,
            source_revision,
            architecture,
            source_digest,
            chart_version,
        )
        check_logs(destination)
        frozen()
    except BaseException as error:
        receipt.update(status="error", qualification_error=str(error) or type(error).__name__)
        raise
    finally:
        receipt.update(
            source_revision=source_revision,
            architecture=architecture,
            source_manifest=sources,
            source_manifest_digest=source_digest,
            diagnostic_payload={
                str(path.relative_to(work)): value for path, value in payload.items()
            },
        )
        try:
            check_logs(destination)
        except Exception as error:
            receipt.update(status="error", final_log_error=str(error))
        owner.exclusive_receipt(destination / "supervisor.json", receipt)
    require(receipt.get("status") == "ok", "native page final logs refused")
    return receipt
