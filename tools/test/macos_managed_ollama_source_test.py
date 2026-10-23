#!/usr/bin/env python3
# tools/test/macos_managed_ollama_source_test.py
"""Receive the native Ollama hooks against independently pinned upstream files."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
UPSTREAM = None
# These vectors were frozen from the reviewed upstream commit, before applying
# any product hook. They must not be regenerated from patched candidate files.
# Ollama v0.40.4 is commit 45e6011815c74acde6a346512856b69dd79dd22b.
FROZEN = {
    "server/download.go": "d9299dd65146ba3dd5f4a5c7efe012795c763dcaa04ee6915086a2ac68665f0b",
    "server/routes.go": "23b3202e270e8f3dba0c716c128529432db02e8b1e40e6d73c94345abf6cfde4",
    "server/images.go": "41903a5408026cf30b4c07ce84c9365c8fa504d523e946d644131d095b22220f",
    "transfer/download.go": "1eb5c3782d9b19b68bffa047d53ff96533ba8f9b94f6f6499c2ac1d6a97547b8",
    "transfer/redirect.go": "fe3ed501f8cc2779c681dbe24ca9efb4e2f3db7fed46c94f87aa0d873fe71fc4",
    "go.mod": "c8330ba5f762c4bded1401cc8ecadbe85ebe8e5d159fd81da122da986b26cda5",
    "go.sum": "d9a0e2f1149951068ff200abac695a8fc6d6711b7cbf59c5aefb5e0a0340caae",
    "auth/auth.go": "ac4c269cb812edc01e2386fce0a7753871851edf76ec46ad26329016dc6f7841",
    "cmd/cmd.go": "749cd910c303a7b7189e8a6c309dafd8d0aa55afe87620db3bac36410eaff56c",
}
# Seams that Ollama 0.24.0 had and 0.40.4 removed; a producer that still names
# one of them was not ported to the pinned source layout.
RETIRED_SEAMS = (
    "server/internal/client/ollama/registry.go",
    "x/transfer/download.go",
    "http.DefaultClient.Do(req)",
)
SPEC = importlib.util.spec_from_file_location(
    "producer", REPOSITORY / "tools/build/build-macos-managed-ollama.py"
)
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)


class Hooks(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="managed-ollama-hooks-")
        self.addCleanup(self.owner.cleanup)
        self.candidate = Path(self.owner.name)
        for relative, frozen in FROZEN.items():
            original = UPSTREAM / relative
            self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), frozen)
            destination = self.candidate / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, destination)

    def test_source_hooks_preserve_origin_auth_and_original_redirect_owner(self):
        PRODUCER.apply_hooks(self.candidate, REPOSITORY)
        images = (self.candidate / "server/images.go").read_text()
        self.assertLess(
            images.index('req.Header.Set("Authorization", "Bearer "+regOpts.Token)'),
            images.index("nativehttp.Wrap(c.Transport)"),
        )
        self.assertLess(
            images.index("checkRedirect = regOpts.CheckRedirect"),
            images.index("nativehttp.Wrap(c.Transport)"),
        )
        self.assertIn("req.Method == http.MethodGet || req.Method == http.MethodHead", images)
        transfer = (self.candidate / "transfer/download.go").read_text()
        # The checked transfer client stays the base; only its route is wrapped,
        # and the wrapper receives the same registry exemption and --insecure bit.
        self.assertIn(
            "client := *cmp.Or(opts.Client, checkedClient(opts.BaseURL, opts.AllowPrivateHosts))",
            transfer,
        )
        self.assertIn(
            "nativehttp.WrapChecked(client.Transport, opts.BaseURL, opts.AllowPrivateHosts)",
            transfer,
        )
        self.assertIn("client:       &client", transfer)
        self.assertEqual(transfer.count("nativehttp.Do(d.client, req)"), 2)
        self.assertNotIn("d.client.Do(req)", transfer)
        for relative in ("auth/auth.go", "go.mod", "go.sum", "transfer/redirect.go"):
            self.assertEqual(
                (self.candidate / relative).read_bytes(), (UPSTREAM / relative).read_bytes()
            )
        routes = (self.candidate / "server/routes.go").read_text()
        self.assertEqual(
            routes.count(
                'r.GET("/api/ergopti-native-http-admission", gin.WrapH(nativehttp.AdmissionHandler()))'
            ),
            1,
        )
        self.assertIn('r.GET("/api/status", s.StatusHandler)', routes)
        self.assertIn("defer finishNativePull()", routes)
        self.assertIn("case <-ctx.Done():", routes)
        self.assertIn("PullModel(ctx, name.DisplayShortest(), runner, regOpts, fn)", routes)
        self.assertIn("s.modelCaches.show.invalidateLocal(name)", routes)
        download = (self.candidate / "server/download.go").read_text()
        self.assertIn("retireNativeDownload := nativehttp.TrackBackgroundDownload()", download)
        self.assertIn("defer retireNativeDownload()", download)
        # Blob parts come from the registry-named direct URL; an unwrapped
        # client bypassed PAC, proxies and anchors (hosted pull failure), and
        # redirect targets keep upstream's non-public address refusal.
        self.assertIn(
            'client.Transport = nativehttp.WrapChecked(client.Transport, "", opts.Insecure)',
            download,
        )
        # Upstream's redirect validation does a local lookup and refused every
        # host only the proxy could resolve; both calls use the port instead.
        self.assertIn(
            "client.CheckRedirect = nativehttp.RedirectPolicy(requestURL.String(), opts.Insecure)",
            download,
        )
        self.assertIn(
            "nativehttp.ValidateRedirectTarget(ctx, loc, requestURL.String(), opts.Insecure)",
            download,
        )
        self.assertNotIn("transfer.ValidateRedirectTarget(", download)
        self.assertIn("resp, err := nativehttp.Do(client, req)", download)
        self.assertNotIn("resp, err := client.Do(req)", download)

    def test_managed_server_applies_shared_serve_environment_first(self):
        # Ollama 0.40.4 contacts ollama.com from the daemon unless
        # OLLAMA_NO_CLOUD is set; the managed server must set it before serving.
        PRODUCER.apply_hooks(self.candidate, REPOSITORY)
        command = (self.candidate / "cmd/cmd.go").read_text()
        body = command[command.index("func RunServer(") :]
        self.assertLess(
            body.index("nativehttp.ApplyServeEnvironment()"),
            body.index("initializeKeypair()"),
        )
        declared = json.loads(
            (
                REPOSITORY
                / "static/ergopti_plus/_shared/modules/llm/managed_ollama_environment.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(declared["serve_environment"].get("OLLAMA_NO_CLOUD"), "1")

    def test_producer_names_no_retired_upstream_seam(self):
        producer = (REPOSITORY / "tools/build/build-macos-managed-ollama.py").read_text()
        contract = PRODUCER.runtime_contract(REPOSITORY)
        for seam in RETIRED_SEAMS:
            self.assertNotIn(seam, producer)
            self.assertNotIn(seam, contract["upstream_preimages"])
            self.assertNotIn(seam, contract["request_hook_paths"])
        self.assertEqual(contract["upstream_preimages"], FROZEN)
        self.assertEqual(contract["source_commit"], "45e6011815c74acde6a346512856b69dd79dd22b")

    def test_changed_preimages_refuse_before_any_source_edit(self):
        path = self.candidate / "transfer/download.go"
        path.write_bytes(path.read_bytes() + b"\n// Independent unexpected upstream edit.\n")
        before = {relative: (self.candidate / relative).read_bytes() for relative in FROZEN}
        with self.assertRaisesRegex(ValueError, "preimage changed"):
            PRODUCER.apply_hooks(self.candidate, REPOSITORY)
        self.assertEqual(
            before, {relative: (self.candidate / relative).read_bytes() for relative in FROZEN}
        )
        self.assertFalse((self.candidate / "internal/ergoptinativehttp").exists())

    def test_duplicate_seam_and_second_publication_refuse(self):
        with self.assertRaises(ValueError):
            PRODUCER.replace_once("request\nrequest\n", "request\n", "changed\n")
        PRODUCER.apply_hooks(self.candidate, REPOSITORY)
        with self.assertRaisesRegex(ValueError, "preimage changed"):
            PRODUCER.apply_hooks(self.candidate, REPOSITORY)

    def test_all_owned_bridge_sources_join_actual_upstream_module(self):
        PRODUCER.apply_hooks(self.candidate, REPOSITORY)
        package = self.candidate / "internal/ergoptinativehttp"
        contract = PRODUCER.runtime_contract(REPOSITORY)
        self.assertEqual(
            sorted(path.name for path in package.iterdir()),
            sorted(
                Path(name).name
                for name in contract["source_fingerprint_paths"]
                if Path(name).suffix in (".go", ".json")
            ),
        )
        self.assertIn("address_policy.go", {path.name for path in package.iterdir()})
        self.assertIn("managed_ollama_environment.json", {path.name for path in package.iterdir()})
        for path in package.iterdir():
            self.assertEqual(
                path.read_bytes(),
                (
                    REPOSITORY / "static/ergopti_plus/_shared/go/native_http" / path.name
                ).read_bytes(),
            )
        probe = (self.candidate / "ergopti_native_http_capability.go").read_text()
        self.assertIn(
            'len(os.Args) == 2 && os.Args[1] == "--ergopti-native-http-capability"', probe
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    options, remaining = parser.parse_known_args()
    UPSTREAM = options.source.resolve(strict=True)
    unittest.main(argv=[__file__, *remaining])
