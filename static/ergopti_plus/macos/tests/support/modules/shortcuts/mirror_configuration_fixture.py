"""Exercise the dispatched CoreGraphics program against a controllable native API."""

import contextlib
import ctypes
import io
import sys
import types


class Function:
    def __init__(self, implementation):
        self.implementation = implementation

    def __call__(self, *args):
        return self.implementation(*args)


def exercise(source, failure=None, mirrored=False, count=2):
    calls = []

    def invoke(name, result=0):
        def call(*args):
            calls.append((name, args))
            if name == "CGGetOnlineDisplayList":
                args[1][0] = 11
                if count > 1:
                    args[1][1] = 22
                ctypes.cast(args[2], ctypes.POINTER(ctypes.c_uint32))[0] = count
            return 1001 if name == failure else result

        return Function(call)

    library = types.SimpleNamespace(
        CGGetOnlineDisplayList=invoke("CGGetOnlineDisplayList"),
        CGMainDisplayID=invoke("CGMainDisplayID", 11),
        CGDisplayIsInMirrorSet=invoke("CGDisplayIsInMirrorSet", mirrored),
        CGBeginDisplayConfiguration=invoke("CGBeginDisplayConfiguration"),
        CGConfigureDisplayMirrorOfDisplay=invoke("CGConfigureDisplayMirrorOfDisplay"),
        CGCompleteDisplayConfiguration=invoke("CGCompleteDisplayConfiguration"),
        CGCancelDisplayConfiguration=invoke("CGCancelDisplayConfiguration"),
    )
    original = ctypes.cdll.LoadLibrary
    output = io.StringIO()
    try:
        ctypes.cdll.LoadLibrary = lambda _: library
        with contextlib.redirect_stdout(output):
            try:
                exec(source, {})
            except SystemExit as error:
                assert error.code == 0
            except RuntimeError as error:
                assert failure and failure in str(error)
            else:
                assert failure is None, "native failure was reported as success"
    finally:
        ctypes.cdll.LoadLibrary = original
    names = [name for name, _ in calls]
    if failure:
        assert output.getvalue() == "", "failure must not publish a success result"
        assert ("CGCancelDisplayConfiguration" in names) == (
            failure == "CGConfigureDisplayMirrorOfDisplay"
        )
    elif count == 1:
        assert output.getvalue() == "single_screen\n"
        assert "CGBeginDisplayConfiguration" not in names
    else:
        assert output.getvalue() == ("mirror_disabled\n" if mirrored else "mirror_enabled\n")
        configured = next(
            args for name, args in calls if name == "CGConfigureDisplayMirrorOfDisplay"
        )
        assert configured[1:] == (22, 0 if mirrored else 11)
        assert names.count("CGCompleteDisplayConfiguration") == 1


if __name__ == "__main__":
    source = sys.argv[1]
    for failure in (
        "CGGetOnlineDisplayList",
        "CGBeginDisplayConfiguration",
        "CGConfigureDisplayMirrorOfDisplay",
        "CGCompleteDisplayConfiguration",
    ):
        exercise(source, failure)
    exercise(source)
    exercise(source, mirrored=True)
    exercise(source, count=1)
    print("mirror configuration scenarios passed")
