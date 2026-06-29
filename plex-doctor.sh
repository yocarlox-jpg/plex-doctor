#!/usr/bin/env bash

set -uo pipefail

VERSION="0.4.2"
SUMMARY_FILE="/tmp/plex-doctor-summary.txt"
FULL_LOG="/tmp/plex-doctor-full.log"
AUTO_INSTALL_DEPS=1

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
fi

OK_ICON="🟢"
WARN_ICON="🟡"
BAD_ICON="🔴"
INFO_ICON="ℹ️"

declare -a PROBLEMS=()
declare -a INFO_NOTES=()
declare -a RECOMMENDATIONS=()
declare -a SUMMARY_LINES=()

HEALTH_SCORE=100
SYSTEM_STATUS="${OK_ICON} OK"
CPU_STATUS="${OK_ICON} OK"
RAM_STATUS="${OK_ICON} OK"
DISK_STATUS="${OK_ICON} OK"
PLEX_STATUS="${WARN_ICON} No comprobado"
PLEX_DB_STATUS="${WARN_ICON} No comprobado"
TRANSCODER_STATUS="${OK_ICON} Sin procesos activos"
RCLONE_STATUS="${OK_ICON} OK"
NETWORK_STATUS="${OK_ICON} OK"

usage() {
  cat <<EOF
Uso:
  sudo bash plex-doctor.sh
  sudo bash plex-doctor.sh --install-deps
  sudo bash plex-doctor.sh --no-install-deps

Opciones:
  --install-deps           Instala dependencias de diagnóstico con apt-get antes del diagnóstico.
  --install-optional-deps  Alias de --install-deps.
  --no-install-deps        No instala nada; ejecuta solo las comprobaciones disponibles.
  --read-only              Alias de --no-install-deps.
  --version                Muestra la versión y termina.
  -h, --help               Muestra esta ayuda.

Modo normal: puede instalar herramientas estándar de diagnóstico si faltan.
No reinicia servicios, no borra archivos y no cambia configuración de Plex/rclone/discos.
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --install-deps|--install-optional-deps)
        AUTO_INSTALL_DEPS=1
        ;;
      --no-install-deps|--read-only)
        AUTO_INSTALL_DEPS=0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --version)
        printf "plex-doctor %s\n" "$VERSION"
        exit 0
        ;;
      *)
        printf "%sOpción desconocida: %s%s\n" "$C_RED" "$arg" "$C_RESET" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

section() {
  printf "\n%s%s%s\n" "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}"
  printf "%s\n" "────────────────────────────────────"
}

subsection() {
  printf "\n%s%s%s\n" "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"
}

