# TypeScript Helper Template — Gold Standard

Complete template for creating a TypeScript helper script. Structure extracted from
`stripe_helper.ts` (1597 lines) — the gold standard for TS helpers.

## Table of Contents

1. [File Structure Overview](#1-file-structure-overview)
2. [Shebang and JSDoc Header](#2-shebang-and-jsdoc-header)
3. [Types and Interfaces](#3-types-and-interfaces)
4. [CircuitBreaker Class](#4-circuitbreaker-class)
5. [Retry with Backoff](#5-retry-with-backoff)
6. [Main Helper Class](#6-main-helper-class)
7. [CLI Entry Point](#7-cli-entry-point)
8. [Dual Export](#8-dual-export)

---

## 1. File Structure Overview

Every TypeScript helper follows this exact structure, using `═══` separators between
major sections and `───` separators within groups:

```
┌──────────────────────────────────────────────┐
│  Shebang + JSDoc                             │  ~15 lines
│  Imports                                     │  ~5 lines
├──────────────────────────────────────────────┤
│  ═══ Types & Interfaces ═══                  │  ~30 lines
│  RetryOptions, CircuitBreakerOptions, etc.   │
├──────────────────────────────────────────────┤
│  ═══ CircuitBreaker Pattern ═══              │  ~170 lines
│  CircuitBreakerState enum                    │
│  CircuitBreakerOpenError class               │
│  CircuitBreaker class                        │
├──────────────────────────────────────────────┤
│  ═══ Retry with Exponential Backoff ═══      │  ~40 lines
│  retryWithBackoff<T>() function              │
├──────────────────────────────────────────────┤
│  ═══ {{Service}}Helper Class ═══             │  ~400-1000 lines
│  Constructor, execute<T>(), methods          │
├──────────────────────────────────────────────┤
│  ═══ CLI ═══                                 │  ~150 lines
│  printHelp(), printResult(), main()          │
├──────────────────────────────────────────────┤
│  ═══ Exports ═══                             │  ~20 lines
│  Named exports + CLI guard                   │
└──────────────────────────────────────────────┘
```

---

## 2. Shebang and JSDoc Header

```typescript
#!/usr/bin/env npx tsx
/**
 * {{service}}_helper.ts — Reusable helper functions for {{SERVICE_NAME}} API operations.
 *
 * Usage:
 *   import { {{ServiceName}}Helper } from './{{service}}_helper';
 *   const helper = new {{ServiceName}}Helper(process.env.{{ENV_VAR}}!);
 *   const result = await helper.{{primaryMethod}}({...});
 *
 * Or as CLI:
 *   npx tsx {{service}}_helper.ts --action {{action-1}} --param value
 *   npx tsx {{service}}_helper.ts --action {{action-2}} --param value
 *   npx tsx {{service}}_helper.ts --action {{action-3}} --param value
 *
 * Requires: npm install {{package}}@{{version}}
 * API Version: {{API_VERSION}} | {{package}} v{{SDK_VERSION}}
 */

import {{Import}} from '{{package}}';
```

**Key rules:**
- Shebang is `#!/usr/bin/env npx tsx` (NOT `ts-node`, NOT `node`)
- JSDoc includes both import usage AND CLI usage examples
- `Requires:` line with exact package and version
- `API Version:` line with API version and SDK version

---

## 3. Types and Interfaces

```typescript
// ═══════════════════════════════════════════════════════════════════════════════
// Types & Interfaces
// ═══════════════════════════════════════════════════════════════════════════════

interface RetryOptions {
  maxRetries: number;
  baseDelayMs: number;
  maxDelayMs: number;
  jitter: boolean;
}

interface CircuitBreakerOptions {
  failureThreshold: number;
  resetTimeoutMs: number;
  halfOpenMax: number;
}

interface CircuitBreakerStats {
  state: CircuitBreakerState;
  failureCount: number;
  successCount: number;
  halfOpenCalls: number;
  lastFailureTime: number;
  timeUntilRecoveryMs: number;
}

// ─── {{Service}}-specific types ────────────────────────────────────────────────

interface {{ServiceName}}Config {
  apiKey: string;
  baseUrl?: string;
  timeout?: number;
}

// Add service-specific request/response interfaces here
```

---

## 4. CircuitBreaker Class

This is the **exact pattern** used across all TS helpers. Copy it verbatim and only
modify the `isRetryable()` method for your specific service's error types.

```typescript
// ═══════════════════════════════════════════════════════════════════════════════
// CircuitBreaker Pattern
// ═══════════════════════════════════════════════════════════════════════════════


/** Estados del circuit breaker. */
enum CircuitBreakerState {
  CLOSED = 'closed',       // Normal: llamadas pasan
  OPEN = 'open',           // Fallando: llamadas rechazadas
  HALF_OPEN = 'half_open', // Probando recuperacion
}


/** Se lanza cuando el circuit breaker esta abierto y rechaza llamadas. */
class CircuitBreakerOpenError extends Error {
  public readonly state: CircuitBreakerState;
  public readonly failureCount: number;
  public readonly timeUntilRecoveryMs: number;

  constructor(message: string, state: CircuitBreakerState, failureCount: number, timeUntilRecoveryMs: number) {
    super(message);
    this.name = 'CircuitBreakerOpenError';
    this.state = state;
    this.failureCount = failureCount;
    this.timeUntilRecoveryMs = timeUntilRecoveryMs;
  }
}


/**
 * Implementacion del patron Circuit Breaker para proteger contra fallos en cascada.
 *
 * Flujo: CLOSED -> (fallos >= threshold) -> OPEN -> (timeout) -> HALF_OPEN -> (exito) -> CLOSED
 *                                                                            -> (fallo) -> OPEN
 *
 * Uso standalone:
 *   const cb = new CircuitBreaker({ failureThreshold: 5, resetTimeoutMs: 30000, halfOpenMax: 3 });
 *   const result = await cb.execute(() => apiCall());
 *
 * Integrado en {{ServiceName}}Helper:
 *   Todas las llamadas API pasan automaticamente por el circuit breaker.
 */
class CircuitBreaker {
  private state: CircuitBreakerState = CircuitBreakerState.CLOSED;
  private failureCount = 0;
  private successCount = 0;
  private halfOpenCalls = 0;
  private lastFailureTime = 0;
  private lastStateChange: number = Date.now();

  private readonly failureThreshold: number;
  private readonly resetTimeoutMs: number;
  private readonly halfOpenMax: number;

  constructor(options: CircuitBreakerOptions = { failureThreshold: 5, resetTimeoutMs: 30000, halfOpenMax: 3 }) {
    this.failureThreshold = options.failureThreshold;
    this.resetTimeoutMs = options.resetTimeoutMs;
    this.halfOpenMax = options.halfOpenMax;
  }

  /** Ejecuta la funcion a traves del circuit breaker. */
  async execute<T>(fn: () => Promise<T>): Promise<T> {
    const currentState = this.getCurrentState();

    if (currentState === CircuitBreakerState.OPEN) {
      const remaining = this.timeUntilRecovery();
      throw new CircuitBreakerOpenError(
        `Circuit breaker OPEN. ${this.failureCount} fallos consecutivos. ` +
        `Reintento en ${Math.ceil(remaining / 1000)}s`,
        currentState,
        this.failureCount,
        remaining,
      );
    }

    if (currentState === CircuitBreakerState.HALF_OPEN) {
      if (this.halfOpenCalls >= this.halfOpenMax) {
        this.transitionToOpen();
        throw new CircuitBreakerOpenError(
          `Circuit breaker re-opened: maximo de pruebas half-open alcanzado`,
          CircuitBreakerState.OPEN,
          this.failureCount,
          this.resetTimeoutMs,
        );
      }
      this.halfOpenCalls++;
    }

    try {
      const result = await fn();
      this.recordSuccess();
      return result;
    } catch (error) {
      if (this.isRetryable(error)) {
        this.recordFailure();
      }
      throw error;
    }
  }

  private recordSuccess(): void {
    this.failureCount = 0;
    this.successCount++;
    if (this.state === CircuitBreakerState.HALF_OPEN) {
      if (this.successCount >= this.halfOpenMax) {
        this.transitionToClosed();
      }
    }
  }

  private recordFailure(): void {
    this.failureCount++;
    this.successCount = 0;
    this.lastFailureTime = Date.now();
    if (this.failureCount >= this.failureThreshold) {
      this.transitionToOpen();
    }
    if (this.state === CircuitBreakerState.HALF_OPEN) {
      this.transitionToOpen();
    }
  }

  /**
   * CUSTOMIZE THIS METHOD for your service's error types.
   *
   * Determine if an error is transient (retryable) or permanent.
   * Only transient errors should trigger the circuit breaker.
   *
   * Common retryable patterns:
   * - HTTP 429 (rate limit)
   * - HTTP 500+ (server errors)
   * - Connection errors / timeouts
   * - Network failures
   *
   * NOT retryable:
   * - HTTP 400 (bad request)
   * - HTTP 401/403 (auth errors)
   * - HTTP 404 (not found)
   * - Validation errors
   */
  isRetryable(error: unknown): boolean {
    // {{SERVICE}}-specific error classification
    // Example for a fetch-based client:
    if (error instanceof Error) {
      // Network errors
      if (error.message.includes('ECONNREFUSED') || error.message.includes('ETIMEDOUT')) return true;
      // Rate limiting
      if (error.message.includes('429')) return true;
      // Server errors
      if (error.message.includes('500') || error.message.includes('503')) return true;
    }
    return false;
  }

  private getCurrentState(): CircuitBreakerState {
    if (this.state === CircuitBreakerState.OPEN) {
      if (Date.now() - this.lastFailureTime >= this.resetTimeoutMs) {
        this.tryRecovery();
      }
    }
    return this.state;
  }

  private transitionToOpen(): void {
    this.state = CircuitBreakerState.OPEN;
    this.lastStateChange = Date.now();
    process.stderr.write(`[CircuitBreaker] OPEN (fallos=${this.failureCount})\n`);
  }

  private transitionToClosed(): void {
    this.state = CircuitBreakerState.CLOSED;
    this.failureCount = 0;
    this.successCount = 0;
    this.halfOpenCalls = 0;
    this.lastStateChange = Date.now();
    process.stderr.write(`[CircuitBreaker] CLOSED (recuperado)\n`);
  }

  private tryRecovery(): void {
    this.state = CircuitBreakerState.HALF_OPEN;
    this.halfOpenCalls = 0;
    this.successCount = 0;
    this.lastStateChange = Date.now();
    process.stderr.write(`[CircuitBreaker] HALF_OPEN (probando recuperacion)\n`);
  }

  private timeUntilRecovery(): number {
    const elapsed = Date.now() - this.lastFailureTime;
    return Math.max(0, this.resetTimeoutMs - elapsed);
  }

  getState(): CircuitBreakerState {
    return this.getCurrentState();
  }

  getStats(): CircuitBreakerStats {
    return {
      state: this.getCurrentState(),
      failureCount: this.failureCount,
      successCount: this.successCount,
      halfOpenCalls: this.halfOpenCalls,
      lastFailureTime: this.lastFailureTime,
      timeUntilRecoveryMs: this.state === CircuitBreakerState.OPEN ? this.timeUntilRecovery() : 0,
    };
  }
}
```

---

## 5. Retry with Backoff

```typescript
// ═══════════════════════════════════════════════════════════════════════════════
// Retry with Exponential Backoff + Jitter
// ═══════════════════════════════════════════════════════════════════════════════


/**
 * Ejecuta una funcion con reintentos y backoff exponencial con full jitter.
 *
 * Full jitter: delay = random(0, min(maxDelay, baseDelay * 2^attempt))
 * Esto distribuye reintentos para evitar thundering herd.
 */
async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  options: RetryOptions = { maxRetries: 3, baseDelayMs: 500, maxDelayMs: 30000, jitter: true },
  isRetryable: (error: unknown) => boolean = () => true,
): Promise<T> {
  let lastError: unknown;

  for (let attempt = 0; attempt <= options.maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;

      if (attempt === options.maxRetries || !isRetryable(error)) {
        throw error;
      }

      const exponentialDelay = options.baseDelayMs * Math.pow(2, attempt);
      const cappedDelay = Math.min(exponentialDelay, options.maxDelayMs);
      const delay = options.jitter ? Math.random() * cappedDelay : cappedDelay;

      process.stderr.write(
        `[Retry] Intento ${attempt + 1}/${options.maxRetries} fallido. ` +
        `Reintentando en ${Math.round(delay)}ms...\n`
      );

      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }

  throw lastError;
}
```

---

## 6. Main Helper Class

```typescript
// ═══════════════════════════════════════════════════════════════════════════════
// {{ServiceName}}Helper
// ═══════════════════════════════════════════════════════════════════════════════


/**
 * Helper class providing typed, circuit-breaker-protected access to the
 * {{SERVICE_NAME}} API.
 *
 * All public methods pass through the internal CircuitBreaker and retryWithBackoff.
 */
class {{ServiceName}}Helper {
  private readonly client: {{ClientType}};
  private readonly circuitBreaker: CircuitBreaker;

  constructor(apiKey: string, options?: { circuitBreaker?: CircuitBreakerOptions }) {
    this.client = new {{Client}}(apiKey);
    this.circuitBreaker = new CircuitBreaker(options?.circuitBreaker);
  }

  /**
   * Execute any API call through circuit breaker + retry.
   * All public methods should use this internally.
   */
  private async execute<T>(fn: () => Promise<T>): Promise<T> {
    return this.circuitBreaker.execute(() =>
      retryWithBackoff(
        fn,
        { maxRetries: 3, baseDelayMs: 500, maxDelayMs: 30000, jitter: true },
        (error) => this.circuitBreaker.isRetryable(error),
      )
    );
  }

  // ─── {{Group 1: e.g., Payments}} ─────────────────────────────────────────

  async {{method1}}(params: {{Params1}}): Promise<{{Return1}}> {
    return this.execute(() => this.client.{{apiMethod1}}(params));
  }

  async {{method2}}(params: {{Params2}}): Promise<{{Return2}}> {
    return this.execute(() => this.client.{{apiMethod2}}(params));
  }

  // ─── {{Group 2: e.g., Customers}} ────────────────────────────────────────

  async {{method3}}(params: {{Params3}}): Promise<{{Return3}}> {
    return this.execute(() => this.client.{{apiMethod3}}(params));
  }

  // ─── Diagnostics ─────────────────────────────────────────────────────────

  getCircuitBreakerStats(): CircuitBreakerStats {
    return this.circuitBreaker.getStats();
  }
}
```

**Pattern: Group methods by domain** using `// ─── Group Name ───` separators.

---

## 7. CLI Entry Point

```typescript
// ═══════════════════════════════════════════════════════════════════════════════
// CLI
// ═══════════════════════════════════════════════════════════════════════════════


function printHelp(): void {
  const help = `
{{service}}_helper.ts — CLI for {{SERVICE_NAME}} API operations

USAGE:
  npx tsx {{service}}_helper.ts --action <action> [options]

ACTIONS:
  {{action-1}}              {{Description}}
  {{action-2}}              {{Description}}
  {{action-3}}              {{Description}}
  diagnostics             Show circuit breaker stats

OPTIONS:
  --key <secret>          API key (default: env {{ENV_VAR}})
  --format json|pretty    Output format (default: pretty)

EXAMPLES:
  npx tsx {{service}}_helper.ts --action {{action-1}} --param value
  npx tsx {{service}}_helper.ts --action diagnostics
`;
  process.stdout.write(help);
}


function printResult(data: unknown, format: string): void {
  if (format === 'json') {
    process.stdout.write(JSON.stringify(data) + '\n');
  } else {
    process.stdout.write(JSON.stringify(data, null, 2) + '\n');
  }
}


async function main(): Promise<void> {
  const { parseArgs } = await import('node:util');

  const { values: args } = parseArgs({
    options: {
      action: { type: 'string' },
      key: { type: 'string' },
      format: { type: 'string', default: 'pretty' },
      help: { type: 'boolean', short: 'h' },
      // Add action-specific options here:
      // param1: { type: 'string' },
      // param2: { type: 'string' },
    },
    strict: false,
    allowPositionals: true,
  });

  if (args.help || !args.action) {
    printHelp();
    process.exit(args.help ? 0 : 1);
  }

  const apiKey = args.key || process.env.{{ENV_VAR}};
  if (!apiKey) {
    process.stderr.write('Error: {{ENV_VAR}} env var o --key flag requerido\n');
    process.exit(1);
  }

  const helper = new {{ServiceName}}Helper(apiKey);
  const format = args.format || 'pretty';

  try {
    let result: unknown;

    switch (args.action) {
      case '{{action-1}}':
        result = await helper.{{method1}}({
          // Map CLI args to method params
        });
        break;

      case '{{action-2}}':
        result = await helper.{{method2}}({...});
        break;

      case 'diagnostics':
        result = { circuitBreaker: helper.getCircuitBreakerStats() };
        break;

      default:
        process.stderr.write(`Accion desconocida: ${args.action}\n`);
        process.stderr.write(`Ejecuta sin --action para ver la ayuda.\n`);
        process.exit(1);
    }

    printResult(result, format);
  } catch (err) {
    if (err instanceof CircuitBreakerOpenError) {
      const errorOutput = {
        error: true,
        type: 'CircuitBreakerOpen',
        message: err.message,
        state: err.state,
        failureCount: err.failureCount,
        timeUntilRecoveryMs: err.timeUntilRecoveryMs,
      };
      process.stderr.write(JSON.stringify(errorOutput, null, 2) + '\n');
    } else {
      process.stderr.write(String(err) + '\n');
    }
    process.exit(1);
  }
}
```

---

## 8. Dual Export

```typescript
// ═══════════════════════════════════════════════════════════════════════════════
// Exports
// ═══════════════════════════════════════════════════════════════════════════════

export {
  // Main classes
  {{ServiceName}}Helper,
  CircuitBreaker,
  CircuitBreakerOpenError,
  CircuitBreakerState,
  // Utility functions
  retryWithBackoff,
  // Add any service-specific utilities
};

export type { RetryOptions, CircuitBreakerOptions, CircuitBreakerStats };

// Ejecutar CLI si se invoca directamente
if (
  typeof process !== 'undefined' &&
  process.argv[1] &&
  (process.argv[1].endsWith('{{service}}_helper.ts') || process.argv[1].endsWith('{{service}}_helper'))
) {
  main().catch((err) => {
    process.stderr.write(`Fatal: ${err}\n`);
    process.exit(1);
  });
}
```

**Key rules for dual export:**
1. Named exports (NOT default export) — allows tree-shaking
2. Separate `export type` for interfaces
3. CLI guard checks both `.ts` and extensionless variants
4. `main()` is async and caught at the top level
