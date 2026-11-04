# Prompt — Issue template para Bugs

Plantilla específica para issues de tipo bug. Usar al crear cualquier issue con `kind:fix`. Es más estricta que la de feature porque sin repro no hay bug accionable.

## Estructura

````markdown
## Síntoma

[Descripción 1-2 frases de qué está pasando que no debería.]

## Severidad

[S1 / S2 / S3 / S4 — ver workflows/05-bug-handling.md]

## Repro

1. Paso 1 (concreto, accionable)
2. Paso 2
3. Paso 3
4. ...

## Resultado esperado

[Qué debería pasar al ejecutar los pasos anteriores.]

## Resultado observado

[Qué pasa realmente. Sé específico — copia error messages exactos
si los hay.]

## Ambiente

- Producción / Staging / Local
- Browser/OS si aplica: Chrome 132 macOS 14
- Versión del producto: <commit hash o tag>
- Usuario afectado (rol): admin / cliente / interno
- Frecuencia: siempre / ocasional / 1 sola vez

## Evidencia

- Screenshot: [link o pegado]
- Logs: [link a Datadog / Sentry / paste]
- Error message exacto: `<message>`
- Sentry issue ID: <id>

## Hipótesis (si la tienes)

[Opcional. Donde sospechas que está el bug.]
- Probablemente en `src/auth/validate.ts` línea 42
- Posible cambio reciente que lo introdujo: PR #<N>

## Workaround

[Si hay alguno mientras se arregla, mencionarlo. NO es opcional para S1/S2.]

## Test que debería pasar

[Si tienes un test que reproduce el bug, ponlo aquí.
Si no, la primera tarea del fix será escribirlo.]

```typescript
test('valida password con caracteres especiales', () => {
  const result = validatePassword('p@ssw0rd!');
  expect(result.valid).toBe(true);
});
```

## Out of scope

[Si el reporte original incluía cosas que NO son este bug.]

````

## Checklist de calidad

Antes de crear el bug:

- [ ] **Title** describe el síntoma, no la solución (`Login falla con caracteres especiales` no `Mejorar validación de password`)
- [ ] **Repro reproducible** (puedes seguir tus pasos en otra máquina y obtener el mismo resultado)
- [ ] **Severidad** asignada
- [ ] **Resultado esperado** y **observado** son distinguibles textualmente
- [ ] **Ambiente** documentado
- [ ] **Evidencia** adjunta (al menos error message)
- [ ] Si S1/S2: **workaround** documentado
- [ ] **Vertical label** + `kind:fix`
- [ ] **Priority** mapeada de severidad
- [ ] Si va a IA: tests escritos antes de delegar

## Ejemplos de buenos bugs

### Ejemplo 1 — Bug con repro claro (delegable a IA)

````markdown
# Title
Validación de password rechaza caracteres especiales válidos

## Síntoma

Usuarios no pueden registrarse con passwords que contengan `@`, `!`, `#`
aunque la guía de UX dice que deben aceptarse.

## Severidad

S2 — Alto. Bloquea registro nuevo, parcialmente.

## Repro

1. Ir a https://talent-land.com/registro
2. Llenar email cualquiera
3. En password escribir `pass@word123`
4. Click en "Crear cuenta"

## Resultado esperado

Cuenta creada, redirige a /dashboard.

## Resultado observado

Mensaje de error: "Password contiene caracteres no permitidos"
La cuenta NO se crea.

## Ambiente

- Producción
- Reproducido en Chrome 132 (mac), Safari (iOS), Firefox (linux)
- Frecuencia: siempre con caracteres especiales
- Versión: master @ commit abc123

## Evidencia

- Screenshot del error: [adjunto]
- Console error: ninguno (es validación server-side)
- Network response: `{"error": "INVALID_PASSWORD_CHARS"}`

## Hipótesis

`src/auth/validatePassword.ts` línea ~50 tiene regex que excluye
caracteres especiales. Probablemente fue cambiado en PR #234
(commit hace 2 semanas).

## Test que debería pasar

```typescript
test('acepta password con @ y !', () => {
  expect(validatePassword('pass@word!')).toEqual({ valid: true });
});

test('acepta password con # y $', () => {
  expect(validatePassword('p#ss$word')).toEqual({ valid: true });
});
```

## Workaround

Mientras tanto: el frontend muestra un mensaje pidiendo no usar
caracteres especiales. Es UX degradada pero permite seguir.

````

→ Buen candidato para `actor/ai`. Repro claro, test definido, archivo identificado.

### Ejemplo 2 — Bug intermitente (NO delegable inicialmente)

```markdown
# Title
Sesiones se cierran aleatoriamente en talent-land-online

## Síntoma

Usuarios reportan que estando viendo un video la sesión se cierra
y los devuelve al login. Intermitente, no reproducible a demanda.

## Severidad

S3 — Medio. Afecta UX, hay workaround (re-login).

## Repro

NO reproducible a demanda. Ocurre aprox. 2 veces por semana
según reportes de usuarios.

## Resultado esperado

Sesión persiste mientras se ve contenido (token de 24h).

## Resultado observado

Logout forzado en momentos aparentemente aleatorios.

## Ambiente

- Producción
- Diferentes browsers (Chrome, Safari, Firefox)
- Diferentes devices (desktop, móvil)
- Frecuencia: ~2/semana, varios usuarios distintos

## Evidencia

- 5 reportes en support (links a tickets)
- No hay errores en frontend logs (Sentry frontend)
- En backend logs: `auth: token validation failed` con timestamp
  matching los reportes
- [Sentry issue ID](link)

## Hipótesis

Posibles causas:
1. Token caducando antes de los 24h por alguna race condition
2. Refresh token no funcionando en algún edge case
3. Session storage del browser limpiada por algo

## Workaround

Volver a hacer login.

## Out of scope

- Logout esperado (después de 24h o cierre de sesión manual)
- Logout en múltiples devices (es comportamiento by-design)
```

→ NO delegar a IA. Necesita debugging exploratorio. Asignar a humano. Primer paso: **añadir más logging** (sub-issue `kind:chore`).

## Plantilla mínima (para bugs cosméticos S4)

```markdown
## Síntoma
[1 frase]

## Repro
[Pasos ultra concisos]

## Esperado vs observado
[Línea por línea]

## Severidad: S4 — cosmético
```

## Anti-patrones

❌ **Bug sin repro**: ruido, no accionable. Pedir repro antes de crear.

❌ **"No funciona"** como title o description: cero información.

❌ **Repro que requiere data del reporter**: si tu repro es "con mi cuenta de X", crea un usuario de test que sea reproducible para el equipo.

❌ **Severity = priority del reporter**: severity es objetiva (impacto medible). El reporter dirá que todo es urgente.

❌ **Bug sin workaround para S1/S2**: el workaround importa al equipo de soporte mientras se arregla.

❌ **Asumir causa raíz como hecho**: la hipótesis es hipótesis. NO escribir "el bug está en X" sin evidencia.

❌ **Mezclar dos bugs en uno**: si tu repro genera 2 errores distintos, son 2 bugs.

❌ **No vincular a Sentry / Datadog issue ID**: pierdes la trazabilidad post-mortem.