run_cmd() {
  local title="$1"
  shift
  printf "\n%s$ %s%s\n" "${C_DIM}" "$*" "${C_RESET}"
  "$@" 2>&1 || printf "%sComando no disponible o falló: %s%s\n" "${C_YELLOW}" "$title" "${C_RESET}"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

install_missing_diagnostic_deps() {
  local missing_packages=()

  have smartctl || missing_packages+=("smartmontools")
  have iostat || missing_packages+=("sysstat")
  have sensors || missing_packages+=("lm-sensors")
  have ethtool || missing_packages+=("ethtool")

  if ((${#missing_packages[@]} == 0)); then
    return
  fi

  if (( AUTO_INSTALL_DEPS == 0 )); then
    add_info "Faltan herramientas de diagnóstico (${missing_packages[*]}), pero se omitió la instalación por --no-install-deps."
    printf "%s%s Faltan herramientas de diagnóstico: %s%s\n" "$C_YELLOW" "$WARN_ICON" "${missing_packages[*]}" "$C_RESET"
    return
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    add_info "Faltan herramientas de diagnóstico (${missing_packages[*]}). Ejecuta con sudo para instalarlas automáticamente."
    printf "%s%s Faltan herramientas de diagnóstico: %s. Ejecuta con sudo para instalarlas.%s\n" "$C_YELLOW" "$WARN_ICON" "${missing_packages[*]}" "$C_RESET"
    return
  fi

  if ! have apt-get; then
    add_info "Faltan herramientas de diagnóstico (${missing_packages[*]}), pero este sistema no tiene apt-get."
    printf "%s%s Faltan herramientas de diagnóstico: %s. No hay apt-get disponible.%s\n" "$C_YELLOW" "$WARN_ICON" "${missing_packages[*]}" "$C_RESET"
    return
  fi

  printf "%s%s Instalando herramientas de diagnóstico faltantes: %s%s\n" "$C_YELLOW" "$WARN_ICON" "${missing_packages[*]}" "$C_RESET"
  if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"; then
    add_info "Se instalaron herramientas de diagnóstico faltantes: ${missing_packages[*]}."
  else
    add_problem "$WARN_ICON" "no se pudieron instalar herramientas de diagnóstico (${missing_packages[*]})"
    add_recommendation "revisar apt-get e instalar dependencias de diagnóstico"
  fi
}

add_problem() {
  local severity="$1"
  local message="$2"
  PROBLEMS+=("${severity} ${message}")
  case "$severity" in
    "$BAD_ICON") HEALTH_SCORE=$((HEALTH_SCORE - 12)) ;;
    "$WARN_ICON") HEALTH_SCORE=$((HEALTH_SCORE - 4)) ;;
    *) HEALTH_SCORE=$((HEALTH_SCORE - 2)) ;;
  esac
}

add_info() {
  local message="$1"
  local existing
  for existing in "${INFO_NOTES[@]:-}"; do
    [[ "$existing" == "$message" ]] && return
  done
  INFO_NOTES+=("$message")
}

add_recommendation() {
  local recommendation="$1"
  local existing
  for existing in "${RECOMMENDATIONS[@]:-}"; do
    [[ "$existing" == "$recommendation" ]] && return
  done
  RECOMMENDATIONS+=("$recommendation")
}

count_text_matches() {
  local text="$1"
  local pattern="$2"
  printf "%s\n" "$text" | grep -Eic "$pattern" 2>/dev/null || true
}

print_plex_error_summary() {
  local errors="$1"
  local client_profile h264 transcode_dead db_corruption db_busy eae_errors

  if [[ -z "$errors" ]]; then
    printf "\nResumen de errores Plex:\n%s\n" "sin errores recientes encontrados"
    return
  fi

  client_profile="$(count_text_matches "$errors" 'Unable to find client profile|ClientProfileExtra')"
  h264="$(count_text_matches "$errors" 'non-existing PPS|decode_slice_header|no frame|invalid NAL|error while decoding|h264')"
  transcode_dead="$(count_text_matches "$errors" 'Session appears to have died|TranscodeOutputStream')"
  db_corruption="$(count_text_matches "$errors" 'database disk image is malformed|database corruption|database is corrupt|SQLITE_CORRUPT|SQLITE_NOTADB|not a database|file is encrypted or is not a database')"
  db_busy="$(count_text_matches "$errors" 'database is locked|busy DB|SQLITE_BUSY|Sleeping for .*busy DB|retry busy DB')"
  eae_errors="$(count_text_matches "$errors" 'Error iterating EAE watchfolder|EasyAudioEncoder|EAE')"

  printf "\nResumen de errores Plex:\n"
  (( db_corruption > 0 )) && printf -- "- %s señales de posible corrupción de DB. Esto sí es importante: backup antes de tocar nada.\n" "$db_corruption"
  (( db_busy > 0 )) && printf -- "- %s señales de DB ocupada/bloqueada. Suele ser temporal si coincide con escaneos, metadatos o mucha actividad.\n" "$db_busy"
  (( eae_errors > 0 )) && printf -- "- %s errores EAE/transcode. Suelen venir de audio/subtítulos/transcodificación.\n" "$eae_errors"
  (( h264 > 0 )) && printf -- "- %s errores H264/decode. Normalmente apuntan a un vídeo/stream/cliente concreto, no a Plex entero.\n" "$h264"
  (( transcode_dead > 0 )) && printf -- "- %s sesiones de transcode caídas. Puede ser normal si el cliente cerró reproducción.\n" "$transcode_dead"
  (( client_profile > 0 )) && printf -- "- %s errores de perfil cliente. Suele ser ruido de una app/TV concreta.\n" "$client_profile"

  if (( db_corruption + db_busy + eae_errors + h264 + transcode_dead + client_profile == 0 )); then
    printf -- "- Hay errores en logs, pero no coinciden con patrones frecuentes clasificados.\n"
  fi

  if (( db_corruption + db_busy > 0 )); then
    printf "\nLíneas DB recientes, máximo 5:\n"
    printf "%s\n" "$errors" | grep -Ei 'database disk image is malformed|database corruption|database is corrupt|SQLITE_CORRUPT|SQLITE_NOTADB|not a database|file is encrypted or is not a database|database is locked|busy DB|SQLITE_BUSY|Sleeping for .*busy DB|retry busy DB' | tail -n 5
  fi

  printf "\nÚltimas líneas crudas, máximo 12:\n"
  printf "%s\n" "$errors" | tail -n 12
}

safe_timeout() {
  local seconds="$1"
  shift
  if have timeout; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

count_processes() {
  local pattern="$1"
  if have pgrep; then
    pgrep -f "$pattern" 2>/dev/null | wc -l | awk '{print $1}'
  else
    ps -eo args 2>/dev/null | grep -Ei "$pattern" | grep -vc grep || true
  fi
}

count_process_names() {
  local name="$1"
  if have pgrep; then
    pgrep -x "$name" 2>/dev/null | wc -l | awk '{print $1}'
  else
    ps -eo comm 2>/dev/null | awk -v name="$name" '$0 == name {count++} END {print count+0}'
  fi
}

print_kv() {
  printf "%-24s %s\n" "$1:" "$2"
}

print_compact_systemctl_status() {
  printf "\n%s$ systemctl status plexmediaserver --no-pager --lines=35%s\n" "${C_DIM}" "${C_RESET}"
  systemctl status plexmediaserver --no-pager --lines=35 2>&1 \
    | sed -E 's/(Plex Transcoder|Plex Media Scanner|Plex Media Fingerprinter|Plex EAE Service).{120}.*/\1 ... [línea truncada]/'
}

collect_system() {
  section "1. Sistema"

  local hostname os kernel uptime load cpu_model cpu_count mem swap load1 load_per_cpu mem_total mem_used mem_pct swap_total swap_used swap_pct temp_output
  hostname="$(hostname 2>/dev/null || echo "desconocido")"
  os="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-desconocido}" || echo "desconocido")"
  kernel="$(uname -r 2>/dev/null || echo "desconocido")"
  uptime="$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "desconocido")"
  load="$(uptime 2>/dev/null | awk -F'load average: ' '{print $2}' || true)"
  cpu_model="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "desconocido")"
  cpu_count="$(nproc 2>/dev/null || echo 1)"
  mem="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 " usados / " $2 " total"}')"
  swap="$(free -h 2>/dev/null | awk '/^Swap:/ {print $3 " usados / " $2 " total"}')"

  print_kv "Hostname" "$hostname"
  print_kv "SO" "$os"
  print_kv "Kernel" "$kernel"
  print_kv "Uptime" "$uptime"
  print_kv "Load average" "${load:-desconocido}"
  print_kv "CPU" "${cpu_model} (${cpu_count} cores)"
  print_kv "RAM" "${mem:-desconocida}"
  print_kv "Swap" "${swap:-desconocido}"

  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
  load_per_cpu="$(awk -v avg_load="$load1" -v cpu="$cpu_count" 'BEGIN { if (cpu < 1) cpu=1; printf "%.2f", avg_load / cpu }')"
  if awk -v ratio="$load_per_cpu" 'BEGIN { exit !(ratio >= 1.50) }'; then
    CPU_STATUS="${BAD_ICON} Load muy alto"
    add_problem "$BAD_ICON" "Load average alto para esta CPU (${load1} con ${cpu_count} cores)"
    add_recommendation "revisar procesos con más CPU y posibles bloqueos de I/O"
  elif awk -v ratio="$load_per_cpu" 'BEGIN { exit !(ratio >= 0.85) }'; then
    CPU_STATUS="${WARN_ICON} Load alto"
    add_problem "$WARN_ICON" "Load average alto para esta CPU (${load1} con ${cpu_count} cores)"
    add_recommendation "revisar procesos con más CPU"
  fi

  if have free; then
    read -r mem_total mem_used < <(free -m | awk '/^Mem:/ {print $2, $3}')
    read -r swap_total swap_used < <(free -m | awk '/^Swap:/ {print $2, $3}')
    mem_pct="$(awk -v used="${mem_used:-0}" -v total="${mem_total:-1}" 'BEGIN { if (total < 1) total=1; printf "%.0f", used * 100 / total }')"
    swap_pct="$(awk -v used="${swap_used:-0}" -v total="${swap_total:-0}" 'BEGIN { if (total < 1) print 0; else printf "%.0f", used * 100 / total }')"
    if (( mem_pct >= 95 )); then
      RAM_STATUS="${BAD_ICON} RAM casi llena"
      add_problem "$BAD_ICON" "RAM al ${mem_pct}%"
      add_recommendation "revisar procesos con más RAM y uso de transcodificación"
    elif (( mem_pct >= 85 )); then
      RAM_STATUS="${WARN_ICON} RAM alta"
      add_problem "$WARN_ICON" "RAM al ${mem_pct}%"
    fi
    if (( swap_pct >= 50 )); then
      RAM_STATUS="${WARN_ICON} Swap alto"
      add_problem "$WARN_ICON" "Swap al ${swap_pct}%"
      add_recommendation "revisar presión de memoria"
    fi
  fi

  subsection "Procesos con más CPU"
  ps -eo pid,ppid,user,comm,%cpu,%mem --sort=-%cpu 2>&1 | head -n 21

  subsection "Procesos con más RAM"
  ps -eo pid,ppid,user,comm,%cpu,%mem --sort=-%mem 2>&1 | head -n 21

  subsection "Temperatura"
  if have sensors; then
    temp_output="$(sensors 2>/dev/null || true)"
    printf "%s\n" "$temp_output"
    printf "%s%s Nota: en sensors, high/crit son umbrales. Solo ALARM/CRITICAL/EMERGENCY cuenta como alerta.%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
    if printf "%s\n" "$temp_output" | grep -Eiq 'ALARM|CRITICAL|EMERGENCY'; then
      SYSTEM_STATUS="${WARN_ICON} Temperatura con alerta"
      add_problem "$WARN_ICON" "sensors muestra alerta térmica real"
      add_recommendation "revisar temperatura y ventilación"
    fi
  else
    printf "%s%s sensors no instalado%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi
}

collect_plex() {
  section "2. Plex"

  local plex_active transcoder_count port_listen log_dir db_file db_size plex_errors journal_errors
  local db_corruption_pattern db_busy_pattern db_corruption_count db_busy_count

  db_corruption_pattern='database disk image is malformed|database corruption|database is corrupt|SQLITE_CORRUPT|SQLITE_NOTADB|not a database|file is encrypted or is not a database'
  db_busy_pattern='database is locked|busy DB|SQLITE_BUSY|Sleeping for .*busy DB|retry busy DB'

  if have systemctl; then
    plex_active="$(systemctl is-active plexmediaserver 2>/dev/null || true)"
    print_compact_systemctl_status
    case "$plex_active" in
      active) PLEX_STATUS="${OK_ICON} Running" ;;
      inactive|failed)
        PLEX_STATUS="${BAD_ICON} ${plex_active}"
        add_problem "$BAD_ICON" "plexmediaserver está ${plex_active}"
        add_recommendation "revisar estado de plexmediaserver"
        ;;
      *)
        PLEX_STATUS="${WARN_ICON} Estado desconocido"
        add_problem "$WARN_ICON" "no se pudo confirmar el estado de plexmediaserver"
        ;;
    esac
  else
    PLEX_STATUS="${WARN_ICON} systemctl no disponible"
  fi

  subsection "Errores journalctl Plex últimas 24h"
  if have journalctl; then
    journal_errors="$(journalctl -u plexmediaserver --since "24 hours ago" -p warning..alert --no-pager 2>/dev/null | tail -n 120 || true)"
    printf "%s\n" "${journal_errors:-sin warnings/errores recientes en journalctl}"
    if printf "%s\n" "$journal_errors" | grep -Eiq 'timed out|SIGKILL|failed with result|failed mode'; then
      if [[ "$plex_active" == "active" ]]; then
        add_info "Plex tuvo timeout/fallo de parada anterior, pero ahora está running; revisar solo si coincide con cortes."
      else
        add_problem "$WARN_ICON" "Plex tuvo timeout/fallo de parada o arranque en las últimas 24h"
        add_recommendation "revisar journalctl de plexmediaserver alrededor del último reinicio"
      fi
    fi
  else
    printf "%s%s journalctl no disponible%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi

  subsection "Procesos Plex"
  ps -eo pid,ppid,user,comm,args,%cpu,%mem --sort=-%cpu 2>/dev/null | grep -i '[P]lex' | head -n 30 || true

  transcoder_count="$(count_processes 'Plex Transcoder')"
  print_kv "Plex Transcoder activos" "$transcoder_count"
  if (( transcoder_count >= 10 )); then
    TRANSCODER_STATUS="${BAD_ICON} ${transcoder_count} procesos activos"
    add_problem "$BAD_ICON" "Plex Transcoder activo con muchos procesos (${transcoder_count})"
    add_recommendation "revisar transcodificaciones activas"
  elif (( transcoder_count >= 5 )); then
    TRANSCODER_STATUS="${WARN_ICON} ${transcoder_count} procesos activos"
    add_problem "$WARN_ICON" "Plex Transcoder activo con varios procesos (${transcoder_count})"
    add_recommendation "revisar transcodificaciones activas"
  elif (( transcoder_count >= 1 )); then
    TRANSCODER_STATUS="${OK_ICON} ${transcoder_count} procesos activos"
    add_info "Hay ${transcoder_count} procesos Plex Transcoder; normal si hay usuarios reproduciendo con conversión."
  fi

  subsection "Puerto 32400"
  if have ss; then
    ss -ltnp 2>/dev/null | awk 'NR==1 || /:32400/'
    port_listen="$(ss -ltn 2>/dev/null | grep -c ':32400' || true)"
  elif have netstat; then
    netstat -ltnp 2>/dev/null | awk 'NR==1 || /:32400/'
    port_listen="$(netstat -ltn 2>/dev/null | grep -c ':32400' || true)"
  else
    port_listen=0
    printf "%s%s ss/netstat no disponible%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi
  if (( port_listen < 1 )); then
    PLEX_STATUS="${BAD_ICON} Puerto 32400 no escucha"
    add_problem "$BAD_ICON" "Plex no parece estar escuchando en el puerto 32400"
    add_recommendation "revisar si Plex está arrancado y escuchando en 32400"
  fi

  log_dir="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs"
  subsection "Logs Plex"
  print_kv "Ubicación esperada" "$log_dir"
  if [[ -d "$log_dir" ]]; then
    find "$log_dir" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort | tail -n 10 || true
    plex_errors="$(grep -RihE 'error|critical|exception|database is locked|busy DB|SQLITE_BUSY|SQLITE_CORRUPT|SQLITE_NOTADB|not a database|file is encrypted or is not a database|database disk image is malformed|database corruption|database is corrupt|decode_slice_header|non-existing PPS|no frame' "$log_dir"/*.log 2>/dev/null | tail -n 80 || true)"
    print_plex_error_summary "$plex_errors"
    db_corruption_count="$(count_text_matches "$plex_errors" "$db_corruption_pattern")"
    db_busy_count="$(count_text_matches "$plex_errors" "$db_busy_pattern")"
    if (( db_corruption_count > 0 )); then
      PLEX_DB_STATUS="${BAD_ICON} Posible corrupción"
      add_problem "$BAD_ICON" "logs de Plex muestran posible corrupción de base de datos (${db_corruption_count} líneas)"
      add_recommendation "revisar base de datos de Plex y backups"
    elif (( db_busy_count >= 10 )); then
      PLEX_DB_STATUS="${WARN_ICON} DB ocupada"
      add_problem "$WARN_ICON" "Plex detecta DB ocupada/bloqueada repetidamente (${db_busy_count} líneas)"
      add_recommendation "revisar tareas pesadas de librería y logs de Plex relacionados con DB"
    elif (( db_busy_count > 0 )); then
      PLEX_DB_STATUS="${OK_ICON} Busy puntual"
      add_info "Plex detectó DB ocupada/bloqueada de forma puntual (${db_busy_count} líneas); suele ser normal durante escaneos o mucha actividad."
    fi
    if printf "%s\n" "$plex_errors" | grep -Eiq 'Error iterating EAE watchfolder'; then
      add_problem "$WARN_ICON" "Plex EAE/transcodificación muestra errores de watchfolder"
      add_recommendation "revisar sesiones de transcodificación y permisos/cache de Transcode"
    fi
    if printf "%s\n" "$plex_errors" | grep -Eiq 'Unable to find client profile'; then
      add_info "Plex repite errores de perfil de cliente no encontrado; normalmente es ruido de app/TV salvo cortes en ese cliente."
    fi
    if printf "%s\n" "$plex_errors" | grep -Eiq 'non-existing PPS|decode_slice_header|no frame|invalid NAL|error while decoding'; then
      add_info "Plex muestra errores H264/decode; normalmente apuntan a un archivo, stream o cliente concreto, no a un fallo global del servidor."
    fi
    if printf "%s\n" "$plex_errors" | grep -Eiq 'Session appears to have died|TranscodeOutputStream'; then
      add_info "Alguna sesión de transcodificación murió; puede ser cliente que cerró reproducción si no coincide con quejas de usuario."
    fi
  else
    printf "%s%s no existe o no es accesible%s\n" "$C_YELLOW" "$log_dir" "$C_RESET"
  fi

  db_file="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
  subsection "Base de datos Plex"
  print_kv "DB esperada" "$db_file"
  if [[ -f "$db_file" ]]; then
    db_size="$(du -h "$db_file" 2>/dev/null | awk '{print $1}')"
    print_kv "Tamaño DB" "${db_size:-desconocido}"
    if [[ "$PLEX_DB_STATUS" == "${WARN_ICON} No comprobado" ]]; then
      PLEX_DB_STATUS="${OK_ICON} Tamaño leído"
    else
      print_kv "Estado por logs" "$PLEX_DB_STATUS"
    fi
  else
    PLEX_DB_STATUS="${WARN_ICON} DB no encontrada"
    add_problem "$WARN_ICON" "no se encontró la DB de Plex en la ruta estándar"
  fi
}

