#!/usr/bin/env python3
# tools/build/build-macos-managed-ollama.py
"""Build a runtime-only Ollama CLI with reviewed native HTTP request hooks.

The source checkout, official runtime archive and output directory are explicit.
This producer never edits the input checkout or creates/publishes a release.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile

RUNTIME_CONTRACT = "static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json"
IMPORT = '\tnativehttp "github.com/ollama/ollama/internal/ergoptinativehttp"\n'


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise ValueError("The reviewed upstream request seam changed")
    return source.replace(old, new, 1)


def runtime_contract(repository: Path) -> dict:
    contract = json.loads((repository / RUNTIME_CONTRACT).read_text(encoding="utf-8"))
    if type(contract.get("schema_version")) is not int or contract["schema_version"] != 1:
        raise ValueError("The canonical native runtime contract is invalid")
    return contract


def apply_hooks(source: Path, repository: Path) -> dict[str, str]:
    """Reject changed preimages before editing any newly owned source file."""
    contract = runtime_contract(repository)
    for relative, expected in contract["upstream_preimages"].items():
        if sha256(source / relative) != expected:
            raise ValueError("The reviewed upstream source preimage changed: " + relative)
    patches = {
        "server/images.go": (
            "\treturn c.Do(req)\n",
            "\tif req.Method == http.MethodGet || req.Method == http.MethodHead {\n"
            "\t\tc.Transport = nativehttp.Wrap(c.Transport)\n\t}\n\treturn nativehttp.Do(c, req)\n",
        ),
        "server/internal/client/ollama/registry.go": (
            "\tres, err := c.Do(r)\n",
            "\tif r.Method == http.MethodGet || r.Method == http.MethodHead {\n"
            "\t\tcc := *c\n\t\tcc.Transport = nativehttp.Wrap(c.Transport)\n\t\tc = &cc\n"
            "\t}\n\tres, err := nativehttp.Do(c, r)\n",
        ),
        "x/transfer/download.go": (
            "\td := &downloader{\n\t\tclient:       cmp.Or(opts.Client, defaultClient),\n",
            "\tclient := *cmp.Or(opts.Client, defaultClient)\n"
            "\tclient.Transport = nativehttp.Wrap(client.Transport)\n"
            "\td := &downloader{\n\t\tclient:       &client,\n",
        ),
        "server/routes.go": (
            '\tr.GET("/api/status", s.StatusHandler)\n',
            '\tr.GET("/api/status", s.StatusHandler)\n'
            '\tr.GET("/api/ergopti-native-http-admission", gin.WrapH(nativehttp.AdmissionHandler()))\n',
        ),
        "server/download.go": (
            "\t\tgo download.Run(context.Background(), requestURL, opts.regOpts)\n",
            "\t\tdownloadContext, cancelDownload := context.WithCancel(context.Background())\n"
            "\t\tdownload.CancelFunc = cancelDownload\n"
            "\t\tretireNativeDownload := nativehttp.TrackBackgroundDownload()\n"
            "\t\tgo func() {\n\t\t\tdefer retireNativeDownload()\n"
            "\t\t\tdownload.Run(downloadContext, requestURL, opts.regOpts)\n\t\t}()\n",
        ),
    }
    if set(patches) != set(contract["request_hook_paths"]):
        raise ValueError("The canonical native request hook inventory changed")
    prepared = {}
    for relative, (old, new) in patches.items():
        text = (source / relative).read_text(encoding="utf-8")
        text = replace_once(text, "import (\n", "import (\n" + IMPORT)
        text = replace_once(text, old, new)
        if relative == "x/transfer/download.go":
            if text.count("d.client.Do(req)") != 2:
                raise ValueError("The reviewed upstream download request seams changed")
            text = text.replace("d.client.Do(req)", "nativehttp.Do(d.client, req)")
        if relative == "server/routes.go":
            old_pull = """	ch := make(chan any)
	go func() {
		defer close(ch)
		fn := func(r api.ProgressResponse) {
			ch <- r
		}

		regOpts := &registryOptions{
			Insecure: req.Insecure,
		}

		ctx, cancel := context.WithCancel(c.Request.Context())
		defer cancel()

		if err := PullModel(ctx, name.DisplayShortest(), regOpts, fn); err != nil {
			ch <- gin.H{"error": err.Error()}
		}
	}()
