"""Señuelo propio no volcable; publica su disponibilidad después de prctl."""
import ctypes
from pathlib import Path
import sys
import time

libc = ctypes.CDLL(None, use_errno=True)
name = sys.argv[1].encode()
assert 0 < len(name) <= 15, "comm debe caber sin truncamiento"
assert libc.prctl(15, ctypes.c_char_p(name), 0, 0, 0) == 0, "PR_SET_NAME falló"
assert libc.prctl(4, 0, 0, 0, 0) == 0, "PR_SET_DUMPABLE falló"
Path(sys.argv[2]).write_text("listo\n")
time.sleep(120)
