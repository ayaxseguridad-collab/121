---
name: talent-llm-local
description: >
  Montar un servidor de IA local identico al de referencia: Qwen3.6-35B-A3B (NVFP4)
  sobre vLLM con tensor parallel en 2 GPU Blackwell de 16 GB, 5 usuarios a la vez sin
  colas, puente que expone el modelo en /model de Claude Code junto a los de Anthropic
  con los alias qwen (rapido) y qwent (pensante), medidor por usuario y 4 puestos Hermes.
  Servicios systemd habilitados, todo en loopback, sin credenciales ni terceros. Una
  sola configuracion: la sonda es una PUERTA que autoriza o explica que falta, nunca
  monta una version recortada. Trigger (ES/EN): "IA local", "LLM local", "modelo local",
  "local llm", "self-hosted llm", "montar vllm", "vllm", "tensor parallel", "NVFP4",
  "Qwen3.6", "qwen", "qwent", "modelo propio", "servidor de inferencia", "tokens por
  segundo", "tok/s", "hermes agent", "agentes locales", "claude code modelo local",
  "ANTHROPIC_BASE_URL", "puente anthropic", "custom model option", "dos GPU", "multi-GPU",
  "sin pagar API", "privacidad datos IA", "offline llm".
---

# IA local en tu maquina — la misma que la de referencia

## Quick Orientation

| Propiedad | Valor |
|---|---|
| Que monta | Motor **vLLM 0.26.0** en contenedor · modelo **Qwen3.6-35B-A3B NVFP4** · tensor parallel = 2 · medidor por usuario · puente Anthropic · 4 puestos de agente |
| Para quien | 5 usuarios a la vez: tu sesion de Claude Code + 4 agentes. Sin colas en trabajo normal (medido con los 5 generando a la vez); un vecino leyendo un contexto grande SI te hace esperar — ver gotcha 16 |
| Hardware | **Exactamente 2 GPU Blackwell identicas de 16 GB o mas** (32 GB agregados), **Ubuntu** con systemd, 70 GB de disco |
| Variantes | **Ninguna.** Una sola configuracion, la rodada. La sonda autoriza o rechaza explicando |
| Dependencias externas | **Cero.** Sin credenciales nuestras, sin servidores nuestros, sin telemetria. Todo en loopback |
| Medido (2× RTX 5060 Ti) | 127-135 tok/s con 1 cliente · ~359 agregados con 5 · lectura de contexto 5.900→3.000 tok/s segun tamanio (4k→160k) · cache de prefijo: 100k en 2,2 s en vez de 26,9 s (12×) |
| Idioma | Espanol, para alumnos de Vibecoder Academy |

**Los numeros de arriba son de UNA maquina concreta.** Otro par de Blackwell de 16 GB
pasa la puerta legitimamente y puede rendir distinto: por eso el alumno corre `banco.sh`
y se queda con los suyos.

## Patrones esenciales

Quien habla con quien. **Nadie apunta al motor directamente salvo el medidor**: si un
cliente se salta el medidor, su consumo desaparece del reparto sin que salte ningun error.

```text
  4 puestos Hermes ──┐
   (una clave c/u)   │      medidor :8001          motor vLLM :8000
                     ├────► AUTENTICA a los 5 ───► Qwen3.6-35B-A3B NVFP4
  Claude Code ───────┘      y contabiliza          tensor parallel = 2
   /model qwen  ──► puente         │                (clave interna, modo 600,
   /model qwent ──► :8787 ─────────┘                 nunca en `ps`)
        │
        └── modelos claude* ──► api.anthropic.com  (paso directo, sin tocar nada:
                                                    tu suscripcion sigue intacta)
```

Fases de `montar.sh`, reentrantes e idempotentes:

```text
sonda → requisitos → claves → motor → modelo → servicio
      → medidor → puente → claude → hermes → verificar → banco
                  └──────── opcionales ────┘
```

`claves` va **antes** que `servicio` porque el medidor las necesita ya escritas, y
`servicio` antes que `medidor` porque el medidor lee del motor su clave interna.

La puerta, en una imagen:

```text
              ¿exactamente 2 GPU identicas?
                    │              │
                   si             no ──► RECHAZA, y dice cuantas hay
                    │
              ¿16 GB o mas cada una, 32 en total?
                    │              │
                   si             no ──► RECHAZA, y dice cuanto falta
                    │
              ¿capacidad de computo 10.0 o mas?
                    │              │
                   si             no ──► RECHAZA: sin Blackwell no hay NVFP4
                    │
                 AUTORIZA
```

