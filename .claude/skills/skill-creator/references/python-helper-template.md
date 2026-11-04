# Python Helper Template — Gold Standard

Complete template for creating a Python helper script. Structure extracted from
`ga4_helper.py` (1147 lines) and `google_ads_helper.py` — the gold standards for
Python helpers.

## Table of Contents

1. [File Structure Overview](#1-file-structure-overview)
2. [Shebang and Docstring Header](#2-shebang-and-docstring-header)
3. [Imports and Logging](#3-imports-and-logging)
4. [CircuitBreaker Dataclass](#4-circuitbreaker-dataclass)
5. [Retry with Backoff](#5-retry-with-backoff)
6. [Main Helper Class](#6-main-helper-class)
7. [CLI Entry Point](#7-cli-entry-point)
8. [Main Guard](#8-main-guard)

---

## 1. File Structure Overview

Every Python helper follows this exact structure, using `============` separators
between major sections:

```
┌──────────────────────────────────────────────┐
│  Shebang + Docstring                         │  ~30 lines
│  Imports                                     │  ~10 lines
├──────────────────────────────────────────────┤
│  ============ Logging ============           │  ~10 lines
├──────────────────────────────────────────────┤
│  ============ Circuit Breaker ============   │  ~50 lines
│  CircuitBreaker @dataclass                   │
├──────────────────────────────────────────────┤
│  ============ Retry ============             │  ~40 lines
│  with_retry() function                       │
├──────────────────────────────────────────────┤
│  ============ {{Service}}Helper ============ │  ~400-800 lines
│  Class with typed methods                    │
├──────────────────────────────────────────────┤
│  ============ CLI Commands ============      │  ~100 lines
│  cmd_* functions for each subcommand         │
├──────────────────────────────────────────────┤
│  ============ Main ============              │  ~80 lines
│  argparse setup + main() + guard             │
└──────────────────────────────────────────────┘
```

---

## 2. Shebang and Docstring Header

```python
#!/usr/bin/env python3
"""
{{service}}_helper.py — Script helper para {{SERVICE_NAME}}

{{Brief description of what this helper wraps}}.

Dependencias:
    pip install {{package1}} {{package2}} {{package3}}

Variables de entorno:
    {{ENV_VAR_1}}  — {{Description}}
    {{ENV_VAR_2}}  — {{Description}}
    {{ENV_VAR_3}}  — {{Description}}

Uso CLI:
    python {{service}}_helper.py {{subcommand1}} --param value
    python {{service}}_helper.py {{subcommand2}} --param value
    python {{service}}_helper.py {{subcommand3}} --param value
"""
```

**Key rules:**
- Shebang is `#!/usr/bin/env python3` (NOT `python` or `python2`)
- Docstring includes: description, dependencies, env vars, CLI usage
- Dependencies use exact package names from PyPI
- CLI usage shows real subcommand examples

---

## 3. Imports and Logging

```python
import argparse
import json
import logging
import os
import random
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Callable, Optional, TypeVar

# ============================================================================
# Logging
# ============================================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("{{service}}_helper")

T = TypeVar("T")
```

**Key rules:**
- Standard library imports first, then third-party, then local
- Logger name matches the script filename (without `.py`)
- `TypeVar("T")` for generic typing in retry/circuit breaker
- Import `@dataclass` for CircuitBreaker, not a full class

---

## 4. CircuitBreaker Dataclass

```python
# ============================================================================
# Circuit Breaker
# ============================================================================


@dataclass
class CircuitBreaker:
    """Proteccion contra rate limiting excesivo en APIs de {{SERVICE_NAME}}.

    States:
        closed    — Normal operation, requests pass through
        open      — Too many failures, requests rejected immediately
        half_open — Testing recovery, limited requests allowed
    """

    failure_threshold: int = 5
    recovery_timeout: float = 60.0

    _failure_count: int = field(default=0, init=False, repr=False)
    _state: str = field(default="closed", init=False, repr=False)
    _last_failure_time: float = field(default=0.0, init=False, repr=False)

    def can_execute(self) -> bool:
        """Verificar si se puede ejecutar una request."""
        if self._state == "closed":
            return True
        elif self._state == "open":
            if time.time() - self._last_failure_time >= self.recovery_timeout:
                self._state = "half_open"
                logger.info("Circuit breaker: open -> half_open")
                return True
            return False
        elif self._state == "half_open":
            return True
        return False

    def record_success(self) -> None:
        """Registrar exito — resetear contadores."""
        if self._state != "closed":
            logger.info(f"Circuit breaker: {self._state} -> closed")
        self._failure_count = 0
        self._state = "closed"

    def record_failure(self) -> None:
        """Registrar fallo — potencialmente abrir circuito."""
        self._failure_count += 1
        self._last_failure_time = time.time()
        if self._failure_count >= self.failure_threshold:
            self._state = "open"
            logger.warning(
                f"Circuit breaker ABIERTO despues de {self._failure_count} fallos. "
                f"Recovery en {self.recovery_timeout}s"
            )

    @property
    def state(self) -> str:
        return self._state
```

**Differences from TypeScript version:**
- Uses `@dataclass` instead of a full class (Pythonic)
- Private fields with `_` prefix and `field(init=False, repr=False)`
- No separate Error class — uses `RuntimeError` with descriptive message
- `can_execute()` instead of wrapping in `execute()` (allows more flexible usage)

---

## 5. Retry with Backoff

```python
# ============================================================================
# Retry con Backoff Exponencial
# ============================================================================


def with_retry(
    fn: Callable[[], T],
    max_retries: int = 5,
    base_delay: float = 1.0,
    max_delay: float = 60.0,
    retryable_codes: tuple = (429, 500, 503),
    circuit_breaker: Optional[CircuitBreaker] = None,
) -> T:
    """Ejecutar funcion con retry, backoff exponencial + jitter, y circuit breaker.

    Args:
        fn: Callable that performs the API operation
        max_retries: Maximum number of retry attempts
        base_delay: Base delay in seconds for exponential backoff
        max_delay: Maximum delay cap in seconds
        retryable_codes: HTTP status codes that trigger a retry
        circuit_breaker: Optional CircuitBreaker instance

    Returns:
        The result of fn()

    Raises:
        RuntimeError: If circuit breaker is open or max retries exceeded
        Exception: The last exception from fn() if not retryable
    """
    if circuit_breaker and not circuit_breaker.can_execute():
        raise RuntimeError(
            f"Circuit breaker abierto — esperando recovery "
            f"({circuit_breaker.recovery_timeout}s)"
        )

    for attempt in range(max_retries):
        try:
            result = fn()
            if circuit_breaker:
                circuit_breaker.record_success()
            return result
        except Exception as e:
            code = getattr(e, "code", None) or getattr(
                getattr(e, "response", None), "status_code", None
            )

            if code in retryable_codes and attempt < max_retries - 1:
                delay = min(
                    base_delay * (2 ** attempt) + random.uniform(0, 1),
                    max_delay,
                )
                logger.warning(
                    f"Retry {attempt + 1}/{max_retries} despues de {delay:.1f}s "
                    f"(codigo: {code})"
                )
                time.sleep(delay)
            else:
                if circuit_breaker:
                    circuit_breaker.record_failure()
                raise

    raise RuntimeError("Max retries excedido")
```

**Key differences from TypeScript:**
- `retryable_codes` tuple instead of `isRetryable()` function
- Extracts status code from exception attributes (works with `requests`, official SDKs)
- Uses `time.sleep()` instead of `setTimeout` promise
- `random.uniform(0, 1)` for jitter

---

## 6. Main Helper Class

```python
# ============================================================================
# {{ServiceName}}Helper
# ============================================================================


class {{ServiceName}}Helper:
    """Helper class para operaciones de {{SERVICE_NAME}} API.

    Todas las llamadas pasan por CircuitBreaker + retry automaticamente.
    """

    def __init__(
        self,
        api_key: Optional[str] = None,
        circuit_breaker: Optional[CircuitBreaker] = None,
    ):
        self.api_key = api_key or os.environ.get("{{ENV_VAR}}", "")
        if not self.api_key:
            raise ValueError("{{ENV_VAR}} requerido (env var o parametro api_key)")
        self.cb = circuit_breaker or CircuitBreaker()
        # Initialize SDK client here
        # self.client = {{Client}}(self.api_key)

    def _execute(self, fn: Callable[[], T]) -> T:
        """Ejecutar operacion con circuit breaker + retry."""
        return with_retry(fn, circuit_breaker=self.cb)

    # ─── {{Group 1}} ────────────────────────────────────────────────────────

    def {{method1}}(self, {{params}}) -> dict:
        """{{Description}}."""
        return self._execute(lambda: self.client.{{api_method1}}({{params}}))

    def {{method2}}(self, {{params}}) -> dict:
        """{{Description}}."""
        return self._execute(lambda: self.client.{{api_method2}}({{params}}))

    # ─── {{Group 2}} ────────────────────────────────────────────────────────

    def {{method3}}(self, {{params}}) -> dict:
        """{{Description}}."""
        return self._execute(lambda: self.client.{{api_method3}}({{params}}))
```

---

## 7. CLI Entry Point

```python
# ============================================================================
# CLI Commands
# ============================================================================


def cmd_{{subcommand1}}(args: argparse.Namespace) -> None:
    """Handler para el subcomando '{{subcommand1}}'."""
    helper = {{ServiceName}}Helper(api_key=args.key if hasattr(args, 'key') else None)
    result = helper.{{method1}}({{map_args}})
    print(json.dumps(result, indent=2, default=str))


def cmd_{{subcommand2}}(args: argparse.Namespace) -> None:
    """Handler para el subcomando '{{subcommand2}}'."""
    helper = {{ServiceName}}Helper(api_key=args.key if hasattr(args, 'key') else None)
    result = helper.{{method2}}({{map_args}})
    print(json.dumps(result, indent=2, default=str))


# ============================================================================
# Main
# ============================================================================


def main() -> None:
    parser = argparse.ArgumentParser(
        description="{{service}}_helper.py — CLI para {{SERVICE_NAME}} API"
    )
    parser.add_argument(
        "--key", default=None, help="API key (default: env {{ENV_VAR}})"
    )
    subparsers = parser.add_subparsers(dest="command", help="Subcomandos disponibles")

    # --- {{subcommand1}} ---
    p1 = subparsers.add_parser("{{subcommand1}}", help="{{Description}}")
    p1.add_argument("--param1", "-p", required=True, help="{{Param description}}")
    p1.add_argument("--param2", "-o", default="default", help="{{Param description}}")
    p1.set_defaults(func=cmd_{{subcommand1}})

    # --- {{subcommand2}} ---
    p2 = subparsers.add_parser("{{subcommand2}}", help="{{Description}}")
    p2.add_argument("--param1", required=True, help="{{Param description}}")
    p2.set_defaults(func=cmd_{{subcommand2}})

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    args.func(args)
```

**Key differences from TypeScript CLI:**
- Uses `argparse` with `add_subparsers` instead of `parseArgs` with `--action`
- Each subcommand has its own `cmd_*` function (cleaner than a switch statement)
- `set_defaults(func=cmd_*)` pattern for dispatch
- `print(json.dumps(result, indent=2, default=str))` for output

---

## 8. Main Guard

```python
if __name__ == "__main__":
    main()
```

This is the Python equivalent of the TypeScript CLI guard. **Always the last line
in the file.** Combined with functions and classes being importable, this achieves
the same dual-export pattern:

```python
# As module import:
from {{service}}_helper import {{ServiceName}}Helper
helper = {{ServiceName}}Helper("key")
result = helper.{{method1}}(params)

# As CLI:
python {{service}}_helper.py {{subcommand1}} --param value
```
