# Changelog — talent-context

- Pieza P2 (issue 8544): puntero, herramientas y doctrina del paquete en `scripts/paquete/`; lista de diez miembros tras retirar skill-creator.

Esta es la distribución publicable del paquete de fábrica: la bitácora interna de
desarrollo no se incluye.

## Distribución pública — 2026-09 (paquete 2.0.0)

## Sin publicar — compact vivo

Banco por seis hooks, lista blanca fail-closed, rescate Unicode y guardas A/B. El autocompact
es el camino por defecto; se conserva el relevo manual como modo degradado.

Corrección del acta: dependencia de versión fallida rechazada sin escrituras;
JWT cortos y tokens de todas las longitudes redactados, también en estado manual;
agregado con resumen único, conteos concordantes y mínimos de 187/54 aserciones (la cifra
anterior del hook, 95, figuraba aquí como 94).

Órdenes íntegras: además de la línea del diario, el mensaje ENTERO del usuario y los mensajes
entre sesiones se guardan redactados en `ordenes.md` (0600; secciones LEAD y ENTRE SESIONES;
repetidos contados; retención sin pérdida por número y por tamaño, con archivo) y tras el
compact se inyectan en dos bloques acotados. Un mensaje entre sesiones es un dato, nunca una
orden. Contratos previos intactos: lista blanca fail-closed, redacción, topes, enlaces, rc 0.
El redactor se amplía solo de forma aditiva: las fechas ISO ya no se confunden con teléfonos y
se ocultan los bloques PEM de clave privada, las credenciales dentro de una URL y las claves
`sk_live_`, `whsec_` y `AIza`.
