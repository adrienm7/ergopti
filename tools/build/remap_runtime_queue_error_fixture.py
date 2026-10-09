# tools/build/remap_runtime_queue_error_fixture.py
"""Run independent active queue-error controls through the genuine vendor callback.

The native IOKit, ownership and scheduling ports are modeled. This qualifies
bounded software error propagation only, never Darwin delivery or retirement.
"""

import argparse
import base64
import hashlib
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import zlib

import remap_runtime_inventory_fixture as inventory

QUEUE_SOURCE_SHA256 = "ca54e61d19dd071fc23ce991efc1a9a2798304a6486872261a092019ad97ec58"
BEFORE_VENDOR_SHA256 = "34271d6a5e65f490e0887a3480016a454b41c46b4f10365679b05ced51cf57c1"
REPORT = "PASS owned runtime queue errors=6 unknown=1; modeled platform ports only\n"
ERROR_SCENARIOS = (
    "error-healthy-values",
    "error-active",
    "error-unopened",
    "error-stopped",
    "error-restart",
    "error-pending-values",
)
# Immutable source input from published 7c, including its null-create guard.
# This is neither a behavioral oracle nor a generated successor expectation.
BEFORE_VENDOR_ZLIB_BASE64 = (
    "eNrtHG1z27b5u34F0t5llOvQTl92PcnRLnWS1re22eK0+9DLaIqEJM4UwRKgbC31fvueBy8kSIKi5Lhdb5vuEtsk8AB43t+g"
    "j/MiXK5DwrKIjkYnJyT/ueCTCeO3k0nCrhMRrJI4iOkmiWhANzQTPFizLBGsIJsv/FP/VM7yzsfknOXbIlmuBHkbXofbEKC+"
    "KtfJKrlm5NPTp1/6OPBFwkWRzEtBY1JmMS2IWFHyFWNckEu2EDdhQcm3sFjG6TH5kRY8YRl5CgvJZS4pJSshcj45Obm5ufHn"
    "ONFnxfLk24vzl99fvgyeBqe+uBXj0ejjJIvSMqbk7OL1nxNxAgc5uXj9zcWLF/I0/mrWP+SvJS1bI6JVwTLWeMJFnGTCfrQo"
    "s0jAjsPUfrqma1ZsG08AAbf2g4zFJ/DPX+W5/ZjlXWhIoZNocVKUWZAylgdiVdCwM1UOixOehyJa0cL5eslT53Mg/4k6b+/r"
    "NnMMDCyoKItsYJDY5pS3x8ABssbfwD/Z0n5SiiRNRAO/GxoBh85GoyxcU4AQ0ZqxyftRlIackyH+XiSAeTIheTlPk4jUuJxM"
    "6K0owsmkfhREaQKTAbYaPRkRcnIi/yOXyRIAceIl2YZdA+MvCraWfF/PJ4qIYzUN/gdmmEy4nHm2YUnsjWeEi7AAwZn2vmZ5"
    "3vM6YyLIyjQN+AokLA5yUQQCcAnDFK7OosVkEi3wxZkUgR/DtKRv6GI2mwHsJMtLEWzwGQ/Cokg2aiE43ls4SEFzVgiCtCIJ"
    "JzAuiUGnpFuyYErE47IIkZcJW8i/1eYIoiSSL3zXtkuQr88+DYReIEjiYxjW+chz4OJnEctAk+C0LwMx09OccxR/TybhnLMU"
    "xDEQyZoGOYOpRP4K2F7n45meqxCgt2EhoLNltQO1I8mqj4+JLQOATFoUrAhYFJVFgVAsXvmOihWLecUGAzyqVxsY9XhMnpGY"
    "plRQuRjsq4wEycMCpEOAjtWs/l6eFXRqStic02JDA5vuAAQm0mnfKIUcHLYAdldLyUNdaL7n20xhveTAGWEGT2iRhCn8kWSK"
    "K8o8B0GKSVu5GVDIbBx2TYyQJnD+EIwXyeDMBVEixgFYgqdK4XQEcCQxnYl02wCk369LQCEICKAIMMO2arJZoLFpNV0S16j6"
    "M8TEvoy6B7NWHNfiObXZIaQO4JGECzwxDaOVgcPLKKKcL8qUKOYhLKeZpM6cgvRSCXCRFMhnuCEj7IAj4CmQA+DhCq0/cKrQ"
    "FwFZ52F0TQSDCZyiSIQCNYUIkwx2Nt+6zlcBupAL2ESNG4QkN4lYuSBUGgfZxEDrcAse7wPpbtSuYw+BpanvtHyT81dvyuxb"
    "oAX8IOtwS5YSKSXgCKhWoOMThRx4N1kQVMZt0i1pRrUOhW3CejQU0pjQn0uFkgThRq8vydPPfLXmxQLpuyIh4i5OlAJGvcOP"
    "nWvEoA4iEOFESAwhETkJ50huoGOIR4Z3Gvg37AbJc1y/QrTnBZundA3DOE0X7mX4ipUp8heO3iQxHAMsKi0yrQu4wFFgKVbh"
    "BjQobgeERL/391CLklI3NLyW9sy23PXvMyIH1A96Jdb6uO2o44yztujtA91yT8Hyankc64mTwVPf4zzqc4+tqo/ax/7ja5Pz"
    "/m4s7c3d6H+MnPtMVIahRtZj6/eaHTreZ5sBxvVard0HXuuBNdQig6c5sH6JtkF6SkXgHaG+tN6BUy0COUA5ON71xes30ue5"
    "VDbGhuPwLwKvPqXvGmDNdylde7rj/cBsrbKHoJhxY+0tgbLu37b2iMxYTVh6m4N5Sf4JLidZJ1myLteN8cG8XCxwJRgCztTT"
    "008/12afkLAEZatfDM2dGtcVtijnrcPb5mANyKK4D55gHDgHeuP6HArokRugDFREEgVgzsQZKO4/fg7ujYfvGiCIOYg9XOFl"
    "1gN7PK1m342aP11Y8MHzwJ1bU+8qB+oSRCQuU6rlclSRszLUX1NxrvwNDzzoZx0hejIDEx6YpzZ+uIat0eqZxQkFx7gaJYly"
    "E4J1A2KG19TAxUc4ZeSW3Sczmv2MCQrv7zUye1bED4J7MgNVlyy29fO7egE1AP8PcJS1X6Og/zWkoceEgStQgCnXp5MBjcRz"
    "R02Z9yNlQQQ4owGGxJbmqk5fg2lhoQHkgagWpTTMyvy3I5p7wQeimfTIQnRjlc7yLl6/lumkr8A1U4pcpZd4f0xtguR1kqYJ"
    "p+hEctsGSK8MlLPBYcX/ODll0XWwLMMiVokGlfQi+Nizlw/ki8DCHXq0HJVxYxgg3P7bIOWTT3rG1w5z0JD9PUhjHdFXyLNQ"
    "9BPavXcNRbYnvQ1yEKBFbENa6y+bJC586wPJn11qI1vr/ZVa/5JBJAF6TzUJHoaMKJWPepa17YDKi1Q8PswFchvotsGz6e7R"
    "jeP9Gpwikf0eDE3I5Rr4d6D+mkxqejRFzN9nt4Nj7rpc8NNPGQMtGgGx3r1TORpOwfhBoKqdyvejDyWsIhfRkXiLOI+a1Gkr"
    "lj+B0+Ce+JhcS3dZqSj+dpvTS9z5i0YMVH0mJsckD54XyQaC4YmRg44xtJw1qb/jlteDFsGMrVlTMrDTr6DrXGybDlHD2V8m"
    "QLjiAqe+kTPPdTrEOzoguiI7PJs4FKE3PhiW7Wqdv7rIYqC451xAu3z3XaEB0ySDDgYmI4yOZnCg+g1dM9CL90Oz3rJmhkKB"
    "us+m9Xa72zS+5t8SsdJuyv5bHHJg9gRzXXlI52wNftt3LKbc6TS03ZJKaexQdXpO5aH8X9R+fVFDJZuL4r7zdgrWD5lRoq/A"
    "NT+YZx+Maw/hW+1Y2XWMjNKYSwtclyXUSXt8YRjWMUTfs8xUMxRLqzx5P19PKxF4pDMoFfcuGQCAIDvhq1ZAagKd8xWNrvus"
    "fyPseTg3rdfXappz8ssvFtV2THLaeFuEO2iwuBA3NAigQdi6LGWBaVH1qGe7DSrg0jVkK57fpfoKigDvxj30fI3lFFkCVXkG"
    "m4KYhkCmJdKrNAWXK0sOcfYVZvZZIbslTKpdxd8kLljuV1t3ZtXI48fkkRSN5nPlyFqKVfu2gWB2JN6JdmDPz6UKIVGBJQiy"
    "CjnJGMlA3W0oMTm/qakTyTIwnl/vLgY5TNKyoH4FslkQ9T6qezDO1RLK54SpuK7/0TGpUosvcWojQK52+ResO8GCcnF6C3YC"
    "awmyuiWjqT9gFUUUqhJZcccTwzLsBhxtvkpyf9SNU+6aEmgXeEkBDNKiICjOwzLlNouOp42Aqp2Fa6dd0Qcvmnm2zhAYYYeb"
    "Oyh/TIp2qOukVn1WrE4hhWmMhCqacW0jgWez1BukRG9IaI13nKWdZ37QKNYdrrhSEZYO2enKgEDulYmuaYhM+n6/7HUtCiRC"
    "OhLP9/1xU3wvlhmqGXobUc3rVUdKmixotAVnrirg+i4i7KUq9J48K0yFX5TSn4y6aRb0CqpIlmblmqg+HUvZatjtuFpp4ONR"
    "XZIyXrx6pp3T46ocqzsgJOSwWJZrqUztLgh7UfVjWkfOpi3rzGRXZsPRel0L1r4KHLe1PvxW1Qpk3xBWqq8UYq6AIBlWTJEu"
    "pocIa+BgGq6043N1bKbe0Lq6LW3klYVqaU4qsLZpyW2NqXTjzQokumuQpOz5IwdKbM9q5pASlZSQBeCArkFr6ralVtvIwwgv"
    "BwyhDCBmtfW2ZQHr7X0Zm4mltmqZkS0CodUboNALMp8IaQjnFPDFyxxMB41Vm0MIzsoNIFhSiWBrAU7RDONby+zyxBqel5QB"
    "daShPNKjPRJJwbidzGyoX7vKIpHqJJ7tg0k6A0qvp6MduFZSOxmE7NTAPiBbeTLNTOrwsk0FMbx8D/rsDXSp46jpDp1iHyBd"
    "By6Y7uORO1OmhyXP90Wv1rWT/8S2dkcATgr0OO2yz8wS07qrMRRKCchOwWPCsb0JjsyN0uSsLMAJUf0zKdPPdZNs1/mHJSQ5"
    "TS/V1gQBOBf91Xq21tDo+FfWmWNjJQ6zNPQ5rurXVszl9d8znNVDIaJoOKiV+mjvYtDvPXI4une/hfvW5TzLfXMogoPDJD3P"
    "68QmVc5CWcLewMzKWT9yyH2rqYDoFBNQMxerqm2gV220yC0rmWphCaCZHti5PJEdd7oTFRnqMaFk0oUOUiLdHK/VBFAHe8/j"
    "+KUa5B05ljwmR9QdP9QgTD5Qdi8/30AYEs5TWqcEXWAPTZ+1ctymKdosdv9sdzuBbB/MmUH+gNM8VHquLzvnOoL0Ul2bHrcj"
    "PavOZKdRUWJmXh+Au4ZzPSRTO3na3nQPouszondYjXfmTcla3ouJwhLMweXF15cvv/5R+4zY5MqE8eqxEbRFGH/U2VNPbvb3"
    "zw1uPaTT0S3tqOheJXZ3FGg8HHOEahBUvzhQ6kzqAC13mR46W63MKd5ksplLAUPnu9MDV/GYI52kurtoumg1RQ103xzNPH14"
    "O/OMcHauhgOezPqQ2hKp3mH7FIeak616tYPIA0r1g4j9MET/LyL+ELJbTDA4fF/9+kHXkUh1HUW5guhcKDj7QrD6tG5WSUp1"
    "qXKDQQLMCmNwCgM117Ny0Szffg94loDQDr9N1pSVfc7KqX86brg66v2TGV3naQh0lChTR2Ab6m3G3YIcXl2QHf3noYDoIwuJ"
    "9/TUf/rFWBoMGRtcuV2dqxoC8guSxFFWqDK1xHtO5uUSe+7lguN6+ttVyY8xo6S79hOTCaGmCNGTI6qh18C8Z83MaafENDZH"
    "tz3pDwkAtEAMFpS6WY+7NjV2pskVdd918rTNO3Oe7mTuDQp6NWKrleID9OCHaD9b5x24KHCHKtBjSZXgXc+DABxww6pv+peB"
    "ONp1JbDvY0IrvXJKsyVESCYX/Zuq7X3ti63e9bZVuaTiHwVlPN29FpJJr9Sgn+y3sDNWutj3rHLnui814sgZOd3bNLW5/gDi"
    "992z8+7BAf2dHaZfvckbY6fhdBOiJY5WAQCTUI0rd9WlOnkBTEW6tLqn167DqbLmOkwyXjVR15OU4bOyS3hpD3M2YAwUnVWS"
    "n1u3tTAhIqjpvVaVXRec+k4hDECN6z90W+mgOt9RQewUaxXip6NBHW+VQttFUDed5CirCnq3iy8qjjhY1Q1dKa1ZSnkTePtQ"
    "Xaq0EonGTWizkfEQnue5LuTbNyslBQnEtdaNzl4H8XfFBthqE+bwWnGvNNBhKlsDXHG4kTJVcMWUK8hX+44DPJYpYetiP1Bk"
    "SbmsxcSM6mh/FcLD2oWSi/q1Oanvn6NHanrw8Z6E47a6dVeC4NVSUd9sNqlkcFxNKnnOgCVvgFryGy+IKk1jUUozPo67YcW1"
    "gYi7aXxTgW9fnQZZT/ruIXcTGc3QoFnA7i12d6rp5rZXLRyGzfd05/oL42+x28SczSqPh6hu/wFhBd6oVne6/H1YTBLTSDcQ"
    "YShkMXJrzIk/B32d3aP3sJ3eUdDAa/PGhlt2K7o2buX2jy3GrDWh65sR9rTTvSb6yFp19+mtr2roqNj73+4Mpq5rqXZOGxdx"
    "fCOIrLDbfQ3T0e4C+Y6utP2vbgTvT++GFuqtfoFiRSVNavVLHIp3OmoZznYfDg5oh9w6Jb+Y9RUue79rosZbSzScLbrV4Ht+"
    "KcO+X8ng0kPdtff4YgCYBQS7Q53j+Iaa0b8BvyOviA=="
)


