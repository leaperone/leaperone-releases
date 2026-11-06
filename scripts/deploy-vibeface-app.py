#!/usr/bin/env python3
"""Verify the published app component and its deployed HTTP entry points."""
import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

sys.dont_write_bytecode = True


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identity(tag, sha):
    require(re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', tag),
            'an exact stable product tag is required')
    require(re.fullmatch(r'[0-9a-f]{40}', sha), 'a full source SHA is required')


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def prepare(source, destination, tag, sha):
    identity(tag, sha)
    require(run('git', '-C', str(source), 'rev-parse', tag + '^{commit}') == sha,
            'source SHA does not match the release tag')
    subprocess.run(['git', '-C', str(source), 'merge-base', '--is-ancestor', sha, 'origin/main'], check=True)
    require(run('git', '-C', str(source), 'rev-parse', 'HEAD') == sha, 'checkout does not match release source')
    spec = importlib.util.spec_from_file_location('release', source / 'scripts/release.py')
    release = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(release)
    metadata = json.loads(run('gh', 'release', 'view', tag, '--repo', 'leaperone/vibeface',
                              '--json', 'isDraft,isPrerelease'))
    require(not metadata['isDraft'] and not metadata['isPrerelease'], 'release must be public and stable')
    destination.mkdir(parents=True)
    subprocess.run(['gh', 'release', 'download', tag, '--repo', 'leaperone/vibeface',
                    '--pattern', 'release.json', '--dir', str(destination)], check=True)
    expected = dict(app='product', tag=tag, source_commit=sha, version=tag[1:], channel='stable')
    manifest = json.loads((destination / 'release.json').read_text())
    release.verify_release_identity(manifest)
    require(all(manifest[key] == value for key, value in expected.items()), 'product release identity mismatch')
    archive_name = f'vibeface-app-{tag[1:]}.tar.gz'
    selected = {archive_name, archive_name + '.sha256'}
    seen = set()
    for asset in manifest['assets']:
        name = asset['name']
        release.safe_name(name)
        require('/' not in name and name not in seen, 'invalid or duplicate product asset')
        seen.add(name)
    require(selected <= seen, 'product release is missing the Web component')
    for name in sorted(selected):
        subprocess.run(['gh', 'release', 'download', tag, '--repo', 'leaperone/vibeface',
                        '--pattern', name, '--dir', str(destination)], check=True)
        asset = next(asset for asset in manifest['assets'] if asset['name'] == name)
        file = destination / name
        require(file.is_file() and not file.is_symlink() and file.stat().st_size == asset['size']
                and release.digest(file) == asset['sha256'], 'Web component download differs from product manifest')
    archive = destination / archive_name
    require((destination / (archive_name + '.sha256')).read_text() == f'{release.digest(archive)}  {archive_name}\n',
            'Web component checksum mismatch')
    component = release.unpack(archive, destination / 'unpacked')
    release.verify_component(component, 'app', dict(expected, app='app'))
    site = component / 'web'
    require((site / 'index.html').is_file(), 'app index is missing')
    return site