No hay rama "monta algo mas modesto". Un montaje recortado no es esta configuracion, y
esta es la unica que se ha rodado.

## Reference Files (leer segun necesidad)

| Necesito… | Reference File |
|---|---|
| Que exige la puerta, de donde sale cada umbral y que queda fuera | `references/01-requisitos-y-sonda.md` |
| Motor: contenedor, tensor parallel, flags, unidades, limite de potencia | `references/02-motor-vllm.md` |
| El modelo, los dos alias y los parametros de muestreo exactos | `references/03-modelo-y-muestreo.md` |
| Puente e integracion con Claude Code sin romper la suscripcion | `references/04-puente-y-claude-code.md` |
| Las cinco claves, el medidor y los 4 puestos de agente | `references/05-cinco-usuarios-y-hermes.md` |
| Medir tu maquina y saber si tus numeros son normales | `references/06-medir-tu-maquina.md` |
| Sintoma → causa → arreglo de todo lo que ya nos ha pasado | `references/07-averias.md` |
| Que construir con ella (y las tres lecciones de usarla) | `references/08-que-hacer-con-ella.md` |

## Quick Start

```bash
# 1) ¿Llega tu maquina? (no cambia nada, no necesita administrador)
bash scripts/sonda.sh

# 2) Ver lo que haria, sin tocar nada
bash scripts/montar.sh --dry-run

# 3) Montarlo
sudo bash scripts/montar.sh
#    ...sin la integracion con Claude Code:   sudo bash scripts/montar.sh --sin-puente
#    ...una sola fase:                        sudo bash scripts/montar.sh --only servicio
#    ...retomar donde se quedo:               sudo bash scripts/montar.sh --from puente

# 4) Comprobar
bash scripts/verificar.sh

# 5) Medir TU maquina (los numeros de la documentacion son de otra)
bash scripts/banco.sh
```

Despues, en una sesion **nueva** de Claude Code: `/model` y elige el modelo local, o
teclea `/model qwen` (rapido) y `/model qwent` (pensante).

Para quitarlo todo: `sudo bash scripts/desmontar.sh`.

## Critical Gotchas

1. **Las claves de usuario NUNCA van en la linea de arranque** → los argumentos de un
   proceso los lee cualquier usuario con `ps`, asi que poner ahi las cinco destruiria
   la atribucion por usuario: cualquiera podria suplantar a cualquiera. Aqui autentica
   el **medidor** (que ya es el unico que habla con el motor) leyendolas de un fichero
   restringido, y el motor conoce **una** clave interna que vive en su fichero de
   entorno en modo 600. Si algun dia usas `--api-key` a mano: va **una sola vez** con
   todas las claves detras — repetir el flag hace que la ultima pise a las demas, y
   como una si funciona el fallo parece intermitente.

2. **`--gpus all`, nunca `--gpus '"device=0,1"'`** → la segunda forma no sobrevive al
   parseo de `ExecStart` y systemd aborta con «cannot set both Count and DeviceIDs».

3. **`--max-num-seqs 16`** → el valor por defecto de vLLM (256) **impide arrancar** con
   este modelo por los bloques Mamba de sus capas lineales. No es un ajuste de
   rendimiento: sin el no hay servidor.

4. **Los umbrales de VRAM van en MiB, no en GiB** → una tarjeta «de 16 GB» declara
   16311 MiB, que son 15,93 GiB. Con el umbral escrito en GiB, la puerta rechaza la
   maquina de la que salio este montaje.

5. **Nunca `ANTHROPIC_AUTH_TOKEN` ni `ANTHROPIC_API_KEY` en `settings.json`** →
   anulan la suscripcion de claude.ai. El puente funciona con **solo**
   `ANTHROPIC_BASE_URL`, que es justo lo que preserva el paso directo autenticado.

6. **Claude Code lee el entorno al ARRANCAR** → una sesion ya abierta no ve el modelo
   nuevo por mucho que se recargue. Hay que abrir sesion nueva. Salida de emergencia si
   el puente muriera: `ANTHROPIC_BASE_URL="" claude`.

7. **El limite de potencia es volatil** → se pierde en cada reinicio. Por eso vive en su
   propia unidad de systemd y no en un ajuste que alguien aplico una vez. Y por eso
   `verificar.sh` lo cuenta **aparte**: un limite que no queda puesto no puede esconderse
   dentro de un «todo correcto».