def previous_queue_source():
    """Decode only the exact published source for a private causal before replay."""
    decoder = zlib.decompressobj()
    source = decoder.decompress(base64.b64decode(BEFORE_VENDOR_ZLIB_BASE64, validate=True), 100001)
    if (
        not decoder.eof
        or decoder.unused_data
        or decoder.unconsumed_tail
        or len(source) > 100000
        or hashlib.sha256(source).hexdigest() != BEFORE_VENDOR_SHA256
    ):
        raise RuntimeError("Published queue prerequisite source refused")
    return source


def run_controls(directory, compiler, blocks_root=None, before_errors=False):
    fixture = inventory.bootstrap_fixture()
    directory = fixture.owner(directory)
    before = fixture.stamp(directory.lstat())[:4]
    entries = inventory.composed_entries(fixture)
    queue = inventory.fixed_test(
        fixture,
        "queue_fixed_active_error_controls",
        inventory.BUILD / "remap_runtime_queue_test.py",
        QUEUE_SOURCE_SHA256,
    )
    suite = unittest.TestLoader().loadTestsFromTestCase(queue.NativeQueueErrorBehavior)
    fixture.require(
        suite.countTestCases() == 2 and queue.ERROR_SCENARIOS == ERROR_SCENARIOS,
        "queue_error_control_count",
    )
    with tempfile.TemporaryDirectory(
        prefix="owned-queue-errors-offline-", dir=directory
    ) as temporary:
        work = fixture.owner(Path(temporary))
        source = work / "source"
        source.mkdir(mode=0o700)
        fixture.publish_sources(source, entries)
        queue.OPTIONS = SimpleNamespace(
            upstream=source,
            vendor=source / "vendor/vendor/include",
            compiler=compiler,
            blocks_root=blocks_root,
            original_monitor=False,
            before_queue_errors=previous_queue_source() if before_errors else None,
        )
        previous_temporary = tempfile.tempdir
        try:
            tempfile.tempdir = str(work)
            result = unittest.TextTestRunner(verbosity=2).run(suite)
        finally:
            tempfile.tempdir = previous_temporary
        fixture.require(
            result.testsRun == 2 and not result.skipped and result.wasSuccessful(),
            "queue_error_controls",
        )
        fixture.require(fixture.stamp(directory.lstat())[:4] == before, "queue_error_current_root")
    sys.stdout.write(REPORT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner", type=Path, required=True)
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument(
        "--blocks-root",
        type=Path,
        help="Linux signed BlocksRuntime usr; Darwin uses libSystem",
    )
    parser.add_argument(
        "--before-errors",
        action="store_true",
        help="Private causal replay of immutable published queue source, retaining the null-create guard",
    )
    options = parser.parse_args()
    try:
        run_controls(options.owner, options.compiler, options.blocks_root, options.before_errors)
    except (RuntimeError, OSError, ValueError, zlib.error) as error:
        print("Refused owned queue-error fixture: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
