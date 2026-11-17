# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""
What the iPad's sandbox rules out, said in one place (ROUND5 8E): another program cannot be run
(``subprocess``, ``os.system``), and the app does not go online (Blender starts there as with
``--offline-mode``). Operators that need either fail their poll with the message below, so the
interface shows why instead of failing in silence.
"""

__all__ = (
    "IPAD",
    "NO_PROGRAMS",
    "NO_ONLINE",
    "poll_programs",
    "offline_hint",
)

import os
import sys


def _on_ipad():
    # Python built for iOS says "ios" from 3.13; builds patched before that say "darwin", with the
    # device's model as the machine and "iphoneos" in the multiarch.
    if sys.platform == "ios" or "iphoneos" in getattr(sys.implementation, "_multiarch", ""):
        return True
    return os.uname().machine.startswith(("iPad", "iPhone"))


#: Running on iPadOS (or iOS), in its sandbox.
IPAD = _on_ipad()

NO_PROGRAMS = "Not available on iPad: it needs another program"
NO_ONLINE = "Not available on iPad: the app does not go online"


def poll_programs(cls):
    """
    For the ``poll`` of an operator that runs another program: false on iPad, saying why.
    """
    if IPAD:
        cls.poll_message_set(NO_PROGRAMS)
        return False
    return True


def offline_hint(text):
    """
    What to say where Blender would suggest launching without ``--offline-mode``.
    """
    return NO_ONLINE if IPAD else text
