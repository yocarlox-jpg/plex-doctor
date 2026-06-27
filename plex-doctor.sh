#!/usr/bin/env bash

set -uo pipefail

VERSION="0.1.1"
SUMMARY_FILE="/tmp/plex-doctor-summary.txt"
FULL_LOG="/tmp/plex-doctor-full.log"

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

add_problem() {
  local severity="$1"
  local message="$2"
  PROBLEMS+=("${severity} ${message}")
  case "$severity" in
    "$BAD_ICON") HEALTH_SCORE=$((HEALTH_SCORE - 15)) ;;
    "$WARN_ICON") HEALTH_SCORE=$((HEALTH_SCORE - 6)) ;;
    *) HEALTH_SCORE=$((HEALTH_SCORE - 2)) ;;
  esac
}

add_recommendation() {
  local recommendation="$1"
  local existing
  for existing in "${RECOMMENDATIONS[@]:-}"; do
    [[ "$existing" == "$recommendation" ]] && return
  done
  RECOMMENDATIONS+=("$recommendation")
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

print_kv() {
  printf "%-24s %s\n" "$1:" "$2"
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
    if printf "%s\n" "$temp_output" | grep -Eiq 'crit|alarm|high'; then
      SYSTEM_STATUS="${WARN_ICON} Temperatura con alerta"
      add_problem "$WARN_ICON" "sensors muestra alerta térmica"
      add_recommendation "revisar temperatura y ventilación"
    fi
  else
    printf "%s%s sensors no instalado%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi
}

collect_plex() {
  section "2. Plex"

  local plex_active transcoder_count port_listen log_dir db_file db_size quick_check plex_errors

  if have systemctl; then
    plex_active="$(systemctl is-active plexmediaserver 2>/dev/null || true)"
    run_cmd "systemctl status plexmediaserver" systemctl status plexmediaserver --no-pager -l
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
    journalctl -u plexmediaserver --since "24 hours ago" -p warning..alert --no-pager 2>/dev/null | tail -n 120 || true
  else
    printf "%s%s journalctl no disponible%s\n" "$C_DIM" "$INFO_ICON" "$C_RESET"
  fi

  subsection "Procesos Plex"
  ps -eo pid,ppid,user,comm,args,%cpu,%mem --sort=-%cpu 2>/dev/null | grep -i '[P]lex' | head -n 30 || true

  transcoder_count="$(pgrep -fc 'Plex Transcoder' 2>/dev/null || echo 0)"
  print_kv "Plex Transcoder activos" "$transcoder_count"
  if (( transcoder_count >= 8 )); then
    TRANSCODER_STATUS="${BAD_ICON} ${transcoder_count} procesos activos"
    add_problem "$BAD_ICON" "Plex Transcoder activo con muchos procesos (${transcoder_count})"
    add_recommendation "revisar transcodificaciones activas"
  elif (( transcoder_count >= 3 )); then
    TRANSCODER_STATUS="${WARN_ICON} ${transcoder_count} procesos activos"
    add_problem "$WARN_ICON" "Plex Transcoder activo con varios procesos (${transcoder_count})"
    add_recommendation "revisar transcodificaciones activas"
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
    plex_errors="$(grep -RihE 'error|critical|exception|database is locked|corrupt' "$log_dir"/*.log 2>/dev/null | tail -n 80 || true)"
    printf "\nÚltimos errores relevantes:\n%s\n" "${plex_errors:-sin errores recientes encontrados}"
    if printf "%s\n" "$plex_errors" | grep -Eiq 'database is locked|corrupt|malformed'; then
      PLEX_DB_STATUS="${BAD_ICON} Errores en logs"
      add_problem "$BAD_ICON" "logs de Plex muestran posibles errores de base de datos"
      add_recommendation "revisar base de datos de Plex y backups"
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
    if have sqlite3; then
      quick_check="$(sqlite3 "file:${db_file}?mode=ro" "PRAGMA quick_check;" 2>&1 || true)"
      print_kv "PRAGMA quick_check" "$quick_check"
      if [[ "$quick_check" == "ok" ]]; then
        PLEX_DB_STATUS="${OK_ICON} OK"
      else
        PLEX_DB_STATUS="${BAD_ICON} quick_check falla"
        add_problem "$BAD_ICON" "sqlite3 PRAGMA quick_check no devuelve ok para la DB de Plex"
        add_recommendation "revisar integridad de la DB de Plex"
      fi
    else
      PLEX_DB_STATUS="${WARN_ICON} sqlite3 no instalado"
      add_problem "$WARN_ICON" "sqlite3 no instalado; no se pudo comprobar la DB de Plex"
      add_recommendation "instalar sqlite3 con sudo bash install.sh"
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
  run_cmd "lsblk" lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,SERIAL

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
        if printf "%s\n" "$smart_output" | grep -Eiq 'FAILED|prefail|unknown'; then
          DISK_STATUS="${BAD_ICON} SMART alerta"
          add_problem "$BAD_ICON" "SMART alerta en /dev/${disk}"
          add_recommendation "revisar SMART completo y estado físico del disco"
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
  rclone_count="$(pgrep -fc rclone 2>/dev/null || echo 0)"
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
  kernel_alerts="$(dmesg -T 2>/dev/null | grep -Ei 'out of memory|oom-killer|segfault|nvme.*error|ata[0-9].*error|thermal thrott|critical temperature|temperature above threshold|cpu clock throttled|package temperature|mce:.*hardware error|hardware error' | tail -n 160 || true)"
  printf "%s\n" "${kernel_alerts:-sin eventos críticos recientes en dmesg accesible}"

  if printf "%s\n" "$kernel_alerts" | grep -Eiq 'out of memory|oom-killer'; then
    SYSTEM_STATUS="${BAD_ICON} OOM killer"
    add_problem "$BAD_ICON" "OOM killer detectado"
    add_recommendation "revisar memoria, swap y procesos"
  fi
  if printf "%s\n" "$kernel_alerts" | grep -Eiq 'segfault'; then
    add_problem "$WARN_ICON" "segfaults detectados"
  fi
  if printf "%s\n" "$kernel_alerts" | grep -Eiq 'thermal thrott|critical temperature|temperature above threshold|cpu clock throttled|package temperature'; then
    SYSTEM_STATUS="${WARN_ICON} Thermal throttling"
    add_problem "$WARN_ICON" "posible thermal throttling detectado"
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
    journalctl -k --since "24 hours ago" --no-pager 2>/dev/null | grep -Ei 'out of memory|oom-killer|segfault|nvme.*error|ata[0-9].*error|thermal thrott|critical temperature|temperature above threshold|cpu clock throttled|package temperature|hardware error' | tail -n 160 || true
  fi
}

probable_cause() {
  local joined
  joined="$(printf "%s\n" "${PROBLEMS[@]:-}")"

  if printf "%s\n" "$joined" | grep -Eiq 'mount|rclone|I/O wait|I/O'; then
    echo "El servidor parece inestable por problema de mount/rclone o I/O, no por Plex directamente."
  elif printf "%s\n" "$joined" | grep -Eiq 'DB|base de datos|quick_check'; then
    echo "El síntoma principal apunta a la base de datos de Plex o a errores internos de Plex."
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
    echo "Causa probable:"
    probable_cause
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
  printf "%sPLEX DOCTOR%s v%s\n" "${C_BOLD}${C_CYAN}" "${C_RESET}" "$VERSION"
  printf "Modo: solo lectura. No modifica el sistema, no reinicia servicios, no borra archivos.\n"
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf "%s%s Recomendado: ejecutar con sudo para leer todos los logs.%s\n" "$C_YELLOW" "$WARN_ICON" "$C_RESET"
  fi

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
