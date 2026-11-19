# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""List every cipher in a built iPad app, in three groups (ROUND5 8M, E1; 8M.2, E6 and E7).

    python3 release/ios/check_no_encryption_library.py [--claim ask|exempt [--write-key]] <app or program>

The class is "cipher code that is not the operating system's". The check reads the program with
`nm` (every symbol, local ones included, defined ones for the groups below) and its bytes the way
`strings` does. Given an app, it reads the main program and every library in `Frameworks/` and
loose `.dylib`/`.so` files: the claim is about everything the app carries. It sorts what it finds
into three groups and prints each:

1. **A general encryption library**: OpenSSL (its prefixes, `OPENSSL_SYMBOL`, or its version text),
   BoringSSL and LibreSSL (the same prefixes), mbedTLS, wolfSSL, libsodium, libgcrypt, nettle,
   Crypto++ and libtomcrypt (`GENERAL_LIBRARIES`).
2. **Format ciphers**: cipher code inside a media or document library, each family on the reviewed
   list `reviewed_ciphers.txt` beside this file, with the library it comes from and why it is there.
   The same list names the symbols that only look like ciphers (cryptomatte, FreeType's
   `t1_decrypt`, the random number generators' `chacha_block`) and says why they are not.
3. **Unreviewed**: any defined symbol whose name names a cipher (`names_cipher`) and that is on
   neither list. This group keeps the class whole: a library update cannot bring a cipher in unseen.

The last line of its output is the verdict, one of:

    no encryption library: <program>        exit 0: no general library and nothing unreviewed
    encryption library present: <program>   exit 1: a general encryption library
    unreviewed cipher code: <program>       exit 3: no general library, but a cipher not on the list
    cannot check: <reason>                  exit 2: the program or the list cannot be read (never a pass)

Format ciphers do not change the verdict; they are listed every time.

`--claim` adds the key rule (E7; decision 98): `ITSAppUsesNonExemptEncryption` is `false` only when
the verdict is "no encryption library" **and** the claim is the owner's recorded `exempt`
(`ENCRYPTION_CLAIM` in `testflight.env`; the default is `ask`). In every other case there is no
key, and App Store Connect asks. It prints the line `ITSAppUsesNonExemptEncryption: false` or
`ITSAppUsesNonExemptEncryption: absent (...)` before the verdict. `--write-key` (given an app) also
writes that into the app's `Info.plist`: `build_testflight.sh` uses it, `upload_testflight.sh` reads
the line and refuses an archive whose key differs.

Why the app can be without a general library: OpenSSL reached the program only through two built-in
modules of Python's static library (`_ssl`, `_hashlib`); the iPad build links a copy of that library
without them (`derive_python_without_openssl.py`).
"""

import bisect
import functools
import plistlib
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REVIEWED_LIST = HERE / 'reviewed_ciphers.txt'
CLAIMS = ('ask', 'exempt')
KEY = 'ITSAppUsesNonExemptEncryption'

# Prefixes of OpenSSL 3's own symbols in libssl and libcrypto (with Mach-O's leading underscore):
# the stock app has thousands of each (5339 in all, 2026-11-19). Short or common prefixes are left
# out because other libraries use them: zstd defines `ERR_getErrorString`, which the app without
# OpenSSL still has; `RAND_`, `BN_`, `OBJ_`, `DH_` and the like are as easily someone else's.
# BoringSSL and LibreSSL keep OpenSSL's names, so this finds them too.
OPENSSL_SYMBOL = re.compile(
    r'^_(SSL|SSL_CTX|SSL_SESSION|TLS|DTLS|EVP|OPENSSL|OSSL|CRYPTO|X509|X509V3|PEM|BIO|HMAC|'
    r'RSA|EC_KEY|EC_GROUP|EC_POINT|ECDSA|AES|ASN1|PKCS5|PKCS7|PKCS8|PKCS12|i2d|d2i)_[A-Za-z0-9_]')
# `OpenSSL 3.5.2 5 Aug 2025`, `OpenSSL 3.0.0`: the version text OpenSSL compiles in.
OPENSSL_VERSION = re.compile(rb'OpenSSL [0-9]+\.[0-9]+\.[0-9]+[a-z]?(?: +[0-9]{1,2} [A-Z][a-z]{2} [0-9]{4})?')
# The two Python modules that brought it (their module initialisers).
PYTHON_MODULES = ('_PyInit__ssl', '_PyInit__hashlib')
# The other general encryption libraries, by their own public prefixes (on the demangled name,
# without Mach-O's underscore). Each is a whole library of ciphers for anyone's data.
GENERAL_LIBRARIES = (
    ('BoringSSL', re.compile(r'^bssl::')),
    ('mbedTLS', re.compile(r'^(mbedtls|psa)_[a-z]')),
    ('wolfSSL', re.compile(r'^(wolfSSL|wolfCrypt|wc)_[A-Za-z]')),
    ('libsodium', re.compile(r'^(sodium_|crypto_(secretbox|box|aead|stream|sign|kx|kdf|pwhash|'
                             r'secretstream|core|onetimeauth|scalarmult)_)')),
    ('libgcrypt', re.compile(r'^_?gcry_')),
    ('nettle', re.compile(r'^nettle_')),
    ('Crypto++', re.compile(r'^CryptoPP::')),
    ('libtomcrypt', re.compile(r'^(register_cipher|find_cipher|ltc_|cipher_descriptor)')),
)

# A name names a cipher when one of its words is a cipher's name or holds "crypt" or "cipher".
# Words: the name split at anything not a letter or digit and at lower-to-upper case changes,
# after demangling (C++ and Swift), so `av_aes_ctr_crypt`, `AESContext` and `Rc4Key` all count.
# Block modes (ecb, cbc, ctr, gcm) and words that are as often something else (seed, idea, aria)
# are left out: on their own they found only counters and random seeds (2026-11-19); the
# functions that use them also name the cipher.
CIPHER_WORDS = frozenset((
    'aes', 'des', '3des', 'tdes', 'rc2', 'rc4', 'rc5', 'arc4', 'arcfour', 'tea', 'xtea', 'xxtea',
    'chacha', 'chacha20', 'xchacha20', 'salsa20', 'blowfish', 'twofish', 'camellia', 'serpent',
    'cast5', 'cast128', 'sm4', 'poly1305', 'secretbox',
    # Names of encryption schemes rather than ciphers, whose code does not always say "crypt":
    # MP4's Common Encryption (FFmpeg's `ff_mov_cenc_*` writes it), sample encryption, Secure RTP.
    'cenc', 'senc', 'srtp', 'aaxc'))
CIPHER_FRAGMENT = re.compile(r'crypt|cipher')
WORD = re.compile(r'[A-Z]+[0-9]*(?![a-z])|[A-Z]?[a-z]+[0-9]*|[0-9]+[A-Za-z]*')
# Cheap filter before demangling, on the name in lower case: anything that could hold such a word.
CANDIDATE = re.compile(r'crypt|cipher|aes|des|rc[245]|arc4|arcfour|tea|chacha|salsa|blowfish|'
                       r'twofish|camellia|serpent|cast5|cast128|sm4|poly1305|secretbox|'
                       r'cenc|senc|srtp|aaxc|mbedtls|psa_|wolf|wc_|sodium|gcry|nettle|bssl|cryptopp|ltc_')
MACHO_MAGIC = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
DEFINED_TYPES = frozenset('tTsSdDbB')


def words(name):
    """The words of a (demangled) name, lower case, each once."""
    return {word.lower() for word in WORD.findall(name)}


@functools.lru_cache(maxsize=None)
def cipher_word(word):
    return bool(CIPHER_FRAGMENT.search(word)) or word in CIPHER_WORDS or \
        word.rstrip('0123456789') in CIPHER_WORDS


def names_cipher(name):
    """True when a demangled name holds a cipher's name or "crypt" or "cipher" as one of its words."""
    return any(cipher_word(word) for word in words(name))


class Entry:
    """One line of the reviewed list."""

    def __init__(self, group, library, family, pattern, reason, line):
        self.group, self.library, self.family, self.reason, self.line = group, library, family, reason, line
        self.pattern = re.compile(pattern)
        self.symbols = []

    @property
    def title(self):
        return f'{self.library}: {self.family}'


def reviewed(path=REVIEWED_LIST):
    """The reviewed list: lines `<format|not a cipher> | <library> | <family> | <pattern> | <reason>`,
    the pattern a Python regular expression matched whole against the demangled name without
    Mach-O's leading underscore. Raises ValueError on a line it cannot read: a list that cannot be
    read is never a pass."""
    entries = []
    for number, raw in enumerate(Path(path).read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        fields = [field.strip() for field in line.split(' | ')]
        if len(fields) != 5 or fields[0] not in ('format', 'not a cipher') or not all(fields):
            raise ValueError(f'{path}:{number}: expected "<format|not a cipher> | <library> | '
                             f'<family> | <pattern> | <reason>"')
        try:
            entries.append(Entry(*fields, number))
        except re.error as error:
            raise ValueError(f'{path}:{number}: bad pattern: {error}') from None
    return entries


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


def demangle(names):
    """{name: demangled name without Mach-O's underscore} for C++ (`__Z`) and Swift (`_$s`) names."""
    result = {name: name[1:] if name.startswith('_') else name for name in names}
    for tool, prefixes in ((['xcrun', 'c++filt', '-_'], ('__Z', '___Z')),
                           (['xcrun', 'swift-demangle', '--compact'], ('_$s', '_$S', '_T0'))):
        chosen = [name for name in names if name.startswith(prefixes)]
        if not chosen:
            continue
        if tool[1] == 'swift-demangle':
            chosen_input = [name[1:] for name in chosen]
        else:
            chosen_input = chosen
        run = subprocess.run(tool, input='\n'.join(chosen_input) + '\n', capture_output=True, text=True)
        lines = run.stdout.splitlines()
        if run.returncode != 0 or len(lines) != len(chosen):
            raise RuntimeError(f'{" ".join(tool)} failed: {run.stderr.strip()[:200]}')
        result.update(zip(chosen, lines))
    return result


def symbols(program):
    """All symbol names in one program, and the defined ones. Raises when `nm` fails."""
    result = subprocess.run(['xcrun', 'nm', '-a', str(program)], capture_output=True, text=True)
    if result.returncode != 0 and 'no symbols' not in result.stderr:
        raise RuntimeError(f'nm could not read {program}: {result.stderr.strip()}')
    every, defined = set(), set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if not fields:
            continue
        name = fields[-1]
        every.add(name)
        if len(fields) >= 3 and fields[1] in DEFINED_TYPES:
            defined.add(name)
    return every, defined


class Findings:
    """What the check found in an app or program, in the three groups."""

    def __init__(self, entries):
        self.files = []
        self.general = []        # (file, library, [names]) and (file, 'OpenSSL version text', [texts])
        self.entries = entries    # reviewed entries, each with the symbols it matched
        self.unreviewed = []     # (file, name)

    @property
    def status(self):
        if self.general:
            return 1
        if self.unreviewed:
            return 3
        return 0


def read_program(program, findings):
    every, defined = symbols(program)
    openssl = sorted(name for name in every if OPENSSL_SYMBOL.match(name) or name in PYTHON_MODULES)
    if openssl:
        findings.general.append((program, 'OpenSSL', openssl))
    versions = sorted({match.decode() for match in OPENSSL_VERSION.findall(program.read_bytes())})
    if versions:
        findings.general.append((program, 'OpenSSL version text', versions))
    # One pass over all the names at once, a name per line in lower case (a loop over the main
    # program's 380 000 names is ten times slower).
    ordered = sorted(defined)
    lowered = '\n'.join(ordered).lower()
    starts = [0] + [match.end() for match in re.finditer('\n', lowered)]
    lines = sorted({bisect.bisect_right(starts, match.start()) - 1 for match in CANDIDATE.finditer(lowered)})
    candidates = [ordered[line] for line in lines]
    plain = demangle(candidates)
    others = {}
    for name in candidates:
        text = plain[name]
        library = next((library for library, pattern in GENERAL_LIBRARIES if pattern.search(text)), None)
        if library:
            others.setdefault(library, []).append(text)
            continue
        if not names_cipher(text):
            continue
        entry = next((entry for entry in findings.entries if entry.pattern.fullmatch(text)), None)
        if entry:
            entry.symbols.append(text)
        else:
            findings.unreviewed.append((program, text))
    for library, names in sorted(others.items()):
        findings.general.append((program, library, names))


def check(path, entries=None):
    """Read everything; return the Findings. Raises when something cannot be read."""
    findings = Findings(reviewed() if entries is None else entries)
    findings.files = programs(path)
    for program in findings.files:
        read_program(program, findings)
    return findings


def key_for(status, claim):
    """The key rule (E7, decision 98): False only for "no encryption library" with the owner's
    recorded `exempt`; None (no key) in every other case."""
    if claim not in CLAIMS:
        raise ValueError(f'ENCRYPTION_CLAIM must be one of {", ".join(CLAIMS)}, not {claim!r}')
    return False if status == 0 and claim == 'exempt' else None


def key_reason(status, claim):
    if status == 0 and claim == 'exempt':
        return 'false'
    if status == 1:
        why = 'a general encryption library is in the app'
    elif status == 3:
        why = 'cipher code not on the reviewed list is in the app'
    else:
        why = 'the owner has not decided: ENCRYPTION_CLAIM=ask'
    return f'absent ({why}; App Store Connect asks)'


def report(findings, out=print, root=None):
    """Print the three groups."""
    def where(program):
        try:
            return str(program.relative_to(root)) if root else str(program)
        except ValueError:
            return str(program)

    def examples(names, count=4):
        names = sorted(set(names))
        return ', '.join(names[:count]) + (f', and {len(names) - count} more' if len(names) > count else '')

    out(f'read {len(findings.files)} Mach-O file(s) with nm and for version strings')
    out('1. general encryption library: ' + ('none' if not findings.general else 'PRESENT'))
    for program, library, names in findings.general:
        out(f'   {library} in {where(program)}: {len(names)} ({examples(names)})')
    used = [entry for entry in findings.entries if entry.symbols and entry.group == 'format']
    out(f'2. format ciphers (reviewed, {REVIEWED_LIST.name}): '
        + (f'{len(used)} famil{"y" if len(used) == 1 else "ies"}, '
           f'{sum(len(entry.symbols) for entry in used)} symbols' if used else 'none'))
    for entry in used:
        out(f'   {entry.title}: {len(entry.symbols)} ({examples(entry.symbols)})')
    unused = [entry for entry in findings.entries if entry.symbols and entry.group == 'not a cipher']
    if unused:
        out(f'   named like a cipher but not one (reviewed): '
            + '; '.join(f'{entry.title} ({len(entry.symbols)})' for entry in unused))
    out('3. unreviewed: ' + ('none' if not findings.unreviewed else f'{len(findings.unreviewed)} symbols'))
    for program, name in findings.unreviewed:
        out(f'   {name}  (in {where(program)})')


def write_key(app, key):
    info_path = Path(app) / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.pop(KEY, None)
    if key is not None:
        info[KEY] = key
    info_path.write_bytes(plistlib.dumps(info))


VERDICTS = {0: 'no encryption library', 1: 'encryption library present', 3: 'unreviewed cipher code'}


def main(argv):
    arguments = argv[1:]
    claim = None
    write = False
    while arguments and arguments[0].startswith('--'):
        option = arguments.pop(0)
        if option == '--claim' and arguments:
            claim = arguments.pop(0)
        elif option == '--write-key':
            write = True
        else:
            arguments = []
            break
    if len(arguments) != 1 or (write and claim is None):
        print(__doc__.strip().splitlines()[2].strip())
        return 2
    path = arguments[0]
    try:
        if claim is not None:
            key_for(0, claim)
        findings = check(path)
        if write and not Path(path).is_dir():
            raise FileNotFoundError(f'--write-key needs an app, not {path}')
    except (OSError, RuntimeError, ValueError) as error:
        print(f'cannot check: {error}')
        return 2
    report(findings, root=Path(path) if Path(path).is_dir() else None)
    status = findings.status
    if claim is not None:
        key = key_for(status, claim)
        print(f'claim: {claim}')
        print(f'{KEY}: {key_reason(status, claim)}')
        if write:
            write_key(path, key)
    print(f'{VERDICTS[status]}: {path}')
    return status


if __name__ == '__main__':
    sys.exit(main(sys.argv))
