# 03 — Buckets vivos y baselines (los sets, como DATOS)

> Fuente: TAL-5157 §B3 + §B7 (los sets NOISE/ANON/SA/CERT/KNOWN-BENIGN/WATCH
> «declarados en `references/03`, **no** embebidos en el script»). Este
> fichero es la **casa canónica** de los sets: `sentry_triage.py` los LEE de
> aquí, no los lleva dentro. Leer en cada ciclo y al adjudicar un grupo nuevo.

## Contrato de sincronización (leer primero — honestidad de origen)

La membresía VIVA de estos sets nació en el `ciclo.sh` de la torre C3
(`~/.sentry-analista/ciclo.sh` + el expediente `sentry-regreso.md`), **fuera
del repo y en la máquina de la Vigía**. Este fichero versiona el ESQUEMA y los
miembros que la auditoría TAL-5157 dejó documentados; la membresía completa y
al día se **sincroniza desde el expediente en el host de la Vigía**. Un
miembro que no esté aquí no está clasificado: cae a `SIN-CLASIF` y se triagea a
mano (ver `02-…`). Nunca se inventa un shortId ni una disposición: si no consta
con evidencia, va a `SIN-CLASIF`, no a un bucket.

## Formato que `sentry_triage.py` parsea

Cada bucket es un bloque cercado con la etiqueta `bucket:<NOMBRE>`; una entrada
por línea (`shortId` exacto **o** patrón `re:<regex>` sobre `culprit`/mensaje).
Líneas que empiezan por `#` son comentarios. El script carga estos bloques; si
un bucket está vacío, ese set queda vacío (no error).

### WATCH — crónicos acotados con gatillo de re-escalada (S3)

Conteo bajo, `userCount 0` estable, superficie no-money. Se vigilan; issue
SOLO si el gatillo dispara.

```bucket:WATCH
# shortId/patrón            # gatillo de re-escalada (obligatorio por entrada)
re:/upgrade.*42501          # 4Y: userCount>0 o count +20/24h
re:/ranking                 # cluster ranking: nueva transaction o userCount>0
8E                          # fail_rpc_error (TRANSITORIO): re-escala a +5 (o +1 si hay consulta abierta)
```

### KNOWN-BENIGN — adjudicados benignos por el CEO/lead con evidencia

Se rebaselinan. Cada entrada lleva SUS TRES triggers de re-escalada escritos
(sin los tres triggers, no entra: va a WATCH).

```bucket:KNOWN-BENIGN
# shortId    # 3 triggers de re-escalada (sincronizar del expediente)
93           # (triggers en el expediente; re-escala si cambia mechanism, si userCount>0, o si cruza umbral)
```

### NOISE — ruido S4, curación en `beforeSend` (NUNCA `ignoreErrors`, gotcha #3)

```bucket:NOISE
re:M_ID                     # extensión de navegador (TAL-5119): curar con igualdad EXACTA msg+mechanism
re:DarkReader
re:chrome-extension
re:moz-extension
```

### ANON — fail-closed anónimo en rutas gated (S4, esperado)

```bucket:ANON
re:42501                    # RLS deny anónimo en ruta gated: esperado, no incidente salvo pico en ruta pública
```

### SA — Server Action / deploy-window (esperado en ventana, gotcha #2)

`-22 UnrecognizedActionError` tras cada deploy = cliente con chunk viejo. Solo
incidente si persiste pasada la ventana o trepa con `userCount>0`.

Hallazgo del texto CR-CLI (corridas 2 y 3), medido: `re:-22` es un regex SIN
ancla — casa con `-22` en CUALQUIER posición de `culprit`/título, incluida
una fecha (`...09-22...`) o cualquier otro número no relacionado. Retirada:
`re:UnrecognizedActionError` ya cubre el caso documentado arriba (el nombre
de la clase de error), sin el riesgo de falso-positivo del fragmento suelto.
Las dos corridas del CR-CLI proponían reemplazos distintos entre sí para
anclar `-22` a texto real de Next.js ("Server Action ... was not found") que
no puedo verificar desde este canal (sin acceso empírico a Sentry) — se opta
por la opción que NO requiere adivinar texto de proveedor: quitar la línea
redundante en vez de re-anclarla a una cita sin verificar.

```bucket:SA
re:UnrecognizedActionError
```

### CERT — certeros/red/plataforma (WebKit, red, blips de deploy-window)

Fallos de plataforma/navegador/red no accionables por el producto.
**Definición viva en el expediente** — sincronizar; aquí solo el esqueleto.

```bucket:CERT
re:WebKit
re:NetworkError
re:Load failed
```

## Baseline y rebaselinado

- Tras adjudicar un grupo (benigno o WATCH), se **rebaselina**: el cursor
  registra su `count`/`lastSeen` de referencia; la re-escalada se mide contra
  esa referencia, no contra cero.
- Un cambio de `mechanism` en un grupo ya clasificado lo saca de su bucket:
  vuelve a `SIN-CLASIF`. La clasificación es por (mensaje + mechanism), nunca
  solo por mensaje (mismo principio que `beforeSend`, gotcha #3).
