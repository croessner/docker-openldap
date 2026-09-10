#!/usr/bin/env python3
"""Run the real workflow update steps and merge independent PRs in both orders."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = (ROOT / '.github/workflows/openldap-upstream-check.yml').read_text()


def step(name):
    section = WORKFLOW.split('      - name: ' + name + '\n', 1)[1]
    section = section.split('\n      - name:', 1)[0]
    return textwrap.dedent(section.split('        run: |\n', 1)[1])


def run(*args, env=None):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, env=env).strip()


def pins(channel):
    return dict(line.split('=', 1) for line in Path(f'versions/openldap-{channel}.env').read_text().splitlines())


def update(channel, kind):
    old = pins(channel)
    version = old['OPENLDAP_VERSION']
    if kind == 'version':
        series, patch = version.rsplit('.', 1)
        version = f'{series}.{int(patch) + 1}'
    env = dict(os.environ, CHANNEL=channel, MANIFEST=f'versions/openldap-{channel}.env',
               OLD_VERSION=old['OPENLDAP_VERSION'], OLD_SHA256=old['OPENLDAP_SHA256'],
               OLD_REVISION=old['IMAGE_REVISION'], NEW_VERSION=version,
               NEW_SHA256='a' * 64, CHANGE_KIND=kind)
    run('bash', '-c', step('Update OpenLDAP pin'), env=env)
    actual = pins(channel)
    assert actual['OPENLDAP_VERSION'] == version
    assert actual['IMAGE_REVISION'] == ('1' if kind == 'version' else str(int(old['IMAGE_REVISION']) + 1))
    assert actual['OPENLDAP_SHA256'] == 'a' * 64
    if channel == 'lts':
        for key in ('OPENLDAP_VERSION', 'OPENLDAP_SHA256', 'IMAGE_REVISION'):
            assert f'ARG {key}={actual[key]}\n' in Path('Dockerfile').read_text()
            assert '${' + key + ':-' + actual[key] + '}' in Path('examples/docker-compose.yml').read_text()
    changed = set(run('git', 'diff', '--name-only').splitlines())
    expected = {f'versions/openldap-{channel}.env'}
    if channel == 'lts':
        expected |= {'Dockerfile', 'examples/docker-compose.yml'}
    assert changed == expected, (changed, expected)


with tempfile.TemporaryDirectory(prefix='openldap-update-test-') as directory:
    repo = Path(directory) / 'repo'
    repo.mkdir()
    for name in ('versions', 'scripts', 'examples'):
        shutil.copytree(ROOT / name, repo / name)
    for name in ('README.md', 'Dockerfile'):
        shutil.copy2(ROOT / name, repo / name)
    os.chdir(repo)
    os.environ['GITHUB_OUTPUT'] = str(Path(directory) / 'outputs')
    os.environ.update(GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                      GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
    # GitHub uses GNU sed; adapt only its -i spelling for local macOS execution.
    if sys.platform == 'darwin':
        bindir = Path(directory) / 'bin'
        bindir.mkdir()
        shim = bindir / 'sed'
        shim.write_text('#!/bin/sh\nif [ "$1" = -i ]; then shift; exec /usr/bin/sed -i "" "$@"; fi\nexec /usr/bin/sed "$@"\n')
        shim.chmod(0o755)
        os.environ['PATH'] = str(bindir) + os.pathsep + os.environ['PATH']
    run('git', 'init', '-q')
    run('git', 'add', '.')
    run('git', 'commit', '-qm', 'fixture')
    base = run('git', 'rev-parse', 'HEAD')
    for kind in ('version', 'checksum'):
        for channel in ('lts', 'stable'):
            run('git', 'checkout', '-qB', f'{kind}-{channel}', base)
            update(channel, kind)
            run('git', 'add', '.')
            run('git', 'commit', '-qm', f'{kind} {channel}')
        for first, second in (('lts', 'stable'), ('stable', 'lts')):
            run('git', 'checkout', '-qB', 'combined', f'{kind}-{first}')
            run('git', 'merge', '--no-edit', f'{kind}-{second}')
            for channel in (first, second):
                assert pins(channel)['OPENLDAP_SHA256'] == 'a' * 64
            assert Path('README.md').read_bytes() == (ROOT / 'README.md').read_bytes()
    # Alpine intentionally increments both revisions, but must not edit prose.
    before = {channel: pins(channel) for channel in ('lts', 'stable')}
    alpine = dict(line.split('=', 1) for line in Path('versions/alpine.env').read_text().splitlines())
    env = dict(os.environ, OLD_VERSION=alpine['ALPINE_VERSION'], OLD_DIGEST=alpine['ALPINE_DIGEST'],
               NEW_VERSION='3.99.1', NEW_DIGEST='sha256:' + 'b' * 64)
    run('bash', '-c', step('Update Alpine pin'), env=env)
    for channel in before:
        assert int(pins(channel)['IMAGE_REVISION']) == int(before[channel]['IMAGE_REVISION']) + 1
        assert pins(channel)['OPENLDAP_VERSION'] == before[channel]['OPENLDAP_VERSION']
    assert Path('README.md').read_bytes() == (ROOT / 'README.md').read_bytes()
print('upstream update contract OK: version/checksum PRs merge in both orders; Alpine preserves both pins')
