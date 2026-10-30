#!/usr/bin/env python3
"""
Downloads required libraries for xemu builds on macOS from MacPorts repositories
"""
# Based on https://github.com/tpoechtrager/osxcross/blob/master/tools/osxcross-macports
# which is based on https://github.com/maci0/pmmacports
from urllib.request import urlopen
import re
import os.path
import posixpath
import copy
from tarfile import TarFile
import subprocess
import tempfile
import shutil

MIRROR = 'https://packages.macports.org'

# FIXME: Inline macports key
# FIXME: Move packages to archive directory to track used vs unused
# FIXME: Support multiple mirrors

class LibInstaller:
	DARWIN_TARGET_ARM64="darwin_23" # macOS 14.x

	def __init__(self, arch):
		self._queue = []
		self._installed = []
		if arch == 'arm64':
			self._darwin_target = self.DARWIN_TARGET_ARM64
		else:
			raise ValueError("Metal4 dependencies require Apple Silicon (arm64)")
		self._arch = arch

		self._extract_path = os.path.realpath(f'./macos-libs/{self._arch}')
		if not os.path.exists(self._extract_path):
			os.makedirs(self._extract_path)
		self._installed_path = os.path.join(self._extract_path, 'INSTALLED')
		self._pkgs_path = os.path.realpath(os.path.join(f'./macos-pkgs'))
		if not os.path.exists(self._pkgs_path):
			os.makedirs(self._pkgs_path)

	def get_latest_pkg_filename_url(self, pkg_name, pkg_version=None):
		pkg_base_url = f'{MIRROR}/{pkg_name}'
		version = re.escape(pkg_version) if pkg_version else r'[\w\.\-\_\+]*?'
		pattern = re.escape(pkg_name) + '-' + version + r'\.(?:any_any|darwin_any|' + self._darwin_target + r')\.(?:noarch|' + self._arch + r')\.tbz2'
		if pkg_version:
			cached = [name for name in sorted(os.listdir(self._pkgs_path))
			          if re.fullmatch(pattern, name)]
			if cached:
				return cached[-1], f'{pkg_base_url}/{cached[-1]}'
		with urlopen(pkg_base_url) as response:
			pkg_list = response.read().decode('utf-8')
		pkgs = re.findall(pattern, pkg_list)
		if len(pkgs) < 1:
			print(f'    [*] [ERROR] Unable to find version of {pkg_name} compatible with {self._darwin_target}.{self._arch}')
			exit(1)

		pkg_filename = pkgs[-1]
		return pkg_filename, f'{pkg_base_url}/{pkg_filename}'

	def installed_pkg_version(self, pkg_name):
		if os.path.exists(self._installed_path):
			with open(self._installed_path) as f:
				for line in f:
					name, separator, version = line.strip().partition('=')
					if name == pkg_name and separator and version:
						return version
		return None

	def is_pkg_installed(self, pkg_name):
		return self.installed_pkg_version(pkg_name) is not None

	def mark_pkg_installed(self, pkg_name, pkg_version):
		if self.is_pkg_installed(pkg_name):
			return
		with open(os.path.join(self._extract_path, 'INSTALLED'), 'a+') as f:
			f.write(f'{pkg_name}={pkg_version}\n')

	def download_file(self, desc, url, dst):
		if os.path.exists(dst) and os.path.getsize(dst):
			print(f'    [+] Already have {desc}')
			return
		print(f'    [+] Downloading {desc}')
		fd, partial = tempfile.mkstemp(prefix=os.path.basename(dst) + '.',
		                               suffix='.part', dir=os.path.dirname(dst))
		try:
			with os.fdopen(fd, 'wb') as f, urlopen(url) as response:
				shutil.copyfileobj(response, f)
				expected = getattr(response, 'headers', {}).get('Content-Length')
				if not f.tell() or (expected is not None and f.tell() != int(expected)):
					raise OSError(f'Incomplete download: {desc}')
			os.replace(partial, dst)
		finally:
			if os.path.exists(partial):
				os.unlink(partial)

	def verify_pkg(self, pkg_path, sig_path):
		PUBKEYURL="https://svn.macports.org/repository/macports/trunk/base/macports-pubkey.pem"
		PUBKEYRMD160="d3a22f5be7184d6575afcc1be6fdb82fd25562e8"
		PUBKEYSHA1="214baa965af76ff71187e6c1ac91c559547f48ab"
		key_filename = 'macports-pubkey.pem'
		dst_key_filename = os.path.join(self._pkgs_path, key_filename)
		self.download_file('MacPorts key', PUBKEYURL, dst_key_filename)
		rmd160 = subprocess.run('openssl rmd160 "' + dst_key_filename + "\" | awk '{print $2}'",
	                            capture_output=True, shell=True,
	                            check=True).stdout.decode('utf-8').strip()
		sha1 = subprocess.run('openssl sha1 "' + dst_key_filename + "\" | awk '{print $2}'",
	                            capture_output=True, shell=True,
	                            check=True).stdout.decode('utf-8').strip()
		assert (rmd160 == PUBKEYRMD160 and sha1 == PUBKEYSHA1), 'Invalid MacPorts key'
		sha1 = subprocess.run('openssl dgst -ripemd160 '
			                  f'-verify "{dst_key_filename}" '
			                  f'-signature "{sig_path}" "{pkg_path}"',
	                            shell=True, check=True)

	def is_pkg_skipped(self, pkg_name):
		return any(pkg_name.startswith(n) for n in ('python', 'ncurses', 'mesa', 'llvm', 'libsndfile'))

	def extract_members(self, tb):
		# Build dependencies need the MacPorts prefix, not system launch services.
		members = []
		for original in tb.getmembers():
			member = copy.copy(original)
			name = posixpath.normpath(member.name)
			if name not in ('opt', 'opt/local') and not name.startswith('opt/local/'):
				continue
			if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
				raise ValueError(f'Unsupported archive entry: {member.name}')
			member.name = name
			if member.issym() or member.islnk():
				target = member.linkname
				if target.startswith('/opt/local/'):
					target = target.lstrip('/')
				elif member.issym():
					target = posixpath.join(posixpath.dirname(name), target)
				target = posixpath.normpath(target)
				if not target.startswith('opt/local/'):
					raise ValueError(f'Archive link escapes MacPorts prefix: {member.name}')
				member.linkname = (posixpath.relpath(target, posixpath.dirname(name))
				                   if member.issym() else target)
			members.append(member)
		return members

	def install_pkg(self, pkg_name):
		if pkg_name in self._installed:
			return
		if self.is_pkg_skipped(pkg_name):
			print(f'[*] Skipping package {pkg_name}')
			return

		print(f'[*] Fetching {pkg_name}')
		installed_version = self.installed_pkg_version(pkg_name)
		pkg_filename, pkg_url = self.get_latest_pkg_filename_url(pkg_name, installed_version)
		pkg_version = pkg_filename[len(pkg_name) + 1:].rsplit('.', 3)[0]
		dst_pkg_filename = os.path.join(self._pkgs_path, pkg_filename)
		print(f'    [*] Found package {pkg_filename}')
		self.download_file(pkg_filename, pkg_url, dst_pkg_filename)

		dst_pkg_sig_filename = dst_pkg_filename + '.rmd160'
		pkg_sig_url = pkg_url + '.rmd160'
		self.download_file('package signature', pkg_sig_url, dst_pkg_sig_filename)

		print(f'    [+] Verifying package')
		self.verify_pkg(dst_pkg_filename, dst_pkg_sig_filename)

		print(f'    [+] Looking for dependencies')
		tb = TarFile.open(dst_pkg_filename)
		try:
			self.install_archive(tb, pkg_name, pkg_version, installed_version is not None)
		finally:
			tb.close()
		self._installed.append(pkg_name)

	def install_archive(self, tb, pkg_name, pkg_version, installed):
		pkg_contents_file = tb.extractfile('./+CONTENTS').read().decode('utf-8')
		for dep in re.findall(r'@pkgdep (.+)', pkg_contents_file):
			print(f'        [>] {dep}')
			s = re.search(r'-\d', dep)
			if s:
				dep = dep[0:s.span()[0]]
			self._queue.append(dep)

		print(f'    [*] Checking tarball...')

		members = self.extract_members(tb)
		for member in members:
			fpath = member.name
			extracted_path = os.path.realpath(os.path.join(self._extract_path, fpath))
			assert os.path.commonpath([self._extract_path, extracted_path]) == self._extract_path, f'tarball has a global file: {fpath}'

		# Installed parents must still restore their dependency closure on resume.
		def present(member):
			path = os.path.join(self._extract_path, member.name)
			if member.issym():
				return os.path.islink(path) and os.readlink(path) == member.linkname
			return os.path.isdir(path) if member.isdir() else os.path.isfile(path)
		if installed and all(present(member) for member in members):
			print(f'[*] Package {pkg_name} already installed; dependencies queued')
			return

		print(f'    [*] Extracting to {self._extract_path}')
		tb.extractall(self._extract_path, members=members, numeric_owner=True)

		for member in members:
			fpath = member.name
			# FIXME: Symlinks
			extracted_path = os.path.realpath(os.path.join(self._extract_path, fpath))
			if extracted_path.endswith('.pc'):
				print(f'    [*] Fixing {extracted_path}')
				with open(extracted_path, 'r') as f:
					lines = f.readlines()
				for i, l in enumerate(lines):
					if l.strip().startswith('prefix'):
						new_prefix = f'prefix={self._extract_path}/opt/local\n'
						if pkg_name.startswith('openssl'): # FIXME
							new_prefix = f'prefix={self._extract_path}/opt/local/libexec/openssl11\n'
						lines[i] = new_prefix
					elif l.strip().startswith('Requires.private:'):
						if pkg_name.startswith('libepoxy'):
							lines[i] = ''
				with open(extracted_path, 'w') as f:
					f.write(''.join(lines))

		if pkg_name == 'glib2':
			fpath = './opt/local/include/glib-2.0/glib/gi18n.h'
			extracted_path = os.path.realpath(os.path.join(self._extract_path, fpath))
			print(f'    [*] Fixing {extracted_path}')
			with open(extracted_path, 'r') as f:
				lines = f.read()
			s = '/opt/local/include/libintl.h'
			lines = lines.replace(s, self._extract_path + s)
			with open(extracted_path, 'w') as f:
				f.write(lines)

		self.mark_pkg_installed(pkg_name, pkg_version)

	def install_pkgs(self, requested):
		self._installed.clear()
		self._queue = list(requested)
		while len(self._queue) > 0:
			pkg_name = self._queue.pop(0)
			self.install_pkg(pkg_name)

def main():
	import argparse
	ap = argparse.ArgumentParser()
	ap.add_argument('arch', choices=('arm64',))
	args = ap.parse_args()
	li = LibInstaller(args.arch)
	li.install_pkgs([
		'SDL3',
		'glib2',
		'libsamplerate',
		'libpixman',
		'libepoxy',
		'libpcap',
		'libslirp',
		'libusb'])

if __name__ == '__main__':
	main()
