#!/usr/bin/env python3
import argparse
import hashlib
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

NESTED_DEPS = ("third_party/dawn", "third_party/devtools-frontend/src")


def host_cpu():
    machine = platform.machine().lower()
    if machine in ("arm64", "aarch64"):
        return "arm64"
    if machine in ("x86_64", "amd64"):
        return "x64"
    sys.exit(f"unsupported host cpu: {machine}")


def cipd_paths(cpu):
    arch = "arm64" if cpu == "arm64" else "amd64"
    return [
        "src/buildtools/mac",
        f"src/third_party/typescript/mac-{arch}/src",
        f"src/third_party/dawn/tools/golang/mac-{arch}",
        "src/third_party/devtools-frontend/src/third_party/esbuild",
    ]


def load_deps(src, gclient_eval):
    def parse(path):
        return gclient_eval.Parse(path.read_text(), str(path))["deps"]

    deps = parse(src / "DEPS")
    for nested in NESTED_DEPS:
        for name, dep in parse(src / nested / "DEPS").items():
            deps[f"src/{nested}/{name}"] = dep
    return deps


def install_cipd(src, deps, name):
    dep = deps.get(name)
    if dep is None or dep.get("dep_type") != "cipd":
        sys.exit(f"not a cipd dependency in DEPS: {name}")
    dest = src.joinpath(*name.split("/")[1:])
    dest.mkdir(parents=True, exist_ok=True)
    manifest = "".join(f"{p['package']} {p['version']}\n" for p in dep["packages"])
    print(f"cipd: {name}", flush=True)
    subprocess.run(
        [str(src / "third_party/depot_tools/cipd"), "ensure", "-root", str(dest), "-ensure-file", "-"],
        input=manifest,
        text=True,
        check=True,
    )


def install_gcs(src, deps, gclient_eval, name, cpu):
    dep = deps[name]
    variables = {"host_os": "mac", "host_cpu": cpu, "non_git_source": True}
    objects = [
        o for o in dep["objects"]
        if gclient_eval.EvaluateCondition(o.get("condition", "True"), variables)
    ]
    if len(objects) != 1:
        sys.exit(f"expected one {name} object for mac/{cpu}, found {len(objects)}")
    obj = objects[0]
    dest = src.joinpath(*name.split("/")[1:])
    stamp = dest / ".noctis_sha256"
    if stamp.exists() and stamp.read_text().strip() == obj["sha256sum"]:
        print(f"gcs: {name} up to date", flush=True)
        return
    url = f"https://storage.googleapis.com/{dep['bucket']}/{obj['object_name']}"
    print(f"gcs: {name} <- {url}", flush=True)
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "archive.tar.xz"
        with urllib.request.urlopen(url) as response, archive.open("wb") as out:
            shutil.copyfileobj(response, out)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != obj["sha256sum"]:
            sys.exit(f"sha256 mismatch for {url}: {digest}")
        shutil.rmtree(dest, ignore_errors=True)
        dest.mkdir(parents=True)
        with tarfile.open(archive) as tar:
            if hasattr(tarfile, "data_filter"):
                tar.extractall(dest, filter="data")
            else:
                tar.extractall(dest)
    stamp.write_text(obj["sha256sum"] + "\n")


def main():
    parser = argparse.ArgumentParser(description="Install prebuilt build tools listed in Chromium DEPS.")
    parser.add_argument("src", type=Path)
    args = parser.parse_args()
    src = args.src.resolve()

    sys.path.insert(0, str(src / "third_party/depot_tools"))
    import gclient_eval

    cpu = host_cpu()
    deps = load_deps(src, gclient_eval)
    for name in cipd_paths(cpu):
        install_cipd(src, deps, name)
    install_gcs(src, deps, gclient_eval, "src/third_party/llvm-libclang", cpu)


if __name__ == "__main__":
    main()
