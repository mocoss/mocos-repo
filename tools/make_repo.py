#!/usr/bin/env python3
"""Index existing .deb files; never modify packages. Requires dpkg-deb."""
import argparse
import email.utils
import gzip
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

VARIANTS = {"rootless": "iphoneos-arm64", "roothide": "iphoneos-arm64e"}


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1048576), b""):
            h.update(block)
    return h.hexdigest()


def control(path):
    text = subprocess.check_output(["dpkg-deb", "--field", str(path)], text=True)
    fields = {}
    key = None
    for line in text.splitlines():
        if line.startswith((" ", "\t")) and key:
            fields[key] += "\n" + line
        elif ":" in line:
            key, value = line.split(":", 1)
            if key in fields:
                raise ValueError(f"Duplicate control field: {path}: {key}")
            fields[key] = value.lstrip()
        elif line.strip():
            raise ValueError(f"Malformed control: {path}")
    for key in ("Package", "Version", "Architecture", "Maintainer", "Description"):
        if not fields.get(key):
            raise ValueError(f"Missing {key}: {path}")
    return fields


def build(root, variant, arch, stage, label):
    base = root / variant
    pool = base / "debs"
    if base.is_symlink() or pool.is_symlink():
        raise ValueError(f"Symlink directory is not allowed: {base}")
    debs = sorted(pool.rglob("*.deb"))
    if not debs:
        raise ValueError(f"No .deb files in {pool}")
    seen = set()
    records = []
    for deb in debs:
        relative = deb.relative_to(base).as_posix()
        if deb.is_symlink() or not re.fullmatch(r"[A-Za-z0-9_+./-]+", relative):
            raise ValueError(f"Use ordinary ASCII filenames, not symlinks: {deb}")
        if any(p.is_symlink() for p in deb.parents if p != root.parent):
            raise ValueError(f"Symlink ancestor is not allowed: {deb}")
        fields = control(deb)
        if fields["Architecture"] != arch:
            raise ValueError(f"Wrong architecture in {deb}: expected {arch}")
        identity = tuple(fields[k] for k in ("Package", "Version", "Architecture"))
        if identity in seen:
            raise ValueError(f"Duplicate package/version/architecture: {identity}")
        seen.add(identity)
        for k in ("Filename", "Size", "MD5sum", "SHA1", "SHA256", "SHA512"):
            fields.pop(k, None)
        package = fields.pop("Package")
        fields = {"Package": package, **fields}
        fields.update(Filename=relative, Size=str(deb.stat().st_size), SHA256=sha256(deb))
        records.append("\n".join(f"{k}: {v}" for k, v in fields.items()))
    out = stage / variant
    out.mkdir()
    data = ("\n\n".join(records) + "\n\n").encode("utf-8")
    (out / "Packages").write_bytes(data)
    (out / "Packages.gz").write_bytes(gzip.compress(data, mtime=0))
    release = [f"Origin: {label}", f"Label: {label} ({variant})",
               f"Suite: {variant}", f"Codename: {variant}",
               f"Architectures: {arch}", f"Date: {email.utils.formatdate(usegmt=True)}",
               f"Description: {variant} flat APT repository", "SHA256:"]
    for name in ("Packages", "Packages.gz"):
        p = out / name
        release.append(f" {sha256(p)} {p.stat().st_size} {name}")
    (out / "Release").write_text("\n".join(release) + "\n", encoding="utf-8")
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", type=Path, help="Site root containing rootless/debs and roothide/debs")
    parser.add_argument("--label", default="My Tweak Repo")
    parser.add_argument("--sign-key", help="GPG signing key fingerprint; produces InRelease and Release.gpg")
    args = parser.parse_args()
    if not args.label or "\n" in args.label or "\r" in args.label:
        parser.error("Label must be a nonempty single line")
    if not shutil.which("dpkg-deb"):
        parser.error("Install dpkg-deb first")
    root = args.site.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="apt-index-") as temporary:
        stage = Path(temporary)
        outputs = [build(root, v, a, stage, args.label) for v, a in VARIANTS.items()]
        for out in outputs:
            if args.sign_key:
                common = ["gpg", "--yes", "--local-user", args.sign_key, "--digest-algo", "SHA256"]
                subprocess.run(common + ["--output", str(out / "InRelease"),
                                          "--clearsign", str(out / "Release")], check=True)
                subprocess.run(common + ["--armor", "--output", str(out / "Release.gpg"),
                                          "--detach-sign", str(out / "Release")], check=True)
        for out in outputs:
            target = root / out.name
            for name in ("InRelease", "Release.gpg"):
                (target / name).unlink(missing_ok=True)
            for source in out.iterdir():
                destination = target / source.name
                temporary_path = target / (source.name + ".tmp")
                shutil.copyfile(source, temporary_path)
                os.replace(temporary_path, destination)
            print(f"Indexed {target}")
    if not args.sign_key:
        print("WARNING: indexes are unsigned; configure repository signing before public use.")


if __name__ == "__main__":
    main()
