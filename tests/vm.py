#!/usr/bin/env python3
"""M1 and M2 VM tests: run vps-proxy-setup in disposable QEMU guests.

Adapted from vps-hardening's tests/vm.py (detailed design 9.1); Debian 13
amd64 only (NFR-03). Both suites first build the main configuration of
verification plan 3.2 on an overlay of the official image: vps-tuning applied,
rebooted and verified; vps-hardening v0.1.1 applied on a pseudo-terminal and
confirmed from a new SSH session; this tool installed by its release installer
from a local asset directory. Suites:

  m1-preflight  one guest on an overlay of the main configuration: the two
                namespaces and the target stand-in, VT-80, VT-81, VT-01,
                VT-03, VT-04 and VT-05; then one overlay of that guest each
                for the hardening.verify case of VT-05 and for S1, S2 and S3
                (VT-02).
  m1-check      S1 with the panel on loopback (detailed design 9.5); on
                overlays of it the baseline with VT-74 to VT-76 and VT-73,
                VT-72 with DO-1 and VT-75, then one overlay per VT-71
                injection, each judged here against the baseline.
  m2-deploy     one guest with the namespaces, the stand-in and a fresh
                target-check result: VT-11; then one overlay of it each for
                VT-10 (deploy steps 1 to 4, with VT-13 on its output), VT-12
                (with VT-13 on the real installer output) and VT-13 with a
                failing installer.
  m2-check      one guest with the namespaces, the stand-in and a fresh
                target-check result: a complete deploy and check (VT-70);
                then on overlays of it the baseline of M2 and one overlay per
                VT-71 injection of M2, each judged here against the baseline.

tests/guest/m1.sh is the guest side of M1 and judges everything except
VT-71; tests/guest/m2.sh, which sources it, the guest side of M2.
Evidence goes to .tmp/vm/evidence; it is scanned for the test secrets, also
when the suite fails, and listed with sizes and digests (verification plan 6).
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tarfile
import threading
import time
import traceback
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.tmp/vm'
SSH_PORT = 2222
BUNDLE = '/opt/vps-bundle'
GUEST_EVIDENCE = '/root/vps-evidence'
# Written by tests/guest/m1.sh; read here for the leak scan and never stored.
GUEST_MARKERS = '/root/vps-private/markers'
VH = '/usr/local/bin/vps-hardening'
APPLY_PROMPT = '两项都满足请输入 yes'.encode()
APPLIED = '加固已应用，等待确认'
CONFIRMED = '已确认'


def shell_pins():
    """The scalar pins of lib/vps-proxy-setup/pins.sh, so that the tests use the tool's own values."""
    text = (ROOT / 'lib/vps-proxy-setup/pins.sh').read_text()
    return dict(re.findall(r"^readonly (VPS_PIN_\w+)='([^']*)'$", text, re.M))


def db_items():
    """The database items of check, in its order (VPS_DB_ITEMS in check.sh)."""
    text = (ROOT / 'lib/vps-proxy-setup/check.sh').read_text()
    return re.search(r'^VPS_DB_ITEMS=\(([^)]*)\)', text, re.M).group(1).replace('\\', ' ').split()


