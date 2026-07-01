# emby-doctor

`emby-doctor` es una herramienta Bash de diagnóstico para servidores baremetal Emby en Ubuntu/Debian.

Está pensada para revisar problemas típicos de Emby, rclone/FUSE, discos, kernel y red en servidores baremetal.

## Uso

```bash
sudo bash emby-doctor.sh
```

Para comprobar qué versión tienes:

```bash
bash emby-doctor.sh --version
```

Durante el diagnóstico:

- no reinicia servicios
- no borra archivos
- no desmonta mounts
- no cambia configuración
- no toca Emby, rclone, discos ni mounts

En modo normal puede instalar herramientas estándar de diagnóstico si faltan:

- `smartmontools` para SMART
- `sysstat` para `iostat`
- `lm-sensors` para temperatura
- `ethtool` para velocidad de interfaz

Si quieres forzar modo totalmente solo lectura, sin instalar nada:

```bash
sudo bash emby-doctor.sh --no-install-deps
```

Al terminar muestra un resumen fácil de copiar y pegar en ChatGPT, y además guarda:

```text
/tmp/emby-doctor-summary.txt
/tmp/emby-doctor-full.log
```

El resumen incluye:

- bloque `EN CLARO` con diagnóstico directo
- estado por área
- problemas detectados
- causa probable
- interpretación de las señales
- plan de actuación recomendado
- comandos recomendados

## Dependencias de diagnóstico

El script funciona sin dependencias raras, pero da más información con herramientas estándar. En modo normal intenta instalar solo las que falten usando `apt-get`.

También puedes instalarlas manualmente:

```bash
sudo bash install.sh
```

O pedirlo explícitamente desde el propio doctor:

```bash
sudo bash emby-doctor.sh --install-deps
```

El instalador usa `apt-get` e instala:

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
- no trata `high`/`crit` de `sensors` como fallo por sí solo; son umbrales. Solo alerta con `ALARM`, `CRITICAL`, `EMERGENCY` o throttling real del kernel.

### Emby

- estado de `emby-server` con `systemctl`
- errores de `journalctl` en las últimas 24 horas
- procesos Emby
- procesos activos de `ffmpeg`/transcodificación
- puertos `8096` y `8920`
- ubicación de logs, con rutas habituales de Emby en Linux
- resumen de errores relevantes en logs Emby, agrupado por patrones
- interpretación de errores comunes de Emby
- tamaño de la base de datos
- no toca ni modifica la DB; usa tamaño y logs reales para detectar señales de corrupción o bloqueo
- ignora errores de contenido aislado, como archivos de vídeo corruptos, porque no indican salud general del servidor

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
- conexiones activas a los puertos `8096`/`8920`
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

Ver [examples/emby-sample-output.txt](examples/emby-sample-output.txt).

## Nota importante

`emby-doctor` diagnostica, no repara. Las recomendaciones finales son pistas para investigar, no cambios automáticos.
