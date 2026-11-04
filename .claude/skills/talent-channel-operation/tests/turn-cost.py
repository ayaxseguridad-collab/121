#!/usr/bin/env python3
"""Mide el cuerpo real del calculador con cadenas sintéticas de tamaño creciente."""
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

out = Path(sys.argv[1])
script = out / "cost-function.sh"
script.write_text('tco_valid_token() { return 0; }\n'
                  '_tco_carril_session() { printf "session-current idle 1"; }\n'
                  + os.environ["TCO_COST_BODY"]
                  + '\ntco_turn_identity 01 v:.0 "$(cat "$1")" session-current\n')
medians = []
for count in (3000, 12000, 24000):
    fixture = out / f"chain-{count}.jsonl"
    with fixture.open("w") as stream:
        for i in range(count):
            row = {"type": "user" if i == 0 else "assistant",
                   "sessionId": "session-current", "uuid": f"step-{i}",
                   "parentUuid": f"step-{i-1}", "message": {"content": "texto"}}
            stream.write(json.dumps(row) + "\n")
    measures = []
    for _ in range(5):
        start = time.perf_counter()
        result = subprocess.run(["bash", str(script), str(fixture)], capture_output=True)
        measures.append(time.perf_counter() - start)
        if result.returncode or json.loads(result.stdout) != ["session-current", "step-0", "humano"]:
            sys.exit(1)
    median = statistics.median(measures)
    medians.append(median)
    print(f"registros={count} mediana_ms={median*1000:.2f}", flush=True)
ratio = medians[2] / medians[1]
print(f"duplicacion={ratio:.3f} limite=2.5", flush=True)
sys.exit(0 if ratio <= 2.5 else 1)