PINS = shell_pins()
# Installers the guests run: checked here and again in the guest against
# fixtures/SHA256SUMS. vps-tuning is the newest release (VO-6); vps-hardening
# the version the tool was tested with; 3X-UI's install.sh at the pinned commit.
FIXTURES = {
    'vps-tuning-install.sh': (
        'https://github.com/alieismy/vps-tuning/releases/download/v0.2.0-rc.4/install.sh',
        '06c8b235ce0538d6e5247b3b50fa568e6c71f9ee9f28b4cc999f031b5e9978ec'),
    'vps-hardening-install.sh': (
        'https://github.com/alieismy/vps-hardening/releases/download/v0.1.1/install.sh',
        '338e20ddfbb1513be7dfd5a41fd33f6c9d95ce76bdf8ab0d4576ba08cf83dcfc'),
    '3x-ui-install.sh': (
        f"https://raw.githubusercontent.com/MHSanaei/3x-ui/{PINS['VPS_PIN_XUI_COMMIT']}/install.sh",
        PINS['VPS_PIN_XUI_INSTALL_SHA256']),
}
# The M1 baseline of check on S1 (detailed design 9.5, with the items of
# FR-13). An inferred expectation: a difference fails the run, and the
# design is corrected from the archived baseline.
BASELINE = {
    'PASS': 'root platform deps xui.version xui.files xui.unit xui.env xui.service xui.ipl xui.db panel.listen '
            'routing.outbounds clients.limit-ip sub.enable sub.cert sub.paths sub.json sub.info-node sub.updates '
            'listen.api listen.metrics secrets.handoff absent.acme absent.cf-credentials hardening.verify',
    'FAIL': 'inbounds.set sub.listen sub.domain sub.uri sub.clash sub.remark listen.reality listen.forwarder '
            'listen.sub secrets.install-result record.consistent cfd.files cfd.unit cfd.service cfd.autoupdate '
            'cfd.token cfd.metrics cfd.ready cfd.routes',
    'SKIP': 'reality.settings reality.share reality.hosts forwarder.settings routing.rules routing.ai-ipv6 '
            'ipv6.egress clients.count clients.flow sub.rules state.perms',
    'WARN': 'secrets.api-tokens',
}
# VT-71: injection -> the items that go from PASS to FAIL (detailed design
# 9.5). vps-hardening's verify also fails on a panel listening beyond loopback
# and on extra files in /etc/fail2ban, so hardening.verify is listed with them.
INJECTIONS = {
    'x-ui-script': {'xui.files'},
    'unit-env': {'xui.unit'},
    'env-file': {'xui.env'},
    'disabled': {'xui.service'},
    'listen-all': {'panel.listen', 'hardening.verify'},
    'ipl': {'xui.ipl', 'hardening.verify'},
    'sub-json': {'sub.json'},
    'sub-info-node': {'sub.info-node'},
    'sub-updates': {'sub.updates'},
    'sub-enable': {'sub.enable'},
    'sub-cert': {'sub.cert'},
    'sub-path': {'sub.paths'},
    'acme': {'absent.acme'},
    'cf-credentials': {'absent.cf-credentials'},
    'ufw-rule': {'hardening.verify'},
}
# The M2 baseline of check after deploy steps 1 to 7, before cloudflared
# (VT-70, detailed design 9.6). An inferred expectation, corrected from the
# archived baseline as at M1.
M2_BASELINE = {
    'PASS': 'root platform deps xui.version xui.files xui.unit xui.env xui.service xui.ipl xui.db panel.listen '
            'inbounds.set reality.settings reality.share reality.hosts forwarder.settings routing.rules '
            'routing.outbounds clients.flow clients.limit-ip sub.enable sub.listen sub.cert sub.domain sub.uri '
            'sub.paths sub.clash sub.json sub.info-node sub.updates sub.remark listen.reality listen.forwarder '
            'listen.sub listen.api listen.metrics secrets.install-result secrets.api-tokens absent.acme '
            'absent.cf-credentials state.perms record.consistent hardening.verify',
    'FAIL': 'cfd.files cfd.unit cfd.service cfd.autoupdate cfd.token cfd.metrics cfd.ready cfd.routes',
    'SKIP': 'routing.ai-ipv6 ipv6.egress sub.rules',
    'WARN': 'secrets.handoff',
    'INFO': 'clients.count',
}
# VT-71 at M2 (detailed design 9.6): injection -> the items that leave PASS,
# for FAIL, or for the level given.
M2_INJECTIONS = {
    'inbound-extra': {'inbounds.set'},
    'reality-disabled': {'inbounds.set', 'listen.reality'},
    'server-names': {'reality.settings'},
    'share-host': {'reality.share', 'record.consistent'},
    'exclude-sub': {'reality.share'},
    'host-domain': {'reality.hosts'},
    'forwarder-dest': {'forwarder.settings'},
    'forwarder-target': {'forwarder.settings'},
    'forwarder-listen': {'inbounds.set', 'listen.forwarder'},
    'rules-order': {'routing.rules'},
    'rules-cn': {'routing.rules'},
    'outbound-blocked': {'routing.outbounds'},
    'api-listen': {'listen.api'},
    'metrics-listen': {'listen.metrics'},
    'client-flow': {'clients.flow'},
    'client-limit-ip': {'clients.limit-ip'},
    'sub-listen': {'sub.listen', 'listen.sub'},
    'sub-domain': {'sub.domain', 'sub.uri', 'record.consistent'},
    'sub-uri': {'sub.uri'},
    'sub-clash': {'sub.clash'},
    'sub-remark': {'sub.remark'},
    'api-token': {'secrets.api-tokens': 'WARN'},
    'install-result': {'secrets.install-result'},
    'state-perms': {'state.perms'},
    'record-node-ip': {'record.consistent'},
}
REPORT_LINE = re.compile(r'^\[(PASS|FAIL|WARN|SKIP|INFO)\] (\S+)', re.M)


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, **kwargs)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class Timings:
    def __init__(self, path):
        self.path = path
        self.items = {}

    def measure(self, name, func, *args):
        start = time.monotonic()
        try:
            return func(*args)
        finally:
            self.items[name] = round(time.monotonic() - start, 1)
            self.path.write_text(json.dumps(self.items, indent=2))
            print(f'TIME {name} {self.items[name]}s', flush=True)


