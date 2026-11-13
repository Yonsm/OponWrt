#!/usr/bin/env python3
# 准备 ImageBuilder：拉取 Argon 与 Wing 第三方包，允许本地未签名包，并挂入 UI 定制脚本。
# 用法：prepare.py <ib> <series> <arch> [--nowing]

import json, os, re, sys, urllib.request

ARGON = ('luci-theme-argon', 'luci-app-argon-config', 'luci-i18n-argon-config-zh-cn')
WING = ('chinadns-ng', 'ipt2socks', 'simple-obfs-client', 'shadowsocksr-libev-ssr-redir', 'trojan', 'tcping')
REQUIRED = ('chinadns-ng', 'ipt2socks')
HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'patches', 'ui-replace.sh')


def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'OponWrt'})
    return urllib.request.urlopen(req, timeout=60).read()


def save(pkg_dir, name, data):
    path = os.path.join(pkg_dir, name)
    if os.path.exists(path):
        return
    with open(path, 'wb') as f:
        f.write(data)
    print('[ib] ' + name)


def fetch_argon(pkg_dir, ext):
    release = json.loads(get('https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest'))
    found = set()
    for asset in release['assets']:
        for prefix in ARGON:
            if asset['name'].startswith(prefix) and asset['name'].endswith('.' + ext):
                save(pkg_dir, asset['name'], get(asset['browser_download_url']))
                found.add(prefix)
    if found != set(ARGON):
        raise SystemExit('Argon release does not contain all required packages')


def fetch_wing(pkg_dir, series, arch, ext):
    missing = set(WING)
    base = f'https://downloads.immortalwrt.org/releases/packages-{series}/{arch}/packages'
    html = get(base + '/').decode('utf-8', 'replace')
    for pkg in sorted(missing):
        match = re.search(re.escape(pkg) + r'[_-][0-9][^"/]*\.' + ext, html)
        if match:
            save(pkg_dir, match.group(0), get(base + '/' + match.group(0)))
            missing.discard(pkg)
    # SSR 已不在 ImmortalWrt 源中，Passwall 的构建（libpcre2）可作替代。
    if missing:
        rss = get(f'https://sourceforge.net/projects/openwrt-passwall-build/rss?path=/releases/packages-{series}/{arch}/passwall_packages').decode('utf-8', 'replace')
        for pkg in sorted(missing):
            match = re.search(r'https?://[^<"]+/(' + re.escape(pkg) + r'[_-][0-9][^"<]*\.' + ext + ')', rss)
            if match:
                save(pkg_dir, match.group(1), get(match.group(0) + '/download'))
                missing.discard(pkg)
    for pkg in REQUIRED:
        if pkg in missing:
            raise SystemExit('Required Wing package missing: ' + pkg)


def patch_makefile(ib):
    path = os.path.join(ib, 'Makefile')
    with open(path, encoding='utf-8') as f:
        text = f.read()
    text = re.sub(r'(apk add )(?!\s*--allow-untrusted)', r'\1--allow-untrusted ', text)
    text = re.sub(r'(\$\(APK\) add )(?!\s*--allow-untrusted)', r'\1--allow-untrusted ', text)
    if 'ui-replace.sh' not in text:
        text, count = re.subn(r'^build_image:[^\n]*\n', lambda m: m.group(0) + '\t' + HOOK + ' $(TARGET_DIR)\n', text, count=1, flags=re.M)
        if count != 1:
            raise SystemExit('ImageBuilder build_image target not found')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    ib, series, arch = sys.argv[1:4]
    pkg_dir = os.path.join(ib, 'packages')
    os.makedirs(pkg_dir, exist_ok=True)
    ext = 'apk' if os.path.exists(os.path.join(ib, 'repositories')) else 'ipk'

    fetch_argon(pkg_dir, ext)
    if '--nowing' not in sys.argv[4:]:
        fetch_wing(pkg_dir, series, arch, ext)

    conf = os.path.join(ib, 'repositories.conf')
    if os.path.exists(conf):
        with open(conf) as f:
            text = f.read()
        with open(conf, 'w') as f:
            f.write(re.sub(r'^option check_signature', '# option check_signature', text, flags=re.M))

    patch_makefile(ib)


if __name__ == '__main__':
    main()
