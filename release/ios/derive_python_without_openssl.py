# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Derive Python's static library for the iPad without OpenSSL (ROUND5 8M, M1).

    derive_python_without_openssl.py <libpython3.13.a> <config.c> <python include dir> <output dir>
        --sysroot <iPhoneOS SDK> --minimum <iOS version>

The prebuilt `lib/ios_arm64/python/lib/libpython3.13.a` builds `_ssl` (TLS) and `_hashlib`
(OpenSSL's hashes) in as built-in modules. They are the only members that use OpenSSL, and through
them the whole of `libssl` and `libcrypto` is linked into the app. This writes a copy of the library
without those two members (`_ssl.o`, `_hashopenssl.o`) and with `config.o`, Python's table of
built-in modules, compiled again from `config.c` without their two entries, with the library's own
headers and the build's SDK and deployment target. Python then has no `_ssl` (`import ssl` raises
`ImportError`) and `hashlib` falls back to its own MD5, SHA-1, SHA-2, SHA-3 and BLAKE2, which are in
the library already.

It is a build product: CMake runs it at configure time and writes into the build directory
(`<build>/python_without_openssl/`); nothing is committed. It refuses, rather than guess, when the
library is not the one it knows: when either member or either entry is missing or doubled, when
anything but `config.o` refers to what the two members define, or when the result still refers to
OpenSSL. When its inputs have not changed since the last run (`derive.stamp`), it leaves the
library alone, so the app is not relinked for nothing.

`WITH_PLATYPUS_PYTHON_OPENSSL=ON` skips all of this and links the prebuilt library with OpenSSL,
as build 1 did.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REMOVED_MEMBERS = ('_ssl.o', '_hashopenssl.o')
REMOVED_MODULES = ('_ssl', '_hashlib')
# Python's own hashes, which `hashlib` uses without `_hashlib`.
BUILTIN_HASHES = ('_md5', '_sha1', '_sha2', '_sha3', '_blake2')
# Flags of `config-3.13-arm64-iphoneos/Makefile`'s `.c.o` rule (PY_CORE_CFLAGS), less its SDK and
# minimum, which are the build's.
CFLAGS = ('-fno-strict-overflow', '-DNDEBUG', '-O3', '-std=c11', '-fvisibility=hidden', '-DPy_BUILD_CORE')
# As `check_no_encryption_library.py`'s `OPENSSL_SYMBOL`.
OPENSSL_UNDEFINED = re.compile(r'^_(SSL|TLS|DTLS|EVP|OPENSSL|OSSL|CRYPTO|X509|PEM|BIO|HMAC|RSA|'
                               r'EC_KEY|AES|ASN1|PKCS[0-9]*|i2d|d2i)_[A-Za-z0-9_]')
VERSION = '1'  # Raise when the derivation changes, so existing outputs are made again.


class Refused(Exception):
    pass


def run(*command, cwd=None):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise Refused(f'{" ".join(map(str, command))} failed: {result.stderr.strip()}')
    return result.stdout


def members(library):
    return [line for line in run('xcrun', 'ar', 't', str(library)).splitlines()
            if line and not line.startswith('__.SYMDEF')]


def symbols(library):
    """{member: (defined, undefined)} from `nm -A -g` over the archive."""
    table = {}
    for line in run('xcrun', 'nm', '-A', '-g', str(library)).splitlines():
        # `<library>:<member>: <value> <type> <name>` or `<library>:<member>:  U <name>`.
        head, _, rest = line.partition(': ')
        member = head.rsplit(':', 1)[-1]
        fields = rest.split()
        if len(fields) < 2:
            continue
        defined, undefined = table.setdefault(member, (set(), set()))
        (undefined if fields[-2] == 'U' else defined).add(fields[-1])
    return table


