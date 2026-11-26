# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Find files that hold the home folder of the Mac building the app (ROUND7 R7-19).

A path under the builder's home folder in a file handed to other people tells them the builder's
login name and folder names. `prepare_testflight.py` refuses a prepared app with any such file, and
`build_testflight.sh` reuses NumPy's and OpenImageDenoise's replacements only when none of their
files holds it. The same finder as `harvest_library_set.py` on the 5.3 line (U2b).
"""

import os
from pathlib import Path


def files_holding_home(folder, home=None):
    """Every regular file under `folder` whose bytes hold the home folder (as given and resolved),
    as paths relative to `folder`, sorted."""
    home = home or str(Path.home())
    needles = {form.encode() for form in (home.rstrip('/') + '/', os.path.realpath(home).rstrip('/') + '/')}
    found = []
    for path in sorted(Path(folder).rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        if any(needle in data for needle in needles):
            found.append(str(path.relative_to(folder)))
    return found