class Guest:
    """One boot of a guest disk, with the seed attached and SSH forwarded."""

    def __init__(self, ctx, label, disk):
        self.ctx = ctx
        self.label = label
        self.disk = disk
        self.evidence = ctx.evidence / label
        self.evidence.mkdir()
        # Guest evidence directories written in this boot; overlays also hold
        # those of their backing disks, which were collected there.
        self.collected = []
        self.vm = None
        self.serial = None

    def __enter__(self):
        ctx = self.ctx
        qemu = ['qemu-system-x86_64', '-accel', 'kvm' if ctx.kvm else 'tcg', '-cpu', ctx.cpu,
                '-smp', str(ctx.vcpus), '-m', str(ctx.ram_mib), '-nographic',
                '-drive', f'file={self.disk},if=virtio,format=qcow2',
                '-drive', f'file={ctx.work / "seed.img"},if=virtio,format=raw',
                # No IPv6 from user networking: the main configuration is IPv4 only (verification plan 3.3).
                '-nic', f'user,model=virtio-net-pci,ipv6=off,hostfwd=tcp:127.0.0.1:{SSH_PORT}-:22']
        self.serial = (self.evidence / 'serial.log').open('wb')
        self.vm = subprocess.Popen(qemu, stdin=subprocess.DEVNULL, stdout=self.serial, stderr=subprocess.STDOUT)
        try:
            ctx.timings.measure(f'{self.label}.ready', self.wait, 'test -f /root/vps-cloud-ready')
        except BaseException:
            self.__exit__()
            raise
        return self

    def __exit__(self, *exc):
        try:
            if self.vm.poll() is None:
                self.collect()
        finally:
            if self.vm.poll() is None:
                self.vm.terminate()
                try:
                    self.vm.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    self.vm.kill()
                    self.vm.wait()
            self.serial.close()
        return False

    def ssh(self, command, **kwargs):
        return subprocess.run(self.ctx.ssh + [command], **kwargs)

    def wait(self, command='true', timeout=1800):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.vm.poll() is not None:
                raise RuntimeError(f'QEMU exited; see {self.label}/serial.log')
            try:
                result = self.ssh(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
            except subprocess.TimeoutExpired:
                continue
            if b'REMOTE HOST IDENTIFICATION HAS CHANGED' in result.stderr:
                raise RuntimeError('guest host key mismatch')
            if result.returncode == 0:
                return result.stdout.decode().strip()
            time.sleep(5)
        raise TimeoutError(f'guest {self.label} not ready; see serial.log')

    def boot_id(self):
        return self.wait('cat /proc/sys/kernel/random/boot_id')

    def wait_boot(self, old_boot_id):
        deadline = time.monotonic() + 1800
        while self.boot_id() == old_boot_id:
            if time.monotonic() > deadline:
                raise TimeoutError(f'guest {self.label} did not reboot')
            time.sleep(5)

    def reboot(self):
        old = self.boot_id()
        self.ssh('systemctl reboot', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        self.ctx.timings.measure(f'{self.label}.reboot', self.wait_boot, old)

    def upload(self, bundle):
        with bundle.open('rb') as f:
            run(self.ctx.ssh + [f'rm -rf {BUNDLE} && install -d -m 0755 {BUNDLE} && '
                                f'tar --no-same-owner -xf - -C {BUNDLE}'], stdin=f, timeout=120)

    def read_markers(self):
        """The guest's leak markers, kept in memory only."""
        try:
            result = self.ssh(f'cat {GUEST_MARKERS} 2>/dev/null || true', stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=60)
        except subprocess.TimeoutExpired:
            return False
        self.ctx.markers.update(m for m in result.stdout.decode(errors='replace').splitlines() if len(m) >= 8)
        return result.returncode == 0

    def show(self, title, text, lines=80):
        """The end of an output on the console, test secrets redacted."""
        self.read_markers()
        tail = '\n'.join(text.splitlines()[-lines:])
        print(f'--- {self.label} {title}\n{self.ctx.redact(tail)}', flush=True)

    def phase(self, name, *args, required=False, timeout=1800, script='m1.sh'):
        """Run one phase of tests/guest/SCRIPT in a new session. A failed
        phase fails the run; a required one also stops it."""
        words = (name,) + args
        title = ' '.join(words)
        self.collected.append('-'.join(words))
        print('START', self.label, title, flush=True)
        log_path = self.evidence / ('-'.join(words) + '.log')
        command = f'bash {BUNDLE}/tests/guest/{script} {title}'

        def body():
            with log_path.open('wb') as log:
                return subprocess.run(self.ctx.ssh + [command], stdout=log, stderr=subprocess.STDOUT,
                                      timeout=timeout).returncode
        try:
            status = self.ctx.timings.measure(f'{self.label}.{title}', body)
        except subprocess.TimeoutExpired:
            status = f'timeout after {timeout} s'
        if status == 0:
            print('PASS', self.label, title, flush=True)
            return True
        self.show(f'{title}: exit {status}', log_path.read_text(errors='replace'))
        message = f'{self.label}: phase {title} failed ({status})'
        if required:
            raise RuntimeError(message)
        self.ctx.fail(message)
        return False

    def command(self, name, command, timeout=600):
        """Run one command as root in a new session; keep its output as evidence."""
        result = subprocess.run(self.ctx.ssh + [command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=timeout)
        output = result.stdout.decode(errors='replace')
        (self.evidence / f'{name}.log').write_text(output)
        self.show(f'{name}: exit {result.returncode}', output)
        return result.returncode, output

    def interactive(self, name, command, timeout=1800):
        """Run COMMAND on a pseudo-terminal in a new root session and type
        "yes" when vps-hardening apply asks for it, as the administrator would."""
        log_path = self.evidence / f'{name}.log'
        proc = subprocess.Popen(self.ctx.ssh_as(tty=True) + [command], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        watchdog = threading.Timer(timeout, proc.kill)
        watchdog.start()
        output = bytearray()
        answered = False
        try:
            with log_path.open('wb') as log:
                while chunk := proc.stdout.read1(4096):
                    log.write(chunk)
                    log.flush()
                    output += chunk
                    if not answered and APPLY_PROMPT in output:
                        proc.stdin.write(b'yes\n')
                        proc.stdin.flush()
                        answered = True
            proc.wait()
        finally:
            watchdog.cancel()
            try:
                proc.stdin.close()
            except OSError:
                pass
        text = output.decode(errors='replace')
        self.show(f'{name}: exit {proc.returncode}', text)
        return proc.returncode, text

    def collect(self):
        """Leak markers, then the evidence of this boot. A failed collection
        fails the run (verification plan 6)."""
        if not self.read_markers():
            self.ctx.fail(f'{self.label}: could not read the leak markers')
        if not self.collected:
            return
        names = ' '.join(shlex.quote(n) for n in self.collected)
        try:
            result = self.ssh(f'cd {GUEST_EVIDENCE} && tar -cf - -- {names}', stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=120)
        except subprocess.TimeoutExpired:
            self.ctx.fail(f'{self.label}: evidence collection timed out')
            return
        if result.stdout:
            try:
                with tarfile.open(fileobj=io.BytesIO(result.stdout)) as tar:
                    tar.extractall(self.evidence / 'guest', filter='data')
            except tarfile.TarError as e:
                self.ctx.fail(f'{self.label}: evidence archive unreadable: {e}')
        if result.returncode != 0:
            self.ctx.fail(f'{self.label}: evidence collection failed: '
                          f'{result.stderr.decode(errors="replace").strip()}')

    def poweroff(self):
        self.collect()
        self.ssh('systemctl poweroff', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        self.vm.wait(timeout=600)


class Context:
    def __init__(self, suite):
        self.suite = suite
        self.work = WORK
        self.work.mkdir(parents=True, exist_ok=False)
        os.chmod(self.work, 0o700)
        self.evidence = self.work / 'evidence'
        self.evidence.mkdir()
        self.timings = Timings(self.evidence / 'timings.json')
        self.kvm = os.access('/dev/kvm', os.R_OK | os.W_OK)
        self.cpu = 'host' if self.kvm else 'max'
        self.vcpus, self.ram_mib = 2, 2048
        (self.evidence / 'hypervisor.json').write_text(json.dumps({
            'suite': suite, 'platform': 'debian13', 'arch': 'amd64', 'acceleration': 'kvm' if self.kvm else 'tcg',
            'cpu': self.cpu, 'vcpus': self.vcpus, 'ram_mib': self.ram_mib}, indent=2))
        self.ssh_opts = []
        self.ssh = []
        # Test secrets read from the guests (verification plan 3.4).
        self.markers = set()
        self.failures = []

    def fail(self, message):
        print('FAIL', message, flush=True)
        self.failures.append(message)

    def expect(self, condition, message):
        if condition:
            print('PASS', message, flush=True)
        else:
            self.fail(message)
        return condition

    def require(self, condition, message):
        if not self.expect(condition, message):
            raise RuntimeError(message)

    def redact(self, text):
        for marker in sorted(self.markers, key=len, reverse=True):
            text = text.replace(marker, '<redacted>')
        return text

    def image(self):
        spec = json.loads((ROOT / 'tests/platform-images.json').read_text())['debian13']['amd64']
        (self.evidence / 'image.json').write_text(json.dumps(spec, indent=2))
        image = self.work / 'base.qcow2'
        # Bounded like the fixture download; the digest check below rejects a short file.
        with urllib.request.urlopen(spec['url'], timeout=60) as response, image.open('wb') as out:
            shutil.copyfileobj(response, out)
        with image.open('rb') as f:
            digest = hashlib.file_digest(f, spec['algorithm']).hexdigest()
        if digest != spec['digest']:
            raise RuntimeError('official image checksum mismatch')
        return image

    def overlay(self, backing, name):
        disk = self.work / name
        run(['qemu-img', 'create', '-q', '-f', 'qcow2', '-F', 'qcow2', '-b', str(backing), str(disk), '12G'])
        return disk

    def seed(self):
        for name in ('client', 'host'):
            run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', f'vps-{name}', '-f', str(self.work / name)])
        # Root logs in with the test key (verification plan 3.2); cloud-init's
        # default user keeps uid 1000 for the unprivileged cases.
        user_data = {
            'disable_root': False,
            'ssh_authorized_keys': [(self.work / 'client.pub').read_text().strip()],
            'ssh_keys': {'ed25519_private': (self.work / 'host').read_text(),
                         'ed25519_public': (self.work / 'host.pub').read_text().strip()},
            'runcmd': [['touch', '/root/vps-cloud-ready']],
        }
        (self.work / 'user-data').write_text('#cloud-config\n' + json.dumps(user_data))
        (self.work / 'meta-data').write_text('instance-id: vps-m1\nlocal-hostname: vps-ci\n')
        run(['cloud-localds', str(self.work / 'seed.img'), str(self.work / 'user-data'), str(self.work / 'meta-data')])
        (self.work / 'known-hosts').write_text(f'[127.0.0.1]:{SSH_PORT} ' + (self.work / 'host.pub').read_text())
        self.ssh_opts = ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                         '-o', 'UserKnownHostsFile=' + str(self.work / 'known-hosts'),
                         '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=10',
                         '-o', 'LogLevel=ERROR', '-p', str(SSH_PORT)]
        self.ssh = self.ssh_as()

    def ssh_as(self, tty=False):
        return (['ssh', '-i', str(self.work / 'client'), '-o', 'IdentitiesOnly=yes'] + self.ssh_opts +
                (['-tt'] if tty else []) + ['root@127.0.0.1'])

    def bundle(self):
        """The tool, its installer, the guest tests and the verified fixture installers."""
        path = self.work / 'bundle.tar'
        files = sorted([ROOT / 'install.sh'] + [
            p for d in ('bin', 'lib', 'tests/guest') for p in (ROOT / d).rglob('*')
            if p.is_file() and '__pycache__' not in p.parts])
        fixtures = {}
        for name, (url, digest) in FIXTURES.items():
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            if sha256(data) != digest:
                raise RuntimeError(f'{name}: checksum mismatch')
            fixtures[name] = data
        fixtures['SHA256SUMS'] = ''.join(f'{FIXTURES[n][1]}  {n}\n' for n in sorted(FIXTURES)).encode()
        (self.evidence / 'fixtures.json').write_text(json.dumps(
            {name: {'url': url, 'sha256': digest} for name, (url, digest) in FIXTURES.items()}, indent=2))
        with tarfile.open(path, 'w') as tar:
            def add(name, data, mode):
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = len(data), mode, int(time.time())
                tar.addfile(info, io.BytesIO(data))
            dirs = {'fixtures'}
            for p in files:
                dirs.update(parent.as_posix() for parent in p.relative_to(ROOT).parents if str(parent) != '.')
            for d in sorted(dirs):
                info = tarfile.TarInfo(d)
                info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, int(time.time())
                tar.addfile(info)
            for p in files:
                rel = p.relative_to(ROOT).as_posix()
                add(rel, p.read_bytes(), 0o755 if rel.startswith('bin/') or rel.endswith('.sh') else 0o644)
            for name, data in fixtures.items():
                add(f'fixtures/{name}', data, 0o644)
        return path

    def leak_scan(self):
        """Every evidence file, serial logs included, against the test secrets
        (verification plan 3.4, 6). A hit fails the run, and the file is
        moved out of the evidence so that it is not uploaded."""
        needles = {m.encode() for m in self.markers}
        client = self.work / 'client'
        if client.exists():
            needles |= {line.encode() for line in client.read_text().splitlines()
                        if line and not line.startswith('-----')}
        hits = []
        for path in sorted(p for p in self.evidence.rglob('*') if p.is_file()):
            data = path.read_bytes()
            if any(needle in data for needle in needles):
                rel = path.relative_to(self.evidence)
                target = self.work / 'quarantine' / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(path, target)
                hits.append(rel.as_posix())
        print(f'leak scan: {len(needles)} markers, {len(hits)} files with hits', flush=True)
        if hits:
            (self.evidence / 'LEAKS.txt').write_text(''.join(f'{h}\n' for h in hits))
            self.fail('test secrets found in ' + ' '.join(hits))

    def manifest(self):
        """Size and SHA-256 of every evidence file (verification plan 6)."""
        entries = {}
        for path in sorted(p for p in self.evidence.rglob('*') if p.is_file()):
            data = path.read_bytes()
            entries[path.relative_to(self.evidence).as_posix()] = {'size': len(data), 'sha256': sha256(data)}
        (self.evidence / 'MANIFEST.json').write_text(json.dumps(entries, indent=1, sort_keys=True))


def verdicts(ctx, path):
    """Item -> level of one check output, or None when there is no usable output."""
    try:
        text = path.read_text(errors='replace')
    except OSError:
        ctx.fail(f'no check output at {path.relative_to(ctx.evidence)}')
        return None
    found = {}
    for level, item in REPORT_LINE.findall(text):
        if item in found:
            ctx.fail(f'{path.relative_to(ctx.evidence)}: item {item} reported twice')
            return None
        found[item] = level
    return found


def record(ctx, name, data):
    out = ctx.evidence / 'vt71'
    out.mkdir(exist_ok=True)
    (out / f'{name}.json').write_text(json.dumps(data, indent=1, sort_keys=True))


def transitions(base, got):
    return {item: [base.get(item), got.get(item)] for item in sorted(set(base) | set(got))
            if base.get(item) != got.get(item)}


def judge_baseline(ctx, got, table=BASELINE, section='9.5', title='VT-71 baseline', name='baseline'):
    if got is None:
        ctx.fail(f'{title}: no check output')
        return
    want = {item: level for level, items in table.items() for item in items.split()}
    diff = transitions(want, got)
    record(ctx, name, {'verdicts': got, f'differences from detailed design {section} [expected, actual]': diff})
    ctx.expect(not diff, f'{title} as in detailed design {section}' + (f'; differences: {diff}' if diff else ''))


def judge_injection(ctx, name, base, got, expected):
    """Only the expected items leave PASS, each for its level (FAIL when
    EXPECTED is a set); the item set is unchanged."""
    if base is None or got is None:
        ctx.fail(f'VT-71 {name}: no baseline or no check output')
        return
    if isinstance(expected, set):
        expected = dict.fromkeys(expected, 'FAIL')
    expected = dict(sorted(expected.items()))
    changed = transitions(base, got)
    left_pass = {item for item, (before, _) in changed.items() if before == 'PASS'}
    ok = (set(got) == set(base) and left_pass == set(expected) and
          all(got[item] == level for item, level in expected.items()))
    record(ctx, name, {'expected from PASS': expected, 'transitions [baseline, injected]': changed,
                       'result': 'PASS' if ok else 'FAIL'})
    ctx.expect(ok, f'VT-71 {name}: from PASS exactly {expected}' + ('' if ok else f'; got {changed}'))


def judge_vt73(ctx, base, got):
    """The program replaced: xui.version and xui.files fail, the database items are SKIP."""
    if base is None or got is None:
        ctx.fail('VT-73: no baseline or no check output')
        return
    changed = transitions(base, got)
    failed = {item for item, (before, after) in changed.items() if before == 'PASS' and after == 'FAIL'}
    skipped = ['xui.db'] + db_items()
    ok = (set(got) == set(base) and failed == {'xui.version', 'xui.files'} and
          all(got.get(item) == 'SKIP' for item in skipped))
    record(ctx, 'program', {'transitions [baseline, replaced program]': changed, 'result': 'PASS' if ok else 'FAIL'})
    ctx.expect(ok, 'VT-73 and VT-71 program: xui.version and xui.files fail, database items SKIP' +
               ('' if ok else f'; got {changed}'))


def main_config(ctx, image):
    """Verification plan 3.2 and detailed design 9.2, in the companions' documented order."""
    disk = ctx.overlay(image, 'main.qcow2')
    with Guest(ctx, 'main', disk) as guest:
        guest.upload(ctx.bundle())
        guest.phase('prepare', required=True)
        guest.phase('tuning', required=True)
        guest.reboot()
        guest.phase('tuning-verify', required=True)
        guest.phase('hardening-install', required=True)
        status, output = guest.interactive('hardening-apply', f'{VH} apply')
        ctx.require(status == 0 and APPLIED in output, 'vps-hardening apply finished and awaits confirmation')
        status, output = guest.command('hardening-confirm', f'{VH} confirm')
        ctx.require(status == 0 and CONFIRMED in output, 'vps-hardening confirmed from a new root session')
        guest.phase('installer', required=True)
        guest.phase('main-config', required=True)
        guest.poweroff()
    return disk


def m1_preflight(ctx, main):
    disk = ctx.overlay(main, 'preflight.qcow2')
    with Guest(ctx, 'preflight', disk) as guest:
        guest.phase('network', required=True)
        guest.phase('vt80')
        guest.collected.append('standin')
        for name in ('vt01', 'vt03', 'vt04', 'vt05'):
            guest.phase(name)
        guest.poweroff()
    # The input file, the test token and a fresh target-check result are on this disk.
    for name in ('vt05-verify', 's1', 's2', 's3'):
        with Guest(ctx, name, ctx.overlay(disk, f'{name}.qcow2')) as guest:
            guest.phase(name)
            guest.poweroff()


def m1_check(ctx, main):
    xui = ctx.overlay(main, 'xui.qcow2')
    with Guest(ctx, 'xui', xui) as guest:
        guest.phase('xui', required=True)
        guest.poweroff()
    with Guest(ctx, 'baseline', ctx.overlay(xui, 'baseline.qcow2')) as guest:
        guest.phase('baseline')
        guest.phase('vt73')
        guest.poweroff()
    baseline = verdicts(ctx, ctx.evidence / 'baseline/guest/baseline/check-1.out')
    judge_baseline(ctx, baseline)
    judge_vt73(ctx, baseline, verdicts(ctx, ctx.evidence / 'baseline/guest/vt73/vt73.out'))
    with Guest(ctx, 'dbstate', ctx.overlay(xui, 'dbstate.qcow2')) as guest:
        guest.phase('vt72')
        guest.phase('vt75')
        guest.poweroff()
    for name, expected in INJECTIONS.items():
        label = f'inject-{name}'
        with Guest(ctx, label, ctx.overlay(xui, f'{label}.qcow2')) as guest:
            guest.phase('inject', name)
            guest.poweroff()
        judge_injection(ctx, name, baseline, verdicts(ctx, ctx.evidence / f'{label}/guest/{label}/check.out'),
                        expected)


def m2_deploy(ctx, main):
    disk = ctx.overlay(main, 'm2.qcow2')
    with Guest(ctx, 'm2', disk) as guest:
        guest.phase('network', required=True)
        guest.phase('m2-prep', required=True, script='m2.sh')
        guest.phase('vt11', script='m2.sh')
        guest.poweroff()
    # The input file, the test token and a fresh target-check result are on this disk.
    names = ('vt10', 'vt12', 'vt13-fail', 'vt15-inbound', 'vt15-client', 'vt15-settings', 'vt17-lost',
             'vt17-unsent', 'vt18-refused', 'vt18-lost', 'vt18-short-id')
    for name in names:
        with Guest(ctx, name, ctx.overlay(disk, f'{name}.qcow2')) as guest:
            guest.phase(name, script='m2.sh')
            guest.poweroff()
    judge_short_ids(ctx, names)


def judge_short_ids(ctx, names):
    """VT-16: every deploy of the run generated its own shortId. The guests
    archive only a digest of it."""
    digests = {}
    for name in names:
        for path in sorted((ctx.evidence / name / 'guest' / name).glob('*sid-digest.txt')):
            digests[f'{name}/{path.name}'] = path.read_text().strip()
    lines = ''.join(f'{k} {v}\n' for k, v in sorted(digests.items()))
    (ctx.evidence / 'vt16-short-ids.txt').write_text(lines)
    if len(digests) < 3:
        ctx.fail(f'VT-16: only {len(digests)} shortId digests to compare')
    elif len(set(digests.values())) != len(digests):
        ctx.fail('VT-16: two deploys of the run have the same shortId')


def m2_check(ctx, main):
    disk = ctx.overlay(main, 'm2.qcow2')
    with Guest(ctx, 'm2', disk) as guest:
        guest.phase('network', required=True)
        guest.phase('m2-prep', required=True, script='m2.sh')
        guest.phase('vt70-deploy', required=True, script='m2.sh')
        guest.poweroff()
    judge_baseline(ctx, verdicts(ctx, ctx.evidence / 'm2/guest/vt70-deploy/check.out'), M2_BASELINE, '9.6',
                   'VT-70 right after the deploy', 'vt70-deploy')
    # The deployed host; the baseline and each injection boot an overlay of it.
    with Guest(ctx, 'vt70', ctx.overlay(disk, 'vt70.qcow2')) as guest:
        guest.phase('vt70', script='m2.sh')
        guest.poweroff()
    baseline = verdicts(ctx, ctx.evidence / 'vt70/guest/vt70/check.out')
    judge_baseline(ctx, baseline, M2_BASELINE, '9.6', 'VT-70 and the VT-71 baseline of M2')
    for name, expected in M2_INJECTIONS.items():
        label = f'vt71-{name}'
        with Guest(ctx, label, ctx.overlay(disk, f'{label}.qcow2')) as guest:
            guest.phase('vt71', name, script='m2.sh')
            guest.poweroff()
        judge_injection(ctx, name, baseline, verdicts(ctx, ctx.evidence / f'{label}/guest/{label}/check.out'),
                        expected)


SUITES = {'m1-preflight': m1_preflight, 'm1-check': m1_check, 'm2-deploy': m2_deploy, 'm2-check': m2_check}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--suite', choices=sorted(SUITES), required=True)
    args = parser.parse_args()
    ctx = Context(args.suite)
    try:
        image = ctx.timings.measure('image', ctx.image)
        ctx.seed()
        SUITES[args.suite](ctx, main_config(ctx, image))
    except Exception:
        traceback.print_exc()
        ctx.fail('the suite stopped early')
    # Verification plan 6: the whole archive, of a failed run too, before the upload.
    ctx.leak_scan()
    if ctx.failures:
        (ctx.evidence / 'FAILURES.txt').write_text(''.join(f'{f}\n' for f in ctx.failures))
    else:
        (ctx.evidence / 'COMPLETED').write_text(f'PASS {args.suite}\n')
    ctx.manifest()
    if ctx.failures:
        print(f'FAIL {args.suite}: {len(ctx.failures)} failures', flush=True)
        raise SystemExit(1)
    print('PASS', args.suite, flush=True)


if __name__ == '__main__':
    main()