def activate(archive, checksum, releases, config, tag, sha, base):
    import os
    import tarfile
    import tempfile
    identity(tag, sha)
    require(re.fullmatch(r'[0-9a-f]{64}', checksum), 'invalid archive checksum')
    require(archive.stat().st_size <= 384 * 1024 * 1024, 'uploaded archive exceeds size limit')
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == checksum, 'uploaded archive changed')
    require(all(path.is_absolute() and re.fullmatch(r'/[a-zA-Z0-9_./-]+', str(path)) and '..' not in path.parts
                for path in (releases, config)) and not config.is_symlink(), 'invalid deployment paths')
    url = urlsplit(base)
    require(url.scheme == 'https' and url.hostname and not url.username and not url.password
            and url.path in ('', '/') and not url.query and not url.fragment, 'invalid production HTTPS origin')
    original = config.read_text()
    hostname = urlsplit(base).hostname
    names = re.findall(r'^\s*server_name\s+([^;]+);', original, re.M)
    require(names and all(name.strip() == hostname for name in names), 'configuration does not exclusively serve the app')
    roots = re.findall(r'^\s*root\s+([^;]+);', original, re.M)
    require(len(roots) == 1 and Path(roots[0]).parent == releases
            and re.fullmatch(r'[0-9a-f]{40}', Path(roots[0]).name), 'existing root is not a versioned app release')
    old_sources = re.findall(r'^\s*add_header\s+X-Vibeface-Source\s+"([0-9a-f]{40})"\s+always;', original, re.M)
    require(old_sources == [Path(roots[0]).name], 'current source header does not match the active release')
    require(releases.is_dir(), 'existing releases directory is missing')
    current = releases.parent / 'current'
    require(current.is_symlink() and current.resolve() == Path(roots[0]).resolve(), 'current link does not match Nginx root')
    with tempfile.TemporaryDirectory(prefix='.app-', dir=releases) as temporary:
        staging = Path(temporary)
        with tarfile.open(archive) as source:
            members = source.getmembers()
            require(0 < len(members) <= 4096 and sum(item.size for item in members) <= 512 * 1024 * 1024,
                    'invalid uploaded archive size')
            for item in members:
                path = Path(item.name)
                require(not path.is_absolute() and '..' not in path.parts and (item.isfile() or item.isdir()),
                        'unsafe uploaded archive entry')
                item.mode &= 0o777
            source.extractall(staging, members=members)
        site = staging / f'vibeface-app-{tag[1:]}' / 'web'
        require((site / 'index.html').is_file(), 'uploaded app index is missing')
        policy = json.loads((site / '.vibeface-build.json').read_text())['content_security_policy']
        require(isinstance(policy, str) and policy and not any(c in policy for c in '\r\n"\\$'), 'unsafe content security policy')
        target = releases / sha
        if target.exists():
            def hashes(directory):
                require(not any(p.is_symlink() for p in directory.rglob('*')), 'release contains a symlink')
                return {p.relative_to(directory): hashlib.sha256(p.read_bytes()).digest()
                        for p in directory.rglob('*') if p.is_file()}
            require(not target.is_symlink() and hashes(target) == hashes(site), 'existing immutable release differs')
        else:
            site.rename(target)
    updated, count = re.subn(r'^(\s*root\s+)[^;]+;', lambda m: m[1] + str(target) + ';', original, flags=re.M)
    require(count == 1, 'configuration needs one root directive')
    for name, value in [('Content-Security-Policy', policy), ('X-Vibeface-Source', sha)]:
        updated, count = re.subn(r'^(\s*add_header\s+' + name + r'\s+)"[^"\n]*"(\s+always;)',
                                 lambda m: m[1] + '"' + value + '"' + m[2], updated, flags=re.M)
        require(count == 1, 'configuration needs one existing ' + name + ' directive')
    mode = config.stat().st_mode
    def write_config(content):
        descriptor, name = tempfile.mkstemp(prefix='.app-config-', dir=config.parent)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, 'w') as output:
                output.write(content)
            temporary.chmod(mode)
            temporary.replace(config)
        finally:
            temporary.unlink(missing_ok=True)
    require(config.read_text() == original and current.resolve() == Path(roots[0]).resolve(),
            'active app configuration changed during staging')
    write_config(updated)
    try:
        subprocess.run(['nginx', '-t'], check=True)
        subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
        parsed = urlsplit(base)
        response = subprocess.run(['curl', '--noproxy', '*', '--fail', '--silent', '--show-error', '--location', '--max-redirs', '0',
                                   '--max-time', '30', '--resolve', f'{parsed.hostname}:{parsed.port or 443}:127.0.0.1',
                                   base.rstrip('/') + '/'], check=True, capture_output=True).stdout
        require(hashlib.sha256(response).digest() == hashlib.sha256((target / 'index.html').read_bytes()).digest(),
                'local Nginx response differs from the staged app')
        descriptor, name = tempfile.mkstemp(prefix='.app-current-', dir=current.parent)
        os.close(descriptor)
        link = Path(name)
        link.unlink()
        try:
            link.symlink_to(target.relative_to(current.parent))
            link.replace(current)
        finally:
            link.unlink(missing_ok=True)
    except (ValueError, OSError, subprocess.CalledProcessError):
        write_config(original)
        subprocess.run(['nginx', '-t'], check=True)
        subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
        raise
    print('App release activated')