collect_disks() {
  section "3. Discos"

  subsection "df -hT"
  run_cmd "df -hT" df -hT

  subsection "df -ih"
  run_cmd "df -ih" df -ih

  subsection "lsblk"
  if have lsblk; then
    if lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,SERIAL >/tmp/plex-doctor-lsblk.$$ 2>/tmp/plex-doctor-lsblk-err.$$; then
      cat /tmp/plex-doctor-lsblk.$$
    elif lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINT >/tmp/plex-doctor-lsblk.$$ 2>/tmp/plex-doctor-lsblk-err.$$; then
      cat /tmp/plex-doctor-lsblk.$$
    else
      lsblk 2>&1 || true
    fi
    rm -f /tmp/plex-doctor-lsblk.$$ /tmp/plex-doctor-lsblk-err.$$ 2>/dev/null || true
  else
    printf "%s%s lsblk no disponible%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi

  local high_usage high_inode iowait disk_names disk smart_output kernel_io
  high_usage="$(df -P 2>/dev/null | awk 'NR>1 {gsub("%","",$5); if ($5 >= 95) print $6 " " $5 "%"}')"
  if [[ -n "$high_usage" ]]; then
    DISK_STATUS="${BAD_ICON} Disco lleno"
    while IFS= read -r line; do
      add_problem "$BAD_ICON" "filesystem casi lleno: $line"
    done <<< "$high_usage"
    add_recommendation "liberar espacio o revisar crecimiento de logs/cache"
  fi

  high_inode="$(df -Pi 2>/dev/null | awk 'NR>1 {gsub("%","",$5); if ($5 >= 90) print $6 " " $5 "%"}')"
  if [[ -n "$high_inode" ]]; then
    DISK_STATUS="${WARN_ICON} Inodos altos"
    while IFS= read -r line; do
      add_problem "$WARN_ICON" "uso de inodos alto: $line"
    done <<< "$high_inode"
  fi

  subsection "I/O wait"
  if have iostat; then
    iostat -xz 1 2 2>/dev/null || true
    iowait="$(iostat -c 1 2 2>/dev/null | awk '/^avg-cpu:/ {getline; val=$4} END {print val+0}')"
    if awk -v val="$iowait" 'BEGIN { exit !(val >= 25) }'; then
      DISK_STATUS="${BAD_ICON} I/O wait alto"
      add_problem "$BAD_ICON" "I/O wait alto (${iowait}%)"
      add_recommendation "revisar disco/cache y mounts rclone"
    elif awk -v val="$iowait" 'BEGIN { exit !(val >= 10) }'; then
      DISK_STATUS="${WARN_ICON} I/O wait elevado"
      add_problem "$WARN_ICON" "I/O wait elevado (${iowait}%)"
    fi
  else
    printf "%s%s iostat no instalado%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi

  subsection "SMART"
  if have smartctl; then
    disk_names="$(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')"
    if [[ -n "$disk_names" ]]; then
      while IFS= read -r disk; do
        [[ -z "$disk" ]] && continue
        printf "\n/dev/%s\n" "$disk"
        smart_output="$(smartctl -H "/dev/$disk" 2>&1 || true)"
        printf "%s\n" "$smart_output"
        if printf "%s\n" "$smart_output" | grep -Eiq 'SMART overall-health.*FAILED|Drive failure expected'; then
          DISK_STATUS="${BAD_ICON} SMART alerta"
          add_problem "$BAD_ICON" "SMART alerta en /dev/${disk}"
          if printf "%s\n" "$smart_output" | grep -Eiq 'Drive failure expected'; then
            add_recommendation "hacer backup o migrar datos de /dev/${disk} cuanto antes"
          fi
          add_recommendation "revisar SMART completo y estado físico del disco"
        elif printf "%s\n" "$smart_output" | grep -Eiq 'SMART overall-health.*UNKNOWN|SMART support is: Unavailable'; then
          add_problem "$WARN_ICON" "SMART no concluyente en /dev/${disk}"
          add_recommendation "revisar SMART completo si el disco es físico o está detrás de controladora"
        fi
      done <<< "$disk_names"
    else
      printf "No se encontraron discos físicos con lsblk.\n"
    fi
  else
    printf "%s%s smartctl no instalado%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi

  subsection "Errores I/O en kernel/journal"
  kernel_io="$(dmesg -T 2>/dev/null | grep -Ei 'I/O error|blk_update_request|buffer I/O|nvme.*error|ata[0-9].*error|reset SuperSpeed|EXT4-fs error|XFS.*error' | tail -n 120 || true)"
  printf "%s\n" "${kernel_io:-sin errores I/O recientes en dmesg accesible}"
  if [[ -n "$kernel_io" ]]; then
    DISK_STATUS="${BAD_ICON} Errores I/O"
    add_problem "$BAD_ICON" "errores I/O detectados en dmesg"
    add_recommendation "revisar errores NVMe/SATA y salud de discos"
  fi
  if have journalctl; then
    journalctl -k --since "24 hours ago" --no-pager 2>/dev/null | grep -Ei 'I/O error|nvme.*error|ata[0-9].*error|EXT4-fs error|XFS.*error' | tail -n 120 || true
  fi
}

