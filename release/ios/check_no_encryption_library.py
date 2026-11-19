# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Say whether a built iPad app carries OpenSSL (ROUND5 8M, E1).

    python3 release/ios/check_no_encryption_library.py <Blender.app or its main program>

Reads the program with `nm` (every symbol, local ones included) and its bytes the way `strings`
does, and fails when it finds a symbol of OpenSSL's `libssl` or `libcrypto` (their public prefixes:
`SSL_`, `EVP_`, `OPENSSL_`, `X509_` and the rest of `OPENSSL_SYMBOL`) or an OpenSSL version string
(`OpenSSL 3.5.2 5 Aug 2025`). Given an app, it reads the main program and every library in
`Frameworks/` and loose `.dylib`/`.so` files: the claim is about everything the app carries.

The last line of its output is the verdict, one of:

    no encryption library: <program>
    encryption library present: <program>

Exit status 0 for the first, 1 for the second, 2 when the program cannot be read (that is never
a pass). `build_testflight.sh` writes `ITSAppUsesNonExemptEncryption` = false into the tester
build's `Info.plist` exactly when this passes (E4), and `upload_testflight.sh` refuses an archive
whose key and verdict disagree.

Why the app can be without it: OpenSSL reached the program only through two built-in modules of
Python's static library (`_ssl`, `_hashlib`); the iPad build links a copy of that library without
them (`derive_python_without_openssl.py`). `hashlib` then uses Python's own MD5, SHA-1, SHA-2,
SHA-3 and BLAKE2, `hmac` its pure Python code, and `import ssl` raises `ImportError`.
"""

import re
import subprocess
import sys
from pathlib import Path

# Prefixes of OpenSSL 3's own symbols in libssl and libcrypto (with Mach-O's leading underscore):
# the stock app has thousands of each (5339 in all, 2026-11-19). Short or common prefixes are left
# out because other libraries use them: zstd defines `ERR_getErrorString`, which the app without
# OpenSSL still has; `RAND_`, `BN_`, `OBJ_`, `DH_` and the like are as easily someone else's.
OPENSSL_SYMBOL = re.compile(
    r'^_(SSL|SSL_CTX|SSL_SESSION|TLS|DTLS|EVP|OPENSSL|OSSL|CRYPTO|X509|X509V3|PEM|BIO|HMAC|'
    r'RSA|EC_KEY|EC_GROUP|EC_POINT|ECDSA|AES|ASN1|PKCS5|PKCS7|PKCS8|PKCS12|i2d|d2i)_[A-Za-z0-9_]')
# `OpenSSL 3.5.2 5 Aug 2025`, `OpenSSL 3.0.0`: the version text OpenSSL compiles in.
OPENSSL_VERSION = re.compile(rb'OpenSSL [0-9]+\.[0-9]+\.[0-9]+[a-z]?(?: +[0-9]{1,2} [A-Z][a-z]{2} [0-9]{4})?')
# The two Python modules that brought it (their module initialisers).
PYTHON_MODULES = ('_PyInit__ssl', '_PyInit__hashlib')
MACHO_MAGIC = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def programs(path):
    """The Mach-O files to read: the program itself, or an app's main program and libraries."""
    path = Path(path)
    if path.is_file():
        return [path]
    if not path.is_dir():
        raise FileNotFoundError(f'no such program or app: {path}')
    info = path / 'Info.plist'
    if not info.is_file():
        raise FileNotFoundError(f'{path} is not an app (no Info.plist)')
    import plistlib
    main = path / plistlib.loads(info.read_bytes()).get('CFBundleExecutable', 'Blender')
    if not main.is_file():
        raise FileNotFoundError(f'the app has no main program at {main}')
    found = [main]
    for candidate in sorted((path / 'Frameworks').rglob('*')) + sorted(path.rglob('*.dylib')) + \
            sorted(path.rglob('*.so')):
        if candidate.is_file() and not candidate.is_symlink() and candidate not in found:
            with candidate.open('rb') as handle:
                if handle.read(4) in MACHO_MAGIC:
                    found.append(candidate)
    return found


def findings(program):
    """What in one program is OpenSSL's: (symbols, version strings). Raises when `nm` fails."""
    result = subprocess.run(['xcrun', 'nm', '-a', str(program)], capture_output=True, text=True)
    if result.returncode != 0 and 'no symbols' not in result.stderr:
        raise RuntimeError(f'nm could not read {program}: {result.stderr.strip()}')
    symbols = sorted({line.split()[-1] for line in result.stdout.splitlines()
                      if line.strip() and (OPENSSL_SYMBOL.match(line.split()[-1])
                                           or line.split()[-1] in PYTHON_MODULES)})
    versions = sorted({match.decode() for match in OPENSSL_VERSION.findall(program.read_bytes())})
    return symbols, versions


def check(path, out=print):
    """Read everything; return True when no OpenSSL is found. Raises when something is unreadable."""
    clean = True
    files = programs(path)
    for program in files:
        symbols, versions = findings(program)
        if symbols or versions:
            clean = False
            out(f'{program}: {len(symbols)} OpenSSL symbols'
                + (f' (e.g. {", ".join(symbols[:4])})' if symbols else '')
                + (f'; version strings {versions}' if versions else ''))
    out(f'read {len(files)} Mach-O file(s) with nm and for version strings')
    return clean


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2].strip())
        return 2
    try:
        clean = check(argv[1])
    except (OSError, RuntimeError) as error:
        print(f'cannot check: {error}')
        return 2
    print(f'{"no encryption library" if clean else "encryption library present"}: {argv[1]}')
    return 0 if clean else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
