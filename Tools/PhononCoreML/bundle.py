"""Bundle the verified native worker and pinned models into an archive before notarization.

Usage: python3 bundle.py APP VERIFIED_RUNTIME HELPER_RELEASE_DIRECTORY
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

IDENTITY = "Developer ID Application: Turf Terrace Ltd (7W38KL8969)"


def main() -> None:
    app, runtime, release = map(Path, sys.argv[1:])
    manifest = json.loads((runtime / "complete.json").read_text())
    if manifest["model"] != "FluidInference/phonon-2-coreml" or manifest["backend"] != "coreml-neural-engine":
        raise RuntimeError("Wrong speech model or backend")
    for entry in manifest["files"]:
        path = runtime / entry["path"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise RuntimeError(f"Model changed after verification: {path}")
    destination = app / "Contents/Resources/PhononCoreML"
    if destination.exists():
        raise RuntimeError(f"Refusing to overwrite {destination}")
    shutil.copytree(runtime, destination, symlinks=False)
    source = Path(__file__).resolve().parent
    shutil.copy2(source / "THIRD-PARTY-NOTICES.txt", destination / "THIRD-PARTY-NOTICES.txt")
    shutil.copytree(source / "licenses", destination / "licenses")
    (destination / "bin").mkdir(exist_ok=True)
    binary = destination / "bin/phonon-coreml"
    shutil.copy2(release / "phonon-coreml", binary)
    for resource in release.glob("*.bundle"):
        shutil.copytree(resource, destination / "bin" / resource.name)
    for path in destination.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(destination.resolve()):
            raise RuntimeError(f"Escaping bundle link: {path}")
    dependencies = "\n".join(subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:])
    if "/Users/" in dependencies or "/Volumes/" in dependencies or "/opt/homebrew/" in dependencies:
        raise RuntimeError(f"Non-portable native worker: {dependencies}")
    subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp",
                    "--sign", IDENTITY, str(binary)], check=True)
    # The caller signs the outer app after adding any other release resources.
    print(f"Bundled Core ML / Neural Engine Phonon-2: {destination}")


if __name__ == "__main__":
    main()
