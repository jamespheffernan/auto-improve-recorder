"""Private, resident JSON-lines bridge for fermion-research 0.2.3.

Audio and transcripts stay in this process and its parent app. No listening port.
The model is installed and verified separately; this worker never downloads it.
"""

import contextlib
import json
import os
from pathlib import Path
import sys
import threading
import time

MODEL = "FermionResearch/Phonon-2"


def watch_parent(parent_pid: int) -> None:
    while os.getppid() == parent_pid:
        time.sleep(2)
    os._exit(0)


def main() -> None:
    threading.Thread(target=watch_parent, args=(os.getppid(),), daemon=True).start()
    output = sys.stdout
    # Keep diagnostics from dependencies out of the response protocol.
    with contextlib.redirect_stdout(sys.stderr):
        from fermion._speech import backends
        from fermion.transcribe import _resolve
        import numpy as np

        _, profile, pin, model_dir = _resolve(sys.argv[1])
        if profile != "five-value" or model_dir is None:
            raise ValueError("Expected the installed Phonon-2 model directory")
        engine = backends.resolve("ASR/AIR Phonon-2")
        speech = backends.load(engine, model_dir, profile=profile,
                               backend=pin["backend"], quiet=True)
        speech.transcribe_array(np.zeros(16000, dtype=np.float32))
    print(json.dumps({"ready": True, "model": MODEL}), file=output, flush=True)

    for line in sys.stdin:
        try:
            request = json.loads(line)
            audio = Path(request["audio"])
            if not audio.is_file():
                raise ValueError("Recording file is missing")
            with contextlib.redirect_stdout(sys.stderr):
                result = speech.transcribe_detailed(str(audio))
            text, decode_seconds, duration_seconds = result.triple()
            response = {"model": MODEL, "text": text,
                        "decode_seconds": decode_seconds,
                        "duration_seconds": duration_seconds,
                        "truncated": bool(result.truncated)}
        except Exception as error:
            response = {"error": str(error)}
        print(json.dumps(response), file=output, flush=True)


if __name__ == "__main__":
    main()
