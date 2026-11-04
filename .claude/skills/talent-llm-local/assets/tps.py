#!/usr/bin/env python3
"""Monitor en vivo de tokens/segundo del servidor vLLM local.

Uso:  python3 tps.py        (Ctrl+C para salir)

Entorno: METRICS_URL (http://127.0.0.1:8001/metrics) · STATS_KEY (tu clave, la
de /etc/llm-local/claves.env).

Lee /metrics cada 2 s y muestra la tasa real de generacion y de prefill,
mas cuantas peticiones corren y cuantas esperan. Si "esperando" > 0 de
forma sostenida, el servidor esta saturado.
"""
import re
import time
import urllib.request

import os

# Por el MEDIDOR (8001), no por el motor (8000): la regla vale tambien para las
# herramientas propias.
URL = os.environ.get("METRICS_URL", "http://127.0.0.1:8001/metrics")
# Sin clave por defecto: se generan al azar al montar.
KEY = os.environ.get("STATS_KEY", "")
INTERVAL = 2.0

PATTERNS = {
    "gen": re.compile(r'^vllm:generation_tokens_total\{[^}]*\}\s+([0-9.e+]+)', re.M),
    "prompt": re.compile(r'^vllm:prompt_tokens_total\{[^}]*\}\s+([0-9.e+]+)', re.M),
    "running": re.compile(r'^vllm:num_requests_running\{[^}]*\}\s+([0-9.e+]+)', re.M),
    "waiting": re.compile(r'^vllm:num_requests_waiting\{[^}]*\}\s+([0-9.e+]+)', re.M),
}


def scrape():
    req = urllib.request.Request(URL, headers={"Authorization": f"Bearer {KEY}"})
    text = urllib.request.urlopen(req, timeout=5).read().decode()
    out = {}
    for name, pat in PATTERNS.items():
        m = pat.search(text)
        out[name] = float(m.group(1)) if m else 0.0
    return out


def main():
    prev, t_prev = scrape(), time.time()
    print(f"{'hora':8} {'gen tok/s':>10} {'prefill tok/s':>14} {'corriendo':>10} {'esperando':>10}", flush=True)
    while True:
        time.sleep(INTERVAL)
        cur, t_cur = scrape(), time.time()
        dt = t_cur - t_prev
        gen = (cur["gen"] - prev["gen"]) / dt
        pre = (cur["prompt"] - prev["prompt"]) / dt
        mark = "" if gen == 0 and pre == 0 else "  ◀"
        print(f"{time.strftime('%H:%M:%S'):8} {gen:>10.1f} {pre:>14.1f} "
              f"{int(cur['running']):>10} {int(cur['waiting']):>10}{mark}", flush=True)
        prev, t_prev = cur, t_cur


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
