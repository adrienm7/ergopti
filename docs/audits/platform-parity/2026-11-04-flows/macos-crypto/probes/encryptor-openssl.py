"""Re-derive AppleScript shell templates; execute only on newly created private fixture files.
Not an AppleScript/LaunchServices execution. No real password, user file or keychain.
"""

import pathlib, tempfile, subprocess, shlex, re, json, time, os, hashlib

base = pathlib.Path(__file__).resolve().parent.parent
source_path = pathlib.Path(
    "/workspace/ergopti/static/ergopti_plus/macos/apps/Encryptor.app/Contents/Resources/Scripts/main.applescript"
)
source = source_path.read_text()
section = source[source.index("\t-- Run openssl.") : source.index("\tset openssl_ok to false")]
parts = section.split("set openssl_cmd to ")
assert len(parts) == 4  # includes empty seed plus encrypt/decrypt
blocks = [parts[2].split("\n\telse")[0], parts[3].split("\n\tend if")[0]]


def command(block, values):
    pieces = re.findall(r'"([^"\n]*)"|quoted form of (\w+)', block)
    return "".join(a if not b else shlex.quote(values[b]) for a, b in pieces)


log = []
with tempfile.TemporaryDirectory(prefix="ergopti-encryptor-audit-") as tmp:
    d = pathlib.Path(tmp)
    os.chmod(d, 0o700)
    plain = d / "fixture.txt"
    enc = d / "fixture.txt.enc"
    dest = d / "existing-output.txt"
    password = "SYNTHETIC-AUDIT-PASSWORD"
    payload = b"fixture content for owned scratch only\n" * 80
    plain.write_bytes(payload)
    values = {"file_path": str(plain), "dest_path": str(enc), "the_password": password}
    encrypt = command(blocks[0], values)
    assert "-pass pass:" in encrypt and "-out " + shlex.quote(str(enc)) in encrypt
    ok = subprocess.run(["/bin/sh", "-c", encrypt], capture_output=True)
    assert ok.returncode == 0
    decrypt = command(
        blocks[1], dict(file_path=str(enc), dest_path=str(dest), the_password=password)
    )
    dest.write_bytes(b"ORIGINAL-APPROVED-OVERWRITE-TARGET")
    ok = subprocess.run(["/bin/sh", "-c", decrypt], capture_output=True)
    assert ok.returncode == 0 and dest.read_bytes() == payload
    log.append("control_correct_password: exit=0 destination_equals_original_plaintext=true")
    original = b"PREEXISTING-VALUABLE-TARGET-FIXTURE"
    dest.write_bytes(original)
    for attempt in range(64):
        dest.write_bytes(original)
        wrong = command(
            blocks[1],
            dict(
                file_path=str(enc),
                dest_path=str(dest),
                the_password="WRONG-SYNTHETIC-PASSWORD-" + str(attempt),
            ),
        )
        fail = subprocess.run(["/bin/sh", "-c", wrong], capture_output=True)
        if fail.returncode != 0:
            break
    assert fail.returncode != 0
    preserved_before_cleanup = dest.exists() and dest.read_bytes() == original
    assert not preserved_before_cleanup
    assert 'do shell script "rm -f " & quoted form of dest_path' in source
    subprocess.run(["/bin/sh", "-c", "rm -f " + shlex.quote(str(dest))], check=True)
    assert not dest.exists()
    log.append(
        f"wrong_password: exit={fail.returncode} prior_destination_preserved_before_cleanup=false prior_destination_exists_after_exact_failure_cleanup=false"
    )
    # A failure before openssl writes still authorizes the same catch cleanup.
    dest.write_bytes(original)
    subprocess.run(["/bin/sh", "-c", "rm -f " + shlex.quote(str(dest))], check=True)
    assert not dest.exists()
    log.append(
        "source_failure_cleanup_unconditionally_targets_destination=true; no_stage_or_previous_output_receipt"
    )
    # Public shell and child argv both carry the synthetic password. Observe only this child tree.
    seen_shell = seen_native = False
    process = subprocess.Popen(
        ["/bin/sh", "-c", encrypt], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    for _ in range(500):
        ids = [process.pid]
        try:
            ids += [
                int(x)
                for x in pathlib.Path(f"/proc/{process.pid}/task/{process.pid}/children")
                .read_text()
                .split()
            ]
        except OSError:
            pass
        for pid in ids:
            try:
                data = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
            except OSError:
                continue
            if password.encode() in data:
                if b"/bin/sh" in data:
                    seen_shell = True
                if b"openssl\0enc\0" in data or b"/openssl\0enc\0" in data:
                    seen_native = True
        if process.poll() is not None:
            break
        if seen_shell and seen_native:
            break
        time.sleep(0.001)
    process.communicate()
    assert process.returncode == 0
    assert password in process.args[2]
    log.append(
        f"synthetic_password_observed_in_own_shell_argv={seen_shell} own_openssl_argv={seen_native} (Linux /proc; macOS visibility not measured)"
    )
    # Integrity limitation control: alter an early ciphertext block, leaving padding untouched.
    raw = bytearray(enc.read_bytes())
    assert len(raw) > 64
    raw[16] ^= 1
    corrupt = d / "tampered.enc"
    corrupt.write_bytes(raw)
    altered = command(
        blocks[1], dict(file_path=str(corrupt), dest_path=str(dest), the_password=password)
    )
    result = subprocess.run(["/bin/sh", "-c", altered], capture_output=True)
    assert result.returncode == 0 and dest.read_bytes() != payload
    log.append(
        "integrity_limitation: early_ciphertext_bitflip_exit=0 plaintext_changed=true; no_authentication_promise_inferred"
    )
log.append("fixture_directory_removed=true; user_files_keychain_clipboard_network_untouched")
(base / "logs/encryptor-openssl.txt").write_text("\n".join(log) + "\n")
(base / "logs/encryptor-source-provenance.json").write_text(
    json.dumps(
        {
            "path": str(source_path),
            "sha256": hashlib.sha256(source.encode()).hexdigest(),
            "templates": blocks,
        },
        indent=2,
    )
    + "\n"
)
print("\n".join(log))