8. **`--reasoning-parser qwen3` y `--tool-call-parser qwen3_xml`** → sin ellos el
   razonamiento y las llamadas a herramientas salen como texto plano mezclado con la
   respuesta, y el cliente no los distingue.

9. **En el modo pensante hay que dar margen de salida** → con presupuestos cortos el
   razonamiento se agota dentro del bloque y **no sale respuesta**: tokens gastados,
   pantalla vacia. El puente eleva el minimo a 6.000 por eso.

10. **El campo del razonamiento cambio de nombre** → desde vLLM 0.26 llega en `reasoning`
    y antes en `reasoning_content`. El puente lee los dos. Con el campo mal leido el
    sintoma es exactamente el del punto anterior, y se diagnostica mal.

11. **Todos los clientes al medidor (:8001), nadie al motor (:8000)** → apuntar al motor
    funciona igual de bien y hace desaparecer ese consumo del reparto por usuario. No da
    ningun error: simplemente las cuentas dejan de cuadrar.

12. **Un directorio de datos por puesto de agente** → dos instancias sobre el mismo
    directorio corrompen el estado. Y `max_concurrent_children: 1`, porque con 4 puestos
    y la delegacion por defecto salen hasta 16 flujos contra un servidor dimensionado
    para 5.

13. **La imagen se fija por digest, no por `:latest`** → una etiqueta movil hace que la
    maquina de dentro de tres meses no sea la que se rodo hoy. Reproducibilidad o
    etiqueta comoda: no las dos.

14. **Los pesos se descargan con la red abierta** → el `HF_HUB_OFFLINE=1` del entorno del
    servicio hace los arranques diarios rapidos y deterministas, pero impediria la
    descarga inicial. Por eso la fase `modelo` va antes y no hereda ese entorno.

15. **Rutas con espacios** → nada de `${VAR%% *}` para quedarse con el binario de una
    ruta: si el directorio tiene espacios, el troceo la parte y el script cree que falta
    el programa. (Nos paso montando esto.)

16. **El cache de prefijo es COMPARTIDO entre los 5 usuarios y se desaloja desde la
    cabeza** → el cache KV es uno para todos (333k tokens en la referencia), y el
    trafico ajeno desaloja primero los bloques mas viejos, que son el COMIENZO de tu
    prefijo. Sin la cabeza, el resto no sirve aunque siga en memoria: el acierto cae de
    98% a 0% de golpe, no gradualmente (medido: un prefijo de 100k sobrevive a ~50k de
    trafico ajeno y muere con 100k). Perderlo no cuesta nada extra — pagas el prefill en
    frio, exactamente (26,5 s frente a 26,9). Lo caro es la COLA: tu peticion detras de
    un vecino que esta leyendo 160k tarda 250× mas (medido: de 0,3 s a 77 s). Ninguna de
    las dos cosas es un fallo que arreglar: es la aritmetica de un servidor compartido, y
    conviene saberla antes de prometer tiempos.

## Cross-Skill Integration

- **`skill-creator`** — este skill sigue su Gold Standard; se valida con
  `python3 .claude/skills/skill-creator/scripts/validate_skill.py talent-llm-local`.
- **`talent-lecciones`** — si el montaje se convierte en leccion grabada, el guion y las
  slides se escriben con ese skill; este aporta el contenido tecnico y los comandos.
- **`talent-channels`** — comparte molde (script por fases idempotente, `assets/`,
  `tests/`) y publico (aprovisionar una maquina desde cero), pero no se solapan: aquel
  monta canales de desarrollo, este monta un servidor de inferencia.
- **`claude-api`** — para entender el formato de Messages que traduce el puente.
- **`talent-docs-skill`** — cualquier documento que salga de aqui hacia `docs/`.

Este skill **no** toca Linear, ni Supabase, ni el producto: monta una maquina.

## Verificacion

```bash
bash scripts/verificar.sh                      # nucleo y opcionales, por separado
bash tests/probar-sonda.sh                     # 20 casos de la puerta, sin hardware
bash tests/probar-fallo-cerrado.sh             # el instalador falla cerrado
bash tests/probar-puente.sh                    # las 8 combinaciones del puente
bash tests/comparar-con-referencia.sh          # ¿genera lo que de verdad corre?
```

`verificar.sh` distingue tres estados a proposito: **OK**, **FALLO** (con el comando que
lo arregla) y **OMIT** para lo que se salto queriendo. Quien monta con `--sin-puente`
tiene un montaje correcto, no uno a medias.

## Estado de verificacion — lo que esta probado y lo que no

