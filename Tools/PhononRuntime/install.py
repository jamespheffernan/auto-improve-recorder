"""Install the pinned Phonon-2 runtime on an external volume, then link it for both apps.

Usage: python3 Tools/PhononRuntime/install.py '/Volumes/.../Phonon2-0.2.3'
Requires uv and Python 3.12. Never changes an existing completed installation.
"""

import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main() -> None:
    root = Path(sys.argv[1]).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    if root.stat().st_dev == Path.home().stat().st_dev:
        raise SystemExit("Choose a mounted external volume for the runtime and models.")
    link = Path.home() / "Library/Application Support/AutoImproveRecorder/Phonon2"
    if link.is_symlink() and link.resolve() != root or link.exists() and not link.is_symlink():
        raise SystemExit(f"An existing installation occupies {link}; it was not changed.")
    with (root / "install.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not (root / "complete.json").exists():
            source = Path(__file__).resolve().parent
            env = dict(os.environ, UV_CACHE_DIR=str(root / "uv-cache"),
                       UV_PYTHON_INSTALL_DIR=str(root / "python"),
                       FERMION_CACHE_DIR=str(root / "models"), HF_HOME=str(root / "hf-cache"))
            python = root / "runtime/bin/python"
            if not python.exists():
                subprocess.run(["uv", "venv", "--python", "3.12", str(root / "runtime")], env=env, check=True)
            subprocess.run(["uv", "pip", "sync", "--python", str(python),
                            str(source / "requirements.lock")], env=env, check=True)
            subprocess.run([str(root / "runtime/bin/fermion"), "transcribe", "--model", "phonon-2",
                            "--download-only", "unused"], env=env, check=True)
            shutil.copy2(source / "worker.py", root / "worker.py")
            shutil.copy2(source / "THIRD-PARTY-NOTICES.txt", root / "THIRD-PARTY-NOTICES.txt")
            model = root / "models/speech/FermionResearch__Phonon-2/model_phonon2_c4c_int6"
            worker = subprocess.Popen([str(python), "-u", str(root / "worker.py"), str(model)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
            try:
                stdout, _ = worker.communicate(input="", timeout=180)
                ready = json.loads(stdout)
                if worker.returncode or ready != {"ready": True, "model": "FermionResearch/Phonon-2"}:
                    raise RuntimeError("Phonon-2 did not pass its load and decode test")
            finally:
                if worker.poll() is None:
                    worker.kill()
                    worker.wait()
            (root / "complete.json").write_text(json.dumps({"model": "FermionResearch/Phonon-2",
                                                          "fermion_research": "0.2.3"}) + "\n")
        link.parent.mkdir(parents=True, exist_ok=True)
        if not link.is_symlink():
            link.symlink_to(root, target_is_directory=True)
        print(f"Phonon-2 ready: {link} -> {root}")


if __name__ == "__main__":
    main()