collect_rclone() {
  section "4. rclone / FUSE"

  local rclone_count mounts broken duplicate_cmds mountpoint elapsed_ms start_ms end_ms slow_mounts mount_list

  subsection "Procesos rclone"
  ps -eo pid,ppid,user,comm,args,%cpu,%mem --sort=-%cpu 2>/dev/null | grep -i '[r]clone' | head -n 30 || true
  rclone_count="$(count_process_names rclone)"
  print_kv "Procesos rclone" "$rclone_count"

  subsection "Mounts fuse.rclone"
  findmnt -t fuse.rclone,fuse3.rclone -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || mount 2>/dev/null | grep -i rclone || true
  mounts="$(findmnt -rn -t fuse.rclone,fuse3.rclone -o TARGET 2>/dev/null || true)"

  if (( rclone_count > 0 )); then
    duplicate_cmds="$(ps -eo args 2>/dev/null | grep -i '[r]clone.* mount ' | sed -E 's/[[:space:]]+/ /g' | sort | uniq -c | awk '$1 > 1')"
    if [[ -n "$duplicate_cmds" ]]; then
      RCLONE_STATUS="${WARN_ICON} Duplicados"
      add_problem "$WARN_ICON" "posibles procesos rclone duplicados"
      add_recommendation "revisar duplicados de rclone"
      printf "\nDuplicados posibles:\n%s\n" "$duplicate_cmds"
    fi
  fi

  subsection "Mounts rotos y latencia en /mnt"
  broken=""
  slow_mounts=0
  mount_list="$({ printf "%s\n" "$mounts"; find /mnt -mindepth 1 -maxdepth 1 -type d 2>/dev/null; } | awk 'NF && !seen[$0]++')"
  while IFS= read -r mountpoint; do
    [[ -z "$mountpoint" ]] && continue
    start_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
    if ! safe_timeout 4 stat "$mountpoint" >/tmp/plex-doctor-stat.$$ 2>&1; then
      broken+="${mountpoint}: $(tr '\n' ' ' </tmp/plex-doctor-stat.$$ 2>/dev/null)\n"
      continue
    fi
    end_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
    elapsed_ms=$((end_ms - start_ms))
    printf "%-40s %sms\n" "$mountpoint" "$elapsed_ms"
    if (( elapsed_ms >= 2500 )); then
      slow_mounts=$((slow_mounts + 1))
      add_problem "$WARN_ICON" "${mountpoint} responde lento (${elapsed_ms}ms)"
      add_recommendation "revisar latencia de mounts rclone"
    fi
  done <<< "$mount_list"
  rm -f /tmp/plex-doctor-stat.$$ 2>/dev/null || true

  if [[ -n "$broken" ]]; then
    RCLONE_STATUS="${BAD_ICON} mount roto detectado"
    printf "%b\n" "$broken"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      mountpoint="${line%%:*}"
      add_problem "$BAD_ICON" "${mountpoint} no responde correctamente"
    done <<< "$(printf "%b" "$broken")"
    add_recommendation "revisar mount roto"
    add_recommendation "revisar logs rclone"
  elif (( slow_mounts > 0 )); then
    RCLONE_STATUS="${WARN_ICON} mounts lentos"
  fi

  if [[ -z "$mounts" && "$rclone_count" -gt 0 ]]; then
    RCLONE_STATUS="${WARN_ICON} rclone sin fuse.rclone"
    add_problem "$WARN_ICON" "hay procesos rclone pero no se detectan mounts fuse.rclone"
  fi
}

