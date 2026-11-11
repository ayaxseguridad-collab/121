# Pipeline CI/CD para Documentación — Proyecto de ejemplo

## Table of Contents

1. [GitHub Actions Workflow](#github-actions-workflow)
2. [Archivos de configuración](#archivos-de-configuración)
3. [Instalación local](#instalación-local)
4. [Script de validación local](#script-de-validación-local)

---

## GitHub Actions Workflow

Archivo: `.github/workflows/docs.yml`

```yaml
name: Documentation CI

on:
  pull_request:
    paths: ['docs/**', '**/*.md', '.vale.ini', '.markdownlint.json']
  push:
    branches: [main]
    paths: ['docs/**', '**/*.md']

jobs:
  markdown-lint:
    name: 📝 Markdown format
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: DavidAnson/markdownlint-cli2-action@v22
        with:
          globs: 'docs/**/*.md'

  prose-lint:
    name: ✍️ Prose quality
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: errata-ai/vale-action@v2
        with:
          files: docs/

  spell-check:
    name: 🔤 Spelling
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: streetsidesoftware/cspell-action@v8
        with:
          files: 'docs/**/*.md'

  link-check:
    name: 🔗 Links
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: lycheeverse/lychee-action@v2
        with:
          args: '--verbose --no-progress docs/**/*.md'
          fail: true
```

## Archivos de configuración

### `.markdownlint.json`

```json
{
  "default": true,
  "MD013": { "line_length": 120 },
  "MD024": { "siblings_only": true },
  "MD033": { "allowed_elements": ["br", "details", "summary", "sup", "sub"] },
  "MD041": false
}
```

Reglas clave: consistencia en headings, sin HTML innecesario, líneas ≤120 chars.

### `.vale.ini`

```ini
StylesPath = .vale/styles
MinAlertLevel = warning

[docs/*.md]
BasedOn = Vale.Spelling
Google.We = YES
Google.Passive = suggestion
Google.WordList = NO

[*.md]
BasedOn = Vale.Spelling
```

Instalar estilos:
```bash
vale sync  # Descarga Google style guide
```

### `cspell.json`

```json
{
  "version": "0.2",
  "language": "en,es",
  "words": [
    "Example", "Mintlify", "Diátaxis", "Mermaid",
    "webhook", "webhooks", "onboarding", "backend",
    "frontend", "middleware", "monorepo", "runbook",
    "kubernetes", "postgresql", "redis"
  ],
  "ignorePaths": [
    "node_modules/**",
    "docs/api/**"
  ]
}
```

### `.lycheeignore`

```
# URLs que no validar
https://localhost.*
https://127.0.0.1.*
https://example.com.*
```

## Instalación local

```bash
# Markdown lint
npm install -g markdownlint-cli2

# Vale (prose linter)
brew install vale        # macOS
# o descargar binario: https://github.com/errata-ai/vale/releases

# cspell (spelling)
npm install -g cspell

# lychee (link checker)
brew install lychee      # macOS
# o cargo install lychee
```

## Script de validación local

Archivo: `scripts/check-docs.sh`

```bash
#!/bin/bash
set -e
echo "📝 Markdown lint..."
npx markdownlint-cli2 "docs/**/*.md"
echo "✍️  Prose lint..."
vale docs/
echo "🔤 Spell check..."
npx cspell "docs/**/*.md" --no-progress
echo "🔗 Link check..."
lychee --verbose docs/**/*.md
echo "✅ Todos los checks pasaron"
```

Ejecutar antes de cada PR: `bash scripts/check-docs.sh`
