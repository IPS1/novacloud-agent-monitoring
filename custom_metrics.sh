#!/bin/bash

# ================
# CONFIGURATION
# ================
INFLUX_URL="http://localhost:8086"
ORG="my-org"
BUCKET="my-bucket"
TOKEN="my-secret-token"

HOSTNAME=$(hostname)
MEASUREMENT="system_stats"

# ================
# CPU USAGE
# ================
CPU_IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}')
CPU_USAGE=$(echo "scale=2; 100 - $CPU_IDLE" | bc)
LOAD_AVG=$(cat /proc/loadavg | awk '{print $1","$2","$3}')
LOAD1=$(echo $LOAD_AVG | cut -d',' -f1)
LOAD5=$(echo $LOAD_AVG | cut -d',' -f2)
LOAD15=$(echo $LOAD_AVG | cut -d',' -f3)

# ================
# MEMORY USAGE
# ================
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_FREE=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_USAGE=$(echo "scale=2; 100 * ($MEM_TOTAL - $MEM_FREE) / $MEM_TOTAL" | bc)

SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
SWAP_FREE=$(grep SwapFree /proc/meminfo | awk '{print $2}')
if [ "$SWAP_TOTAL" -gt 0 ]; then
  SWAP_USAGE=$(echo "scale=2; 100 * ($SWAP_TOTAL - $SWAP_FREE) / $SWAP_TOTAL" | bc)
else
  SWAP_USAGE=0
fi

# ================
# DISK USAGE
# ================
DISK_LINES=$(df -P | awk 'NR>1 {print $6","$5}' | sed 's/%//g')

# ================
# NETWORK USAGE
# ================
NET_LINES=""
while read -r line; do
  IFACE=$(echo "$line" | awk -F: '{print $1}' | xargs)
  DATA=$(echo "$line" | awk -F: '{print $2}')
  RX_BYTES=$(echo $DATA | awk '{print $1}')
  TX_BYTES=$(echo $DATA | awk '{print $9}')
  if [[ $IFACE != "lo" ]]; then
    NET_LINES="${NET_LINES},${IFACE}_rx=${RX_BYTES},${IFACE}_tx=${TX_BYTES}"
  fi
done < <(cat /proc/net/dev | tail -n +3)

# ================
# PORT CONNECTIONS (example ports)
# ================
# Replace with your actual ports
PORTS=(22 80 443)
PORT_METRICS=""
for PORT in "${PORTS[@]}"; do
  COUNT=$(ss -ntu | awk '{print $5}' | grep -c ":$PORT$")
  PORT_METRICS="${PORT_METRICS},port_${PORT}_connections=${COUNT}"
done

# ================
# SERVICES (example services)
# ================
# Replace with your actual services
SERVICES=("sshd" "nginx")
SERVICE_METRICS=""
for SERVICE in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$SERVICE"; then
    SERVICE_METRICS="${SERVICE_METRICS},service_${SERVICE}=1"
  else
    SERVICE_METRICS="${SERVICE_METRICS},service_${SERVICE}=0"
  fi
done

# ================
# TEMPERATURES
# ================
TEMP_METRICS=""
for zone in /sys/class/thermal/thermal_zone*/; do
  if [[ -f "${zone}/type" && -f "${zone}/temp" ]]; then
    ZNAME=$(cat "${zone}/type" | tr ' ' '_')
    ZVAL=$(cat "${zone}/temp")
    TEMP_METRICS="${TEMP_METRICS},temp_${ZNAME}=${ZVAL}"
  fi
done

# ================
# UPTIME, OS INFO
# ================
UPTIME=$(awk '{print int($1)}' /proc/uptime)
OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')

# ================
# BUILD LINE PROTOCOL
# ================
LINE="${MEASUREMENT},host=${HOSTNAME} cpu_usage=${CPU_USAGE},mem_usage=${MEM_USAGE},swap_usage=${SWAP_USAGE},load1=${LOAD1},load5=${LOAD5},load15=${LOAD15},uptime=${UPTIME}${NET_LINES}${PORT_METRICS}${SERVICE_METRICS}${TEMP_METRICS}"

# Append disk usage as separate lines
while IFS=, read -r MOUNT USAGE; do
  LINE="${LINE}
disk_usage,host=${HOSTNAME},mount=${MOUNT} usage=${USAGE}"
done <<< "$DISK_LINES"

# Optional OS info as a tag in a final line
LINE="${LINE}
host_info,host=${HOSTNAME},os=\"${OS_NAME}\" info=1"

# ================
# PRINT TO CONSOLE
# ================
echo "$LINE"
