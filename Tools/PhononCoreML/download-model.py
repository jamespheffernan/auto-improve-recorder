"""Download the pinned Core ML checkpoint for portable packaging; verify every file.

Usage: python3 download-model.py /Volumes/.../PhononCoreML
No network access is used by the app or worker.
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

REPO = "FluidInference/phonon-2-coreml"
REVISION = "a812a0dfef205660787ef6234317ab79acf4d5d6"
MODELS = ("Preprocessor.mlmodelc/", "Encoder.mlmodelc/", "Decoder.mlmodelc/", "JointDecisionv3.mlmodelc/")


def main() -> None:
    root = Path(sys.argv[1])
    root.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(f"https://huggingface.co/api/models/{REPO}/revision/{REVISION}?blobs=true", timeout=60) as response:
        metadata = json.load(response)
    if metadata["sha"] != REVISION:
        raise RuntimeError("Model revision mismatch")
    files = [f for f in metadata["siblings"] if f["rfilename"].startswith(MODELS)
             or f["rfilename"] in {"parakeet_vocab.json", "LICENSE", "NOTICE", "README.md"}]

    def download(entry: dict) -> dict:
        name = entry["rfilename"]
        target = root / "models" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://huggingface.co/{REPO}/resolve/{REVISION}/{name}"
        if not target.is_file():
            with urllib.request.urlopen(url, timeout=120) as response, target.open("wb") as out:
                while chunk := response.read(1024 * 1024):
                    out.write(chunk)
        content = target.read_bytes()
        if len(content) != entry["size"]:
            raise RuntimeError(f"Size mismatch: {name}")
        digest = hashlib.sha256(content).hexdigest()
        if entry.get("lfs"):
            valid = digest == entry["lfs"]["sha256"]
        else:
            blob = hashlib.sha1(f"blob {len(content)}\0".encode() + content).hexdigest()
            valid = blob == entry["blobId"]
        if not valid:
            raise RuntimeError(f"Hash mismatch: {name}")
        print(f"Verified {name}", flush=True)
        return {"path": f"models/{name}", "bytes": len(content), "sha256": digest}

    with ThreadPoolExecutor(max_workers=4) as pool:
        manifest = list(pool.map(download, files))
    (root / "complete.json").write_text(json.dumps({
        "model": REPO, "revision": REVISION, "backend": "coreml-neural-engine",
        "fluid_audio_version": "0.17.5", "files": manifest
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
