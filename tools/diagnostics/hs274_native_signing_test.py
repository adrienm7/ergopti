# tools/diagnostics/hs274_native_signing_test.py
"""Frozen portable refusal controls; native tools and credentials are UNEXECUTED."""

import importlib.util
import contextlib
import io
from unittest.mock import patch
import os
from pathlib import Path
import tempfile
import time
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/diagnostics"))
import hs274_signed_runtime_observation as O  # noqa: E402

# Helper-only qualification: observer executes retained fixture bytes in its own module.
F = O.F
spec = importlib.util.spec_from_file_location(
    "handwritten", ROOT / "tools/build/remap_runtime_signing_fixture.py"
)
B = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = B
# Borrowed handwritten oracle is executed from exact retained bytes, no cache authority.
exec(
    compile(
        (ROOT / "tools/build/remap_runtime_signing_fixture.py").read_bytes(),
        str(spec.origin),
        "exec",
    ),
    B.__dict__,
)


class PortableControls(unittest.TestCase):
    def test_non_darwin_no_private_root(self):
        if sys.platform == "darwin":
            # This vector is a platform policy control, not a native setup substitute.
            self.assertTrue(F.supported("darwin"))
            self.assertFalse(F.supported("linux"))
        else:
            with tempfile.TemporaryDirectory() as tmp:
                target = Path(tmp).resolve() / "private"
                with self.assertRaises(F.FixtureRefusal):
                    F.setup(target, Path(tmp).resolve())
                self.assertFalse(target.exists())

    def test_quoted_keychain_list(self):
        self.assertEqual(
            F.list_keychains(b'    "/a/login.keychain-db"\n    "/b/private.keychain-db"\n'),
            ("/a/login.keychain-db", "/b/private.keychain-db"),
        )

    def test_keychain_list_malformed_duplicate(self):
        for raw in (
            b"/a/key\n",
            b'"/a/key"\n"/a/key"\n',
            b'"relative"\n',
            b'"/a/key" trailing\n',
            b'"/a/../key"\n',
        ):
            with self.assertRaises(F.FixtureRefusal):
                F.list_keychains(raw)

    def test_foreign_search_list_preserved(self):
        self.assertEqual(
            F.foreign_list(("/a/login", "/fixture/owned", "/b/other"), "/fixture/owned"),
            ("/a/login", "/b/other"),
        )
        self.assertFalse(
            F.search_unchanged(("/a/login",), ("/a/login", "/b/new"), "/fixture/owned")
        )

    def test_collision_no_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            target = root / "owned"
            target.mkdir(mode=0o700)
            (target / "marker").write_bytes(b"original")
            with self.assertRaises(F.FixtureRefusal):
                F.create_private(target)
            self.assertEqual((target / "marker").read_bytes(), b"original")

    def test_alias_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            real = root / "real"
            real.mkdir()
            alias = root / "alias"
            alias.symlink_to(real, target_is_directory=True)
            with self.assertRaises(F.FixtureRefusal):
                F.create_private(alias / "owned")
            self.assertFalse((real / "owned").exists())

    def test_actual_same_byte_replacement_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            path = root / "leaf"
            path.write_bytes(b"held")
            path.chmod(0o644)
            held = F.ordinary(path, 0o644)
            (root / "replacement").write_bytes(b"held")
            (root / "replacement").chmod(0o644)
            os.replace(root / "replacement", path)
            with self.assertRaises(F.FixtureRefusal):
                F.current(held)

    def test_wrong_mode_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / "keychain"
            path.write_bytes(b"db")
            path.chmod(0o644)
            with self.assertRaises(F.FixtureRefusal):
                F.ordinary(path, 0o600)

    def test_absolute_deadline(self):
        with self.assertRaises(F.FixtureRefusal):
            F.remaining(time.monotonic() - 0.01)
        self.assertLessEqual(F.remaining(time.monotonic() + 0.02), 0.02)

    def test_public_fields_do_not_export_private_state(self):
        record = F.public_record("A" * 40, "b" * 64)
        self.assertEqual(
            set(record),
            {
                "schema",
                "status",
                "identity",
                "public_leaf_sha256",
                "test_only",
                "shipping_qualified",
                "installation_qualified",
                "authentication_qualified",
            },
        )
        self.assertTrue(record["test_only"])
        self.assertIs(record["authentication_qualified"], False)

    def test_exact_native_designated_requirement(self):
        O.require_identifier(
            b'designated => identifier "com.ergoptiplus.remap.cli" and certificate leaf = H"'
            + b"A" * 40
            + b'"\n',
            "com.ergoptiplus.remap.cli",
            "A" * 40,
        )
        with self.assertRaises(F.FixtureRefusal):
            O.require_identifier(
                b'designated => identifier "foreign" and certificate leaf = H"'
                + b"A" * 40
                + b'"\n',
                "com.ergoptiplus.remap.cli",
                "A" * 40,
            )

    def test_wrong_leaf_refuses(self):
        with self.assertRaises(F.FixtureRefusal):
            O.require_leaf(b"actual other leaf", b"expected")

    def test_independent_supported_layout(self):
        self.assertEqual(
            O.layout_unchanged(B.universal(), B.universal(signed=True)), ("x86_64", "arm64")
        )

    def test_changed_executable_refuses(self):
        with self.assertRaises(F.FixtureRefusal):
            O.layout_unchanged(B.universal(), B.universal(signed=True, code=b"FOREIGN CODE"))

    def test_unknown_macho_refuses(self):
        with self.assertRaises(F.FixtureRefusal):
            O.layout_unchanged(b"unknown", b"unknown")

    def test_fixed_five_targets(self):
        self.assertEqual(
            tuple((row[0], row[1]) for row in O.TARGETS),
            (
                (
                    "Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
                    "com.ergoptiplus.remap.core",
                ),
                ("Runtime/ErgoptiPlus-Remap-Core.app", "com.ergoptiplus.remap.core"),
                (
                    "Runtime/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
                    "com.ergoptiplus.remap.console",
                ),
                ("Runtime/ErgoptiPlus-Remap-Console.app", "com.ergoptiplus.remap.console"),
                ("Runtime/bin/ergoptiplus_remap_cli", "com.ergoptiplus.remap.cli"),
            ),
        )


