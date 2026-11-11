# Framework Diátaxis — Reglas para el proyecto

Diátaxis organiza la documentación en 4 tipos según dos ejes: **acción vs. conocimiento** y **aprender vs. aplicar**. Cada tipo tiene reglas estrictas.

## Table of Contents

1. [Tutorials (`docs/tutorials/`)](#tutorials-docstutorials)
2. [How-to Guides (`docs/guides/`)](#how-to-guides-docsguides)
3. [Reference (`docs/reference/`)](#reference-docsreference)
4. [Explanation (`docs/explanation/`)](#explanation-docsexplanation)
5. [Regla de oro](#regla-de-oro)

---

## Tutorials (`docs/tutorials/`)

**Propósito**: Experiencia de aprendizaje guiada. El lector NO sabe nada aún.

**Reglas**:
- Siempre producen un resultado concreto y funcional al final
- Cada paso es ejecutable y verificable (el lector puede confirmar que funcionó)
- Minimizar explicaciones — priorizar "haz esto" sobre "esto funciona porque"
- Nunca ofrecer alternativas ni opciones — elegir UNA ruta y seguirla
- Si algo requiere explicación profunda, link a `explanation/` en vez de explicar inline
- El lector debe poder completarlo en 30 minutos o menos (dividir si es más largo)
- Nombrar archivo: `docs/tutorials/verbo-resultado.md` (ej: `crear-primer-evento.md`)

**Test**: ¿Un dev nuevo puede seguir esto sin ayuda y terminar con algo funcionando? Si no, reescribir.

**NO es un tutorial**: "Guía completa de la API de eventos" (eso es referencia). "Cómo configurar webhooks para tu caso específico" (eso es how-to).

## How-to Guides (`docs/guides/`)

**Propósito**: Resolver un problema concreto. El lector YA sabe lo básico.

**Reglas**:
- Título siempre empieza con "Cómo [verbo]..." o es un verbo en infinitivo
- Asumir que el lector ya completó el tutorial o tiene experiencia equivalente
- Ir directo al grano — sin introducción sobre qué es el sistema
- Puede ofrecer variantes ("si usas Docker..." / "si usas directamente...")
- Enfocarse en la tarea, no en el aprendizaje
- Incluir sección de troubleshooting si hay errores comunes
- Nombrar archivo: `docs/guides/verbo-tarea.md` (ej: `configurar-webhook-pagos.md`)

**Test**: ¿Alguien con prisa puede escanear esto en 2 minutos y resolver su problema? Si no, simplificar.

**NO es un how-to**: "Aprende a usar webhooks desde cero" (eso es tutorial). "Lista de todos los eventos webhook" (eso es referencia).

## Reference (`docs/reference/`)

**Propósito**: Describir el sistema exactamente como es. Fuente de verdad.

**Reglas**:
- Tono austero y preciso — como un diccionario técnico
- Estructura consistente: siempre la misma organización para el mismo tipo de contenido
- Completo — si un parámetro existe, debe estar documentado
- Sin opiniones, sin tutoriales, sin "te recomendamos"
- Tablas y listas son el formato natural aquí
- Generado automáticamente cuando sea posible (OpenAPI, TypeDoc, etc.)
- Nombrar archivo: `docs/reference/nombre-modulo.md` (ej: `api-eventos.md`)

**Test**: ¿Puedo buscar un dato específico (nombre de parámetro, tipo, valor default) y encontrarlo en 10 segundos? Si no, reorganizar.

**NO es referencia**: "Por qué elegimos PostgreSQL" (eso es explicación/ADR). "Cómo conectarse a la base de datos" (eso es how-to).

## Explanation (`docs/explanation/`)

**Propósito**: Dar contexto, razonamiento y entendimiento profundo.

**Reglas**:
- Tono conversacional — como explicar a un colega inteligente que no tiene contexto
- Responde al "por qué", no al "cómo"
- Conecta conceptos entre sí — puede referenciar múltiples partes del sistema
- Diagramas de arquitectura (Mermaid) son especialmente útiles aquí
- Puede discutir trade-offs, alternativas descartadas, historia de decisiones
- No incluir instrucciones paso a paso
- Nombrar archivo: `docs/explanation/concepto.md` (ej: `arquitectura-example-service-match.md`)

**Test**: ¿Un dev nuevo entiende el "por qué" del sistema después de leer esto? Si no, agregar más contexto.

**NO es explicación**: "Ejecuta este comando para desplegar" (eso es how-to). "Lista de endpoints" (eso es referencia).

## Regla de oro

Si al escribir un doc sientes que estás mezclando tipos, **dividirlo en dos archivos** y linkearlos entre sí. Un doc que es mitad tutorial mitad referencia no sirve bien para ninguno de los dos propósitos.

Patrón típico de un feature bien documentado:

```
docs/tutorials/crear-primer-evento.md          → Aprender haciendo
docs/guides/configurar-webhook-eventos.md       → Resolver tarea específica
docs/reference/api-eventos.md                   → Datos técnicos exactos
docs/explanation/arquitectura-sistema-eventos.md → Contexto y diseño
docs/decisions/0012-usar-kafka-para-eventos.md  → Decisión técnica (ADR)
```

No toda feature necesita los 5 tipos. Mínimo: **referencia** (siempre) + **un tipo más** según complejidad.