collect_network() {
  section "5. Red"

  local gateway ping_gw ping_cloud dns_ok conn_count iface speed_output

  subsection "IPs"
  run_cmd "ip addr" ip -brief addr

  subsection "Rutas"
  run_cmd "ip route" ip route
  gateway="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
  print_kv "Gateway" "${gateway:-no detectado}"

  subsection "Ping gateway"
  if [[ -n "${gateway:-}" ]]; then
    if ping -c 2 -W 2 "$gateway" >/tmp/plex-doctor-ping-gw.$$ 2>&1; then
      ping_gw="ok"
    else
      ping_gw="fail"
      NETWORK_STATUS="${BAD_ICON} Gateway no responde"
      add_problem "$BAD_ICON" "gateway no responde a ping"
      add_recommendation "revisar conectividad local"
    fi
    cat /tmp/plex-doctor-ping-gw.$$ 2>/dev/null || true
    rm -f /tmp/plex-doctor-ping-gw.$$ 2>/dev/null || true
  else
    NETWORK_STATUS="${BAD_ICON} Sin gateway"
    add_problem "$BAD_ICON" "no se detectó gateway por defecto"
  fi

  subsection "Ping 1.1.1.1"
  if ping -c 2 -W 2 1.1.1.1 >/tmp/plex-doctor-ping-cloud.$$ 2>&1; then
    ping_cloud="ok"
  else
    ping_cloud="fail"
    NETWORK_STATUS="${BAD_ICON} Sin salida a internet"
    add_problem "$BAD_ICON" "1.1.1.1 no responde a ping"
    add_recommendation "revisar salida a internet"
  fi
  cat /tmp/plex-doctor-ping-cloud.$$ 2>/dev/null || true
  rm -f /tmp/plex-doctor-ping-cloud.$$ 2>/dev/null || true

  subsection "DNS"
  cat /etc/resolv.conf 2>/dev/null || true
  if have getent; then
    if getent hosts plex.tv >/dev/null 2>&1; then
      dns_ok="ok"
      print_kv "Resolución plex.tv" "OK"
    else
      dns_ok="fail"
      NETWORK_STATUS="${WARN_ICON} DNS falla"
      add_problem "$WARN_ICON" "DNS no resuelve plex.tv"
      add_recommendation "revisar DNS"
    fi
  fi

  subsection "Conexiones activas al puerto 32400"
  if have ss; then
    ss -tnp 2>/dev/null | awk 'NR==1 || /:32400/' | head -n 81
    conn_count="$(ss -tn 2>/dev/null | grep -c ':32400' || true)"
    print_kv "Conexiones 32400" "$conn_count"
  fi

  subsection "Velocidad de interfaz"
  if have ethtool; then
    ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker|veth|br-|virbr)' | while IFS= read -r iface; do
      [[ -z "$iface" ]] && continue
      printf "\n%s\n" "$iface"
      speed_output="$(ethtool "$iface" 2>/dev/null | grep -E 'Speed:|Duplex:|Link detected:' || true)"
      printf "%s\n" "${speed_output:-sin datos}"
      if printf "%s\n" "$speed_output" | grep -Eq 'Speed: (10|100)Mb/s'; then
        NETWORK_STATUS="${WARN_ICON} Enlace lento"
        add_problem "$WARN_ICON" "interfaz ${iface} negociada a baja velocidad"
        add_recommendation "revisar cable/switch/negociación de red"
      fi
    done
  else
    printf "%s%s ethtool no instalado%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi
}