_FROZEN_REVIEW_DRIVERS = {
    "credential": "\"\"\"Before-code counterexample. Native endpoints are modeled; files/inodes are real.\"\"\"\nfrom pathlib import Path\nimport importlib.util, sys, os, json, hashlib, tempfile\nroot=Path(__file__).resolve().parents[1]\npath=root/'author-seal/candidate/tools/diagnostics/hs274_native_signing_fixture.py'\nspec=importlib.util.spec_from_file_location('independent_fixture_credential_before',path)\nF=importlib.util.module_from_spec(spec);sys.modules[spec.name]=F;spec.loader.exec_module(F)\nbase=Path(tempfile.mkdtemp(prefix='credential-after-producer-',dir=root/'tmp'))\nsecret_parent=base/'private-parent';secret_parent.mkdir(mode=0o700)\nevidence_parent=base/'evidence-parent';evidence_parent.mkdir(mode=0o700)\npublic=evidence_parent/'public';public.mkdir(mode=0o700)\nprivate=secret_parent/'credential'; events=[]; replacement={}\nF.sys.platform='darwin'\nF._NATIVE=() # Native tool acquisition intentionally modeled; no system command is executed.\ndef fake_command(args,deadline,guard,env=None):\n guard();F.remaining(deadline);endpoint=args[1];events.append(endpoint)\n out=b''\n if endpoint=='list-keychains':out=b'    \"/foreign/login.keychain-db\"\\n'\n elif endpoint=='req':\n  (private/'private-key.pem').write_bytes(b'modeled encrypted private key')\n  (private/'certificate.pem').write_bytes(b'modeled public certificate')\n elif endpoint=='version':\n  # req has already returned before this unrelated native version port is entered.\n  target=private/'private-key.pem'; original=F.ordinary(target)\n  successor=private/'replacement.tmp';successor.write_bytes(original.data);successor.chmod(original.identity[3]);os.replace(successor,target)\n  replacement.update({'same_bytes':target.read_bytes()==original.data,'inode_changed':target.stat().st_ino!=original.identity[1],'phase':'version-after-req-return'})\n  out=b'LibreSSL 3.3.6\\n'\n elif endpoint=='pkcs12':(private/'identity.p12').write_bytes(b'modeled encrypted p12')\n elif endpoint=='x509':(private/'public-leaf.der').write_bytes(b'modeled public DER')\n elif endpoint=='create-keychain':(private/'fixture.keychain-db').write_bytes(b'modeled mutable keychain')\n elif endpoint=='find-identity':out=b'  1) '+hashlib.sha1((private/'public-leaf.der').read_bytes()).hexdigest().upper().encode()+b' \"TEST ONLY\"\\n'\n elif endpoint not in ('set-keychain-settings','unlock-keychain','import','set-key-partition-list'):raise AssertionError('unknown modeled endpoint')\n guard();F.remaining(deadline);return out,b''\nF.command=fake_command\ntry:\n result=F.setup(private,public)\n observation={'accepted':True,'status':result['status'],'same_byte_replacement':replacement,'fixed_modeled_endpoints':events,'actual_native_commands':0,'canonical_source_modified':False}\nexcept F.FixtureRefusal as error:\n observation={'accepted':False,'refusal':error.code,'same_byte_replacement':replacement,'fixed_modeled_endpoints':events,'actual_native_commands':0,'canonical_source_modified':False}\n(root/'replay/credential-before-observation.json').write_text(json.dumps(observation,indent=2)+'\\n');print(json.dumps(observation,indent=2))\nassert not observation['accepted'], 'same-byte private credential inode replacement was accepted before its first downstream consumer'\n",
    "inventory": "\"\"\"Before-code bound control: actual directory enumeration; no native endpoints.\"\"\"\nfrom pathlib import Path\nimport importlib.util, sys, tempfile, json\nroot=Path(__file__).resolve().parents[1]\npath=root/'author-seal/candidate/tools/diagnostics/hs274_signed_runtime_observation.py'\nspec=importlib.util.spec_from_file_location('independent_inventory_before',path)\nO=importlib.util.module_from_spec(spec);sys.modules[spec.name]=O;spec.loader.exec_module(O)\nfixture=Path(tempfile.mkdtemp(prefix='inventory-before-',dir=root/'tmp'));fixture.chmod(0o755)\nfor i in range(2049):(fixture/f'unknown-{i:04d}').write_bytes(b'x')\nreal_scandir=O.os.scandir; count=0\nclass CountingScandir:\n def __init__(self,path):self.iterator=real_scandir(path)\n def __enter__(self):return self\n def __exit__(self,*args):self.close()\n def __iter__(self):return self\n def __next__(self):\n  global count\n  entry=next(self.iterator);count+=1;return entry\n def close(self):self.iterator.close()\nO.os.scandir=CountingScandir\ntry:\n try:\n  O._inventory(fixture)\n  raise AssertionError('over-limit inventory accepted')\n except O.F.FixtureRefusal as e:\n  assert e.code=='inventory'\nfinally:O.os.scandir=real_scandir\nobservation={'actual_real_entries_yielded':count,'independent_cap':256,'allowed_first_refusing_entry':257,'native_commands':0,'source_modified':False}\n(root/'replay/inventory-before-observation.json').write_text(json.dumps(observation,indent=2)+'\\n');print(json.dumps(observation,indent=2))\nassert count<=257, 'eager enumeration exceeded the fixed inventory admission bound before refusal'\n",
    "mode_normalization": "\"\"\"Before-code counterexample. Native endpoints are modeled; files/inodes are real.\"\"\"\nfrom pathlib import Path\nimport importlib.util, sys, os, json, hashlib, tempfile\nroot=Path(__file__).resolve().parents[1]\npath=root/'author-successor/author-seal/candidate/tools/diagnostics/hs274_native_signing_fixture.py'\nspec=importlib.util.spec_from_file_location('independent_fixture_credential_before',path)\nF=importlib.util.module_from_spec(spec);sys.modules[spec.name]=F;spec.loader.exec_module(F)\nbase=Path(tempfile.mkdtemp(prefix='credential-after-producer-',dir=root/'tmp'))\nsecret_parent=base/'private-parent';secret_parent.mkdir(mode=0o700)\nevidence_parent=base/'evidence-parent';evidence_parent.mkdir(mode=0o700)\npublic=evidence_parent/'public';public.mkdir(mode=0o700)\nprivate=secret_parent/'credential'; events=[]; replacement={}\nF.sys.platform='darwin'\nF._NATIVE=() # Native tool acquisition intentionally modeled; no system command is executed.\ndef fake_command(args,deadline,guard,env=None):\n guard();F.remaining(deadline);endpoint=args[1];events.append(endpoint)\n out=b''\n if endpoint=='list-keychains':out=b'    \"/foreign/login.keychain-db\"\\n'\n elif endpoint=='req':\n  (private/'private-key.pem').write_bytes(b'modeled encrypted private key')\n  (private/'certificate.pem').write_bytes(b'modeled public certificate')\n elif endpoint=='version':out=b'LibreSSL 3.3.6\\n'\n elif endpoint=='pkcs12':(private/'identity.p12').write_bytes(b'modeled encrypted p12')\n elif endpoint=='x509':(private/'public-leaf.der').write_bytes(b'modeled public DER')\n elif endpoint=='create-keychain':(private/'fixture.keychain-db').write_bytes(b'modeled mutable keychain')\n elif endpoint=='find-identity':out=b'  1) '+hashlib.sha1((private/'public-leaf.der').read_bytes()).hexdigest().upper().encode()+b' \"TEST ONLY\"\\n'\n elif endpoint not in ('set-keychain-settings','unlock-keychain','import','set-key-partition-list'):raise AssertionError('unknown modeled endpoint')\n guard();F.remaining(deadline);return out,b''\nF.command=fake_command\nreal_fchmod=F.os.fchmod\nchanged_once=False\ndef mode_port(fd,mode):\n global changed_once\n real_fchmod(fd,mode)\n path=private/'private-key.pem'\n try:\n  actual=os.fstat(fd);key=path.stat();selected=(actual.st_dev,actual.st_ino)==(key.st_dev,key.st_ino)\n except FileNotFoundError:selected=False\n if selected and not changed_once:\n  changed_once=True\n  before=path.stat();data=path.read_bytes();path.write_bytes(data);after=path.stat()\n  replacement.update({'same_bytes':path.read_bytes()==data,'same_inode':before.st_ino==after.st_ino,'mtime_changed':before.st_mtime_ns!=after.st_mtime_ns,'phase':'authorized-mode-normalization'})\nF.os.fchmod=mode_port\ntry:\n result=F.setup(private,public)\n observation={'accepted':True,'status':result['status'],'same_byte_replacement':replacement,'fixed_modeled_endpoints':events,'actual_native_commands':0,'canonical_source_modified':False}\nexcept F.FixtureRefusal as error:\n observation={'accepted':False,'refusal':error.code,'same_byte_replacement':replacement,'fixed_modeled_endpoints':events,'actual_native_commands':0,'canonical_source_modified':False}\n(root/'replay/mode-normalization-observation.json').write_text(json.dumps(observation,indent=2)+'\\n');print(json.dumps(observation,indent=2))\nassert not observation['accepted'], 'same-inode credential mtime drift during mode-only normalization was accepted'\n",
}


