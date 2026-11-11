# GraphQL API para threads de CodeRabbit

> `last_verified: 2026-09-05`

Cubre las queries y mutations GraphQL que el workflow de esta skill usa contra la API de GitHub para
leer y resolver review threads de CodeRabbit, más las tres fuentes REST del App y cuándo usar cada ruta
de reply. Validado en vivo (introspección + query real) contra este mismo repo el 2026-09-05 — ver §11.

## Tabla de contenidos

1. [Por qué GraphQL](#1-por-qué-graphql)
2. [Autenticación](#2-autenticación)
3. [Query: listar review threads de un PR](#3-query-listar-review-threads-de-un-pr)
4. [Mutation: resolver un thread](#4-mutation-resolver-un-thread)
5. [Mutation: des-resolver un thread](#5-mutation-des-resolver-un-thread)
6. [Reply a un thread: GraphQL vs REST](#6-reply-a-un-thread-graphql-vs-rest)
7. [`resolutionReason`: nuevo, pero Copilot-only](#7-resolutionreason-nuevo-pero-copilot-only)
8. [Tres fuentes REST del comentario del App](#8-tres-fuentes-rest-del-comentario-del-app)
9. [Permisos reales del GitHub App](#9-permisos-reales-del-github-app)
10. [Rate limits y patrones comunes](#10-rate-limits-y-patrones-comunes)
11. [Verificación en vivo (2026-09-05)](#11-verificación-en-vivo-2026-09-05)
12. [Errores comunes](#12-errores-comunes)
13. [Gotchas y referencias cruzadas](#13-gotchas-y-referencias-cruzadas)

## 1. Por qué GraphQL

- **Thread resolution es GraphQL-only.** La REST API de GitHub no expone ningún endpoint para
  `resolveReviewThread` / `unresolveReviewThread` — solo el schema GraphQL de Pulls lo soporta.
  Fuente: <https://docs.github.com/en/graphql/reference/pulls> (consultado 2026-09-05).
- Metadata completa de un thread (`isResolved`, `isOutdated`, `path`, `line`, `startLine`) sale en una
  sola query, sin combinar dos llamadas REST.
- Ambas mutations de resolución son **idempotentes** — seguras de llamar sobre un thread ya resuelto
  (devuelven `isResolved: true` sin error).

```text
  ¿qué necesito hacer con un comentario de CR?
     │
     ├─ leer metadata / listar threads ──────────────▶ GraphQL query (§3)
     ├─ marcar el thread como resuelto ───────────────▶ GraphQL mutation resolveReviewThread (§4)
     ├─ responder DENTRO del thread (ya tengo threadId) ▶ GraphQL addPullRequestReviewThreadReply (§6)
     └─ responder y solo tengo el databaseId del 1er
        comentario (p.ej. viene de una fuente REST)  ──▶ REST …/comments/{id}/replies (§6)
```

## 2. Autenticación

`gh` CLI maneja el token automáticamente:

```bash
gh auth status   # verifica que estás logueado con scope repo
```

Si necesitas scopes extra:

```bash
gh auth refresh -s repo,read:org
```

Para introspección de solo lectura (schema, sin mutar nada) basta el token de usuario ya autenticado —
no requiere permisos especiales.

## 3. Query: listar review threads de un PR

```graphql
query($owner: String!, $name: String!, $pr: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id                # PRRT_xxxxx — úsalo para resolve/reply
          isResolved
          isOutdated        # true si la línea comentada ya no existe
          path
          line              # línea del último comentario del rango
          startLine         # línea inicial (para comentarios multi-línea)
          comments(first: 20) {
            nodes {
              id            # node ID del comentario (para GraphQL)
              databaseId    # ID numérico (para REST API si necesitas)
              author { login }
              body
              createdAt
              url
            }
          }
        }
      }
    }
  }
}
```

**CLI:**

```bash
gh api graphql \
  -f query="<QUERY>" \
  -F owner="OWNER" \
  -F name="REPO" \
  -F pr=42
```

## 4. Mutation: resolver un thread

```graphql
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      id
      isResolved
    }
  }
}
```

**CLI:**

```bash
gh api graphql \
  -f query='mutation($threadId: ID!){resolveReviewThread(input:{threadId:$threadId}){thread{id isResolved}}}' \
  -F threadId="PRRT_kwDOL12345"
```

Idempotente: llamar en un thread ya resuelto devuelve `isResolved: true` sin error. `resolveReviewThread`
NO está deprecada (verificado por introspección en vivo, §11).

## 5. Mutation: des-resolver un thread

```graphql
mutation($threadId: ID!) {
  unresolveReviewThread(input: {threadId: $threadId}) {
    thread {
      id
      isResolved
    }
  }
}
```

Útil si resolviste por error y necesitas reabrir la discusión. Tampoco está deprecada.

## 6. Reply a un thread: GraphQL vs REST

**Corrección de v2**: la versión previa de esta referencia daba por hecho que el reply a un review
comment solo era posible por REST, sin alternativa en GraphQL. Eso está **superado** —
`addPullRequestReviewThreadReply` existe, no está deprecada y se puede usar directamente con el
`threadId` (`PRRT_...`) que ya devuelve la query de §3, sin necesitar el `databaseId` que exige la ruta
REST. Fuente: introspección en vivo 2026-09-05 (§11); doc oficial
<https://docs.github.com/en/graphql/reference/pulls> sección `addPullRequestReviewThreadReply` /
`AddPullRequestReviewThreadReplyInput`.

### Ruta GraphQL (preferida si ya tienes el `threadId`)

```graphql
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
    comment { id url }
  }
}
```

```bash
gh api graphql \
  -f query='mutation($threadId:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId,body:$body}){comment{id url}}}' \
  -F threadId="PRRT_kwDOL12345" \
  -F body="@coderabbitai <razón del disagreement>"
```

`AddPullRequestReviewThreadReplyInput` acepta `pullRequestReviewThreadId` (`ID!`), `body` (`String!`),
`pullRequestReviewId` (`ID`, opcional) y `clientMutationId` (`String`, opcional) — verificado por
introspección en vivo (§11).

### Ruta REST (única opción si solo tienes el `databaseId` del primer comentario)

```bash
gh api \
  --method POST \
  "repos/${OWNER}/${REPO}/pulls/${PR}/comments/${COMMENT_ID}/replies" \
  -f body="@coderabbitai <razón del disagreement>"
```

`COMMENT_ID` es el `databaseId` (no el node ID) del **primer** comentario del thread —
`fetch_cr_comments.sh` lo expone como `.comments.nodes[0].databaseId`. GitHub no soporta responder a
una respuesta («Replies to replies are not supported»), así que siempre apunta al comentario raíz.
Fuente: <https://docs.github.com/en/rest/pulls/comments> sección «Create a reply for a review comment»
(consultado 2026-09-05) — el endpoint sigue vigente y funcionando, no está deprecado.

`scripts/challenge_thread.sh` de este skill ofrece las dos rutas: por defecto REST (recibe `comment_id`
= `databaseId`) y, con `--graphql <threadId>`, la mutation `addPullRequestReviewThreadReply` seguida de
`resolveReviewThread` (responde y resuelve en un paso).

## 7. `resolutionReason`: nuevo, pero Copilot-only

El schema en vivo añadió el 2026-08-25 un campo opcional a `ResolveReviewThreadInput`:

```graphql
input ResolveReviewThreadInput {
  clientMutationId: String
  resolutionReason: PullRequestReviewThreadResolutionReason  # enum: ADDRESSED | WONT_FIX | INVALID
  threadId: ID!
}
```

La descripción del campo en el schema dice literalmente **«The reason a Copilot code review thread was
resolved.»** — está scoped al reviewer Copilot de GitHub, no a apps de terceros como CodeRabbit.
`resolve_thread.sh` no necesita pasarlo. Fuente: introspección en vivo 2026-09-05 (§11); changelog
oficial de GitHub, entrada «Schema changes for 2026-08-25»
(<https://docs.github.com/en/graphql/overview/changelog>, consultado 2026-09-05).

## 8. Tres fuentes REST del comentario del App

Cuando el Mergeador opera en fallback App (CLI rate-limited/caído, ver `talent-merger` ref 04), los
comentarios de CodeRabbit sobre un PR salen por **tres** endpoints REST distintos según el tipo:

| Fuente REST | Contenido | Endpoint |
|---|---|---|
| Issue comments | Walkthrough, summary, poem, respuestas a `@coderabbitai` | `GET repos/{owner}/{repo}/issues/{pr}/comments` |
| Reviews | Cuerpo del veredicto de la review (APPROVE/REQUEST_CHANGES/COMMENT) | `GET repos/{owner}/{repo}/pulls/{pr}/reviews` |
| Comentarios inline | Los review comments atados a línea (lo que también trae GraphQL vía `reviewThreads`) | `GET repos/{owner}/{repo}/pulls/{pr}/comments` |

```bash
gh api --paginate "repos/${OWNER}/${REPO}/issues/${PR}/comments" \
  --jq '.[] | select(.user.login | startswith("coderabbitai"))'
```

Usa `--paginate` en las tres (un PR grande puede exceder una página) y filtra por
`.user.login | startswith("coderabbitai")` (cubre tanto `coderabbitai` como `coderabbitai[bot]`). La
query GraphQL de §3 sigue siendo la vía obligatoria para **resolver** un thread — las tres fuentes REST
son solo para **leer** contenido cuando no quieres montar la query completa.

## 9. Permisos reales del GitHub App

`gh api orgs/{org}/installations` sobre este repo (owner de org, verificado en vivo) confirma la
instalación real de CodeRabbit: `app_id: 347564`, `app_slug: coderabbitai`,
`repository_selection: "all"`, permisos `{checks:"write", issues:"write", actions:"read",
members:"read", contents:"write", metadata:"read", statuses:"write", discussions:"read",
pull_requests:"write"}`. Comparado con la doc oficial de CodeRabbit
(<https://docs.coderabbit.ai/platforms/github-com>, sección «Review permissions», que describe
`checks` como read-only), la instalación real tiene `checks: write` — una discrepancia menor entre lo
documentado y lo instalado, sin impacto operativo conocido en este skill. Fuente: `gh api` en vivo
2026-09-05.

## 10. Rate limits y patrones comunes

GraphQL tiene **5000 puntos/hora** (`gh api rate_limit --jq '.resources.graphql'`, confirmado en vivo
2026-09-05 con `limit: 5000`). El listado de threads consume ~10-50 puntos según el tamaño del PR;
resolve/reply consumen ~1 punto cada uno. En el volumen diario de este repo no se llega al límite; si
pasa, `sleep 60 && retry`.

### Obtener solo threads NO resueltos de CR

```bash
gh api graphql -f query='...' -F owner=X -F name=Y -F pr=N \
  | jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved == false)
        | select(.comments.nodes[0].author.login | test("coderabbitai"; "i"))'
```

### Bulk resolve threads ya fixeados

```bash
for thread_id in $(cat resolved_threads.txt); do
  ./scripts/resolve_thread.sh "$thread_id"
  sleep 0.5  # colchón de rate limit, no un límite medido
done
```

## 11. Verificación en vivo (2026-09-05)

Todo lo anterior se re-verificó contra la API real, sin mutar nada (solo lectura/introspección):

- Query de §3 corrida contra el PR #2182 de este repo: devolvió un thread real
  (`id: "PRRT_kwDOSUMvGs6ewPoc"`, `isResolved: true`, `path:
  "supabase/migrations/20271331000000_..."`, comentarios con `author.login: "coderabbitai"` y
  `databaseId` presente).
- Introspección de `Mutation.fields` confirma `addPullRequestReviewThread`,
  `addPullRequestReviewThreadReply`, `resolveReviewThread`, `unresolveReviewThread` con
  `isDeprecated: false` las cuatro.
- Introspección de `AddPullRequestReviewThreadReplyInput` y `ResolveReviewThreadInput` confirma los
  campos citados en §6-§7 letra por letra.
- `gh api rate_limit` devolvió `{"limit":5000,"remaining":5000}` para el recurso `graphql`.

## 12. Errores comunes

### «Could not resolve to a node with the global id»

- El `thread_id` está mal. Debe tener prefijo `PRRT_`. Verifica con la query de listado (§3).
- No uses el `databaseId` del comentario como `threadId` — son identificadores distintos.

### «The user does not have permission»

- Tu token no tiene scope `repo` con write access al repo.
- `gh auth refresh -s repo` para re-autorizar.

## 13. Gotchas y referencias cruzadas

1. **`resolve`/`approve` de chat son todo-o-nada y top-level-only** — el `@coderabbitai resolve` del
   chat resuelve TODOS los threads del PR de una vez y solo acepta postearse como comentario top-level
   nuevo; el flujo `resolve_thread.sh` de este skill (GraphQL, thread por thread) es más preciso.
   Detalle completo en `references/commands.md`.
2. **`resolutionReason` es Copilot-only** (§7) — no lo pases esperando que CodeRabbit lo respete.
3. **La ruta REST de reply exige el `databaseId` del comentario RAÍZ**, nunca el de una respuesta
   (§6).
4. **Las tres fuentes REST del App (§8) son de solo lectura** — para resolver siempre hace falta
   GraphQL.

**Referencias relacionadas:**

- Para el ciclo de vida del comentario y su triage → `references/comment-taxonomy.md`
- Para los 27 comandos oficiales `@coderabbitai` (incluido `resolve`/`approve`) → `references/commands.md`
- Para el gate CLI del repo (que no usa GraphQL, corre local) → `references/gate-cli-del-repo.md`
- GitHub GraphQL explorer: <https://docs.github.com/en/graphql/overview/explorer>
- Schema de mutations: <https://docs.github.com/en/graphql/reference/mutations>
- Rate limits: <https://docs.github.com/en/graphql/overview/resource-limitations>
