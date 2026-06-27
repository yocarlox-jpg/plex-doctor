# Changelog

## 0.2.1

- Corrige falso positivo de temperatura provocado por umbrales informativos `high` de `sensors`.
- Trata `sqlite3` con error `icu_root` como comprobación inconclusa, no como corrupción confirmada de DB.
- Recalibra la puntuación de salud para que avisos repetidos no hundan tanto el score.
- Hace la detección SMART más precisa y mantiene rojo solo para `FAILED`/fallo esperado.

## 0.2.0

- Añade sección `Interpretación` en el resumen final con explicación de las señales detectadas.
- Añade `Plan de actuación recomendado` con pasos priorizados y prudentes.
- Detecta patrones frecuentes en logs de Plex: EAE/watchfolder, perfiles de cliente, DB ocupada y sesiones de transcodificación caídas.
- Mantiene el script sin reparaciones automáticas en modo diagnóstico.

## 0.1.4

- Añade `--version` para comprobar rápidamente qué versión está instalada en el servidor.
- Trunca líneas enormes de `systemctl status plexmediaserver` para que las transcodificaciones no saturen la salida.

## 0.1.3

- Añade aviso inicial cuando falta `sqlite3`.
- Añade `sudo bash plex-doctor.sh --install-deps` para instalar dependencias opcionales de forma explícita antes del diagnóstico.
- Mantiene el modo normal como solo lectura.

## 0.1.2

- Añade fallback de `lsblk` compatible con Ubuntu 20.04.
- Acorta `systemctl status plexmediaserver` para evitar comandos enormes de transcodificación.
- Evita que la ausencia de `sqlite3` se interprete como causa probable de fallo de Plex.
- Detecta timeouts/fallos recientes de `plexmediaserver` en `journalctl` como advertencia.
- Cuenta procesos `rclone` reales con `pgrep -x`.

## 0.1.1

- Corrige compatibilidad con `gawk` en Ubuntu 20.04 evitando usar `load` como variable interna.
- Limita listados largos de procesos y conexiones para que la salida sea más manejable.
- Reduce falsos positivos de thermal throttling en líneas normales de arranque del kernel.

## 0.1.0

- Primera versión de `plex-doctor`.
- Diagnóstico de sistema, Plex, discos, rclone/FUSE, red y kernel.
- Resumen final copiable.
- Logs guardados en `/tmp/plex-doctor-summary.txt` y `/tmp/plex-doctor-full.log`.
- Instalador opcional para dependencias estándar de Ubuntu/Debian.
