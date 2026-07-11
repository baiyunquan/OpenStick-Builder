"""Compatibility shim for mkbootimg packages with missing GKI helpers.

The Ubuntu Noble mkbootimg script imports this module unconditionally even
when no GKI signing arguments are used. This project builds a legacy boot.img
without GKI signing, so the function should never be called.
"""


def generate_gki_certificate(*_args, **_kwargs):
    raise RuntimeError("GKI signing is not supported by the mkbootimg compatibility shim")
