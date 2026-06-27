# Changelog

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