collect_kernel() {
  section "6. Kernel / sistema"

  local kernel_alerts reboots
  kernel_alerts="$(dmesg -T 2>/dev/null | grep -Ei 'out of memory|oom-killer|segfault|nvme.*error|ata[0-9].*error|thermal thrott|critical temperature|temperature above threshold|cpu clock throttled|package temperature above threshold|mce:.*hardware error|hardware error' | tail -n 160 || true)"
  printf "%s\n" "${kernel_alerts:-sin eventos críticos recientes en dmesg accesible}"

  if printf "%s\n" "$kernel_alerts" | grep -Eiq 'out of memory|oom-killer'; then
    SYSTEM_STATUS="${BAD_ICON} OOM killer"
    add_problem "$BAD_ICON" "OOM killer detectado"
    add_recommendation "revisar memoria, swap y procesos"
  fi
  if printf "%s\n" "$kernel_alerts" | grep -Eiq 'segfault'; then
    add_problem "$WARN_ICON" "segfaults detectados"
  fi
  if printf "%s\n" "$kernel_alerts" | grep -Eiq 'thermal thrott|critical temperature|temperature above threshold|cpu clock throttled|package temperature above threshold'; then
    SYSTEM_STATUS="${WARN_ICON} Thermal throttling"
    add_problem "$WARN_ICON" "thermal throttling real detectado en kernel"
    add_recommendation "revisar temperatura y ventilación"
  fi

  subsection "Reinicios recientes"
  if have last; then
    reboots="$(last -x reboot 2>/dev/null | head -n 10 || true)"
    printf "%s\n" "$reboots"
  else
    printf "%s%s last no disponible%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi

  if have journalctl; then
    subsection "Journal kernel últimas 24h"
    journalctl -k --since "24 hours ago" --no-pager 2>/dev/null | grep -Ei 'out of memory|oom-killer|segfault|nvme.*error|ata[0-9].*error|thermal thrott|critical temperature|temperature above threshold|cpu clock throttled|package temperature above threshold|hardware error' | tail -n 160 || true
  fi
}

