# tools/diagnostics/probe_tsm_port.py
"""Temporary probe: report whether com.apple.tsm.uiserver is registered."""

import ctypes
import ctypes.util

cf = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFMessagePortCreateRemote.restype = ctypes.c_void_p
cf.CFMessagePortCreateRemote.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
cf.CFMessagePortIsValid.restype = ctypes.c_bool
cf.CFMessagePortIsValid.argtypes = [ctypes.c_void_p]
name = cf.CFStringCreateWithCString(None, b"com.apple.tsm.uiserver", 0x08000100)
port = cf.CFMessagePortCreateRemote(None, name)
print(
    "tsm_uiserver_port=" + ("registered" if port else "absent"),
    "valid=" + str(bool(port) and cf.CFMessagePortIsValid(port)),
)
