#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline regression tests for the Apple Silicon dependency installer."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/download-macos-libs.py'
SPEC = importlib.util.spec_from_file_location('macos_libraries', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class Response(io.BytesIO):
    def __init__(self, contents, length=None):
        super().__init__(contents)
        self.headers = {} if length is None else {'Content-Length': str(length)}


class Installer(MODULE.LibInstaller):
    def __init__(self):
        super().__init__('arm64')
        self.verified = []

    def verify_pkg(self, package, signature):
        # Fixtures use a controlled signature gate, not real MacPorts signing.
        if Path(signature).read_bytes() != b'fixture-signature':
            raise ValueError('Invalid test signature')
        self.verified.append(Path(package).name)


class ResumeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.old_directory = Path.cwd()
        os.chdir(self.temporary.name)
        self.requests = []
        self.remote = {}
        self.installer = Installer()
        self.mock = patch.object(MODULE, 'urlopen', side_effect=self.open_url)
        self.mock.start()
        self.silence = contextlib.redirect_stdout(io.StringIO())
        self.silence.__enter__()

    def tearDown(self):
        self.silence.__exit__(None, None, None)
        self.mock.stop()
        os.chdir(self.old_directory)
        self.temporary.cleanup()

    def open_url(self, url):
        self.requests.append(url)
        return Response(self.remote[url])

    def package(self, name, version='1.0_0', dependencies=(), cached=True,
                tag='darwin_23.arm64'):
        filename = f'{name}-{version}.{tag}.tbz2'
        out = io.BytesIO()
        with tarfile.open(fileobj=out, mode='w:bz2') as archive:
            contents = ''.join(f'@pkgdep {dep}-1.0_0\n'
                               for dep in dependencies).encode()
            member = tarfile.TarInfo('./+CONTENTS')
            member.size = len(contents)
            archive.addfile(member, io.BytesIO(contents))
            payload = f'{name} {version}'.encode()
            member = tarfile.TarInfo(f'opt/local/lib/{name}.fixture')
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
        url = f'{MODULE.MIRROR}/{name}/{filename}'
        self.remote[url] = out.getvalue()
        self.remote[url + '.rmd160'] = b'fixture-signature'
        base = f'{MODULE.MIRROR}/{name}'
        self.remote[base] = self.remote.get(base, b'') + filename.encode() + b'\n'
        if cached:
            (Path(self.installer._pkgs_path) / filename).write_bytes(out.getvalue())
            (Path(self.installer._pkgs_path) / (filename + '.rmd160')).write_bytes(b'fixture-signature')
        return filename

    def installed(self, name, version='1.0_0', payload=True):
        self.installer.mark_pkg_installed(name, version)
        if payload:
            p = Path(self.installer._extract_path) / 'opt/local/lib' / (name + '.fixture')
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(f'{name} {version}')
        return Path(self.installer._extract_path) / 'opt/local/lib' / (name + '.fixture')

    def test_parent_marker_does_not_skip_missing_dependencies(self):
        parent = self.package('parent', dependencies=('child',))
        child = self.package('child')
        existing = self.installed('parent')
        self.installer.install_pkgs(['parent'])
        self.assertTrue(self.installer.is_pkg_installed('child'))
        self.assertEqual(existing.read_text(), 'parent 1.0_0')
        self.assertEqual(self.installer.verified, [parent, child])

    def test_missing_payload_with_marker_is_repaired(self):
        self.package('parent', dependencies=('child',))
        self.package('child')
        self.installed('parent')
        leaf = self.installed('child', payload=False)
        self.installer.install_pkgs(['parent'])
        self.assertEqual(leaf.read_text(), 'child 1.0_0')
        self.assertEqual(Path(self.installer._installed_path).read_text().count('child='), 1)

    def test_dependency_cycles_and_duplicates_terminate(self):
        first = self.package('first', dependencies=('second', 'second'))
        second = self.package('second', dependencies=('first',))
        self.installer.install_pkgs(['first', 'first'])
        self.assertEqual(self.installer.verified, [first, second])

    def test_resume_uses_cached_installed_version_not_latest(self):
        old = self.package('parent', dependencies=('oldchild',))
        self.package('parent', '2.0_0', dependencies=('newchild',))
        self.package('oldchild')
        existing = self.installed('parent')
        self.installer.install_pkgs(['parent'])
        self.assertEqual(self.installer.verified[0], old)
        self.assertFalse(self.installer.is_pkg_installed('newchild'))
        self.assertEqual(existing.read_text(), 'parent 1.0_0')
        self.assertNotIn(f'{MODULE.MIRROR}/parent', self.requests)

    def test_uncached_resume_finds_exact_version(self):
        old = self.package('parent', cached=False)
        self.package('parent', '2.0_0', cached=False)
        self.installed('parent')
        self.installer.install_pkgs(['parent'])
        self.assertEqual(self.installer.verified, [old])
        self.assertNotIn(f'{MODULE.MIRROR}/parent/parent-2.0_0.darwin_23.arm64.tbz2', self.requests)

    def test_noarch_version_is_recorded_and_resumed_exactly(self):
        version = '1.2.3_4+variant'
        archive = self.package('data', version, tag='any_any.noarch')
        self.installer.install_pkgs(['data'])
        self.assertEqual(self.installer.installed_pkg_version('data'), version)
        self.installer.install_pkgs(['data'])
        self.assertEqual(self.installer.verified, [archive, archive])

    def test_invalid_signature_does_not_commit_marker(self):
        archive = self.package('bad')
        (Path(self.installer._pkgs_path) / (archive + '.rmd160')).write_bytes(b'invalid')
        with self.assertRaises(ValueError):
            self.installer.install_pkgs(['bad'])
        self.assertFalse(self.installer.is_pkg_installed('bad'))
        self.assertFalse((Path(self.installer._extract_path) / 'opt/local/lib/bad.fixture').exists())

    def test_each_run_rechecks_previously_installed_payload(self):
        self.package('child')
        leaf = self.installed('child')
        self.installer.install_pkgs(['child'])
        leaf.unlink()
        self.installer.install_pkgs(['child'])
        self.assertEqual(leaf.read_text(), 'child 1.0_0')

    def test_interrupted_download_does_not_publish_partial_file(self):
        class Interrupted(Response):
            def read(self, size=-1):
                if self.tell():
                    raise OSError('Connection interrupted')
                return super().read(3)
        destination = Path(self.installer._pkgs_path) / 'interrupted.tbz2'
        with patch.object(MODULE, 'urlopen', return_value=Interrupted(b'abcdef')):
            with self.assertRaises(OSError):
                self.installer.download_file('fixture', 'fixture-url', str(destination))
        self.assertFalse(destination.exists())
        self.assertFalse(list(destination.parent.glob('*.part')))
        self.remote['fixture-url'] = b'complete'
        self.installer.download_file('fixture', 'fixture-url', str(destination))
        self.assertEqual(destination.read_bytes(), b'complete')

    def test_truncated_or_empty_download_is_not_published(self):
        destination = Path(self.installer._pkgs_path) / 'truncated.tbz2'
        for response in (Response(b'short', 100), Response(b'')):
            with patch.object(MODULE, 'urlopen', return_value=response):
                with self.assertRaises(OSError):
                    self.installer.download_file('fixture', 'fixture-url', str(destination))
            self.assertFalse(destination.exists())
            self.assertFalse(list(destination.parent.glob('*.part')))

    def test_legacy_empty_cache_file_is_replaced(self):
        destination = Path(self.installer._pkgs_path) / 'empty.tbz2'
        destination.touch()
        self.remote['fixture-url'] = b'complete'
        self.installer.download_file('fixture', 'fixture-url', str(destination))
        self.assertEqual(destination.read_bytes(), b'complete')

    def test_intel_is_rejected_before_creating_installer_paths(self):
        for architecture in ('x86_64', 'i386'):
            with self.assertRaises(ValueError):
                MODULE.LibInstaller(architecture)


if __name__ == '__main__':
    unittest.main()
