"""Verify the release contract before publishing; smoke-test files are excluded."""
import pathlib
import sys
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
print("Verified six platform packages:", *names, sep="\n")
