"""Bundle an installed Phonon-2 model and standalone Python into an ASR archive.

Usage: python3 bundle.py APP INSTALLED_RUNTIME STANDALONE_PYTHON ENTITLEMENTS
Run before notarization. The app must be a disposable build/archive copy.
"""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import subprocess
import sys

IDENTITY = "Developer ID Application: Turf Terrace Ltd (7W38KL8969)"
MACHO = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def main() -> None:
    app, installed, python, entitlements = map(Path, sys.argv[1:])
    bundled = app / "Contents/Resources/Phonon2"
    if bundled.exists():
        raise SystemExit(f"Refusing to overwrite {bundled}")
    if not (installed / "complete.json").is_file():
        raise SystemExit("The source runtime has not passed its installation check")
    ignore = shutil.ignore_patterns("__pycache__", "*.pyc")
    shutil.copytree(python, bundled / "runtime", symlinks=True, ignore=ignore)
    shutil.copytree(installed / "runtime/lib/python3.12/site-packages",
                    bundled / "runtime/lib/python3.12/site-packages",
                    symlinks=True, dirs_exist_ok=True, ignore=ignore)
    shutil.copytree(installed / "models/speech", bundled / "models/speech", symlinks=True)
    for name in ["worker.py", "complete.json", "THIRD-PARTY-NOTICES.txt"]:
        shutil.copy2(installed / name, bundled / name)

    binaries = []
    for path in bundled.rglob("*"):
        if path.is_symlink():
            if not path.resolve().is_relative_to(bundled.resolve()):
                raise SystemExit(f"Runtime link escapes the app: {path}")
        elif path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    dependencies = subprocess.check_output(["otool", "-L", str(path)], text=True)
                    if "/opt/homebrew/" in dependencies or "/Users/" in dependencies:
                        raise SystemExit(f"Non-portable library dependency: {path}\n{dependencies}")
                    binaries.append(path)
    print(f"Signing {len(binaries)} runtime binaries", flush=True)

    def sign(path: Path) -> None:
        command = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", IDENTITY]
        if path == bundled / "runtime/bin/python3.12":
            command += ["--entitlements", str(entitlements)]
        subprocess.run([*command, str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(sign, binaries))
    subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp", "--entitlements",
                    str(entitlements), "--sign", IDENTITY, str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(f"Bundled and signed: {app}")


if __name__ == "__main__":
    main()