Este skill sale de un montaje **rodado**, no de un disenio sobre papel. Aun asi, dos cosas
**no se han verificado** y se dicen con esas palabras en vez de darlas por buenas.

| Punto | Estado | Evidencia |
|---|---|---|
| La puerta rechaza lo que debe | **Verificado** | 20 casos en `tests/probar-sonda.sh`, cada uno con veredicto **y** motivo |
| El instalador no anuncia exito sobre algo roto | **Verificado** | `tests/probar-fallo-cerrado.sh`: un `settings.json` invalido detiene la fase, no se toca el fichero, y el caso valido sigue funcionando |
| Las 8 combinaciones del puente | **Verificado** | `tests/probar-puente.sh`: texto/herramientas × bloqueante/streaming × `qwen`/`qwent`, 8 de 8, comprobando ademas que `qwen` **no** razona |
| Ninguna clave de usuario visible con `ps` | **Verificado** | `verificar.sh` lo comprueba explicitamente, y que el motor rechace una clave de usuario |
| El skill reproduce el montaje real | **Verificado** | `tests/comparar-con-referencia.sh`: la unidad que genera coincide con la que corre |
| `qwen` y `qwent` responden, con razonamiento | **Verificado** | `verificar.sh` contra la maquina de referencia |
| Paso directo a Anthropic sin romper la suscripcion | **Verificado** | Sesiones de trabajo reales de horas atravesando el puente, sin un solo 401 |
| La lectura de contexto es una curva, no una cifra | **Verificado** | Banco del 27-jul con texto unico y conteo real de tokens (0 aciertos de cache en 755k consultas, comprobado): 5.873 tok/s a 4k → 2.997 a 160k. Dos tandas independientes coinciden dentro del 3% |
| El cache de prefijo con conversacion real | **Verificado** | Conversacion creciente 20k→100k reenviando todo el historial: 26,9 s en frio → 2,2 s reutilizado (12×), y casi plano al crecer — el coste es proporcional a lo NUEVO, no al total |
| Desalojo y cola entre usuarios | **Verificado** | Acantilado entre 50k y 100k de trafico ajeno (acierto 98,4% → 0,0%) · volver desalojado cuesta lo mismo que en frio (26,49 s frente a 26,92) · cola concurrente detras de un vecino de 160k: 250× |
| **Persistencia tras un reinicio completo** | **NO VERIFICADA** | Las unidades estan `enabled` y arrancan solas, pero **el ciclo entero de reinicio no se ha ejercitado**. Tras montar, reinicia y corre `verificar.sh`: si algo no vuelve, esta en `07-averias.md` |
| **Idempotencia de `montar.sh` corriendolo dos veces** | **NO VERIFICADA de extremo a extremo** | Cada pieza esta escrita para ser reentrante (bloques delimitados, claves que no rotan solas, unidades que se reescriben) y el recorrido completo se comprobo en `--dry-run`, pero **no se ha corrido dos veces seguidas sobre una maquina real** |

Cuando alguien las ejercite, esta tabla se actualiza con lo que salga. Mientras tanto, un
«no verificado» honesto vale mas que un «funciona» sin comprobar — que es exactamente el
fallo que este mismo modelo comete y que `08-que-hacer-con-ella.md` ensenia a no repetir.

## Fuera de alcance

Una sola GPU (aunque sea de 32 GB) · tensor parallel de 4 u 8 · tarjetas distintas entre
si · GPU sin NVFP4 (anteriores a Blackwell) · AWQ/GPTQ · otros motores · distribuciones
que no sean Ubuntu · macOS · Windows · entrenamiento y ajuste fino · exponer el servidor
fuera de la maquina.

Cada uno de esos casos necesita una configuracion distinta que **no hemos rodado**;
`references/01-requisitos-y-sonda.md` explica que haria falta, marcado como informacion,
no como promesa.

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.

## Next Steps

- ¿Tu maquina llega? → `references/01-requisitos-y-sonda.md`
- ¿Que hace cada flag del motor? → `references/02-motor-vllm.md`
- ¿Cuando `qwen` y cuando `qwent`? → `references/03-modelo-y-muestreo.md`
- ¿Como convive con Opus en `/model`? → `references/04-puente-y-claude-code.md`
- ¿Como enchufo los 4 agentes? → `references/05-cinco-usuarios-y-hermes.md`
- ¿Mis numeros son normales? → `references/06-medir-tu-maquina.md`
- Algo no arranca → `references/07-averias.md`
- Ya funciona, ¿y ahora que? → `references/08-que-hacer-con-ella.md`
