# Imagen para correr el CRM en la nube (Railway).
# Se fija la versión de Node a mano: el server usa el SQLite que trae Node
# adentro (node:sqlite), y eso recién queda firme a partir de Node 24.

FROM node:24-slim

# El servidor de la nube corre en horario de Greenwich. Sin esto, el horario de
# silencio y el resumen diario salen tres horas corridos: el resumen de las 8
# llegaba 5 de la mañana.
ENV TZ=America/Argentina/Buenos_Aires

WORKDIR /app

# Primero las dependencias solas. Así, cuando cambia únicamente el código,
# no hay que volver a bajar todo de nuevo.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY . .

# Los datos (la base, las copias y la sesión de WhatsApp) NO viajan en la
# imagen: viven en el disco aparte que Railway monta en /app/datos y que
# sobrevive a cada actualización. El server crea las carpetas si faltan.

CMD ["node", "server.js"]