class Redirects(HTTPRedirectHandler):
    max_redirections = 3
    max_repeats = 1

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        origin = urlsplit(req.full_url)
        target = urlsplit(newurl)
        require((origin.scheme, origin.netloc) == (target.scheme, target.netloc), 'cross-origin redirect refused')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Assets(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = set()
        self.inline_scripts = []
        self.external_scripts = set()
        self.inline = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'script':
            self.inline = [] if 'src' not in attrs else None
            if attrs.get('src'):
                self.external_scripts.add(attrs['src'])
        path = attrs.get('src') if tag == 'script' else attrs.get('href') if tag == 'link' else None
        if path and path.startswith('/assets/'):
            self.paths.add(path)

    def handle_data(self, data):
        if self.inline is not None:
            self.inline.append(data)

    def handle_endtag(self, tag):
        if tag == 'script' and self.inline is not None:
            self.inline_scripts.append(''.join(self.inline))
            self.inline = None


def smoke(base, site, sha=None):
    require(urlsplit(base).scheme in ('http', 'https') and urlsplit(base).path in ('', '/'),
            'smoke URL must be an HTTP origin')
    opener = build_opener(Redirects())
    policy = json.loads((site / '.vibeface-build.json').read_text())['content_security_policy'] if sha else None

    index = (site / 'index.html').read_bytes()
    assets = Assets()
    assets.feed(index.decode())
    require(assets.paths, 'app index has no startup assets')

    def check(path, expected, html=False):
        with opener.open(Request(urljoin(base, path), headers={'Cache-Control': 'no-cache', 'User-Agent': 'Vibeface-Deploy-Smoke/1.0'}), timeout=30) as response:
            require(response.status == 200, 'HTTP smoke did not return 200')
            if html and sha:
                require(response.headers.get('X-Vibeface-Source') == sha, 'HTTP source header is stale')
                require(response.headers.get('Content-Security-Policy') == policy, 'HTTP content security policy is stale')
                require(response.headers.get('Cache-Control') == 'no-store', 'app shell must not be cached')
            limit = len(expected) + (64 * 1024 if html else 0)
            content = bytearray()
            while len(content) <= limit:
                chunk = response.read1(min(64 * 1024, limit + 1 - len(content)))
                if not chunk:
                    break
                content.extend(chunk)
            require(len(content) <= limit, 'HTTP response exceeds the smoke limit')
            if html:
                page = Assets()
                page.feed(content.decode())
                require(assets.paths <= page.paths and assets.external_scripts <= page.external_scripts,
                        'HTTP HTML is missing app startup assets')
                require(page.inline_scripts == assets.inline_scripts, 'HTTP inline bootstrap scripts changed')
                for source in page.external_scripts - assets.external_scripts:
                    address = urlsplit(source)
                    require(address.scheme == 'https' and address.netloc == 'static.cloudflareinsights.com'
                            and (address.path == '/beacon.min.js' or address.path.startswith('/beacon.min.js/')),
                            'HTTP HTML contains an unexpected external script')
            else:
                require(hashlib.sha256(content).digest() == hashlib.sha256(expected).digest(),
                        'HTTP asset does not match the deployed artifact')

    for path in ('/', '/connect', '/join'):
        check(path, index, html=True)
    for path in sorted(assets.paths):
        require('..' not in path.split('/'), 'unsafe asset URL')
        check(path, (site / path.lstrip('/')).read_bytes())
    print('HTTP smoke passed for app entry points and startup assets')


def self_test(source=None):
    import tempfile
    import threading
    Path('.artifacts').mkdir(exist_ok=True)
    from http.server import BaseHTTPRequestHandler, HTTPServer
    for tag, sha in [('app-v1.2.3', 'a' * 40), ('v1.2.3-rc.1', 'a' * 40), ('www-v1.2.3', 'a' * 40),
                     ('v01.2.3', 'a' * 40), ('v1.2.3', 'invalid')]:
        try:
            identity(tag, sha)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid release identity accepted')
    identity('v1.2.3', 'a' * 40)
    try:
        Redirects().redirect_request(Request('https://example.invalid/'), None, 302, '', {}, 'http://example.invalid/')
    except ValueError:
        pass
    else:
        raise AssertionError('HTTPS downgrade accepted')
    with tempfile.TemporaryDirectory(dir='.artifacts') as directory:
        site = Path(directory)
        (site / 'assets').mkdir()
        (site / 'index.html').write_text('<body><script>window.app = true;</script><script src="/assets/app.js"></script></body>')
        (site / 'assets/app.js').write_text('console.log("app")')
        (site / '.vibeface-build.json').write_text(json.dumps({'content_security_policy': "default-src 'self'"}))
        class Handler(BaseHTTPRequestHandler):
            mode = 'ok'
            def do_GET(self):
                if self.mode in ('loop', 'cross-origin'):
                    self.send_response(302)
                    self.send_header('Location', self.path if self.mode == 'loop' else 'https://example.invalid/')
                    self.end_headers(); return
                if self.mode == 'missing':
                    self.send_error(404); return
                self.send_response(200)
                self.send_header('X-Vibeface-Source', 'b' * 40 if self.mode == 'source' else 'a' * 40)
                self.send_header('Content-Security-Policy', 'stale' if self.mode == 'policy' else "default-src 'self'")
                self.send_header('Cache-Control', 'public' if self.mode == 'cache' else 'no-store')
                self.end_headers()
                body = (site / 'assets/app.js' if self.path.startswith('/assets/') else site / 'index.html').read_bytes()
                if self.mode == 'transformed':
                    body = body.replace(b'</body>', b'<script src="https://static.cloudflareinsights.com/beacon.min.js/fixture"></script></body>')
                elif self.mode == 'inline':
                    body = body.replace(b'window.app = true;', b'window.app = false;')
                elif self.mode == 'external':
                    body += b'<script src="https://other.invalid/script.js"></script>'
                self.wfile.write(b'stale' if self.mode == 'stale' else body)
            def log_message(self, *_args):
                pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            base = f'http://127.0.0.1:{server.server_port}'
            smoke(base, site, 'a' * 40)
            Handler.mode = 'transformed'
            smoke(base, site, 'a' * 40)
            for mode in ('loop', 'cross-origin', 'missing', 'stale', 'source', 'policy', 'cache', 'inline', 'external'):
                Handler.mode = mode
                try:
                    smoke(base, site, 'a' * 40)
                except (ValueError, HTTPError):
                    pass
                else:
                    raise AssertionError(f'{mode} smoke passed')
        finally:
            server.shutdown(); thread.join(); server.server_close()
    import tarfile
    from unittest.mock import patch
    with tempfile.TemporaryDirectory(dir='.artifacts') as directory:
        root = Path(directory).resolve()
        releases = root / 'releases'; releases.mkdir()
        previous = releases / ('0' * 40); previous.mkdir()
        (previous / 'index.html').write_text('previous')
        current = root / 'current'; current.symlink_to(previous)
        component = root / 'vibeface-app-1.2.3'; site = component / 'web'; site.mkdir(parents=True)
        (site / 'index.html').write_text('new app')
        (site / '.vibeface-build.json').write_text(json.dumps({'content_security_policy': "default-src 'self'"}))
        archive = root / 'release.tar.gz'
        with tarfile.open(archive, 'w:gz') as output:
            output.add(component, arcname=component.name)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        config = root / 'site.conf'
        config.write_text('map "$status:$uri" $cache { default "no-store"; }\n'
                          'server {\n    server_name example.invalid;\n    return 301 https://example.invalid$request_uri;\n}\nserver {\n'
                          '    server_name example.invalid;\n    root ' + str(previous) + ';\n'
                          '    add_header Content-Security-Policy "old-policy" always;\n'
                          '    add_header X-Vibeface-Source "' + '0' * 40 + '" always;\n'
                          '    location / { try_files $uri $uri/ /_shell.html; }\n}\n')
        original = config.read_text()
        fail = {'command': None, 'body': b'new app'}
        def fake_nginx(command, **_kwargs):
            if command == fail['command']:
                fail['command'] = None
                raise subprocess.CalledProcessError(1, command)
            if command[0] == 'curl':
                return type('Response', (), {'stdout': fail['body']})()
        with patch.object(subprocess, 'run', fake_nginx):
            activate(archive, checksum, releases, config, 'v1.2.3', 'a' * 40, 'https://example.invalid')
            expected = original.replace(str(previous), str(releases / ('a' * 40))).replace('old-policy', "default-src 'self'").replace('0' * 40, 'a' * 40)
            assert config.read_text() == expected and current.resolve() == releases / ('a' * 40)
            activate(archive, checksum, releases, config, 'v1.2.3', 'a' * 40, 'https://example.invalid')
            for command in (['nginx', '-t'], ['systemctl', 'reload', 'nginx']):
                fail['command'] = command
                try:
                    activate(archive, checksum, releases, config, 'v1.2.3', 'b' * 40, 'https://example.invalid')
                except subprocess.CalledProcessError:
                    pass
                else:
                    raise AssertionError('failed Nginx operation accepted')
                assert config.read_text() == expected and current.resolve() == releases / ('a' * 40)
            fail['body'] = b'stale app'
            try:
                activate(archive, checksum, releases, config, 'v1.2.3', 'b' * 40, 'https://example.invalid')
            except ValueError:
                pass
            else:
                raise AssertionError('stale loopback smoke accepted')
            assert config.read_text() == expected and current.resolve() == releases / ('a' * 40)
            fail['body'] = b'new app'
            active_index = releases / ('a' * 40) / 'index.html'
            active_index.write_text('changed')
            try:
                activate(archive, checksum, releases, config, 'v1.2.3', 'a' * 40, 'https://example.invalid')
            except ValueError:
                pass
            else:
                raise AssertionError('changed immutable release accepted')
            active_index.write_text('new app')
            for bad_checksum, url in [('f' * 64, 'https://example.invalid'), (checksum, 'https://other.invalid')]:
                try:
                    activate(archive, bad_checksum, releases, config, 'v1.2.3', 'c' * 40, url)
                except ValueError:
                    pass
                else:
                    raise AssertionError('invalid activation accepted')
                assert config.read_text() == expected
        assert (previous / 'index.html').read_text() == 'previous'
    if source:
        import shutil
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('fixture_release', source / 'scripts/release.py')
        release = importlib.util.module_from_spec(spec); spec.loader.exec_module(release)
        with tempfile.TemporaryDirectory(dir='.artifacts') as directory:
            root = Path(directory)
            fixture = root / 'assets'; fixture.mkdir()
            component = root / 'vibeface-app-1.2.3'; (component / 'web').mkdir(parents=True)
            (component / 'web/index.html').write_text('<script src="/assets/app.js"></script>')
            expected = dict(app='app', tag='v1.2.3', source_commit='a' * 40, version='1.2.3', channel='stable')
            info = dict(expected, schema=1, target=None, files=release.files(component))
            release.write_json(component / 'COMPONENT-INFO.json', info)
            archive = fixture / 'vibeface-app-1.2.3.tar.gz'
            release.public_archive(component, archive)
            manifest = dict(expected, app='product', schema=1, assets=[dict(name=p.name, size=p.stat().st_size,
                            sha256=release.digest(p)) for p in fixture.iterdir()])
            release.write_json(fixture / 'release.json', manifest)
            def fake_run(*args):
                return json.dumps(dict(isDraft=False, isPrerelease=False)) if args[:3] == ('gh', 'release', 'view') else 'a' * 40
            def fake_process(args, **_kwargs):
                if args[:3] == ['gh', 'release', 'download']:
                    pattern = args[args.index('--pattern') + 1]
                    assert pattern in {'release.json', 'vibeface-app-1.2.3.tar.gz', 'vibeface-app-1.2.3.tar.gz.sha256'}
                    shutil.copy2(fixture / pattern, Path(args[-1]) / pattern)
            with patch.object(sys.modules[__name__], 'run', fake_run), patch.object(subprocess, 'run', fake_process):
                result = prepare(source, root / 'valid', 'v1.2.3', 'a' * 40)
                assert (result / 'index.html').read_bytes() == (component / 'web/index.html').read_bytes()
                for case in ('wrong-source', 'corrupt-archive'):
                    if case == 'wrong-source':
                        manifest['source_commit'] = 'b' * 40
                    else:
                        manifest['source_commit'] = 'a' * 40
                        archive.write_bytes(b'corrupt')
                    release.write_json(fixture / 'release.json', manifest)
                    try:
                        prepare(source, root / case, 'v1.2.3', 'a' * 40)
                    except ValueError:
                        pass
                    else:
                        raise AssertionError(f'{case} release accepted')
    print('self-test passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'activate', 'smoke', 'self-test'))
    parser.add_argument('--source', type=Path)
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--tag')
    parser.add_argument('--sha')
    parser.add_argument('--url')
    parser.add_argument('--site', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--checksum')
    parser.add_argument('--releases', type=Path)
    parser.add_argument('--config', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'prepare':
            print(prepare(args.source, args.destination, args.tag, args.sha))
        elif args.command == 'activate':
            activate(args.archive, args.checksum, args.releases, args.config, args.tag, args.sha, args.url)
        elif args.command == 'smoke':
            smoke(args.url, args.site, args.sha)
        else:
            self_test(args.source)
    except (ValueError, OSError, subprocess.CalledProcessError):
        sys.exit('App deployment verification failed')
