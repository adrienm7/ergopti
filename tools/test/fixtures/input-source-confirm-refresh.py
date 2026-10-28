"""Execute the actual confirmation worker with a bounded Carbon interface model."""

import builtins
import ctypes
import json
import pathlib
import sys
import time

worker = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
duration = sys.argv[2:]
events = []
printed = []
real_print = builtins.print


class Pointer:
    """Represent an opaque Carbon property identifier without a native library."""

    def __init__(self, value):
        self.value = value

    @classmethod
    def in_dll(cls, library, name):
        if library.framework != "Carbon" or name not in sources[0]:
            raise ValueError("Unknown Carbon property identifier")
        return cls(name)


class Function:
    """Accept the ctypes signature metadata used by the actual worker."""

    def __init__(self, callback):
        self.callback = callback

    def __call__(self, *args):
        return self.callback(*args)


class Reference:
    """Keep native property references truthy even for CFBoolean false."""

    def __init__(self, value):
        self.value = value


def source(name, selected):
    """Supply only the six TIS properties read by the production worker."""
    return {
        key: Reference(value)
        for key, value in {
            "kTISPropertyInputSourceID": "org.example." + name,
            "kTISPropertyLocalizedName": name,
            "kTISPropertyInputSourceType": "TISTypeKeyboardLayout",
            "kTISPropertyInputSourceIsEnabled": True,
            "kTISPropertyInputSourceIsSelectCapable": True,
            "kTISPropertyInputSourceIsSelected": selected,
        }.items()
    }


sources = [source("Other", False), source("Target", True)]


def copy_string(value, buffer, _size, _encoding):
    """Fill the real ctypes string buffer through the CF conversion boundary."""
    buffer.value = value.value.encode("utf-8")
    return True


def select(value):
    """Record the exact source selected by each call, returning OSStatus zero."""
    events.append(["select", value["kTISPropertyLocalizedName"].value])
    return 0


class Library:
    """Expose only the functions owned by the requested native framework."""

    def __init__(self, framework, functions):
        self.framework = framework
        for name, callback in functions.items():
            setattr(self, name, Function(callback))


def load_library(name):
    """Record framework admission so invalid durations precede native I/O."""
    events.append(["load", name])
    if name == "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation":
        return Library(
            "CoreFoundation",
            {
                "CFArrayGetCount": len,
                "CFArrayGetValueAtIndex": lambda values, index: values[index],
                "CFStringGetCString": copy_string,
                "CFBooleanGetValue": lambda value: value.value,
                "CFRelease": lambda _value: events.append(["release"]),
                "CFURLCreateFromFileSystemRepresentation": lambda *_args: object(),
            },
        )
    if name == "/System/Library/Frameworks/Carbon.framework/Carbon":
        return Library(
            "Carbon",
            {
                "TISCreateInputSourceList": lambda *_args: sources,
                "TISGetInputSourceProperty": lambda value, key: value[key],
                "TISSelectInputSource": select,
                "TISRegisterInputSource": lambda _value: 0,
                "TISEnableInputSource": lambda _value: 0,
            },
        )
    raise ValueError("Unknown native framework")


ctypes.CDLL = load_library
ctypes.c_void_p = Pointer
time.sleep = lambda seconds: events.append(["sleep", seconds])
builtins.print = lambda *args, **_kwargs: printed.append(" ".join(map(str, args)))
sys.argv = ["confirm-source", "Target", "", "refresh", *duration]
error = None
try:
    exec(compile(worker, "confirm-source", "exec"), {})
except BaseException as exception:
    error = type(exception).__name__
real_print(json.dumps({"error": error, "events": events, "printed": printed}))
