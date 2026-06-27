# plex-doctor

`plex-doctor` es una herramienta Bash de diagnóstico para servidores baremetal Plex en Ubuntu/Debian.

Está pensada para revisar problemas típicos de Plex, rclone/FUSE, discos, kernel y red sin modificar nada del sistema.

## Uso

```bash
sudo bash plex-doctor.sh
```

El script es de solo lectura:

- no reinicia servicios
- no borra archivos
- no desmonta mounts
- no cambia configuración
- no instala nada

Al terminar muestra un resumen fácil de copiar y pegar en ChatGPT, y además guarda:

```text
/tmp/plex-doctor-summary.txt
/tmp/plex-doctor-full.log
```

## Instalación de dependencias opcionales

El script funciona sin dependencias raras, pero puede dar más información si instalas herramientas estándar:

```bash
sudo bash install.sh
```

El instalador usa `apt-get` e instala:

- `sqlite3`
- `smartmontools`
- `sysstat`
- `lm-sensors`
- `ethtool`

## Qué revisa

### Sistema

- hostname
- sistema operativo
- kernel
- uptime
- load average
- CPU
- RAM
- swap
- procesos con más CPU
- procesos con más RAM
- temperatura si existe `sensors`

### Plex

- estado de `plexmediaserver` con `systemctl`
- errores de `journalctl` en las últimas 24 horas
- procesos Plex
- procesos activos de `Plex Transcoder`
- puerto `32400`
- ubicación de logs
- últimos errores relevantes en logs Plex
- tamaño de la base de datos
- `PRAGMA quick_check` de la DB si existe `sqlite3`

### Discos

- `df -hT`
- `df -ih`
- `lsblk`
- I/O wait con `iostat` si existe
- SMART con `smartctl` si existe
- errores I/O en `dmesg` y `journalctl`

### rclone / FUSE

- procesos `rclone`
- mounts `fuse.rclone`
- mounts rotos tipo `Transport endpoint is not connected`
- posibles duplicados de rclone
- respuesta rápida de rutas bajo `/mnt`

### Red

- IPs
- gateway
- ping al gateway
- ping a `1.1.1.1`
- DNS
- conexiones activas al puerto `32400`
- velocidad de interfaz si existe `ethtool`

### Kernel / sistema

- OOM killer
- segfaults
- errores NVMe/SATA
- thermal throttling
- reinicios recientes

## Compatibilidad

Objetivo principal:

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Ubuntu 26.04
- Debian moderno

El script evita Bash avanzado innecesario y comprueba si cada herramienta opcional existe antes de usarla.

## Ejemplo de salida

Ver [examples/sample-output.txt](examples/sample-output.txt).

## Nota importante

`plex-doctor` diagnostica, no repara. Las recomendaciones finales son pistas para investigar, no cambios automáticos.