"""
            new_pull = """	ctx, cancel := context.WithCancel(c.Request.Context())
	ch := make(chan any)
	nativePullHandedOff = true
	go func() {
		defer finishNativePull()
		defer close(ch)
		defer cancel()
		fn := func(r api.ProgressResponse) {
			select {
			case ch <- r:
			case <-ctx.Done():
			}
		}

		regOpts := &registryOptions{
			Insecure: req.Insecure,
		}

		if err := PullModel(ctx, name.DisplayShortest(), regOpts, fn); err != nil {
			select {
			case ch <- gin.H{"error": err.Error()}:
			case <-ctx.Done():
			}
		}
	}()
"""
            text = replace_once(text, old_pull, new_pull)
            text = replace_once(
                text,
                "func (s *Server) PullHandler(c *gin.Context) {\n",
                """func (s *Server) PullHandler(c *gin.Context) {
	finishNativePull, nativeAdmissionError := nativehttp.BeginPull(c.Request)
	if nativeAdmissionError != nil {
		c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "Native pull admission unavailable"})
		return
	}
	nativePullHandedOff := false
	defer func() { if !nativePullHandedOff { finishNativePull() } }()
""",
            )
        if relative == "server/download.go":
            text = replace_once(text, "\tctx, b.CancelFunc = context.WithCancel(ctx)\n", "")
            text = replace_once(
                text,
                "\tticker := time.NewTicker(60 * time.Millisecond)\n",
                "\tticker := time.NewTicker(60 * time.Millisecond)\n\tdefer ticker.Stop()\n",
            )
        prepared[relative] = text
    package = source / "internal/ergoptinativehttp"
    package.mkdir(parents=True, exist_ok=False)
    bridge = repository / "static/ergopti_plus/_shared/go/native_http"
    for name in ("transport.go", "worker_darwin.go", "worker_other.go", "admission.go"):
        shutil.copyfile(bridge / name, package / name)
    # This flag is a build capability probe, never an admission receipt by itself.
    (source / "ergopti_native_http_capability.go").write_text(
        'package main\n\nimport (\n"fmt"\n"os"\n'
        'nativehttp "github.com/ollama/ollama/internal/ergoptinativehttp"\n)\n\n'
        "func init() {\nif len(os.Args) == 2 && os.Args[1] == "
        '"--ergopti-native-http-capability" {\nfmt.Println(nativehttp.Capability())\n'
        "os.Exit(0)\n}\n}\n",
        encoding="utf-8",
    )
    for relative, text in prepared.items():
        (source / relative).write_text(text, encoding="utf-8")
    return {relative: sha256(source / relative) for relative in patches}


def run(argv: list[str], *, cwd: Path | None = None, env=None) -> str:
    return subprocess.run(
        argv, cwd=cwd, env=env, check=True, text=True, stdout=subprocess.PIPE
    ).stdout.strip()


def extract_archive(archive: Path, destination: Path) -> None:
    with tarfile.open(archive) as stream:
        stream.extractall(destination, filter="data")


def build(options) -> Path:
    if platform.system() != "Darwin":
        raise ValueError("A genuine macOS SDK and CGO compiler are required")
    source = options.source.resolve(strict=True)
    repository = options.repository.resolve(strict=True)
    contract = runtime_contract(repository)
    contract_sha256 = sha256(repository / RUNTIME_CONTRACT)
    repository_sources = {
        path: sha256(repository / path) for path in contract["source_fingerprint_paths"]
    }
    official = options.official_archive.resolve(strict=True)
    release = json.loads(
        (repository / "static/ergopti_plus/_shared/modules/llm/ollama_release.json").read_text(
            encoding="utf-8"
        )
    )
    if release["schema_version"] != 1 or release["version"] != contract["version"]:
        raise ValueError("The canonical release no longer matches the reviewed source")
    official_identity = release["assets"][contract["official_asset_key"]]
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    architecture = {"arm64": "arm64", "x86_64": "amd64"}.get(platform.machine())
    if architecture is None:
        raise ValueError("Unsupported native macOS architecture")
    asset_contract = contract["assets"]["macos-" + architecture]
    if run([options.go, "env", "GOVERSION", "GOHOSTOS", "GOHOSTARCH"]).splitlines() != [
        contract["go_version"],
        asset_contract["os"],
        architecture,
    ]:
        raise ValueError("The pinned native Go toolchain is required")
    if run(["git", "rev-parse", "HEAD"], cwd=source) != contract["source_commit"]:
        raise ValueError("The source checkout is not the reviewed upstream commit")
    if run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=source):
        raise ValueError("The source checkout has unreviewed modifications")
    if (
        official.stat().st_size != official_identity["bytes"]
        or sha256(official) != official_identity["sha256"]
    ):
        raise ValueError("The official runtime archive identity changed")
    asset = output / asset_contract["filename"]
    receipt = output / (asset.name + ".provenance.json")
    if asset.exists() or receipt.exists():
        raise ValueError("The output asset or provenance is already owned")
    with tempfile.TemporaryDirectory(prefix="managed-ollama-", dir=output) as temporary:
        work = Path(temporary)
        archive = work / "source.tar"
        with archive.open("xb") as stream:
            subprocess.run(
                ["git", "archive", contract["source_commit"]], cwd=source, stdout=stream, check=True
            )
        candidate = work / "source"
        candidate.mkdir()
        extract_archive(archive, candidate)
        archive.unlink()
        hook_hashes = apply_hooks(candidate, repository)
        gofmt = str(Path(options.go).resolve().with_name("gofmt"))
        go_files = [candidate / path for path in hook_hashes]
        go_files += [candidate / "ergopti_native_http_capability.go"]
        run([gofmt, "-w", *map(str, go_files)])
        hook_hashes = {path: sha256(candidate / path) for path in hook_hashes}
        runtime = work / "runtime"
        runtime.mkdir()
        extract_archive(official, runtime)
        # Keep every verified upstream dynamic backend and metallib unchanged.
        library_hashes = {
            str(path.relative_to(runtime)): sha256(path)
            for path in sorted(runtime.rglob("*"))
            if path.is_file() and str(path.relative_to(runtime)) != contract["binary_path"]
        }
        if not library_hashes or not any(path.endswith(".dylib") for path in library_hashes):
            raise ValueError("The official runtime library closure is missing")
        license_path = runtime / contract["license_path"]
        if license_path.exists() or license_path.is_symlink():
            raise ValueError("The native asset license path is already owned")
        shutil.copyfile(candidate / "LICENSE", license_path)
        cli = runtime / contract["binary_path"]
        if not cli.is_file() or cli.is_symlink():
            raise ValueError("The official CLI layout changed")
        env = dict(os.environ)
        env.update(
            GOTOOLCHAIN="local",
            GOOS=asset_contract["os"],
            GOARCH=architecture,
            CGO_ENABLED="1",
            CGO_CFLAGS=contract["cgo_cflags"],
            CGO_CXXFLAGS=contract["cgo_cxxflags"],
            CGO_LDFLAGS=asset_contract["cgo_ldflags"],
            CGO_CPPFLAGS="",
            CC=run(["xcrun", "--find", "clang"]),
            CXX=run(["xcrun", "--find", "clang++"]),
            GOCACHE=str(work / "go-cache"),
            GOMODCACHE=str(work / "go-mod-cache"),
            GOTMPDIR=str(work / "go-tmp"),
        )
        Path(env["GOTMPDIR"]).mkdir()
        # Do not inherit ambient flags that could change the reviewed source or ABI.
        env.pop("GOFLAGS", None)
        env.pop("GOEXPERIMENT", None)
        run(
            [
                options.go,
                "build",
                "-mod=readonly",
                "-trimpath",
                "-buildvcs=false",
                "-ldflags",
                "-w -s -X=github.com/ollama/ollama/version.Version="
                + contract["version"]
                + " -X=github.com/ollama/ollama/internal/ergoptinativehttp.BuiltSourceCommit="
                + contract["source_commit"]
                + " -X=github.com/ollama/ollama/server.mode=release",
                "-o",
                str(cli),
                ".",
            ],
            cwd=candidate,
            env=env,
        )
        signing = [
            "codesign",
            "--force",
            "--sign",
            options.signing_identity,
            "--options",
            "runtime",
        ]
        signing += ["--timestamp=none"] if options.signing_identity == "-" else ["--timestamp"]
        run(signing + [str(cli)])
        run(["codesign", "--verify", "--strict", str(cli)])
        if run([str(cli), "--ergopti-native-http-capability"]) != contract["capability"]:
            raise ValueError("The source-built native transport probe failed")
        dependencies = run(["otool", "-L", str(cli)])
        native_architectures = run(["lipo", "-archs", str(cli)])
        if native_architectures != ("arm64" if architecture == "arm64" else "x86_64"):
            raise ValueError("The actual native binary architecture changed")
        for relative, expected in library_hashes.items():
            if sha256(runtime / relative) != expected:
                raise ValueError("The verified upstream native library changed")
        with asset.open("xb") as stream:
            with gzip.GzipFile(fileobj=stream, filename="", mode="wb", mtime=0) as compressed:
                with tarfile.open(
                    fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT
                ) as bundle:
                    for path in sorted(runtime.rglob("*")):
                        info = bundle.gettarinfo(str(path), str(path.relative_to(runtime)))
                        info.uid = info.gid = 0
                        info.uname = info.gname = ""
                        info.mtime = 0
                        if info.isfile():
                            with path.open("rb") as content:
                                bundle.addfile(info, content)
                        else:
                            bundle.addfile(info)
        if sha256(repository / RUNTIME_CONTRACT) != contract_sha256 or any(
            sha256(repository / path) != digest for path, digest in repository_sources.items()
        ):
            raise ValueError("The admitted repository source changed during the native build")
        provenance = dict(
            schema_version=1,
            capability=contract["capability"],
            version=contract["version"],
            runtime_contract_sha256=contract_sha256,
            repository_source_sha256=repository_sources,
            repository_commit=run(["git", "rev-parse", "HEAD"], cwd=repository),
            platform="darwin",
            capability_source_sha256=sha256(candidate / "ergopti_native_http_capability.go"),
            source_commit=contract["source_commit"],
            upstream_preimages=contract["upstream_preimages"],
            request_hook_sha256=hook_hashes,
            bridge_sha256={
                path.name: sha256(path)
                for path in (candidate / "internal/ergoptinativehttp").glob("*.go")
            },
            go_version=contract["go_version"],
            architecture=architecture,
            cgo_enabled=True,
            deployment_target=contract["deployment_target"],
            cgo_ldflags=env["CGO_LDFLAGS"],
            sdk_version=run(["xcrun", "--show-sdk-version"]),
            clang_version=run([env["CC"], "--version"]),
            official_archive_sha256=official_identity["sha256"],
            official_archive_bytes=official_identity["bytes"],
            runtime_libraries_sha256=library_hashes,
            binary_sha256=sha256(cli),
            native_dependencies=dependencies,
            signing_mode="ad-hoc" if options.signing_identity == "-" else "configured-certificate",
            filename=asset.name,
            sha256=sha256(asset),
            bytes=asset.stat().st_size,
        )
        with receipt.open("x", encoding="utf-8") as stream:
            json.dump(provenance, stream, indent=2, sort_keys=True)
            stream.write("\n")
    return asset


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--official-archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--go", required=True, help="Absolute source-contract pinned native Go executable"
    )
    parser.add_argument(
        "--signing-identity",
        default="-",
        help="Existing release certificate; CI uses ad hoc signing",
    )
    options = parser.parse_args()
    print(build(options))


if __name__ == "__main__":
    main()