def table_without(config_source):
    """`config.c` without the two modules' declarations and entries; refuses unless each is there once."""
    text = config_source
    for module in REMOVED_MODULES:
        declaration = f'extern PyObject* PyInit_{module}(void);\n'
        entry = re.compile(rf'^\s*\{{"{module}", PyInit_{module}\}},\n', re.MULTILINE)
        if text.count(declaration) != 1 or len(entry.findall(text)) != 1:
            raise Refused(f'config.c does not declare and list {module} exactly once')
        text = entry.sub('', text.replace(declaration, ''))
    for module in BUILTIN_HASHES:
        if f'{{"{module}", PyInit_{module}}}' not in text:
            raise Refused(f'config.c has no built-in {module}: hashlib would have no fallback')
    return text


def stamp_for(arguments):
    digest = hashlib.sha256(VERSION.encode())
    for path in (arguments.library, arguments.config, Path(__file__)):
        digest.update(Path(path).read_bytes())
    digest.update(f'{arguments.sysroot}\n{arguments.minimum}\n{arguments.include}'.encode())
    return digest.hexdigest()


def derive(arguments):
    library, output = Path(arguments.library), Path(arguments.output)
    target = output / library.name
    stamp_file = output / 'derive.stamp'
    stamp = stamp_for(arguments)
    if target.is_file() and stamp_file.is_file() and stamp_file.read_text().strip() == stamp:
        print(f'derive_python_without_openssl: up to date: {target}')
        return target

    # What the stock library must be for this to hold.
    stock = members(library)
    for member in REMOVED_MEMBERS + ('config.o',):
        if stock.count(member) != 1:
            raise Refused(f'{library.name} has {stock.count(member)} members named {member}, expected 1')
    table = symbols(library)
    removed_defines = set().union(*(table[member][0] for member in REMOVED_MEMBERS))
    users = sorted(member for member, (_, undefined) in table.items()
                   if member not in REMOVED_MEMBERS and undefined & removed_defines)
    if users != ['config.o']:
        raise Refused(f'members other than config.o use what {REMOVED_MEMBERS} define: {users}')
    config_source = table_without(Path(arguments.config).read_text())

    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        work = Path(temporary)
        copy = work / library.name
        shutil.copyfile(library, copy)
        os.chmod(copy, 0o644)
        run('xcrun', 'ar', 'd', str(copy), *REMOVED_MEMBERS)
        (work / 'config.c').write_text(config_source)
        run('xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-isysroot', arguments.sysroot,
            f'-miphoneos-version-min={arguments.minimum}', *CFLAGS, '-I', arguments.include,
            '-c', 'config.c', '-o', 'config.o', cwd=work)
        run('xcrun', 'ar', 'r', str(copy), 'config.o', cwd=work)
        run('xcrun', 'ranlib', str(copy))

        # The result: the same members less two (duplicate names kept), no OpenSSL anywhere.
        expected = list(stock)
        for member in REMOVED_MEMBERS:
            expected.remove(member)
        derived = members(copy)
        if sorted(derived) != sorted(expected):
            raise Refused(f'the derived members differ from the stock less {REMOVED_MEMBERS}')
        derived_table = symbols(copy)
        undefined_inits = {name for name in derived_table['config.o'][1] if name.startswith('_PyInit_')}
        stock_inits = {name for name in table['config.o'][1] if name.startswith('_PyInit_')}
        if undefined_inits != stock_inits - {f'_PyInit_{module}' for module in REMOVED_MODULES}:
            raise Refused('the compiled module table is not the stock one less _ssl and _hashlib')
        openssl = sorted({name for _, undefined in derived_table.values() for name in undefined
                          if OPENSSL_UNDEFINED.match(name)})
        if openssl:
            raise Refused(f'the derived library still refers to OpenSSL: {openssl[:5]}')
        os.replace(copy, target)
    stamp_file.write_text(stamp + '\n')
    print(f'derive_python_without_openssl: wrote {target} ({len(derived)} members; '
          f'without {", ".join(REMOVED_MEMBERS)}; config.o for iOS {arguments.minimum})')
    return target


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument('library')
    parser.add_argument('config')
    parser.add_argument('include')
    parser.add_argument('output')
    parser.add_argument('--sysroot', required=True)
    parser.add_argument('--minimum', required=True)
    arguments = parser.parse_args(argv)
    try:
        derive(arguments)
    except Refused as error:
        print(f'derive_python_without_openssl: refused: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
