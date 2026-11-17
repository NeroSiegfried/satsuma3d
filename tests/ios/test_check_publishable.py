# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""`release/ios/check_publishable.sh` (ROUND5 8I.4, decision 48) passes on a clean commit and fails
on each thing it guards against: a file through Git LFS, a foreign author, a home path in a file,
a private string in a commit message. Each case is one commit made on top of HEAD in a throwaway
clone that shares this repository's objects, so the checkout is never touched."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'release/ios/check_publishable.sh'


def git(*args, cwd, env=None, data=None):
    return subprocess.run(['git', *args], cwd=cwd, env=env, input=data, capture_output=True, check=True,
                          text=isinstance(data, str) or data is None).stdout


class CheckPublishableTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which('git') is None or not (ROOT / '.git').exists():
            raise unittest.SkipTest('needs this repository\'s git checkout')
        cls.email = git('config', 'user.email', cwd=ROOT).strip()
        cls.name = git('config', 'user.name', cwd=ROOT).strip()
        if not cls.email.endswith('@users.noreply.github.com'):
            raise unittest.SkipTest('the checkout has no GitHub no-reply user.email')
        cls.tmp = tempfile.mkdtemp()
        cls.repo = os.path.join(cls.tmp, 'repo')
        subprocess.run(['git', 'clone', '-q', '--shared', '--no-checkout', str(ROOT), cls.repo], check=True)
        git('config', 'user.email', cls.email, cwd=cls.repo)
        git('config', 'user.name', cls.name, cwd=cls.repo)
        cls.base = git('rev-parse', 'HEAD', cwd=ROOT).strip()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def commit(self, path, content, message='A change', email=None):
        """A commit on top of the base adding \a path with \a content, its hash."""
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(self.tmp, 'index'),
                   GIT_AUTHOR_NAME=self.name, GIT_AUTHOR_EMAIL=email or self.email,
                   GIT_COMMITTER_NAME=self.name, GIT_COMMITTER_EMAIL=self.email)
        git('read-tree', self.base, cwd=self.repo, env=env)
        blob = git('hash-object', '-w', '--stdin', cwd=self.repo, env=env, data=content).strip()
        git('update-index', '--add', '--cacheinfo', '100644,%s,%s' % (blob, path), cwd=self.repo, env=env)
        tree = git('write-tree', cwd=self.repo, env=env).strip()
        return git('commit-tree', tree, '-p', self.base, cwd=self.repo, env=env, data=message).strip()

    def check(self, tip):
        result = subprocess.run(['sh', str(SCRIPT), self.base, tip], cwd=self.repo, capture_output=True, text=True)
        return result.returncode, result.stdout

    def test_clean_commit_passes(self):
        code, out = self.check(self.commit('release/ios/notes.txt', 'Plain text.\n'))
        self.assertEqual(code, 0, out)
        self.assertIn('Publishable', out)

    def test_file_through_lfs_fails(self):
        code, out = self.check(self.commit('release/ios/picture.png', 'not really a picture\n'))
        self.assertEqual(code, 1, out)
        self.assertIn('through Git LFS', out)

    def test_lfs_pointer_fails(self):
        pointer = ('version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize 12\n' % ('0' * 64))
        code, out = self.check(self.commit('release/ios/data.bin', pointer))
        self.assertEqual(code, 1, out)
        self.assertIn('LFS pointer', out)

    def test_other_author_fails(self):
        code, out = self.check(self.commit('release/ios/notes.txt', 'Text.\n', email='someone@example.com'))
        self.assertEqual(code, 1, out)
        self.assertIn('author or committer', out)

    def test_home_path_in_file_fails(self):
        code, out = self.check(self.commit('release/ios/notes.txt', 'See %s/Desktop/x.\n' % ('/Users/' + 'someone')))
        self.assertEqual(code, 1, out)
        self.assertIn('home path', out)

    def test_private_string_in_message_fails(self):
        code, out = self.check(self.commit('release/ios/notes.txt', 'Text.\n',
                                           message='Built in %s/build\n' % os.path.expanduser('~')))
        self.assertEqual(code, 1, out)
        self.assertIn('message', out)


if __name__ == '__main__':
    unittest.main()