class IndependentCustodyControls(unittest.TestCase):
    """Exact reviewer drivers with explicit parent checks surviving optimization."""

    def run_frozen(self, name):
        import shutil
        import subprocess

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            (root / "tmp").mkdir()
            (root / "replay").mkdir()
            source = root / "author-seal/candidate/tools/diagnostics"
            if name == "mode_normalization":
                source = root / "author-successor/author-seal/candidate/tools/diagnostics"
            source.mkdir(parents=True)
            for filename in (
                "hs274_native_signing_fixture.py",
                "hs274_signed_runtime_observation.py",
            ):
                shutil.copy2(ROOT / "tools/diagnostics" / filename, source / filename)
            driver = root / "replay" / (name + "_before_control.py")
            driver.write_text(_FROZEN_REVIEW_DRIVERS[name])
            environment = os.environ.copy()
            environment["TMPDIR"] = str(root / "tmp")
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            result = subprocess.run(
                [sys.executable, str(driver)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
                env=environment,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
            import json

            filename = (
                "mode-normalization-observation.json"
                if name == "mode_normalization"
                else name + "-before-observation.json"
            )
            return json.loads((root / "replay" / filename).read_bytes())

    def test_credential_is_held_before_version_consumer(self):
        observation = self.run_frozen("credential")
        self.assertIs(observation["accepted"], False)
        self.assertIs(observation["same_byte_replacement"]["same_bytes"], True)
        self.assertIs(observation["same_byte_replacement"]["inode_changed"], True)
        self.assertNotIn("pkcs12", observation["fixed_modeled_endpoints"])
        self.assertEqual(observation["actual_native_commands"], 0)

    def test_inventory_refuses_before_eager_directory_materialization(self):
        observation = self.run_frozen("inventory")
        self.assertLessEqual(observation["actual_real_entries_yielded"], 257)
        self.assertEqual(observation["native_commands"], 0)

    def test_mode_port_preserves_preexisting_size_and_mtime(self):
        observation = self.run_frozen("mode_normalization")
        self.assertIs(observation["accepted"], False)
        self.assertIs(observation["same_byte_replacement"]["same_bytes"], True)
        self.assertIs(observation["same_byte_replacement"]["same_inode"], True)
        self.assertIs(observation["same_byte_replacement"]["mtime_changed"], True)
        self.assertNotIn("version", observation["fixed_modeled_endpoints"])
        self.assertEqual(observation["actual_native_commands"], 0)


_KEYCHAIN_MODE_BOUNDARY_DRIVER = "\"\"\"Fixed native ports modeled; genuine filesystem mode operations and custody.\"\"\"\nfrom pathlib import Path\nimport importlib.util, sys, os, json, hashlib, tempfile, stat\nsource=Path(sys.argv[1]).resolve(strict=True)\nwork=Path(sys.argv[2]).resolve(strict=True)\nscenario=sys.argv[3]\nif scenario not in ('attack','healthy','mutable'):raise RuntimeError('control scenario')\nspec=importlib.util.spec_from_file_location('keychain_mode_control',source)\nF=importlib.util.module_from_spec(spec);sys.modules[spec.name]=F\nexec(compile(source.read_bytes(),str(source),'exec'),F.__dict__)\ncase=Path(tempfile.mkdtemp(prefix='keychain-mode-',dir=work)).resolve(strict=True)\nparent=case/'private-parent';parent.mkdir(mode=0o700)\nevidence=case/'evidence';evidence.mkdir(mode=0o700)\npublic=evidence/'public';public.mkdir(mode=0o700)\nprivate=parent/'credential';keychain=private/'fixture.keychain-db'\nforeign=case/'foreign.keychain';foreign.write_bytes(b'foreign placeholder; not a real credential');foreign.chmod(0o644)\nbefore=foreign.stat();events=[];interleaved=False;mutation=False;opened_matches=False\nF.sys.platform='darwin';F._NATIVE=()\ndef command(args,deadline,guard,env=None):\n global mutation\n guard();F.remaining(deadline);endpoint=args[1];events.append(endpoint);out=b''\n if endpoint=='list-keychains':out=b'    \"/foreign/login.keychain-db\"\\n'\n elif endpoint=='req':\n  (private/'private-key.pem').write_bytes(b'modeled encrypted private key')\n  (private/'certificate.pem').write_bytes(b'modeled public certificate')\n elif endpoint=='version':out=b'LibreSSL 3.3.6\\n'\n elif endpoint=='pkcs12':(private/'identity.p12').write_bytes(b'modeled encrypted p12')\n elif endpoint=='x509':(private/'public-leaf.der').write_bytes(b'modeled public DER')\n elif endpoint=='create-keychain':keychain.write_bytes(b'modeled mutable keychain');keychain.chmod(0o644)\n elif endpoint=='set-keychain-settings' and scenario=='mutable':\n  keychain.write_bytes(b'modeled mutable keychain database legitimately updated');mutation=True\n elif endpoint=='find-identity':out=b'  1) '+hashlib.sha1((private/'public-leaf.der').read_bytes()).hexdigest().upper().encode()+b' \"TEST ONLY\"\\n'\n elif endpoint not in ('set-keychain-settings','unlock-keychain','import','set-key-partition-list'):raise RuntimeError('unexpected modeled port')\n guard();F.remaining(deadline);return out,b''\nF.command=command\nreal_chmod=Path.chmod;real_fchmod=F.os.fchmod\ncreated=False\ndef replace_name():\n global interleaved\n keychain.unlink();keychain.symlink_to(foreign);interleaved=True\ndef path_mode(path,mode,*args,**kwargs):\n if path==keychain and mode==0o600 and scenario=='attack' and not interleaved:replace_name()\n return real_chmod(path,mode,*args,**kwargs)\ndef descriptor_mode(fd,mode):\n global opened_matches\n try:\n  opened=os.fstat(fd);named=keychain.lstat()\n  selected=stat.S_ISREG(named.st_mode) and (opened.st_dev,opened.st_ino)==(named.st_dev,named.st_ino)\n except FileNotFoundError:selected=False\n if selected and mode==0o600 and scenario=='attack' and not interleaved:\n  opened_matches=True;replace_name()\n return real_fchmod(fd,mode)\nPath.chmod=path_mode;F.os.fchmod=descriptor_mode\ntry:\n try:\n  result=F.setup(private,public);refusal=None;accepted=True\n except (F.FixtureRefusal,OSError) as error:\n  refusal=error.code if isinstance(error,F.FixtureRefusal) else type(error).__name__;accepted=False\nfinally:\n Path.chmod=real_chmod;F.os.fchmod=real_fchmod\nfinal=foreign.stat()\nobservation={'scenario':scenario,'accepted':accepted,'refusal':refusal,'actual_interleaving':interleaved,'opened_fd_matches_owned_keychain':opened_matches,'foreign_original_mode':stat.S_IMODE(before.st_mode),'foreign_final_mode':stat.S_IMODE(final.st_mode),'foreign_same_inode':before.st_ino==final.st_ino,'foreign_same_bytes':foreign.read_bytes()==b'foreign placeholder; not a real credential','keychain_database_updated':mutation,'modeled_native_ports':events,'actual_native_commands':0,'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest()}\nprint(json.dumps(observation,sort_keys=True))\nif scenario=='attack':\n if accepted or not interleaved or stat.S_IMODE(final.st_mode)!=0o644 or not observation['foreign_same_inode'] or not observation['foreign_same_bytes']:raise AssertionError('Keychain mode boundary must refuse without mutating foreign symlink target')\n if 'set-keychain-settings' in events:raise AssertionError('No subsequent native port after keychain custody refusal')\nelse:\n if not accepted or interleaved or stat.S_IMODE(keychain.stat().st_mode)!=0o600:raise AssertionError('Healthy owned keychain normalization must finish')\n if scenario=='mutable' and not mutation:raise AssertionError('Actual same-inode keychain database update did not occur')\n"


class KeychainModeBoundaryControl(unittest.TestCase):
    """Actual file/symlink mutation; fixed native command ports are modeled."""

    def test_owned_keychain_normalization_never_changes_foreign_target(self):
        import json
        import subprocess

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(strict=True)
            driver = root / "keychain-mode-control.py"
            driver.write_text(_KEYCHAIN_MODE_BOUNDARY_DRIVER)
            environment = os.environ.copy()
            environment["TMPDIR"] = str(root)
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            result = subprocess.run(
                [
                    sys.executable,
                    str(driver),
                    str(ROOT / "tools/diagnostics/hs274_native_signing_fixture.py"),
                    str(root),
                    "attack",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
                env=environment,
                check=False,
            )
            observation = json.loads(result.stdout)
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
            self.assertIs(observation["accepted"], False)
            self.assertIs(observation["actual_interleaving"], True)
            self.assertEqual(observation["foreign_original_mode"], 0o644)
            self.assertEqual(observation["foreign_final_mode"], 0o644)
            self.assertIs(observation["foreign_same_inode"], True)
            self.assertIs(observation["foreign_same_bytes"], True)
            self.assertNotIn("set-keychain-settings", observation["modeled_native_ports"])
            self.assertEqual(observation["actual_native_commands"], 0)


class ClosedDiagnosticControls(unittest.TestCase):
    def check_refusal(self, error, code):
        output, errors = io.StringIO(), io.StringIO()
        with (
            patch.object(F, "setup", side_effect=error),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(errors),
        ):
            status = F.main(["setup", "/private/not-consumed", "/public/not-consumed"])
        self.assertEqual(status, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(
            errors.getvalue(), "Native signing TEST-ONLY fixture refused: " + code + "\n"
        )
        self.assertNotIn("SECRET", errors.getvalue())

    def test_ancestry_closed_code(self):
        self.check_refusal(F.FixtureRefusal("ancestry"), "ancestry")

    def test_evidence_boundary_closed_code(self):
        self.check_refusal(F.FixtureRefusal("private_in_evidence"), "private_in_evidence")

    def test_native_command_closed_code(self):
        self.check_refusal(F.FixtureRefusal("native_command"), "native_command")

    def test_unknown_code_cannot_export_payload(self):
        self.check_refusal(
            F.FixtureRefusal("SECRET private native command output"), "unknown_refusal"
        )

    def test_oserror_cannot_export_payload(self):
        self.check_refusal(PermissionError("SECRET /private/path"), "system_io")

    def test_valueerror_cannot_export_payload(self):
        self.check_refusal(ValueError("SECRET credential state"), "invalid_value")


if __name__ == "__main__":
    unittest.main()
