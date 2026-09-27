"""Verify the release contract before publishing; smoke-test files are excluded."""
import pathlib
import sys
import struct
import zipfile
directory, version = pathlib.Path(sys.argv[1]), sys.argv[2]
names = [f"TokenLens-macOS-{arch}-{version}.zip" for arch in ("arm64", "x86_64")]
names += [f"TokenLens-Windows-{arch}-{version}{suffix}" for arch in ("x64", "arm64")
          for suffix in ("-Setup.exe", ".zip")]
for name in names:
    artifact = directory / name
    if not artifact.is_file() or artifact.stat().st_size < 100_000:
        raise SystemExit(f"Missing or empty platform package: {name}")
extras = [p.name for p in directory.glob("TokenLens-*") if p.name not in names]
if extras:
    raise SystemExit(f"Unexpected platform packages: {extras}")
for arch, wanted in (("x64", 0x8664), ("arm64", 0xAA64)):
    with zipfile.ZipFile(directory / f"TokenLens-Windows-{arch}-{version}.zip") as package:
        for name in ("TokenLens.exe", f"resources/koffi/build/win32_{arch}/koffi.node"):
            data = package.read(name)
            offset = struct.unpack_from("<I", data, 0x3C)[0]
            if data[offset:offset+4] != b"PE\0\0" or struct.unpack_from("<H", data, offset+4)[0] != wanted:
                raise SystemExit(f"Wrong packaged Windows architecture: {arch}, {name}")
print("Verified six platform packages:", *names, sep="\n")
