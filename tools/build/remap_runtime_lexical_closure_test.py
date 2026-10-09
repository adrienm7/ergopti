# tools/build/remap_runtime_lexical_closure_test.py
"""Genuine sparse source closure and refusal controls; native execution unqualified."""

import ast
import base64
import hashlib
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[2]
FIXED_PROVIDER = "c29ceb96e73655cadea7763805b9468c32744033c2f177bae492e4ce9fe4100a"
FIXED_FACTORY = "71237241a3a43fa3dbc5c5b8db488432b9051ed66322cbdf497959b3724b10a1"
FIXED_PRODUCER = "9c1318b77219663f7328be5795f129fad64803211fddb952f82a886897240843"
FIXED_INVENTORY = "5a033ca40c506b654f62fd3e1a0b9eee7a74396c8fd68f2319aba38173e92515"
FIXED_BUILDER = "12dfa8d5eaa9048a5a78a55111e547b875b0a1aa379c8a4a203024cb792355ca"
OLD_PROVIDER_SHA256 = "a4ef0f4b7bd2c9cdabb4b8eb9e0a7249eab4f9e06f9991bcdb2f59a230220b4f"
OLD_FACTORY_SHA256 = "70d90ede3bdfbf44e146ba4a26f101ebfec2a1745bc05a8260db001d5a236537"
# Exact historical producer source bytes, frozen before the closure edit.
# They are private negative inputs, never replacement policy or expected data
# regenerated from the successor. Hashes below bind both complete preimages.
OLD_PROVIDER = zlib.decompress(
    base64.b64decode(
        "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"
        "Qh576pIVhTTehiwUXBNOU0FuGNDpT9kdZkTf1tXJJ3ZbX82s0UJFTL0NEHdIAXGnOqBImJOS9GQGCxrLgDKa29MiyYs1D538KmQF"
        "Hp1A1aTIPtJ3Jib3d2eyym6hklO9kkpnEX9G6SrFo5Zs+0ck/4chofqnn+APRnY18cMWjghxIZnqYQe+mU4GHdBnegeHokTnJvsy"
        "mlyDAq+MUtjwtkWvsVhmk1sQ4w3nuTv+oyWcL/SRVPEzDRL71HROIvVgQzqjDH30mo31arx93DBlQL43aCDYYj39fdZIcEphfJHG"
        "qdWs8KDQ8obBw04WyRzT16TxRrGxrhyOnLDLcUazKmnZ84Dd+/E83P4XwVIJsvzo02lylQ3Xy8nqrqP1Qu+bc+zpYpoO3elHjB57"
        "osRfv/3jb2/e93/56b9/efX26tRo4ttJp7Mj/vsT2jhf7ozWn1bpItumcVpPpqOd92I6d4B/5MtOCi2qWc9/wGYL5zAKn99E/YbC"
        "9nSQ31oNMnMhOFAsHTRXwfh0YCI8dqu51f8vOENC3g=="
    )
)
OLD_FACTORY = zlib.decompress(
    base64.b64decode(
        "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"
        "Y4dSm0ask6n/F52Wgp4="
    )
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load(name, path, data=None):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    exec(compile(path.read_bytes() if data is None else data, str(path), "exec"), module.__dict__)
    return module


class LexicalSourceClosureControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="lexical-source-closure-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.root.chmod(0o700)
        self.provider_path = self.root / "tools/build/remap_runtime_patch.py"
        self.factory_path = self.root / "tools/build/remap_runtime_source.py"
        self.builder_path = self.root / "tools/build/remap_runtime_build.py"
        factory_data = (ROOT / "tools/build/remap_runtime_source.py").read_bytes()
        dependencies = []
        for node in ast.parse(factory_data).body:
            if isinstance(node, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id in {"DEPENDENCIES", "VHD_DEPENDENCIES"}
                for target in node.targets
            ):
                dependencies.extend(ast.literal_eval(node.value))
        self.assertEqual(len(dependencies), 36)
        self.assertEqual(
            tuple(row for row in dependencies if row[0] == "tools/build/remap_runtime_producer.py"),
            (("tools/build/remap_runtime_producer.py", FIXED_PRODUCER),),
        )
        self.assertEqual(
            tuple(
                row for row in dependencies if row[0] == "tools/build/remap_runtime_inventory.hpp"
            ),
            (("tools/build/remap_runtime_inventory.hpp", FIXED_INVENTORY),),
        )
        paths = {path for path, _ in dependencies} | {
            "tools/build/remap_runtime_source.py",
            "tools/build/remap_runtime_build.py",
            "tools/diagnostics/hs274_native_build.py",
        }
        for relative in sorted(paths):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        self.builder = load("lexical_closure_builder_" + str(id(self)), self.builder_path)
        self.assertEqual(digest(OLD_PROVIDER), OLD_PROVIDER_SHA256)
        self.assertEqual(digest(OLD_FACTORY), OLD_FACTORY_SHA256)

    def test_actual_coherent_fixed_source_loads_and_captures_all_dependencies(self):
        self.assertEqual(digest(self.provider_path.read_bytes()), FIXED_PROVIDER)
        self.assertEqual(digest(self.factory_path.read_bytes()), FIXED_FACTORY)
        self.assertEqual(digest(self.builder_path.read_bytes()), FIXED_BUILDER)
        self.assertEqual(self.builder_path.stat().st_size, 144976)
        self.assertEqual(self.builder.PROVIDER_SHA256, FIXED_PROVIDER)
        self.assertEqual(self.builder.SOURCE_FACTORY_SHA256, FIXED_FACTORY)
        self.assertEqual(self.builder.CURRENT_OWNED_SOURCE_FACTORY_SHA256, FIXED_FACTORY)
        factory = self.builder._source_factory()
        deadline = time.monotonic() + 60
        captured = factory.capture_dependencies(self.root, deadline)
        self.assertEqual(len(captured), 34)
        self.assertEqual(
            tuple(
                (row.path, digest(row.data))
                for row in captured
                if row.path == "tools/build/remap_runtime_producer.py"
            ),
            (("tools/build/remap_runtime_producer.py", FIXED_PRODUCER),),
        )
        self.assertEqual(len(factory.capture_vhd_dependencies(self.root, deadline)), 2)
        self.assertEqual(
            self.builder._identifiers(),
            {
                "core": "com.ergoptiplus.remap.core",
                "console": "com.ergoptiplus.remap.console",
                "cli": "com.ergoptiplus.remap.cli",
            },
        )
        self.assertEqual(
            self.builder._identifiers(repository=self.root, deadline=deadline),
            self.builder._identifiers(),
        )

    def test_genuine_historical_provider_refuses_current_direct_loader(self):
        self.provider_path.write_bytes(OLD_PROVIDER)
        with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
            self.builder._identifiers()
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(caught.exception.args, ("Reviewed single identity provider changed",))

    def test_genuine_historical_factory_refuses_current_captured_loader(self):
        self.factory_path.write_bytes(OLD_FACTORY)
        with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
            self.builder._source_factory()
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(caught.exception.args, ("The fixed current source factory changed",))

    def test_actual_old_factory_refuses_current_provider_dependency(self):
        old_factory = load(
            "lexical_actual_old_factory_" + str(id(self)), self.factory_path, OLD_FACTORY
        )
        with self.assertRaises(old_factory.SourceRefusal) as caught:
            old_factory.capture_dependencies(self.root, time.monotonic() + 60)
        self.assertEqual(caught.exception.code, "dependency_changed")

    def test_actual_current_factory_refuses_old_provider_dependency(self):
        factory = self.builder._source_factory()
        self.provider_path.write_bytes(OLD_PROVIDER)
        with self.assertRaises(factory.SourceRefusal) as caught:
            factory.capture_dependencies(self.root, time.monotonic() + 60)
        self.assertEqual(caught.exception.code, "dependency_changed")

    def test_genuine_factory_write_restore_after_first_read_refuses_incarnation(self):
        ordinary = self.builder._ordinary
        observations = []

        def observed(path, *arguments):
            result = ordinary(path, *arguments)
            if Path(path) == self.factory_path:
                observations.append(result)
                if len(observations) == 1:
                    original = self.factory_path.read_bytes()
                    self.factory_path.write_bytes(original + b"\n# changed retained factory\n")
                    self.factory_path.write_bytes(original)
            return result

        with patch.object(self.builder, "_ordinary", side_effect=observed):
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.builder._source_factory()
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(
            caught.exception.args, ("The actual source factory changed during loading",)
        )
        self.assertEqual(len(observations), 2)

    def test_genuine_provider_restore_after_actual_execution_refuses_dependency_incarnation(self):
        factory = self.builder._source_factory()
        actual_load = factory.load_fixed
        entered = []

        def observed(name, row):
            module = actual_load(name, row)
            if row.path == "tools/build/remap_runtime_patch.py":
                entered.append(row)
                original = self.provider_path.read_bytes()
                self.provider_path.write_bytes(original + b"\n# changed retained provider\n")
                self.provider_path.write_bytes(original)
            return module

        with patch.object(factory, "load_fixed", side_effect=observed):
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.builder._identifiers(repository=self.root, deadline=time.monotonic() + 60)
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(
            caught.exception.args, ("Actual fixed identity provider changed across loading",)
        )
        self.assertEqual(len(entered), 1)

    def test_genuine_same_byte_factory_replacement_after_read_refuses_named_incarnation(self):
        ordinary = self.builder._ordinary
        observations = []

        def observed(path, *arguments):
            result = ordinary(path, *arguments)
            if Path(path) == self.factory_path:
                observations.append(result)
                if len(observations) == 1:
                    replacement = self.factory_path.with_name("replacement.py")
                    replacement.write_bytes(self.factory_path.read_bytes())
                    replacement.replace(self.factory_path)
            return result

        with patch.object(self.builder, "_ordinary", side_effect=observed):
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.builder._source_factory()
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(
            caught.exception.args, ("The actual source factory changed during loading",)
        )
        self.assertEqual(len(observations), 2)


# Independent physical staged-leaf controls; admission provenance is modeled.
# The complete fixed path/mode input comes from immutable pre-successor evidence.
STAGED_PATHS_SHA256 = "5d86f891bf585fbadc6f01a29f03df4f628f09c4feab4b61de29d690e3e64e85"
STAGED_PATHS_ZLIB_BASE64 = (
    "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"
    "kgYnfUtDxP1Pl3mMFiAkAccQtaHapaEe1/BOR4SF8Q7AkuMFgArT7xcGIMMOzFCqiDy+fdIg08n2xZKDhE0N0GVMmks4Df0r"
    "QbF6UzGv5AcRQEvmaLEAs8R83vxcs5Trh38ewj0kLOEs7Mhhc//fD7O72Z/3+rOp+GgqV0j+Rua54wKUPorngsTR6cmC5MK6"
    "pAz7ZLlBL1j6x31yiOaUee9OVknshaa8dxw6HxAlfBnxFsyTPCbPZcSFP7pwvvAI3vCoeyOpD1w8cpSeNn/4Td+8PYt2dskk"
    "el1Ah2ZimCWjMBFfGmUofEELPJL33k5PcCTVoXaYDJVNEHuRpngsrcl9hesCeOUynXYPXdUBcD29nNzOJidJNFDQsLUeJhdX"
    "NwZ06qPqrrb6xQggwpn4ljBoVhYgzY+MYPA7EiuYRa9VAJeyF64Jz/lJ3v0A9gEQw57UCaW5eSUqAEv+8hpA82/66yd5+Zj5"
    "r58/D4MsPzSZkDVEKv6uBsgKda+6fUDkjUku/oxtkIosQjl20kjlXy/vb/aP/ah4yVGGR+OTX09+Ob14evx59zDbdztkU6BS"
    "THvG9aZANYxEqSLppBoqJdSoTPA9WGw+x0OFxMcRfi4WA8XwK4oHi6jzS5oNlFviOKYDZeRsCZ8pGyr2njGc56uBYhyl0TN9"
    "HyqlnnQRRiRDrCdjuWL1HrjaEDAVQyxcEvkOZcHElnHfjD8svvFbgFhyPj5ZnpDUIeKXT04RcaIVFk6dwi6wMA9J6BQz+fL1"
    "xS0gybjjDpKQjnsoo2+YZaHjgpaojsvKCA9fHZdUYToup1jdmesWVZiuy1lkmC2dQr47rva74yq/f/0yHK+8zcYM9HctWv8U"
    "PIehRRHWOGGMZAZbB0g2WroFbuGogsZavgVLRlQ7AcpJunKD9Go4EOQ/ozLL4+nV02/B02wSnI+/TR+D+0dhkRuM0VbIL58k"
    "5N29O8SL6+mP2+CTY7yvjvG+/eUQ8Pruj+Dp9mryfXo7uQq+TX5e/D69e3BH8HD5M5g9PkxvfzjEfLj4K/j2NL1+nN46Rv1+"
    "MXu8v3j86Rj2/uHu3gP2bDZ5eJze3TqcAY8Xt+Pgj7uH3y4e7sS4cIj89ONmcvsYTB4e7h6CS7FbeZx4An/8+XD3hzvs3++m"
    "V8H99cXj97uHm+D70+2lUzX27WI2+fLJ/egocWdP9/d3D4/uYO/uricXt87n37eHi1uhK35Obx8dtq0YCGKOBNfT39wNtm9P"
    "379PHu6+/Wty+ei+eZ++X09uz744BFT9FExvp4//ctiyfz1OLu+uJsHV0829+1YQ6HcPV5MH94iBmMWXkytnwJcXlz+Fkrh8"
    "nP5+IXWxY+DLi0fxz4ND1Ovr2ePF5W9iTtxM3fXY5TeheF3rBAV6NbkMHiaXHoo7ufWF7Ho+XF5f3P4QVsTFj5sLd3P48u7m"
    "5u72X7Pg5u7q6XriFPh+ei3mmvvWrZAd25QS9+lRWMDT2+9SU/7lHvn2wuHEuBPWmZhpE/cj7f4+mPx5Obl3a1deCcNSWE0O"
    "17USUaoHD6hCNbhFnThXjgr0+82jnArfH6c3E8fIwti9eHQ9zxT0j8ljcH0nVqLg8X/uvn+fTR7d49863AEoUAEogWVD332/"
    "uvjLPbr7PpSof0xvr4QR7A1YaKBvN47h7y8exI8+ht79w0z24pXLzWcNLAp8774TxRwJftz4xA0evCHP3CN7GdANYDG4g6uZ"
    "Q5V0dXUvBrJLQMd4k29PP9yi/RAWmtwY/pxc3LtH/v7HlVg/fvxwqh2a4Kp9L4SZ+egef3o7u59cegC+v5C/Pt1eXjz9+OkB"
    "37WlWQMrd52YdY/T7395QH+4EC0uCh48iv88PUzcUkiHzWz6P65Rrye/T64dY/7xMHW56k0m98FloHwJ7kDvnr5dC1N54hrx"
    "2j3i9PY3satzq+E0tMuV3vFSoeDE9vP6zqEHvER9uHqcXboDffpNbOXcb7vEzvDuSqw8FbC7Zpg8PDg+FhGIbs9CJrMvLrGC"
    "0ol+/3D3eKcOycSS+5cPBrHHVCSPf92L7ZtTBoH7p9syP0x+TP68lycilw6dcg3k2V/CvPnTKfLT7VQdB0xml2LWOYT+1SVW"
    "IGsvR9nFo8ND7snsq0OsfzrE+nap3fwzt5g3F3+qAxUPsGJZndw+3XxzeOQx+fPi5t6hATD5c3Ipj4G1D8strNiCTh+kwvom"
    "T9+Dy58Th9aVYrh/mHyX1rxLm1UBC91yeXc7kxE5YuvvHF453p4enTfJ/fX0cvoY3D5dX6szUofQj7NHsZ98mExcYwprafJw"
    "67gpZACCS1tR4olB8f1SjORHsV34fvF07RJdbNCDnxe3V9cOVYVGFXroeuLOYvw+FTb99M4h3u3FtZhf7rfka2TXe+Xv15M/"
    "g8t//tMt4N3txKkeU6Ci+nduUaVqefzd4VJRxiA5PKEqER2fplWobk/TJKo8nXS+tZPAarbeXtxM3G9HFLwf6B+Xl86jA35c"
    "OtcC8mDu5u5W7MPEbsHtedcudHAp7LPfqjM7n0TVwcF/3186pXkQq9vdTekVcod8ffdNLHLfpKnp0IFewTqekz8vZj/VVkPs"
    "MFX48+QqeDofBxeXYm/sbrBLN55bjVoiOtaoFapbjfpTLHvO408lqGsD5WfpztFR1Rff5AS5dRzJ1s5xM711ahRsspS2smTw"
    "WhtRix/ysOXi6sozw9X09+nMoY+lYpncPj74rccmg696SL0m4xwePSHLCwd+RtL1xV9yH37mC3jsC/jcHbAOTZFDfnr1p3PY"
    "S5e7zwp08qeMerlwjnt98T9/OS7x4821ik2duLwKML26/Hnx4H6Zm97qWScWZnWd6lJfQnGI/ziR59gOz0QryGv3kDduIR8e"
    "nu7lceOT/NkDsj4Y/z7988ndIe6/3G0C/jXzsMtVoMIq1V529xOiwi/1gzd898HlCnly8fjHz+njxFPBvdw5UMj//XQntkk+"
    "G12DT7//5Qvf8W7hX+6W5uvJn9Lfej1VR/96w+8OfPrj56PyDjmPKbiePup7RE43LzcXD7+JbdHsDxkD5M9pLGkCwRMoIk+w"
    "7mfjjZgYzrW2Av1+4/DUvkR0XUZ1bdgd5KzUOo8XMjLqwa2///bicfq7vhPnfhiU4Pqyndujult5znpV7rgv724vLx5lnOPU"
    "5VHYBseNMG69EszkMawMKrxWxp5rEqVcZTfLOFnXzvcmx+zu6eFy4pnj8cZ5A0kvuWib3yZ/iQ758SS3Xq4ptPkzuwyexr+M"
    "v6r//tM1RxnfdHV3fS32eo5jkUqOmf+mqqy4h7sbuWlVgVUqgYpDoirYVKzdFzPJNptcf5cGpDsOvcFwvRKWTh0PsHJtmTl0"
    "q99dymgC11bt3cz1zah7sUJNrtweUTcwg/u72Wzq8gjrXi2p6k70xePjg1vcq6ebG7HiTZzGoClkeUrrvrw3s9+rw1+HwPJw"
    "8+Kby3GrMSd/Tl1Dug4C0qizyQ+3EUv3Fw8XtzKVjLpwpq+Fu80YUTMoD+TMPe6Nyy3//eVYBnu6w5s8qDvLt5fug/7v5QWl"
    "yeO32VUjN5JTdB8pl3yEegrL9mY689DCD3e/T2U6GR0nWLrSq1Afd23i9pJJFd7o0GioIM/HLiEnDxM5LxSyS9NBQF/7sMYE"
    "rozD8+hcKrcKl0Kz3QbCtL5xeI9rA9uDwqjwvaVZKQlk4PWTaHhvBK5t44fJ/XXw/V6YhsLidHibVOFOZyo1zMQ16vT2u2tI"
    "l7lmFORs+uPW5f5TrCJVxNjl9Z1DK6ABPL39OXlwXGa9+Zw5xbx/fJAzWei6h5nb0up9orvSziZl4K1DxOvvgfQ6uCzk479u"
    "3Ony2c/JN7nRdB6QMPv59F0sns4XNjFVXTeBdmqKxeybS9THBxmq5NB0KhGFDSnf8XCNOvttKhasn9Pvjy6hp5cyCuHy2jXm"
    "0+P3r2XHOYVeX3x2Ces25aUAfLz4Flz+vHBbyhrU7ZaqRFbhhm6trBL55uJPHwV2HRJbwoqd4Df3oHqNdQ1bhuyq0z3RzLPf"
    "XBPMfoop95ufYeF84fnr5tud+xsAjxfTa3l05xDwQd6uEGa3uzt5j/Ku/reLy99m7iHF+nDv0O+2vkeh71BMZu4d9DKj/MPs"
    "8u7BuTn2dCsNULkPm2rHgLsGf5KZouVafOFwUihQx7mXf78oU/iqJcOtSVJju1U5NWyp0LTG9FT0kmN2feGP4+l2dvF94hD3"
    "YXpxNZU5EC4f7hwOlcnDtzudCcbliUANWzmIXOPfXT/dCj39V/DDnbNWORR18vbALBS+fMBSv5ESE5QeeCNxP4h6kW+BmXzm"
    "KKMst4EiHD3HOHgu5nPM6LN8fJk7wMP8iwUKThWIqmeQMZLmvzhFO3OKNrZHmyOey3d1zYFi+hYkOKFs5QQk4DkjmQVUhpl6"
    "7lSM9IDjlJOcvNqMeUaTQD4RLprJZnxyHBaM5CsnZeJLFMsmC0VroQPvp+5HyklC0oVNoeYYyWfANnTX3f2j1VMvXZhu3rHY"
    "g264q+9CtMghfgDS9JLuIVjDW7qdsMaZX7sRXQOa5ZLdC2eXTPYgtFU22V7oNulkDxI4n7guM6fu5TBPndoNa7h56wa0SXLa"
    "iXqtvSRXDiFdz2O7RJ8HYA2DMLpQjRO8dQPaJxzrxpa5u2RcqOnh3B5k84RjB0DtMo51gRunHOsElG876WcSXYNaPEnVCWye"
    "xukApGuDxjKR0z7YKubd+nZGHxLr6xldJDbJkrowf17Iu0lPs8e7m+CnQ1jzVDcHIF2POstkN12wDi6Wd0E7uybbReDiqmgX"
    "ttO7Un1IvM3G27vNa2Ulqfntsn1EzadHnfaG5euV+4C97vwlgZvXIfcw2L9dtwfcYWryfiy26ckPsBimKN+DapzTdB+m+eXG"
    "Paj/unQLJzS8e8Q/3SK6hbO9hr8P2s317j0M1S1jddR9Z3ttsweRkzvZfXms7mX3JbG+m32YyM/Ud3rx+DCPw1u7e8iqLHVa"
    "rftamxosHtcmywuye5CtrrTuwzW9tLYH08X1nL3wdlct9kBbxIPvQ7ULN96HbBNvuwfXJvprD6xt8MY+aKsAiz3A9kEWXeA2"
    "F/S7MC0vEHfB2lwL7MKs7iMHYr6pYruENr+E0Y1pFvbXiWd7W6IT2Py6RCek+c2GPZDWUf17sB2f1NsF4PdBDdxuFKxCgjtB"
    "bQN4u4AdRNd2QtuEqy4xijAb8ZRkGc756ZdPzySnGT9ZnpDUCgnFZJEmOM2DOYljkjpAZOGS5DiUrVCCOijn8yrHlImPAvE/"
    "8oojl5Cuqi6DF0lcAzqodphlAX4PsRpMAUcpyVf2qBHKcZAx+krEx/ZwizAMwhili+CVcPJMYieFJKloQhy8UfaCGC1SBz2e"
    "8NfQaRl1PGgQoxUtcnu4DIUvOAryVxQ7G5NZjHIZaBiIv0dEDiMx5dMwLiLMXaKL399zhlxiOptFNSJfIoYjd9VnWPW/jE4N"
    "EpQv7RHzVYb5mSOcsSOcIPznP11BxXiBQqOpF2dNNLmufg8upn86g7qZ/ri4mzmDu716uJteOYO7l3E4rsAeblxBfbu8dAY1"
    "c9Zal2bjtRVKJkNzBnZ/7xDq7MwZ2F8//hAbCkdoV08Pos3uXMFNbmaXD9P7x4mzAn6/FpvI++uLvyYPziAfJhOHA/iHu2n1"
    "8/7JmY68nt66A7v58vU3Z1jT2x9/OAR7dId172xJkfkIXWHpnGvO0KQH+EoGoP50BXl3P7l1WMK7h29TZx1xfzdzZ3fc3zvr"
    "1P++dVaqh+ns8ndXYLP7iwdnlZw93bqDup88OBuxMmbsfvowcYj3l7NWe3Rn2T5dXk+/OSuYfMJVvW7trny37ibn7w7t2/Ix"
    "S1dwf379Mhyq2gkbXBGsRdfbaUTeLYrQwEnIAlHuBiuNGCWRG6wsi7ETpHC1eDPx5rRARQVD6YI6wcIJDxnJcuymaPMY8aX4"
    "bWXiVWzBW+AUMxK6xHrmkUu4InU0BZZZ4QYoJqkjJJrh1FVzUfZM3MzvjHJHTf536gaH0xgxR7WTt7czwtwondyRShWaK6Jv"
    "Blg5WgxZaKq0Dac36AXPSYwHij1MLq5uJieM5wMFxcfyAIPzFCXYqMQSQf1y8m9uKhokOEdCnqbGCBmj7yuLIoQ0ScQCatcE"
    "mDHKjCFoFtLIrBPk8QlaYJMm5DnKSXgqBjoWSiEfTF3K83wlDIaQczPxN/E76d99ssGJPHkYOG70bydZ2Hs+13kYhk6xWlAm"
    "gghHy9UzI5EjFFl/9UGgPzgJnaItjdBiuliQdGFbxQpmXaryE8NKduPZVVP8O16kRRbT/CRbGUHllMlQAdsWq2DWNSw/MWyx"
    "bryhLRYmkTzJNq9gBaCWKf3z4Eq1YSztMcQwektwMrw4QsdnQlePhKXwatEyGzCqXOUn8rj71bJYu3hLK7wc89ygSPM5thk8"
    "Wn4R02cU8xP9qxnGEot5YIUgjQscG0Jk2agOhbFYibZwNiJsRPtk2UA8tYiPcrEp56PoFcUFHmi/7kMyrmULlhzO6oNAfzB4"
    "KPbBXNpjGk2TJg6n4QvO3bRdibWup/7Aqp4dmIFyJoQegKsN3GDsIklWIxktNqqixSxatQVMfRZshqMNLSQWo8a8VEpa/seA"
    "F6d5TGlmQ15BPCNOhM0hR35f878FJQzqny2q00RZOkGxqVJMxI/lyLZuIBwmyE25pHon1KKVE0RSC/GMxjZDlmP2Ko8U3DRr"
    "qRPNi5OTRJTGrBiLQqgN8zmoxefk2ZQ5Y6LwVsLhEocvg1uvAqAh5tycX4lLU54blqDIMsxCxIfbE8qeNO85LV4apQNl//2e"
    "MZznK3P2GqH6YXAZuDCGn+m7eREqgPLf/gWQcboGtEpM744zSuPBZu62vH0J1ptz+evABujGWZriZDmTdwAGOC87MYI5eS8y"
    "86IMs6KVdPhMmVmnKknD7lSy8j8RltvlAW6ktbjaqYsfTCpcyy6Hy0qnqykvK9JAdtIrDnPpL++vwTWG2K3SGBv2Vyls2mWl"
    "uHaQqJ+HtkALwtIIwWCciw9Hr2cjOctQbtaAmxCGzbgJIpvi9SzQv1nVaBNpaYFk3bgSICivRZ0NHeLdUGMHUHLTd+YIZ3B5"
    "Kv+50eAzP2PYEJfDZPCpQifC0gjBYIAlJCUJikcqtfzcrAW3MAwbcgtFtkb5kc57P7erWQve0gbPpK1pVMR4VP7NsK03MUzb"
    "ehNFtY36KKiOM0PHeEsbPPO2ToUNZNXQCsCulRVEo0nk7xa12UZaGiMZNKsa/CMUY2a41DcBDJu1CSEbQ/0eqN8tarONtDRG"
    "GtKsMQlxyvVLLQlN/81P8vd8oGhcIAOppGDi/5eIL8cG0jyLSZ6Q9y+fDITfKaN8SRg9G3/N4mJAncsTr77mQUbjlbz2Wtu3"
    "o1KJGyBUn+unaywAVEDPiOM8x0zMw/SNkVy+yuIK0gEe4dULMcMx9NGogaC+/T1CnJNFai6fMZpTeTl2FAntlOKFahV3eNwU"
    "r/FEjej2NxMERhPC+3csZ+GIpFmRn84yHBIUXyIuzMTR12eS959zHSgmAE8pkU6JK5Qj40I0MEzEDR71WQuvHVtiLKAi7q3m"
    "tyAyUr6AZSG/yrWDxxghRP3PPFqkBXdoI652nuYAOjzUWHyJUWYuLcOKhW6wARA6JEW9faO7COXjW8Yl0NrNXJ6JlZgm5vL6"
    "CSsLcTZgo70rL4/IzKSfSYAYQytj6WcqDBGUmstbaA4hPsTBuiMsYwushAdFZbQjDAy/2AUZtsPdkcep0H3Gg08CSGvNWHpe"
    "pKEMrjIGKA00U3HppDcWVlldTIXTInm2GPg2Gk+IN8w3cwyqFL+5fGkAWsirWyzm4u/meo/heWzTAUyY8u+ZsbjNiiHFV8kz"
    "NZ81+ZJhFNmI0zfTgRM9x0Lrillr1O/a0DIXlSevOLJZtMrrPChklNsgvPJ0mCO5BWRhVQkpbdSSeskwFw1QsZBpCc3KriFi"
    "mi7+nWQ2EDZ9WCIQHtrIq4lkCFCFNZv1wzzOLWahWHrexIbLcMOw1BarmeyzzBYorQ5TeT31bYT1ptus22oIzgc4iNsxZI5Q"
    "YwBhf5g3ghC2GPtLud226EK5WTaWtOo8KT8nMsnif7AFhHRz2xgACiRB7EVe53zDOLOBsdi5awDzcSDFhR0WiimdW0DopgxR"
    "uMTWKNpXbYyyjJj50BTCdnoB97/FtCWZotxiQpZ7GRthq2lZQdi0XYmhborbQWCxM7RDsJhSJUIWjofcJOwAYeYrjN6cmY2I"
    "UjXaCNuNhRLDohvKDdbSQthqRpQQ9fGCFYp1O2j3qmEp7JzTYosg7BVDWW4qFyBGTF1LQro+TTGlNz9MkcJlonN7ANPi43cc"
    "Fjk1L4Gx3hKyr8iY13Q7FYsKG5JqUSNWsUwNuUfdLmzEXNt8htLK82YhaznESxC7UcpwFqMQSzcId4Bg1Bocx/Mh4UEd0mbc"
    "ao01LHj+anpkoCSNOAt90m8lHPAiy6ipXVKBqD2K4aApcmJafyEZPJNc3+Rg5vQSRJ1a2YEUcxlaZIURItOxr8QjWhhvFhWA"
    "9APItd6iL6327xUAe7ORN7YOlbgwT1cWp/c6mrd3rqO1bKV/hgXepHSdJEWlQRsylxrCnBYsxEOTO22CDD023pIcUHCOM8RQ"
    "ju0ijjZRjIKOdiEM4o52QIZay7sAQ6OPWhAGByDtYAyOQdpBGBqGtANgEInUgjF8v7cDMlwr7kAMP6DfgRiu13YgBgcmtSAM"
    "dTTvQAwNT9oAMIlQ2gYwCFLagbBTNgahStvyQ6OV2uQHByy1ghjELO3gDF9/tiFMIpd2MIYGL20DmMQvbWMMD2HaRhgaxbQt"
    "PzSQaVt+eCzTNoKltjSPaNqBGR7UtAMxPK6pBWJgaFMLwruVzjQIcNqFGBrjtI1gufgYRTptIwwPdmpBGBrvtAlh4IZvBzAd"
    "UMM3KxviJjFbmwBDw7Z2pU0jt1qQhgf+tIAYxW/t4ixsazMwimsDYHAg1660SSxXC4pBOFcLimXHmgV1tUAMjuvaxDAJ7dpA"
    "MInu2gQwCPDaABge47UpbhTmtQUxONKrTX74MWw7yuDz6FaYgQdbOxgDo77a5O3mh1Hs1ybCwPCvHWHbHjUNAttFMYsD28Ux"
    "DQVrQbLzmxgFhO0imMSE7aIYhoV1AQ2ODNsBGhgc1iZvrUcGhohtChtEiW0CDA8Ua5O3ncDG4WKtMIMjxlpRhgaNtYLYzTzz"
    "0LF2HGa1WA0OINsUHx5D1iZvPUYMI8k2QYYHk7XJ284ai5CyViAXbWIQWLYBY33WMDy8bFOcW4gODzLbBjCJM9vGsDo8M4w2"
    "68SwqIdJNM82ho3CGx55tiVusdsbHH/WIm3KbRCF1ipvym8Si7YFMDQcrUXcfhpYBKVt4ZjFpXWDmLaMSXRaO4BxCYyjNDZh"
    "hoe6bcgPjXbbFTZlNoh5a5M3CXtrxRke+bYJMzD4bUfYMP6tFccgBK4FxyQKbhdmaCDcLsLwWLhdDKNwuF0YSx+GWVBcC4SN"
    "fWsRGtfEGRjoZXZUZKcqDSLZhtYsp1Tl3Eue5aNmAqB3GvJKUraIfB1uoJzYouSCMIvegzLb4EAElVxTNGmQU7mKaJ/6YAil"
    "9oZKJdl6ezBMVuWglI4RxLEyzQzFl4hxQ1mxXvxdYGGP63e/hoEscFpvcgdLlrNnmJycMGMZiDpQLsFsgZvvyw4Tz5hUFbhe"
    "XSM0GIJhTuNX+YCemlyRfKEap3QgCg9RWltJBqIFx5GSFxPtWfxnIIZs+bHaQB2Wk+rnZEFyskgpw32+3Tcv7VD9u6M7x7+I"
    "/xM/nJzs1bIHoJa9oZZdUBmjys276o6sLv8haRgXET5FnNCTZffrfC1fP0XpSu2aYiwn+XrjYwezFOut8iQMRyHUvBBZJj4d"
    "LMWDvMjk4wpD5TgNiViaSp8gMinxGiOUIVtxjFT7cflYrDmWcQOuIUiS4Ej+aA1mIrlKQ7H75TI0fqjsGyoz5Q4UVM/LKeW9"
    "YCip3zA0AsFIv/yq3uwyw5C6zkxSTKDqgMhEXJvKAQrlo1cWxWDozaoRpWNa9mOQkcywCBz/HcgHz3FuVRKOGZHvC8ittxmA"
    "WOYEADcugE3h9fOWsjszg6m4AUKosA4wSqxANIRy9xuhKHGLcVkCWLWpiyoI8WD+FplBVErORsNUKcXNJhhJLZY9JW294CkU"
    "09VJCdsvclV0lImUdDYTuR/VQWomEGKhLg/wjOZlC4bRmKxwLIvhoATKjWdbjiaIeWl4ID2KJtNDz4wAzXNsLJubCVbTUa1Y"
    "dhC5vKhjgyDz8w8GoGobQsVW1kCUZ+gtHS5Xb3vEpjMiJrO5LLOhmEFV9eZ4sFRqYFaWYkbLjHzhQz4cMViM0SKX4TcDBe0s"
    "9/I2b3MjnNMXnBrgGJFjxoaPhQjnMrbPSI7Ep2WAsrmsiYKt5HVYkaFwThNhBZWn1jYQPCZJkBQ5fjfEEfYYDuZM7LrsNegu"
    "5KZ6MsWT5pKhV6eCEMbiiwzjqmytQD6ebgZV2U+c/AcHiwKxyA5J7BQLLJo+EHvOLDev4pYlw0Ut0cK0D2VMUHlz2RBgyWhK"
    "rYSVIgyEjUpkCIIZkLVbcBcowZxbNOwaKEOrmKLIGZCDKsoFPXijzLjXaRoWYiVIw1WwJMbKrbZlxChcBTiVW0Wx3ZLv0TtF"
    "tFGcZnbMWpgXiVRIpb1uisPzSCy+FtLmnaTuoaspar6Kbto80tv1SkJsDCZd8GKMGFnvNQgPGcn0EsHtQdT21nixaQDpjaEF"
    "0muQUaHURYFCg31hCYNdYFjMYyU7j2RgmLTrVfQvKyyWzcZNPUP50qCo0xBY4hj3sGqV3NKKmEtLJAqUvWQKUTbE8D18DSC0"
    "sr1lK2BkwIeZcJkQwky4XIfLPEtLHGfmGr7CEitG7ghKBli8qKsVdjBCyQpN8HdBWBUmaoVnYXbIsLMgQaYzhwhLqtMaJ+aQ"
    "W2uJFZIT7d2OZVEu7KpQ2FmJuhcIC9SdqWOBRWhQqCtFjeFRGT4uYOXxlFNAO6usHctJucpDPQ0ZSLeDDe6LmPgFdjGYt5As"
    "ypQWYlZoe8kCRXo/HU8IsVMk7w5KpmD0Km8N0zgrdzHONGh5c88eh/Mgy63aXI0n8oodK44a1vF8KgMLmXvA8uZgRmlsg8el"
    "67mI7SZCOa0caI0tJKsy6QYvz3hXdqXawrIpVx2L4mLclsPV0rKqB71L7SgP1hvxAS5W0C5I+1K6K5yDMpVTW+528HtuiUTf"
    "yvRINjDKMaUXdBlEZQH1RtJA6O2c49B+yZNg1suvBCE0zJzZjDWgNpidQhJaD4ulWzgXpXNsfKxx3S7KErfM7uC2i+SBIXE0"
    "ru1tLoVib3EJGNmd7vtAoJYe79oGWboGtCuhrLNYDonx7BCiKrrNMKBgC4TwDOXh0hZH2OK5HYY8b1MDwBBFax1GY3OAcv7K"
    "njIH2XFB6AQjubn/uRPUKaKltdKCqA9WXNfc8rim3ZtjiaW8CVWAoH3RaIbN4ke3gRxVbyPc3EH9SrwqhswZIMPhq1s0FWzj"
    "FDHhC3eAXHzVLVpOXeK5HH0bRoIlpIy0t6gnD7bONMyBTEPUS4QXvHqjLKpNMkMUFw7amCTm4UTyykEczBkWmj3Vh6SiaYip"
    "SVGmOTAUtjgaTXVAHs+D+BXFBTaHCWm2MrnxViGs/dsWAA4OrRWO1aGvQrDqlML6KE1BlF421RrYDsmFgtRIzd2hBU6VR88C"
    "wUoFVYkRqbH9TuMoUPvl6EWFxyLTkU8z7ZUyFrcz3rrOlAzRRG2qVA+mCOsDKRsEJ1E0GspKnTRPxmwQ2vxSVngutEsJZa8U"
    "Ns7orCCs1EJW8KXl+N13uGeJ6Gbbt31MaLvN2saz3mZtA9pts9rQ7LZZbYhW26zdg1ubbVYbms02q+NY2S2azTarhrTbZtlZ"
    "bKW0NX1gaQ6IwbgKY5Uv2fRidY20wO8WIeFVPiLxDfUQlE3TaCRrANGwbGUNY6/P2+IpLLGaoRRmULYnGLW8tT9xjZQj/mIP"
    "opuGpHNqjCWqFAUW29ISwdwycWahO4lzcRSY4sQGLUHs7kyVIOqczArBWLm0xNQYAtnG25cr81LscM3bcx3TYwlgo0c6Q4Ks"
    "8GS8vHm1VG5OtTJbVMx+w8Vzu3t4Ut6Bu07CWG2vJYBtOzhqTqvdq9tIMycRYeWDGa8EvxkiWLXIVgSZFciC0SKzg5Dmg42l"
    "1gxjs0KwvOcmo0uqvEnmq1Ujms4ewapZt8L6bFBsLeAtFIu9k50XS13osrpuL9MUk9zUrFP7cDt7zG4rvxugaY5js0hKeSd+"
    "aAlktUy2B4haYpWBh3axQV2Rpm7QLKN33MWs1khunLg1nO1eew30ilksk9+66MsGmLka2xuSawvpxve9jWft+94GtPN9t6HZ"
    "+b7bEK1837vx0WnkEs3laHHgr6sh7Z1SNZT9Wmm7RrYHopvjOdiQNcLPLQCszDCBIFSgdSnEgLOFYPKFTZkOO0EpWthYITWS"
    "zXhjUm9YuvQ3YJj9mGO5Sx2+RrNW4Gsoa9W4ewXCJZalWnR2k0JjyR0MN0dY35owhKDspb7sYF4Vpm0o072U6WULIUe5UQ5S"
    "I/+GEgr062YDJZW7zKScleCp8TFpAyJdGQfWrlGeUeQCpUyQaI+gt6zIrnUNN007AGLVMcewb1WSquRmte9Nz0irZibpqxh3"
    "MnU6YkJFmGQ6W4MlQk9YlYaGYZGhNFxZQBS5sNvSSAW8G6QAWiNlTF41C2gaWxSHYZ0BlS9JZowSWI1f0xFHdQ4ls5yk+D0T"
    "22WZxwnJ5LYBF/0RYzuU+qUA7W2gjFvh6acDQjGHUhy7QKqSVeZOQDfy5xpn496EdFEsjWF2hNCKZOYi3oQyT5W+jWOUN30L"
    "xO04oIxaA7ho5DqZru42Y5ffPlCxT8HEaEO2D1VtWao8gtw5suvCGu2JWiFlz9vnLO6EzhhNCMeBhfG6i7xUq8UiRSbpFtsA"
    "1RV0D62bIZYrh7BuBStIVUY3y+RGdY3ylbTA2eognbkKMTFSRKmMzsFb8Fw1fMHle5UuqiiRXBTLYVO5KI6TBrJoG3VcaOLY"
    "MTj7XuBUlDksjboqbNgUpX6ET9Q8p+HwsNgaqMzra1ueZm7LCouYYcln8Wyr1XjXzhpKP1RgCtPMjEvSQtvdS0oH7yCXZLHU"
    "LmG9eTN6f6V+zmu4oFxJOl5CJYZYzYdMjTCMXjOtFkWjJ021sOkLmlvSJnV28arZJpDNg2B6Gbd4jGsDILeQ3nyWy6RlTXdp"
    "pbDJOwtNUbMiG7031ZQ1enRqF8Cw9CZPV5Xpoc3eciqFzR500subie27ltQnAUbitn67DhTzslCz6W4ebrQtblJ0+Ri96aph"
    "clBdC5rqNyVbCOshNhSPCJPz1OLgaxPIyEdXpWmtY51M7O52EJNRYK7pOQvN5FY8x4nVyN+CIOYQVvPX4jbejrxJHeSOz84E"
    "kwhmD2/oxIPSYjKXNFEE1RGdYbdpcbH6GCOY6+xaMtAXNwYDZKcoisTOh5tLBq+frISNH6rdRBHVH/4kWxPii5Wwk1p8Ma6F"
    "jAGoYEI0PMWlgrDxntQAVWSVNYAoisEF0V0Yi47ZQlK3wO1hxA9FnJvMOEuP0hrBypm0hrG6aylglpTnQYoSkxFPwiQzEVNu"
    "AmOdtyFOrMTN9OY2gm0ZvliX4YtpGawVjn6Ypx5DhsVIca6CJsy7o4FgW4Yv1mUw6Y5E6CNiuGxYNZ9VvWuFarTdacjr7B6G"
    "KHloooaKyEgqNe0lYVqYREURHqAsi4mON8uYjCDITVCUi35R0IKbr8fmSUiFqNoWVX5ZA3m9uzAFUGlDLRWexqg9g4gwMwTr"
    "860Sxs4W2QCxMkc0koNTqRLI7kxKqdIsboR8DjYzZDXQAkdGSWyyGIVYZ+AYTiwT4ZWjdJ2EzgalbExbMHfyRlpeg7ioy+Bp"
    "oiNaDaRM/LBG+xvpdqCJuhAprEF57D8YwcDza+j0Nff3Skm9CBqc6TjIrebC1WznZdYpm9Sxpl4GhwOol2INxVSwrtCoQ8Ub"
    "Lm0LUSO9sc7MZC5pRqz35UaiJs57zmMDEdM7Hg1Rsyry2vCoD+plKAlfoheTONYGHk4XJLUpkKNylAaVKgyxQxEmfyo+M3oJ"
    "qIlFLaqzUQZ7GKM8XA2cDHGuXjMQ9mL8jIbnsGpgGebAaCDwZZFH9C21RNHWTUiZzfAVu2kyX7loF9P8GxLCaHmTgrUvKVAV"
    "IWa51iRSFYRhqt825ImhvFE4RS3d0RimcAZnu1LWLHZqLWm8QlRD2bwPS4TE4HpqmcfA4jRYWGooWplFMpqdJZbtbbID0KJi"
    "MR4saHXwXx3Y//+1nVuv47YRx9/7MfJcr9CgQIu+pdlFsgi22WaRC1AEAi3RNmtJ1JLSsR2g370zJGVJvp6Z0T5kz4kP/z/z"
    "Tg4vQ1Z3IdvsT3JW8XS7sKBGP9vN8wYhqISYPOY9pqjKYO6v0KFYfCnDcU4lDKRQUjqvdb1m5HmEpAum+P6PjCCKRVyvFkQi"
    "AhaIQ+qnwktC+tgK03Vh6UlSeIlaJF4LxEcUj5TbrGWaOYJpit+EcA1zAPHWEc6N2XKkwZtvoznR5R/UATHvK0HFuBCDZRSW"
    "ABhC1pDUNyejK3I8RafN+AfNQMnfS4JZnWcYBcHXFm8oPBj47ODTkvrMZZYQNTrbWwI3XwlegpimlDLUIhm2WFbJHBwOlCWz"
    "WpbJLjl44CyLs856co95UjuotQX7N+u7N0Xb1lTN67+mOB5tS+oTSr3ut7nyXpNWtHF61u3TD4IOvceGfygasH5VtbVQVLua"
    "ogmJIgjWp04TgpenJlfOqRNBA/8RQjeAtweCIGx5w5BCkPhWNcTgMNpRshV9oBGC/xEdvr9SUat2bY+ZxmkYyS1x8C+AuyK0"
    "rZymsrtaNU2myip5hDV/kKY4ZwJWtzAFVKYBI+4A1Tv3/ZrogumMS0udam3yWhXOegEEYpVmJj4Lnlr/60mTlEe8zqJbFOeX"
    "wwkjxzpbcQnZKb8TyE3T9l22NtDiT+F0Ea9KzWjh38HjtxfjMJdzr45iUAWTZXnqWqhCS2DS7nfeSVDpENpgD+ITPvRzaQ+o"
    "HZ48r9tqMVq8g9s6ezwtyLSObpTcZ4YK5zS2dL1sfrYOX+1GP0MLYEM0i953Nm4P5EWlvJcC00guxTi9ESDCOJKHR8PElL4R"
    "c+BHhpuBYMmV2VpvTbMYjXa+6TarbekrCDdJ8DvYmFocI1PqpsPl7k5txSwv7PsDJTzX5KUU3sMiN1Ev1pSirt/23WTkDuak"
    "k+PijyXG7gSUzVTnLzHhCq3q5BztCyXqEBKH6mP5EvOiql7zKgF35hn6ZtpS7FlrXRkOGYHlw5F3O+NKdF12yna6rPTwY0kW"
    "dPYlbeCxJf5HULSfYRwvNlkwwBm6tbWVVg1H2ROXtgZhsSEu0g3C0gTHhcpxEtr0xD2iuTAjTjsHteubvLKW8e7AHQKYadDl"
    "Zx5MR/SpI8bHzoMh7B05P1ge2C+Uy0BiJpZ6bfvwaCLxUsAd3PkDmPsa2jtVt4mplBdMMnUj6pKS1v1NKWCEAwzx6U0JhXje"
    "MOh182KcbdATX/6iYC6wpndhtxh0Mzyg8FhPPLRCVW4LcglsPbnBEldzooZeN0CSFdASO3eivjtw1sfqHfYK+PJhRKcupZ0x"
    "zAwD27DpN6pAq8nlvC4ZMa2zZc9qnlM1//udDsf6x9s8vEtGD3i8djZh8bKm92qr2cK8FaoNK8Xxc0aKObUfNdnGulp1Hb2A"
    "grqGst0pukv1kYC/5bJI9I0oGtYfs7iBbNbURztvA7J0V5h4aPoObGOL3sOUoje5rnTNmKRcM8NJ5H86U26h21h9n1btF2DG"
    "ObcMVNvGdMxyFGb8KF8qiy6JvAwqtmFGWSlW5QQ19RHWK22m+mPY8nMWX9/sOl4On3HyCIV/c+Ke4zVmmXKe49iFHBl7zZtU"
    "zSC17b2IABZWy9LvYKpt+cpMrYMDYh1Ohedl79jt+SaQek3/kiZO3wIT1wktOc1nxwnqGdFD6pU2U02xwx00blscOB0ewKJP"
    "fpAR/KwLRo6pPubp9BPPePjxjN4BwVZrexSJM68LsDVS24w75IL0RgDPpL/USyy5Oyxx65gxF01s8v5i6EsZl6ilyi/3MDEs"
    "lgQtWaKX0EWLdoSnq76dOy3HXD5ffasLszG8jsTYvelysBPBvCY+BXOXEfsTL6qKZ6TAPrmCXH/CHl8mpNB5DrflWCu+c6Bg"
    "WBghYRtvAcRiDSxgGQdMLghp5ZmxdTQyWnvAa2Ihm2V165KUiat89ATiTjm/20mcrneCkhreDxYniLVAfyEXDx1XqIXqc0Ry"
    "lnsvGWOzC05s8Dwab9J6DQXTb22VK4V93RRZq2JHdfvyADev9MyEx1MEwin7XrtG0HYq1YPZUnSVSJyVtlb40r1yW93JUEM7"
    "JnqCfUBqVbdbhsRPH8yXw+0c02ysVL/Qas01krdi43HVktcnJWmmus6Zdd/x+t2BUmzzZUCC5jggJJkSJ2bxbrhuCmZarijS"
    "MekuUTw03SDXtgwWQp7epF4qD2R26w3glyotyZiAXnR9q3i20Vm8UDdzwaP3MamfoqYlyQZXD1x5GJ8V+eXZGYN4HXKu5aUe"
    "JiiavNTGWQL1bVnZLU+V4dEBSzcaBjX7FEoCMJtYUpOv+UzFomzrG/O51zh1ZOwW805JRFV61KXb/J2ph39rtrTHc8uaKedE"
    "Ojm7wdv6VCkU0TFPs2Ky16o7hIy3VnMDlF5mNDbf6aql16F7yMLpcGdBVX4pZGO7s7sx8lWWh+RWL5dwhoPohzz0pqJ9x11Z"
    "u4tFb7f1EjloW9aIeIOExZAvW3HQXFsk06hLQal/Vv7UFK+e5ExFOfwG5b0yTSXRU7XFBvRu+8LR6YYlix2P56R0IidLbQ2D"
    "PutLg5KqildU0INJsQdTqeAV7TWFSyiMK/pKufwzmwCt3sKUGJ1AhNbKw4RpdSxESY5MMGxE3QkJ8Hte+60kHQkhlCdX3AtE"
    "5OzUm0ep27rI15Ut9njBi13Xmr6q8hqMtyOXYL0kMyy7ekNtMrY0RY7Wr6xELlBczLBiLYnKwODqcYQKZ3R6n59NPx6qK9q0"
    "dblKrovkJDZh9Ikpyd2Za00eoi+XypWRxCWkCOTpz1QMdMt4Kzfv0EY5stThol+JExsv0UefwXz9cCxNQLCVdTJA3QZPvBKE"
    "E+nh9zeVKXQDmel8JwCFY/KchnZNkRCsl6nTogAf0TrTdBsJIbwvKkqG70qJ/IiehDgAfpsSNAWswgwZFjVHxy8dZqnwSmO8"
    "tUIUHsiR5BvHPLO4LslWfBvyohkv83BiewWhArxp9j5TTenQPwb+H5fgTRh8AoOTlFscHiP45pFF44xgy2EaHkxOcTymIB5k"
    "eFZDgChhonaSxqMEk0Ai79u0kSGA7Gzv5CnZq81eCfS1bbZWovcvhUAerGW+PM1IBITPsR54nhp3aeKqgyAKzqI38ma7RCu9"
    "ZvE4slgIvrcrbd/lY7/rBbG4Yok4y8RGEo+Tx5UuQeaGfWfJ2IrrDnw12ud8Ndjm8RS4LBMAs8TsYIYhI8IP1penLXiiqrPt"
    "AV15UIXdQat9TTY8zh7mXykLztW82uhMBYfLGh9naC2Y3pRjFiOF7mhpqkVHUuRjvCMgvPNSdHncbST5B55Cmo3ZcqX4/JFp"
    "JIko8UwXusOJtL4gXuSckqKL4MpsMUZ9IwZVud2ICFTH47cIkJocWv85eyS4AFENPolNdLhxA9Xie10verjxLYGBKVfoHHop"
    "2ouQVxzj88Z2O2cPuT+otiU6Arri1aqFWL3YvYgS3AnhhUyas7EJxx4a4mP2o3hTqS1bSHyQdSq2cXpIvUo9Igz0jkemstNb"
    "ZvWOXulzdnaLOuNBTPRsOwFE15r4/FetO2YWnI/ZstTQS4GlFwaEkpmKTm23oh6cejJlVKa2ytMa/8oDk94V9zybfPz3T59+"
    "/PTbN9MPP6STmP5gNt0XQb874u0f/yW+4cc1HjgKJ9S+jSNFpb9IUj4Ft3oM8sT/ysAdP3qPnTaZeXaxkYDffvcO/5cHm11F"
    "ScCP8bP38BEPOh48T8Rfhw9IvGRgrHtTldmbrelgumKdpio/qL3GhQSqDrIG74++OdXVq6XpAFrxqlaaJGlLJt/UXWXWaemZ"
    "hig2W6JgspxAEp5XZIi6ZPLRNNPFhtvKYKHNP//9z18lt3T+q3/85yvkQSv02bfx+NTP0GN8CqcUx7d/0sGq3uMKWPwb2j+2"
    "iVfTZydB2bzJZ6bEhzwaHIdmB4uZbKcLbV6kMTyfUOUjepOv8dLKU8i8aT0IiH8aIlY8S13oV7If8HlSfBfmKgD0vOe+Z4Jx"
    "+lO8ZDhJm9PDreYMyh762la72oSLZVB0utjfyu0noFLpGu/K3akJ90vxddzkT2ELqV8vRcmHIyXTG+ZkJjtleCA45j9PGr//"
    "kfa6IkLVwdP+D/6CvyN+UiGD191bTeK6fY9B0Vj2N/4ypiKPCbgH0W6Lk/oVWHC6XDUK3+VYgUkJYe2stGLwZ043JiH913/7"
    "62qvT6u5R41bIfARUn3/7+E2+QrnsSs7TtbuhJ+EWM0t/8uQTh1WhWonb0Zchoh7KitV7B8HwJ1JXBpY3cnk24HRPad/bVhn"
    "109iCd/9LIB9lpDg8OVZkLt1YxoMi3W2bnknXKpx0C7K8V7Tk7C4Lqnc68CPq8A87Eb11ZPUX9wUuRMKTwJCqfknpTu/z3En"
    "0Pwq8r1AU7dQY5hhYl6ZjS5OBboquJqHxJBO41JSilCu+vOV+0dB8jsFPA85vIPyJFgLH91oOrcCve57X3blVYjoBALvEMcb"
    "SZNV4TR1PI/8q7cOx5sfTLf6xbiuV9X379++1bPRIhgr+0GRlUGxNx1Y2kEx9VE0DCqzLuLBG5fDiiFe/IkPAOe29W/MAx3R"
    "QRLTQZDAnYvgvpzshthid7gEN5m4d5fAFlnrDY7oyVTJYTKDFViXf/karRN8gRZ6z2P2nar1R1X+YvQBauNPOvYKPkMj/E1b"
    "mXBus91vg53+Fs+Co7MF7FyO8zk0THLfQ8f56WCi0/s7qAfT6OeKcf70LGxYmXicqHPYD9CDQ4Xri927Y6eb4MzhmSbF40Ms"
    "6NW/YOLwEVoyGKkwpV59g1NHT4VMAG/D/Os1hA4XpP2v4eT10+A/tyVUgYc5Evu8c/+Uj5uRv//vT/8H5qzDGg=="
)
STAGED_COUNT_BEFORE_SHA256 = "50fb679becd85980354858e38a4231488839bedfbf013b203505b7a5912c66bc"
STAGED_COUNT_BEFORE_ZLIB_BASE64 = (
    "eNrtffuT27iV7u/+K3i1VbekSbea74cTV8Vr90xc49iutmeyKZdLBeLRzWu1pJCU7U7W//v9AJAU+NLLnuzm3nXN2BIJggcH"
    "5/EdnANoMpm8yfmG5NwiFuMloXecWSL7gr/Xn1f4u1hvc8qtTb7+P5yW2Xr1e2u1tj7nWckLa51bK1Jmn/D0trxb4+LDfDKZ"
    "PHok8vW9xQj6W5KiQMvsfrPOy92lR9WFO1LcLbO0/qr/wYX5tsyW9dV1oTvckFI2rjt7g691k6IkZfP5oem+zO75o0f/Zr27"
    "4xjViiytYkspLwpQLnLO/w7SyHJprYVV3vGCW3S9ojkvuZXzTxn/DAYwvuErxlc048UcXT1dWdmKru83S9lso7hHJGOs+21R"
    "4jmxLfjvray0VvwTz63lmrAC90qSLms+WSwnokR3z6/fXL96fv3q2Yvrt9YTa/rIwh/9t/wzKdfrZXGVbrMlu8r5Pdks8u1K"
    "DmohO5rfbTaTi11rEaaJ67CY8shPvNgPvTRkbsxoYKeM+EEUBQEjTmi7InRpwgOXx2lKotAObZ9EQdXX7OI0Mhab9TKjD11q"
    "CHf9hLsxd8LYDiiJA9tlvnAcTinemiaR6yX4TqIoTB3X9n1XuLYdJF6YxEKE51JT5mRVyNmfbx5MepwEL+BcOH7i0tTlSQD6"
    "Qp+Hjh+ETpDYNPUdwXwahr4QLo18wbjrBa4Xcx6K9Ax6MshNKZWiwxq8wWaew8GQ2PaTiIjQY8Jx4yi1PeE5vhOIIKKxQ0QU"
    "Jy7h1KHMxQSGEUj1+DmkrD6BlnXeoyUgtudR4tuQkjANAx+yIZjHHWKnCec8IpHvJSGNBQtj4XpOQlLixU7k8cQNnHOERtqb"
    "VdklxPZTiC61A0FszlMHIukHhHI7AQEs9kREMG1CzlccEM8JAseJI5aI2OU+C52zCRmR39jxiOM4aegSJ01CBsKoHfsiSaKI"
    "cOgLt1nguQGmjrqUCjtBa8kskfiU+clZ9JT0riO21E0ox/t55IUB1IhxqTAeVCpN/DCmnhv5vpxCVzhRlIKyBPygPBHcd2yb"
    "nENGvmZbyvMOJXHqeFBR7oYeWG/71Euo64dO6gRhGDlMBJQRaFESkjQmJHJtzw2jMCABSajveAcoYRm5Xa2LMqPF1V2BUV1+"
    "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"
)


def staged_source_count_controls(before=False):
    """Build a separately discovered cohort; preserve all eight historical methods."""
    import json
    import os

    def decoded(encoded, wanted, limit):
        decoder = zlib.decompressobj()
        data = decoder.decompress(base64.b64decode(encoded, validate=True), limit + 1)
        if (
            not decoder.eof
            or decoder.unused_data
            or decoder.unconsumed_tail
            or len(data) > limit
            or digest(data) != wanted
        ):
            raise RuntimeError("Frozen staged-source control input refused")
        return data

    resource = json.loads(decoded(STAGED_PATHS_ZLIB_BASE64, STAGED_PATHS_SHA256, 1000000))
    rows = tuple(tuple(row) for row in resource["rows"])
    products = tuple(resource["products"])
    path_modes = {row[0]: row[1] for row in rows}
    header_path = "src/share/remap_runtime_vhd.hpp"
    vendor_queue_path = "vendor/vendor/include/pqrs/osx/iokit_hid_device_events_monitor.hpp"
    source_path = ROOT / "tools/build/remap_runtime_source.py"
    if before:
        data = decoded(STAGED_COUNT_BEFORE_ZLIB_BASE64, STAGED_COUNT_BEFORE_SHA256, 100000)
    else:
        data = source_path.read_bytes()
        if digest(data) != FIXED_FACTORY:
            raise RuntimeError("Current staged-source control factory refused")
    factory = load("staged_count_actual_factory_" + str(id(resource)), source_path, data)

    class PhysicalStagedSourceCountControls(unittest.TestCase):
        def setUp(self):
            temporary = tempfile.TemporaryDirectory(prefix="staged-count-physical-")
            self.addCleanup(temporary.cleanup)
            self.root = Path(temporary.name).resolve()
            self.root.chmod(0o700)
            self.assertEqual(len(rows), 4532)
            self.assertEqual(len(path_modes), 4532)
            self.assertEqual(sum(mode != "120000" for _, mode, _ in rows), 4528)
            self.assertEqual(sum(mode == "120000" for _, mode, _ in rows), 4)
            self.assertEqual(len(products), 64)
            self.assertEqual(factory.VHD_NATIVE_HEADER, header_path)
            self.assertIn(vendor_queue_path, path_modes)
            bodies = {}
            for relative, mode, target in rows:
                path = self.root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                if mode == "120000":
                    os.symlink(target, path)
                    bodies[relative] = os.fsencode(target)
                else:
                    if relative.endswith("/project.yml"):
                        body = b"name: OwnedFixture\n"
                    elif relative == "version":
                        body = b"1.0.0\n"
                    elif "vendor" not in Path(relative).parts and relative.endswith(
                        (".hpp.in", ".h.in", ".plist.in", ".xml.in")
                    ):
                        body = b"Owned fixture @VERSION@\n"
                    else:
                        body = b"Modeled content for fixed path: " + relative.encode() + b"\n"
                    path.write_bytes(body)
                    path.chmod(0o755 if mode == "100755" else 0o644)
                    bodies[relative] = body
            self.deadline = time.monotonic() + 25
            files = tuple(
                factory.read_input(self.root, relative, 8192, self.deadline)
                for relative, mode, _ in rows
                if mode != "120000"
            )
            links = tuple(
                factory._staged_link(self.root, relative, self.deadline)
                for relative, mode, _ in rows
                if mode == "120000"
            )
            inventory = tuple(
                (relative, mode, "modeled-provenance", digest(bodies[relative]))
                for relative, mode, _ in rows
                if relative != header_path
            )
            dependency = factory.SealedInput(
                "tools/build/remap_runtime_vhd.hpp", (), bodies[header_path]
            )
            projection = factory.PreparedSource(
                self.root.parent,
                (),
                self.root.parent / "unmaterialized-pristine",
                (),
                (),
                inventory,
                (),
                (dependency,),
                tuple((path, bodies[path]) for path in products),
            )
            self.image = factory.StagedSource(
                projection,
                self.root,
                factory.root_identity(self.root),
                files,
                links,
            )
            # Only admission provenance is modeled. The count, exact pathsets,
            # contents, modes, named physical FDs and actual scan remain genuine.
            admission = patch.object(factory, "revalidate_owned_source", return_value=None)
            self.admission = admission.start()
            self.addCleanup(admission.stop)

        def test_complete_4528_regular_four_link_image_runs_every_actual_guard(self):
            with (
                patch.object(factory, "read_input", wraps=factory.read_input) as reads,
                patch.object(factory, "_staged_link", wraps=factory._staged_link) as links,
                patch.object(
                    factory, "_staged_expectations", wraps=factory._staged_expectations
                ) as expected,
                patch.object(
                    factory, "_staged_inventory", wraps=factory._staged_inventory
                ) as scans,
                patch.object(
                    factory, "_staged_generator_outputs", wraps=factory._staged_generator_outputs
                ) as generated,
            ):
                failure = None
                try:
                    factory.current_staged_source(self.image, self.deadline)
                except factory.SourceRefusal as error:
                    failure = error
                self.assertIsNone(
                    failure, "Complete independently fixed stage refused: " + repr(failure)
                )
                self.assertEqual(reads.call_count, 4528)
                self.assertEqual(links.call_count, 4)
                self.assertEqual(expected.call_count, 1)
                self.assertEqual(scans.call_count, 1)
                self.assertEqual(generated.call_count, 1)
            self.assertEqual(self.admission.call_count, 1)

        def test_missing_genuine_vendor_leaf_refuses_its_physical_read(self):
            (self.root / vendor_queue_path).unlink()
            with self.assertRaises(factory.SourceRefusal) as caught:
                factory.current_staged_source(self.image, self.deadline)
            self.assertEqual(caught.exception.code, "unsafe_path")
            self.assertEqual(caught.exception.args, ("Actual source input is unavailable",))

        def test_extra_foreign_leaf_refuses_unchanged_exact_inventory(self):
            (self.root / "vendor/unowned-foreign-leaf").write_bytes(b"foreign\n")
            with self.assertRaises(factory.SourceRefusal) as caught:
                factory.current_staged_source(self.image, self.deadline)
            self.assertEqual(caught.exception.code, "inventory")
            self.assertEqual(
                caught.exception.args, ("Actual staged tree gained an unowned source leaf",)
            )

        def test_original_link_replaced_by_same_target_bytes_refuses_type(self):
            relative, _, target = next(row for row in rows if row[1] == "120000")
            path = self.root / relative
            path.unlink()
            path.write_bytes(os.fsencode(target))
            with self.assertRaises(factory.SourceRefusal) as caught:
                factory.current_staged_source(self.image, self.deadline)
            self.assertEqual(caught.exception.code, "unsafe_path")
            self.assertEqual(
                caught.exception.args, ("Actual source link is not singly linked and owned",)
            )

    return unittest.defaultTestLoader.loadTestsFromTestCase(PhysicalStagedSourceCountControls)


if __name__ == "__main__":
    staged_only = "--staged-count-only" in sys.argv
    staged_before = "--staged-count-predecessor" in sys.argv
    for option in ("--staged-count-only", "--staged-count-predecessor"):
        if option in sys.argv:
            sys.argv.remove(option)
    staged_suite = staged_source_count_controls(before=staged_before)
    if staged_suite.countTestCases() != 4:
        raise SystemExit("Incomplete independent staged-source cohort")
    staged_result = unittest.TextTestRunner(verbosity=2).run(staged_suite)
    if staged_result.testsRun != 4 or staged_result.skipped or not staged_result.wasSuccessful():
        raise SystemExit(1)
    if staged_only or staged_before:
        raise SystemExit(0)


if __name__ == "__main__":
    unittest.main()