probable_cause() {
  local joined
  joined="$(printf "%s\n" "${PROBLEMS[@]:-}")"

  if printf "%s\n" "$joined" | grep -Eiq 'SMART alerta|errores I/O'; then
    echo "El síntoma principal apunta a almacenamiento físico o enlace SATA: disco, cable, backplane, puerto o controladora."
  elif printf "%s\n" "$joined" | grep -Eiq 'mount|rclone|I/O wait'; then
    echo "El servidor parece inestable por problema de mount/rclone o I/O, no por Plex directamente."
  elif printf "%s\n" "$joined" | grep -Eiq 'corrupción de base de datos'; then
    echo "El síntoma principal apunta a posible corrupción de la base de datos de Plex."
  elif printf "%s\n" "$joined" | grep -Eiq 'DB ocupada|DB.*bloqueada|base de datos'; then
    echo "El síntoma principal apunta a la DB de Plex ocupada o bloqueada por actividad interna."
  elif printf "%s\n" "$joined" | grep -Eiq 'Transcoder'; then
    echo "La carga actual parece venir sobre todo de transcodificaciones activas en Plex."
  elif printf "%s\n" "$joined" | grep -Eiq 'RAM|Swap|OOM'; then
    echo "El servidor muestra presión de memoria; Plex puede estar afectado como consecuencia."
  elif printf "%s\n" "$joined" | grep -Eiq 'Gateway|DNS|internet|32400'; then
    echo "La causa probable está en conectividad de red o exposición del puerto de Plex."
  elif ((${#PROBLEMS[@]} == 0)); then
    echo "No se detectan problemas graves en las comprobaciones de solo lectura."
  else
    echo "Hay varias señales de alerta; revisar primero los problemas marcados en rojo y amarillo."
  fi
}

write_plain_diagnosis() {
  local joined score_reason
  joined="$(printf "%s\n" "${PROBLEMS[@]:-}")"
  score_reason="No hay penalizaciones importantes."

  echo "EN CLARO:"

  if printf "%s\n" "$joined" | grep -Eiq 'SMART alerta|errores I/O'; then
    echo "- Problema principal: almacenamiento/disco/SATA."
    echo "- ¿Es real?: sí. SMART o el kernel han devuelto errores reales; no es que Plex Doctor no pueda comprobarlo."
    echo "- Qué NO parece culpable: Plex, la DB de Plex, rclone o DNS no son la causa principal según esta ejecución."
    echo "- Qué hacer ahora: priorizar backup/migración de datos y revisar disco, cable SATA, backplane, puerto o controladora."
    score_reason="Baja sobre todo por alertas rojas de SMART/I/O."
  elif printf "%s\n" "$joined" | grep -Eiq 'mount roto|no responde correctamente|rclone'; then
    echo "- Problema principal: mount/rclone/FUSE."
    echo "- ¿Es real?: sí, alguna ruta montada no responde o responde mal."
    echo "- Qué NO parece culpable: Plex puede quedarse esperando datos, pero no tiene por qué ser el origen."
    echo "- Qué hacer ahora: revisar logs de rclone, estado del remote y estabilidad del mount afectado."
    score_reason="Baja sobre todo por mount/rclone."
  elif printf "%s\n" "$joined" | grep -Eiq 'corrupción de base de datos'; then
    echo "- Problema principal: posible corrupción de la DB de Plex."
    echo "- ¿Es real?: sí, aparece en logs de Plex; no significa reparar ya, significa hacer backup antes de tocar."
    echo "- Qué NO parece culpable: CPU, RAM, discos, rclone y red están OK en esta ejecución."
    echo "- Qué hacer ahora: guardar /tmp/plex-doctor-full.log, hacer backup de la DB y revisar las líneas exactas antes de mantenimiento."
    score_reason="Baja por señales de posible corrupción de DB."
  elif printf "%s\n" "$joined" | grep -Eiq 'DB ocupada|DB.*bloqueada'; then
    echo "- Problema principal: DB de Plex ocupada/bloqueada repetidamente."
    echo "- ¿Es real?: sí, Plex lo registró en logs, pero puede ser temporal durante escaneos, metadatos o mucha actividad."
    echo "- Qué NO parece culpable: no hay señal de fallo de disco, rclone o red en esta ejecución."
    echo "- Qué hacer ahora: revisar si coincide con escaneo de librería, intro/credits detection, metadatos o muchos usuarios."
    score_reason="Baja por DB ocupada repetidamente, no por corrupción confirmada."
  elif printf "%s\n" "$joined" | grep -Eiq 'Transcoder activo|transcodificación'; then
    echo "- Problema principal: carga por transcodificación."
    echo "- ¿Es real?: sí, hay procesos Plex Transcoder activos; puede ser normal si hay usuarios viendo contenido."
    echo "- Qué NO parece culpable: no hay señal fuerte de fallo global si discos, rclone, RAM y red están OK."
    echo "- Qué hacer ahora: identificar qué usuario/dispositivo fuerza transcode y revisar subtítulos, audio y calidad remota."
    score_reason="Baja por avisos de transcodificación, no por fallo crítico."
  elif ((${#PROBLEMS[@]} == 0)); then
    echo "- Problema principal: no hay fallo claro en esta ejecución."
    echo "- ¿Es real?: si hay cortes, probablemente son intermitentes o externos al momento de la prueba."
    echo "- Qué hacer ahora: repetir Plex Doctor cuando el problema esté ocurriendo."
  else
    echo "- Problema principal: hay avisos mezclados; mirar primero los rojos."
    echo "- ¿Es real?: los rojos son señales accionables; los amarillos son contexto o carga."
    echo "- Qué hacer ahora: resolver primero el primer problema rojo del listado."
    score_reason="Baja por problemas rojos/amarillos detectados."
  fi

  echo "- Puntuación: ${HEALTH_SCORE}/100. ${score_reason}"
}

write_interpretation() {
  local joined
  joined="$(printf "%s\n" "${PROBLEMS[@]:-}")"

  echo "Interpretación:"
  if ((${#PROBLEMS[@]} == 0)); then
    echo "- No hay una señal clara de fallo. Si hay cortes, pueden ser intermitentes o externos al servidor."
    return
  fi

  if printf "%s\n" "$joined" | grep -Eiq 'SMART alerta|errores I/O'; then
    echo "- Prioridad alta: almacenamiento físico o enlace SATA. SMART/I/O no es ruido de Plex; puede ser disco, cable, backplane, puerto o controladora."
  elif printf "%s\n" "$joined" | grep -Eiq 'mount roto|no responde correctamente|rclone|I/O wait'; then
    echo "- Prioridad alta: almacenamiento/mounts. Si rclone, FUSE o el disco se bloquean, Plex puede parecer culpable aunque solo esté esperando datos."
  fi
  if printf "%s\n" "$joined" | grep -Eiq 'Transcoder activo|transcodificación'; then
    echo "- Hay transcodificación activa. Esto puede explicar load alto, CPU alta y errores EAE, sobre todo con subtítulos quemados, audio EAC3/DTS o clientes poco compatibles."
  fi
  if printf "%s\n" "$joined" | grep -Eiq 'corrupción de base de datos'; then
    echo "- La DB de Plex muestra señales compatibles con corrupción. Prioridad: backup de la DB antes de cualquier reparación o limpieza."
  elif printf "%s\n" "$joined" | grep -Eiq 'DB ocupada|DB.*bloqueada|base de datos'; then
    echo "- La DB de Plex aparece ocupada/bloqueada. Esto suele pasar con escaneos, metadatos, tareas programadas o mucha actividad; solo preocupa si se repite y coincide con lentitud/cortes."
  fi
  if printf "%s\n" "$joined" | grep -Eiq 'perfil de cliente'; then
    echo "- Los errores de perfil de cliente suelen venir de TVs/apps concretas. Normalmente no tiran Plex, pero pueden forzar transcodificación o provocar reproducción irregular."
  fi
  if printf "%s\n" "$joined" | grep -Eiq 'timeout/fallo de parada|SIGKILL|failed'; then
    echo "- Plex tuvo problemas al parar/arrancar recientemente. Eso puede dejar sesiones, cache o procesos en estado raro aunque ahora el servicio aparezca running."
  fi
  if printf "%s\n" "$joined" | grep -Eiq 'RAM|Swap|OOM'; then
    echo "- Hay presión de memoria. Si aparece OOM killer, cualquier síntoma posterior de Plex puede ser consecuencia de falta de RAM."
  fi
  if printf "%s\n" "$joined" | grep -Eiq 'Gateway|DNS|internet|32400'; then
    echo "- Hay señales de red o puerto 32400. Si la red falla, el servidor puede estar sano pero inaccesible para clientes externos."
  fi
  if printf "%s\n" "$joined" | grep -Eiq 'thermal|Temperatura'; then
    echo "- Hay señal térmica. Si el equipo reduce frecuencia por temperatura, Plex transcodificando será lo primero que se degrade."
  fi
}

write_action_plan() {
  local joined
  joined="$(printf "%s\n" "${PROBLEMS[@]:-}")"

  echo "Plan de actuación recomendado:"
  echo "1. Confirmar versión: bash plex-doctor.sh --version."

  if printf "%s\n" "$joined" | grep -Eiq 'SMART alerta|errores I/O'; then
    echo "2. Tratar almacenamiento como prioridad: backup, revisar SMART completo y comprobar cable/backplane/puerto antes de culpar a Plex."
  elif printf "%s\n" "$joined" | grep -Eiq 'mount roto|no responde correctamente|rclone|I/O wait'; then
    echo "2. Revisar almacenamiento antes que Plex: comprobar que los mounts rclone responden, mirar logs de rclone y confirmar que el disco/cache no está saturado."
  elif printf "%s\n" "$joined" | grep -Eiq 'Transcoder activo|transcodificación'; then
    echo "2. Revisar sesiones activas en Plex: identificar usuarios/dispositivos que transcodifican, subtítulos quemados y audios que obligan a convertir."
  elif printf "%s\n" "$joined" | grep -Eiq 'corrupción de base de datos'; then
    echo "2. Hacer backup de la DB de Plex y revisar las líneas exactas del full log antes de cualquier mantenimiento."
  elif printf "%s\n" "$joined" | grep -Eiq 'DB ocupada|base de datos'; then
    echo "2. Revisar qué tarea de Plex estaba activa: escaneo, metadatos, detección de intros/créditos o muchos usuarios."
  else
    echo "2. Atacar primero los problemas rojos del resumen; si solo hay amarillos, repetir prueba durante el fallo real."
  fi

  if printf "%s\n" "$joined" | grep -Eiq 'timeout/fallo de parada|SIGKILL|failed'; then
    echo "3. Revisar el tramo del reinicio: journalctl -u plexmediaserver --since 'YYYY-MM-DD HH:MM' --no-pager para entender por qué Plex no cerró limpio."
  else
    echo "3. Guardar /tmp/plex-doctor-full.log y comparar con una segunda ejecución cuando el problema esté ocurriendo."
  fi

  echo "4. Evitar cambios destructivos hasta identificar causa: no borrar DB/cache ni desmontar rutas sin backup o ventana de mantenimiento."
}

write_summary() {
  (( HEALTH_SCORE < 0 )) && HEALTH_SCORE=0
  (( HEALTH_SCORE > 100 )) && HEALTH_SCORE=100

  if ((${#RECOMMENDATIONS[@]} == 0)); then
    RECOMMENDATIONS+=("guardar este resumen y comparar si el problema se repite")
  fi

  {
    echo "════════════════════════════════════"
    echo "PLEX DOCTOR - RESUMEN"
    echo "════════════════════════════════════"
    echo
    echo "Servidor: $(hostname 2>/dev/null || echo desconocido)"
    echo "Fecha: $(date -Is 2>/dev/null || date)"
    echo "Versión: ${VERSION}"
    echo
    write_plain_diagnosis
    echo
    printf "%-20s %s\n" "Sistema ............" "$SYSTEM_STATUS"
    printf "%-20s %s\n" "CPU ................" "$CPU_STATUS"
    printf "%-20s %s\n" "RAM ................" "$RAM_STATUS"
    printf "%-20s %s\n" "Discos ............." "$DISK_STATUS"
    printf "%-20s %s\n" "Plex ..............." "$PLEX_STATUS"
    printf "%-20s %s\n" "DB Plex ............" "$PLEX_DB_STATUS"
    printf "%-20s %s\n" "Transcoder ........." "$TRANSCODER_STATUS"
    printf "%-20s %s\n" "rclone ............." "$RCLONE_STATUS"
    printf "%-20s %s\n" "Red ................" "$NETWORK_STATUS"
    echo
    echo "Problemas detectados:"
    if ((${#PROBLEMS[@]} == 0)); then
      echo "${OK_ICON} No se detectaron problemas claros."
    else
      printf "%s\n" "${PROBLEMS[@]}"
    fi
    echo
    echo "Notas informativas:"
    if ((${#INFO_NOTES[@]} == 0)); then
      echo "${OK_ICON} Sin notas informativas relevantes."
    else
      printf "ℹ️ %s\n" "${INFO_NOTES[@]}"
    fi
    echo
    echo "Causa probable:"
    probable_cause
    echo
    write_interpretation
    echo
    write_action_plan
    echo
    echo "Comandos recomendados:"
    printf -- "- %s\n" "${RECOMMENDATIONS[@]}"
    echo
    echo "Puntuación salud: ${HEALTH_SCORE}/100"
    echo
    echo "Logs guardados:"
    echo "- ${SUMMARY_FILE}"
    echo "- ${FULL_LOG}"
  } >"$SUMMARY_FILE"

  printf "\n%s%s%s\n" "${C_BOLD}${C_GREEN}" "Resumen listo para copiar:" "${C_RESET}"
  cat "$SUMMARY_FILE"
}

main() {
  parse_args "$@"
  printf "%sPLEX DOCTOR%s v%s\n" "${C_BOLD}${C_CYAN}" "${C_RESET}" "$VERSION"
  if (( AUTO_INSTALL_DEPS == 1 )); then
    printf "Modo: instala herramientas de diagnóstico si faltan. No reinicia servicios, no borra archivos.\n"
  else
    printf "Modo: solo lectura. No instala nada, no reinicia servicios, no borra archivos.\n"
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf "%s%s Recomendado: ejecutar con sudo para leer todos los logs.%s\n" "$C_YELLOW" "$WARN_ICON" "$C_RESET"
  fi
  install_missing_diagnostic_deps

  collect_system
  collect_plex
  collect_disks
  collect_rclone
  collect_network
  collect_kernel
  write_summary
}

: >"$FULL_LOG"
main "$@" 2>&1 | tee -a "$FULL_LOG"
