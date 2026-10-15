#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Copy Mach-O binaries into an app bundle and make them self-contained.

Every non-system dylib a binary (transitively) links against is copied into
Contents/Frameworks, its install name is rewritten to @rpath/<name> and each
binary gets an LC_RPATH pointing at Contents/Frameworks relative to itself.

Usage:
    bundle_deps.py <App.app> <src>=<dest-relative-to-Contents> [...]
"""

import os
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (
        b"\xcf\xfa\xed\xfe",  # MH_MAGIC_64
        b"\xca\xfe\xba\xbe",  # FAT_MAGIC
    )


def linked_libs(path):
    """Return the install names a Mach-O file links against (excluding its own id)."""
    lines = run("otool", "-L", path).splitlines()[1:]
    names = [l.strip().split(" (compatibility")[0] for l in lines if l.strip()]
    own_id = run("otool", "-D", path).splitlines()[1:]
    if own_id and names and names[0] == own_id[0].strip():
        names = names[1:]
    return names


def rpaths(path):
    out = run("otool", "-l", path).splitlines()
    result = []
    for i, line in enumerate(out):
        if line.strip() == "cmd LC_RPATH":
            for follow in out[i + 1 : i + 4]:
                follow = follow.strip()
                if follow.startswith("path "):
                    result.append(follow.split()[1])
    return result


def resolve(name, origin_path, origin_rpaths):
    loader_dir = os.path.dirname(origin_path)
    if name.startswith("@loader_path/") or name.startswith("@executable_path/"):
        return os.path.realpath(os.path.join(loader_dir, name.split("/", 1)[1]))
    if name.startswith("@rpath/"):
        rest = name[len("@rpath/") :]
        for rp in origin_rpaths:
            rp = rp.replace("@loader_path", loader_dir).replace("@executable_path", loader_dir)
            candidate = os.path.join(rp, rest)
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        raise FileNotFoundError(f"cannot resolve {name} for {origin_path}")
    return os.path.realpath(name)


class Bundler:
    def __init__(self, app):
        self.contents = os.path.join(os.path.abspath(app), "Contents")
        self.frameworks = os.path.join(self.contents, "Frameworks")
        os.makedirs(self.frameworks, exist_ok=True)
        # basename in Frameworks -> original real path
        self.copied = {}

    def install_tool(self, *args):
        subprocess.run(["install_name_tool", *args], check=True, capture_output=True)

    def add(self, src, dest_rel):
        dest = os.path.join(self.contents, dest_rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(os.path.realpath(src), dest)
        os.chmod(dest, 0o755)
        self.fix(dest, os.path.realpath(src))

    def fix(self, dest, original):
        """Rewrite dependencies of `dest` (a copy of `original`)."""
        orig_rpaths = rpaths(original)
        for rp in rpaths(dest):
            self.install_tool("-delete_rpath", rp, dest)
        rel = os.path.relpath(self.frameworks, os.path.dirname(dest))
        self.install_tool("-add_rpath", "@loader_path" if rel == "." else f"@loader_path/{rel}", dest)

        if run("otool", "-D", dest).splitlines()[1:]:
            self.install_tool("-id", f"@rpath/{os.path.basename(dest)}", dest)

        for name in linked_libs(original):
            if name.startswith(SYSTEM_PREFIXES):
                continue
            real = resolve(name, original, orig_rpaths)
            base = os.path.basename(name)
            self.install_tool("-change", name, f"@rpath/{base}", dest)
            self.copy_lib(real, base)

    def copy_lib(self, real, base):
        if base in self.copied:
            if self.copied[base] != real:
                raise RuntimeError(f"name clash for {base}: {self.copied[base]} vs {real}")
            return
        self.copied[base] = real
        dest = os.path.join(self.frameworks, base)
        shutil.copy2(real, dest)
        os.chmod(dest, 0o755)
        self.fix(dest, real)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    bundler = Bundler(sys.argv[1])
    for spec in sys.argv[2:]:
        src, dest_rel = spec.split("=", 1)
        if not is_macho(os.path.realpath(src)):
            sys.exit(f"not a Mach-O file: {src}")
        bundler.add(src, dest_rel)
    print(f"bundled {len(sys.argv) - 2} binaries, {len(bundler.copied)} libraries")


if __name__ == "__main__":
    main()
