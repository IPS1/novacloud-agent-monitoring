#!/bin/bash
#
#
#	IPS1 Server Monitoring Agent - Install Script
#	Copyright 2025 - 2026 @  IPS1
#	For support, please open a ticket on our website https://www.ipserverone.com/
#
#
#		DISCLAIMER OF WARRANTY
#
#	The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind, 
#	including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement. 
#	IPS1 makes no warranty that the Software is free of defects or is suitable for any particular purpose. 
#	In no event shall IPS1 be responsible for loss or damages arising from the installation or use of the Software, 
#	including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including, 
#	without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses. 
#	The entire risk as to the quality and performance of the Software is borne by you, the user.
#
#

# Reject Windows (CRLF) line endings — they silently break bash keyword parsing
if grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then
	echo "ERROR: ${BASH_SOURCE[0]} contains Windows (CRLF) line endings."
	echo "Fix with:  sed -i 's/\r\$//' ${BASH_SOURCE[0]}"
	exit 1
fi

# Set PATH/Locale
export LC_NUMERIC="C"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ScriptPath=$(dirname "${BASH_SOURCE[0]}")

# Agent Version (do not change)
Version="0.1"

# Load configuration file
if [ -f "$ScriptPath"/ips1.cfg ]
then
	. "$ScriptPath"/ips1.cfg
else
	exit 1
fi

# Serialize agent runs. Two overlapping runs — a manual invocation racing the
# systemd timer, a slow tick overlapping the next, or the self-heal reset racing
# an in-flight run — can both enter the enroll+seal path and leave the gateway
# holding a freshly minted token that no sealed store has, which then 401s until
# a manual reinstall. Hold an exclusive whole-run lock; if another run already
# holds it, exit 0 and let that run finish this cycle. Fail open (run without the
# lock) when flock is unavailable so monitoring never silently stops.
LOCK_FILE="$ScriptPath/.lock"
if command -v flock >/dev/null 2>&1 && ( : >>"$LOCK_FILE" ) 2>/dev/null; then
	exec 9>>"$LOCK_FILE"
	if ! flock -n 9; then
		echo "IPS1 agent: another run is already in progress; skipping this tick." >&2
		exit 0
	fi
fi

# Load gateway cred from the machine-bound (key derived from /etc/machine-id);
creds=$(/usr/local/bin/creds reveal 2>/dev/null)
if [ -n "$creds" ]; then
	eval "$creds"
fi

# Reset the agent to its pre-enrollment state so the enrollment block below (or
# the next timer tick) re-enrolls from scratch. Restores GATEWAY_URL into
# ips1.cfg first, because the installer blanks that line after the first
# enrollment and the sealed store we are about to delete is its only remaining
# copy — without it a later tick could not reach the gateway to re-enroll.
# Safe against a genuinely deauthorized instance: re-enrollment goes through
# /v1/enroll, which the gateway verifies live against Nova and refuses if the
# instance no longer qualifies, so this can never re-authorize a revoked host.
reset_enrollment() {
	if [ -n "$GATEWAY_URL" ]; then
		sed -i "s|^GATEWAY_URL=.*|GATEWAY_URL=\"$GATEWAY_URL\"|" "$ScriptPath"/ips1.cfg 2>/dev/null || true
	fi
	rm -f /etc/ips1/.d
	SERVER_TOKEN=""
	SID=""
}

# Honor a customer opt-out set as instance metadata at launch
# (`openstack server create --property ips1_agent=disabled`). This is the
# opt-out model: monitoring runs unless the flag holds an explicit off value.
# An unreachable metadata service or unrecognized value falls through to
# monitoring, so a transient metadata outage never silently stops reporting.
# The gateway enforces the same flag at enroll time, so this on-VM check is a
# convenience/kill-switch, not the security boundary.
AGENT_META=$(curl -s --connect-timeout 5 http://169.254.169.254/openstack/latest/meta_data.json)
AGENT_FLAG=$(printf '%s' "$AGENT_META" | sed -n 's/.*"ips1_agent": *"\([^"]*\)".*/\1/p' | tr 'A-Z' 'a-z' | tr -d '[:space:]')
case "$AGENT_FLAG" in
	off|false|0|no|disabled)
		echo "IPS1 agent: monitoring disabled by instance metadata (ips1_agent=$AGENT_FLAG); exiting." >&2
		# The agent always runs as the unprivileged 'ips1' user, which cannot
		# manage systemd, so the early exit below is the real opt-out. The
		# root-only branch remains only as a courtesy for manual root runs.
		if [ "$(id -u)" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
			systemctl disable --now ips1-agent.timer >/dev/null 2>&1 || true
		fi
		exit 0
		;;
esac

# a reused volume carries the old instance's
# sealed store + /etc/machine-id, so the agent would keep reporting under the
# deleted instance's SID. Compare the sealed SID to the live metadata uuid each
# run; on a confirmed mismatch, reset to pre-enrollment state and re-enroll below.
# Fail-safe: only act on a confirmed mismatch (unreachable metadata = no-op).
# Stop/start/reboot/resize keep the uuid, so only volume re-homing triggers this.
# Reuses the metadata document fetched for the opt-out check above — the same
# tick never needs two snapshots of an immutable identity.
if [ -n "$SERVER_TOKEN" ] && [ -n "$SID" ]; then
	LIVE_SID=$(printf '%s' "$AGENT_META" | sed -n 's/.*"uuid": *"\([^"]*\)".*/\1/p')
	if [ -n "$LIVE_SID" ] && [ "$LIVE_SID" != "$SID" ]; then
		echo "IPS1 agent: instance identity changed ($SID -> $LIVE_SID); volume appears reused on a new instance. Dropping stale credentials and re-enrolling." >&2
		reset_enrollment
	fi
fi

# First-run self-enrollment: if this host has no sealed token yet, prove its
# OpenStack identity (instance uuid + project_id, read from the metadata service)
# to the gateway, which verifies it live against Nova. On success we seal the
# returned token and continue this run; otherwise we exit 0 so the next timer
# tick retries — this absorbs the brief window before the instance is ACTIVE in
# Nova and any transient verification outage.
if [ -z "$GATEWAY_URL" ] || [ -z "$SERVER_TOKEN" ]
then
	# GATEWAY_URL is sourced from ips1.cfg above (the installer writes it there).
	if [ -z "$GATEWAY_URL" ]; then
		echo "ERROR: not enrolled and GATEWAY_URL is not set in ips1.cfg. Re-run the installer." >&2
		exit 1
	fi
	# Reuse the metadata document already fetched for the opt-out check; only
	# refetch if that earlier call came back empty (transient metadata outage).
	META="$AGENT_META"
	if [ -z "$META" ]; then
		META=$(curl -s --connect-timeout 5 http://169.254.169.254/openstack/latest/meta_data.json)
	fi
	SID=$(printf '%s' "$META" | sed -n 's/.*"uuid": *"\([^"]*\)".*/\1/p')
	PROJECT_ID=$(printf '%s' "$META" | sed -n 's/.*"project_id": *"\([^"]*\)".*/\1/p')
	if [ -z "$SID" ] || [ -z "$PROJECT_ID" ]; then
		echo "ERROR: could not read uuid/project_id from OpenStack metadata; cannot enroll." >&2
		exit 1
	fi
	ENROLL_RESPONSE=$(curl -fsS --max-time 30 -XPOST "$GATEWAY_URL/v1/enroll" \
		-H "Content-Type: application/json" \
		-d "{\"sid\":\"$SID\",\"project_id\":\"$PROJECT_ID\"}") || {
		echo "Not yet authorized to enroll SID $SID (gateway rejected). Will retry next run." >&2
		exit 0
	}
	SERVER_TOKEN=$(printf '%s' "$ENROLL_RESPONSE" | sed -n 's/.*"server_token":"\([^"]*\)".*/\1/p')
	if [ -z "$SERVER_TOKEN" ]; then
		echo "ERROR: gateway returned no server_token. Response: $ENROLL_RESPONSE" >&2
		exit 0
	fi
	/usr/local/bin/creds seal --gateway "$GATEWAY_URL" --token "$SERVER_TOKEN" --sid "$SID" || {
		echo "ERROR: failed to seal credentials after enrollment." >&2
		exit 1
	}
	# The gateway URL and token are now sealed into the encrypted, machine-bound
	# credential store, which is authoritative from here on (loaded via `creds
	# reveal` at the top of every run). Blank the plaintext GATEWAY_URL out of
	# ips1.cfg so it no longer appears in any on-disk config file. This run keeps
	# using the in-memory $GATEWAY_URL; subsequent runs get it from the store.
	sed -i 's|^GATEWAY_URL=.*|GATEWAY_URL=""|' "$ScriptPath"/ips1.cfg 2>/dev/null || true
	echo "IPS1 agent enrolled successfully (SID=$SID)."
fi

# Script start time
ScriptStartTime=$(date +[%Y-%m-%d\ %T)

# Hostname, resolved once — it is interpolated into every line-protocol line,
# and forking $(hostname) per line adds up.
HOST=$(hostname)

# Service status function. Uses the $PSEF process snapshot captured just before
# each service-check loop, so N services cost one `ps` instead of N.
function servicestatus() {
	# Check first via ps
	if (( $(printf '%s\n' "${PSEF:-$(ps -ef)}" | grep -E "[\/ ]$1([^\/]|$)" | grep -cv "grep") > 0 ))
	then # Up
		echo "1"
	else # Down, try with systemctl (if available)
		if command -v "systemctl" > /dev/null 2>&1
		then # Use systemctl
			if systemctl is-active --quiet "$1"
			then # Up
				echo "1"
			else # Down, try service command
				if service "$1" status > /dev/null 2>&1
				then
					echo "1"
				else
					echo "0"
				fi
			fi
		else # No systemctl, try service command
			if service "$1" status > /dev/null 2>&1
			then
				echo "1"
			else
				echo "0"
			fi
		fi
	fi
}

# Function used to prepare base64 str for url encoding
function base64prep() {
	str=$1
	str="${str//+/%2B}"
	str="${str//\//%2F}"
	echo "$str"
}

# Current hour/minute as plain integers (10# strips leading zeros without sed)
H=$((10#$(date +%H)))
M=$((10#$(date +%M)))

# Clear debug.log every day at midnight
if [ "$H" -eq 0 ] && [ "$M" -eq 0 ] && [ -f "$ScriptPath"/debug.log ]
then
	rm -f "$ScriptPath"/debug.log
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Cleared debug.log" >> "$ScriptPath"/debug.log; fi
fi

# Start timers
START=$(date +%s)
tTIMEDIFF=0

if [ "$M" -eq 0 ]
then
	# Clear ips1_cron.log every hour
	if [ -f "$ScriptPath"/ips1_cron.log ]
	then
		rm -f "$ScriptPath"/ips1_cron.log
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Cleared ips1_cron.log" >> "$ScriptPath"/debug.log; fi
	fi
fi

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Starting IPS1 Agent v$Version" >> "$ScriptPath"/debug.log; fi

# Kill any lingering agent processes
HTProcesses=$(pgrep -f ips1_agent.sh | wc -l)
if [ -z "$HTProcesses" ]
then
	HTProcesses=0
fi
if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Found $HTProcesses agent processes\n$(ps aux | grep 'ips1_agent.sh')" >> "$ScriptPath"/debug.log; fi

if [ "$HTProcesses" -ge 50 ]
then
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Killing $HTProcesses lingering agent processes" >> "$ScriptPath"/debug.log; fi
	pgrep -f ips1_agent.sh | xargs -r kill -9
fi
if [ "$HTProcesses" -ge 10 ]
then
	for PID in $(pgrep -f ips1_agent.sh)
	do
		PID_TIME=$(ps -p "$PID" -oetime= | tr '-' ':' | awk -F: '{total=0; m=1;} {for (i=0; i < NF; i++) {total += $(NF-i)*m; m *= i >= 2 ? 24 : 60 }} {print total}')
		if [ -n "$PID_TIME" ] && [ "$PID_TIME" -ge 90 ]
		then
			if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Killing PID $PID, running for $PID_TIME seconds" >> "$ScriptPath"/debug.log; fi
			kill -9 "$PID"
		fi
	done
fi

# Network interfaces
# Automatically detect the active network interfaces
NetworkInterfacesArray=()
while IFS='' read -r line; do NetworkInterfacesArray+=("$line"); done < <(ip a | grep BROADCAST | grep 'state UP' | awk '{print $2}' | awk -F ":" '{print $1}' | awk -F "@" '{print $1}')
if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Network Interfaces: ${NetworkInterfacesArray[*]}" >> "$ScriptPath"/debug.log; fi

# Initial network usage
declare -A aRX
declare -A aTX
declare -A tRX
declare -A tTX
declare -A WantNIC
for NIC in "${NetworkInterfacesArray[@]}"
do
	WantNIC[$NIC]=1
	tRX[$NIC]=0
	tTX[$NIC]=0
done

# Capture RX/TX byte counters for every monitored NIC in one pass over
# /proc/net/dev (RX bytes = 1st and TX bytes = 9th value after "iface:").
while read -r NIC_NAME NIC_RX NIC_TX
do
	[ -n "${WantNIC[$NIC_NAME]+x}" ] || continue
	aRX[$NIC_NAME]=$NIC_RX
	aTX[$NIC_NAME]=$NIC_TX
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Network Interface $NIC_NAME RX: ${aRX[$NIC_NAME]} TX: ${aTX[$NIC_NAME]}" >> "$ScriptPath"/debug.log; fi
done < <(awk -F: 'NR>2 {iface=$1; gsub(/[[:space:]]/,"",iface); split($2,f," "); print iface, f[1], f[9]}' /proc/net/dev)

# Check Services
if [ -n "$CheckServices" ]
then
	declare -A SRVCSR
	IFS=',' read -r -a CheckServicesArray <<< "$CheckServices"
	PSEF=$(ps -ef)
	for i in "${CheckServicesArray[@]}"
	do
		SRVCSR[$i]=$(( ${SRVCSR[$i]} + $(servicestatus "$i") ))
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Service $i status: ${SRVCSR[$i]}" >> "$ScriptPath"/debug.log; fi
	done
fi

# Disks IOPS
# Resolve mountpoint→device and capture the starting /proc/diskstats counters
# with one pass per data source instead of grep pipelines per disk.
declare -A vDISKs
LSBLK_L=$(lsblk -l)
for i in $(timeout 3 df | awk '$1 ~ /\// {print $(NF)}')
do
	vDISKs[$i]=$(printf '%s\n' "$LSBLK_L" | awk -v mp="$i" '{for (f = 2; f <= NF; f++) if ($f == mp) {print $1; exit}}')
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Disk $i: ${vDISKs[$i]}" >> "$ScriptPath"/debug.log; fi
done
declare -A BlockSize
declare -A IOPSRead
declare -A IOPSWrite
declare -A READOPS_START
declare -A WRITEOPS_START
declare -A IOPSReadOps
declare -A IOPSWriteOps

# Device → physical sector size, first match wins (lsblk lists each device once)
declare -A PHYSEC
while read -r DEV_NAME DEV_PHYSEC _
do
	[ -n "${PHYSEC[$DEV_NAME]+x}" ] || PHYSEC[$DEV_NAME]=$DEV_PHYSEC
done < <(lsblk -l -b -o NAME,PHY-SEC,MOUNTPOINTS | sed 1d)

# Device → diskstats counters: reads completed ($4), sectors read ($6),
# writes completed ($8), sectors written ($10)
declare -A DS_OPS_READ DS_SEC_READ DS_OPS_WRITE DS_SEC_WRITE
while read -r DEV_NAME DEV_ROPS DEV_RSEC DEV_WOPS DEV_WSEC
do
	DS_OPS_READ[$DEV_NAME]=$DEV_ROPS
	DS_SEC_READ[$DEV_NAME]=$DEV_RSEC
	DS_OPS_WRITE[$DEV_NAME]=$DEV_WOPS
	DS_SEC_WRITE[$DEV_NAME]=$DEV_WSEC
done < <(awk '{print $3, $4, $6, $8, $10}' /proc/diskstats)

for i in "${!vDISKs[@]}"
do
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) IOPS Disk $i: ${vDISKs[$i]}" >> "$ScriptPath"/debug.log; fi
	# An unresolved mountpoint has no device; keep counters at 0 (and never use
	# an empty string as an array subscript — older bash rejects it).
	DEV=${vDISKs[$i]}
	BlockSize[$i]=""
	IOPSRead[$i]=0
	IOPSWrite[$i]=0
	READOPS_START[$i]=0
	WRITEOPS_START[$i]=0
	if [ -n "$DEV" ]
	then
		BlockSize[$i]=${PHYSEC[$DEV]:-}
		IOPSRead[$i]=${DS_SEC_READ[$DEV]:-0}
		IOPSWrite[$i]=${DS_SEC_WRITE[$DEV]:-0}
		READOPS_START[$i]=${DS_OPS_READ[$DEV]:-0}
		WRITEOPS_START[$i]=${DS_OPS_WRITE[$DEV]:-0}
	fi
	if [ -z "${BlockSize[$i]}" ] || ! [[ ${BlockSize[$i]} =~ ^[0-9]+$ ]] || [ "${BlockSize[$i]}" -eq 0 ]
	then
		BlockSize[$i]=512
	fi
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Disk $i Block Size: ${BlockSize[$i]} IOPS Read: ${IOPSRead[$i]} Write: ${IOPSWrite[$i]}" >> "$ScriptPath"/debug.log; fi
done

# Zpool IOPS
if [ -x "$(command -v zpool)" ]
then
	readarray -t zpoolsray < <(zpool list -H -o name)
	if [ ${#zpoolsray[@]} -gt 0 ]
	then
		current_second=$(date +%S | sed 's/^0*//')
		remaining_seconds=$((58 - current_second))
		declare -A pipes
		declare -A pids
		declare -A zpools_mountpoints
		for pool in "${zpoolsray[@]}"
		do
			zpools_mountpoints[$pool]=$(zfs get -H -o value mountpoint "$pool")
			pipe=$(mktemp -u)
			mkfifo "$pipe"
			pipes[$pool]="$pipe"
			timeout 60 zpool iostat -v -p "$pool" "$remaining_seconds" 2 | awk 'BEGIN{found=0} /capacity/ {found++} found==2' | grep "$pool" > "$pipe" &
			pids[$pool]=$!
			if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) zpool $pool mounted at ${zpools_mountpoints[$pool]} starting iostat pid ${pids[$pool]} pipe ${pipes[$pool]} for $remaining_seconds seconds" >> "$ScriptPath"/debug.log; fi
		done
	fi
fi

# Calculate how many how many data sample loops
RunTimes=$(echo | awk "{print 60 / $CollectEveryXSeconds}")
if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Collecting data for $RunTimes loops" >> "$ScriptPath"/debug.log; fi

# Memory totals cannot change between samples — read both once, in one pass
read -r bRAM cRAM <<< "$(awk '/^MemTotal:/ {t=$2} /^SwapTotal:/ {s=$2} END{print t+0, s+0}' /proc/meminfo)"

# Initialize accumulators
tCPU=0; tCPUwa=0; tCPUst=0; tCPUus=0; tCPUsy=0; tCPUidle=0; tCPUSpeed=0
tloadavg1=0; tloadavg5=0; tloadavg15=0
tRAM=0; tRAMSwap=0; tRAMBuff=0; tRAMCache=0

# Collect data loop
for X in $(seq "$RunTimes")
do
	# Get vmstat
	VMSTAT=$(vmstat "$CollectEveryXSeconds" 2 | tail -1)
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) $VMSTAT" >> "$ScriptPath"/debug.log; fi

	# CPU clock: per-core MHz rounded and summed in one pass
	CPUSpeed=$(awk -F': *' '/^cpu MHz/ {s += int($2 + 0.5)} END{printf "%d", s}' /proc/cpuinfo)

	# CPU Load, straight from /proc (no subprocess)
	read -r loadavg1 loadavg5 loadavg15 _ < /proc/loadavg

	# Derive every per-sample value from the vmstat line and update all
	# accumulators in a single awk pass (replaces ~30 subshells per sample):
	# us=$13 sy=$14 id=$15 wa=$16 st=$17, swap used=$3, free/buff/cache=$4/$5/$6
	read -r CPU CPUwa CPUst CPUus CPUsy CPUidle RAM RAMSwap RAMBuff RAMCache \
		tCPU tCPUwa tCPUst tCPUus tCPUsy tCPUidle tRAM tRAMSwap tRAMBuff tRAMCache \
		tloadavg1 tloadavg5 tloadavg15 tCPUSpeed <<< "$(echo "$VMSTAT" | awk \
		-v bram="$bRAM" -v cram="$cRAM" -v spd="${CPUSpeed:-0}" \
		-v l1="$loadavg1" -v l5="$loadavg5" -v l15="$loadavg15" \
		-v tcpu="$tCPU" -v twa="$tCPUwa" -v tst="$tCPUst" -v tus="$tCPUus" \
		-v tsy="$tCPUsy" -v tid="$tCPUidle" -v tram="$tRAM" -v tswap="$tRAMSwap" \
		-v tbuff="$tRAMBuff" -v tcache="$tRAMCache" \
		-v tl1="$tloadavg1" -v tl5="$tloadavg5" -v tl15="$tloadavg15" -v tspd="$tCPUSpeed" '{
		cpu = 100 - $15; wa = $16; st = $17; us = $13; sy = $14; idle = $15
		ram = 100 - (($4 + $5 + $6) * 100 / bram)
		swap = (cram > 0) ? ($3 * 100 / cram) : 0
		buff = $5 * 100 / bram
		cache = $6 * 100 / bram
		print cpu, wa, st, us, sy, idle, ram, swap, buff, cache, \
			tcpu + cpu, twa + wa, tst + st, tus + us, tsy + sy, tid + idle, \
			tram + ram, tswap + swap, tbuff + buff, tcache + cache, \
			tl1 + l1, tl5 + l5, tl15 + l15, tspd + spd
	}')"

	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) CPU: $CPU IO wait: $CPUwa Steal time: $CPUst User time: $CPUus System time: $CPUsy Load: $loadavg1 $loadavg5 $loadavg15" >> "$ScriptPath"/debug.log; fi
	if [ "$DEBUG" -eq 1 ]; then
      echo -e "$ScriptStartTime-$(date +%T]) RAM: $RAM Swap: $RAMSwap Buffers: $RAMBuff Cache: $RAMCache" >> "$ScriptPath"/debug.log
    fi

	# Network usage
	END=$(date +%s)
	TIMEDIFF=$(( END - START ))
	[ "$TIMEDIFF" -le 0 ] && TIMEDIFF=1
	tTIMEDIFF=$(( tTIMEDIFF + TIMEDIFF ))
	START=$END

	# Read all NIC counters in one pass and accumulate per-interface rates
	# with shell arithmetic (byte counters and seconds are integers).
	while read -r NIC_NAME NIC_RX NIC_TX
	do
		[ -n "${WantNIC[$NIC_NAME]+x}" ] || continue
		RX=$(( (NIC_RX - ${aRX[$NIC_NAME]:-NIC_RX}) / TIMEDIFF ))
		TX=$(( (NIC_TX - ${aTX[$NIC_NAME]:-NIC_TX}) / TIMEDIFF ))
		aRX[$NIC_NAME]=$NIC_RX
		aTX[$NIC_NAME]=$NIC_TX
		tRX[$NIC_NAME]=$(( ${tRX[$NIC_NAME]:-0} + RX ))
		tTX[$NIC_NAME]=$(( ${tTX[$NIC_NAME]:-0} + TX ))
	done < <(awk -F: 'NR>2 {iface=$1; gsub(/[[:space:]]/,"",iface); split($2,f," "); print iface, f[1], f[9]}' /proc/net/dev)

	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Network Traffic: ${tRX[*]} ${tTX[*]}" >> "$ScriptPath"/debug.log; fi

	# Check if minute changed, so we can end the loop
	MM=$((10#$(date +%M)))
	if [ "$MM" -ne "$M" ]
	then
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Minute changed, ending loop" >> "$ScriptPath"/debug.log; fi
		break
	fi
done

# --- RAM used/free in BYTES for charts (one meminfo pass per minute) ---
read -r MemTotalKB MemAvailKB MemFreeKB BuffersKB CachedKB SReclaimKB ShmemKB <<< \
	"$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} /^Buffers:/ {b=$2} /^Cached:/ {c=$2} /^SReclaimable:/ {r=$2} /^Shmem:/ {m=$2} END{print t+0, a+0, f+0, b+0, c+0, r+0, m+0}' /proc/meminfo)"
if [ "$MemAvailKB" -eq 0 ]; then
  MemAvailKB=$(( MemFreeKB + BuffersKB + CachedKB + SReclaimKB - ShmemKB ))
fi
RAMUsedBytes=$(( (MemTotalKB - MemAvailKB) * 1024 ))
RAMFreeBytes=$(( MemAvailKB * 1024 ))

# Get user running the agent
User=$(whoami)

# Check if system requires reboot
RequiresReboot=0
if [ -f  /var/run/reboot-required ]
then
	RequiresReboot=1
fi

# Operating System
# Check via lsb_release if possible
if command -v "lsb_release" > /dev/null 2>&1
then
	OS=$(lsb_release -s -d)
# Check if it's Debian
elif [ -f /etc/debian_version ]
then
	OS="Debian $(cat /etc/debian_version)"
# Check if it's CentOS/Fedora
elif [ -f /etc/redhat-release ]
then
	OS=$(cat /etc/redhat-release)
	# Check if system is CloudLinux release 8 (CL8 will only output "This system is receiving updates from CloudLinux Network server.")
	if [[ "$OS" != "CloudLinux release 8."* ]]
	then
		# Check if system requires reboot (Only supported in CentOS/RHEL 7 and later, with yum-utils installed)
		if timeout -s 9 5 needs-restarting -r | grep -q 'Reboot is required'
		then
			RequiresReboot=1
		fi
	fi
# If all else fails
else
	OS="$(grep '^PRETTY_NAME=' /etc/os-release | awk -F'"' '{print $2}')" || OS="$(uname -s)" || OS="Linux"
fi
OS=$(echo -ne "$OS" | base64 | tr -d '\n\r\t ')

# Kernel
Kernel=$(uname -r | base64 | tr -d '\n\r\t ')

# Hostname
Hostname=$(uname -n | base64 | tr -d '\n\r\t ')

# Server uptime
Uptime=$(awk '{print $1}' < /proc/uptime | awk '{printf "%18.0f",$1}' | xargs)

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) User: $User OS: $OS Kernel: $Kernel Hostname: $Hostname Uptime: $Uptime" >> "$ScriptPath"/debug.log; fi

# lscpu
lscpu=$(lscpu)

# CPU model
CPUModel=$(grep -m1 -E 'model name|cpu model' /proc/cpuinfo | awk -F": " '{print $NF}' | xargs)
if [ -z "$CPUModel" ]
then
	CPUModel=$(echo "$lscpu" | grep "^Model name:" | awk -F": " '{print $NF}' | xargs)
fi
CPUModel=$(echo -ne "$CPUModel" | base64 | tr -d '\n\r\t ')

# CPU sockets
CPUSockets=$(grep -i "physical id" /proc/cpuinfo | sort -u | wc -l)

# CPU cores
CPUCores=$(echo "$lscpu" | grep "^CPU(s):" | awk '{print $(NF)}' | xargs)
if [ -z "$CPUCores" ] || [ "$CPUCores" -eq 0 ] 2>/dev/null; then
	CPUCores=1
fi

# CPU threads
CPUThreads=$(echo "$lscpu" | grep "^Thread(s) per core:" | awk '{print $(NF)}' | xargs)

# CPU clock speed
if [ -z "$tCPUSpeed" ] || [ "$tCPUSpeed" -eq 0 ]
then
	CPUSpeed=$(echo "$lscpu" | grep "^CPU max MHz" | awk '{print $NF}' | awk '{printf "%18.0f",$1}' | xargs)
else
	CPUSpeed=$(awk -v t="$tCPUSpeed" -v c="$CPUCores" -v x="$X" 'BEGIN{printf "%.0f", t / c / x}')
fi

# RAM sizes were read once before the sampling loop
RAMSize=$bRAM
RAMSwapSize=$cRAM

# Averages over the X collected samples, all in one awk pass. CPU is reported
# as us+sy+wa+st+idle (≈100), matching the historical recomputation.
read -r CPU CPUwa CPUst CPUus CPUsy CPUidle loadavg1 loadavg5 loadavg15 RAM RAMSwap RAMBuff RAMCache <<< "$(awk \
	-v x="$X" -v twa="$tCPUwa" -v tst="$tCPUst" -v tus="$tCPUus" -v tsy="$tCPUsy" -v tid="$tCPUidle" \
	-v tl1="$tloadavg1" -v tl5="$tloadavg5" -v tl15="$tloadavg15" \
	-v tram="$tRAM" -v tswap="$tRAMSwap" -v tbuff="$tRAMBuff" -v tcache="$tRAMCache" \
	-v swapsize="$RAMSwapSize" 'BEGIN{
	wa = twa / x; st = tst / x; us = tus / x; sy = tsy / x; idle = tid / x
	printf "%.2f ", us + sy + wa + st + idle
	print wa, st, us, sy, idle, tl1 / x, tl5 / x, tl15 / x, \
		tram / x, (swapsize > 0 ? tswap / x : 0), tbuff / x, tcache / x
}')"

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) CPU Model: $CPUModel Sockets: $CPUSockets Cores: $CPUCores Threads: $CPUThreads Speed: $CPUSpeed CPU: $CPU IO wait: $CPUwa Steal time: $CPUst User time: $CPUus System time: $CPUsy Load: $loadavg1 $loadavg5 $loadavg15" >> "$ScriptPath"/debug.log; fi

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) RAM Size: $RAMSize Usage: $RAM Swap Size: $RAMSwapSize Usage: $RAMSwap Buffers: $RAMBuff Cache: $RAMCache" >> "$ScriptPath"/debug.log; fi

# Disks inodes
INODEs=$(echo -ne "$(timeout 3 df -Ti | sed 1d | grep -v -E 'tmpfs' | awk '{print $(NF)","$3","$4","$5";"}')" | tr -d '\n\r\t ' | base64 | tr -d '\n\r\t ')

# Disks IOPS
IOPS=""
if [ -z "$tTIMEDIFF" ] || [ "$tTIMEDIFF" -le 0 ]; then
  tTIMEDIFF=1
fi
# Re-read the closing /proc/diskstats counters in one pass, then compute all
# four rates per disk with a single awk call (was ~10 pipelines per disk).
while read -r DEV_NAME DEV_ROPS DEV_RSEC DEV_WOPS DEV_WSEC
do
	DS_OPS_READ[$DEV_NAME]=$DEV_ROPS
	DS_SEC_READ[$DEV_NAME]=$DEV_RSEC
	DS_OPS_WRITE[$DEV_NAME]=$DEV_WOPS
	DS_SEC_WRITE[$DEV_NAME]=$DEV_WSEC
done < <(awk '{print $3, $4, $6, $8, $10}' /proc/diskstats)
for i in "${!vDISKs[@]}"
do
	# Same empty-subscript guard as the initial capture: no device → all zeros
	DEV=${vDISKs[$i]}
	CUR_RSEC=0; CUR_WSEC=0; CUR_ROPS=0; CUR_WOPS=0
	if [ -n "$DEV" ]
	then
		CUR_RSEC=${DS_SEC_READ[$DEV]:-0}
		CUR_WSEC=${DS_SEC_WRITE[$DEV]:-0}
		CUR_ROPS=${DS_OPS_READ[$DEV]:-0}
		CUR_WOPS=${DS_OPS_WRITE[$DEV]:-0}
	fi
	read -r DISK_R_BPS DISK_W_BPS DISK_R_IOPS DISK_W_IOPS <<< "$(awk \
		-v rsec="$CUR_RSEC" -v rsec0="${IOPSRead[$i]:-0}" \
		-v wsec="$CUR_WSEC" -v wsec0="${IOPSWrite[$i]:-0}" \
		-v rops="$CUR_ROPS" -v rops0="${READOPS_START[$i]:-0}" \
		-v wops="$CUR_WOPS" -v wops0="${WRITEOPS_START[$i]:-0}" \
		-v bs="${BlockSize[$i]}" -v t="$tTIMEDIFF" 'BEGIN{
		if (t <= 0) t = 1
		printf "%.0f %.0f %.2f %.2f", (rsec - rsec0) * bs / t, (wsec - wsec0) * bs / t, (rops - rops0) / t, (wops - wops0) / t
	}')"
	IOPSRead[$i]=$DISK_R_BPS
	IOPSWrite[$i]=$DISK_W_BPS
	IOPSReadOps[$i]=$DISK_R_IOPS
	IOPSWriteOps[$i]=$DISK_W_IOPS
	IOPS="$IOPS$i,${IOPSRead[$i]},${IOPSWrite[$i]};"
done
# Zpool IOPS
if [ -x "$(command -v zpool)" ]
then
	if [ ${#zpoolsray[@]} -gt 0 ]
	then
		for pool in "${zpoolsray[@]}"
		do
			if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) zpool $pool mounted at ${zpools_mountpoints[$pool]} reading from iostat pipe" >> "$ScriptPath"/debug.log; fi
			zpooloutput=$(<"${pipes[$pool]}")
			if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) zpool $pool iostat output: $zpooloutput" >> "$ScriptPath"/debug.log; fi
			if [ "$zpooloutput" != "Terminated" ] && [ -n "$zpooloutput" ]
			then
				read_bytes_per_sec=$(echo "$zpooloutput" | awk '{print $(NF-1)}')
				write_bytes_per_sec=$(echo "$zpooloutput" | awk '{print $NF}')
				if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) zpool $pool read bytes per sec: $read_bytes_per_sec write bytes per sec: $write_bytes_per_sec" >> "$ScriptPath"/debug.log; fi
				kill "${pids[$pool]}" 2>/dev/null
				rm "${pipes[$pool]}" 2>/dev/null
				IOPS="$IOPS${zpools_mountpoints[$pool]},$read_bytes_per_sec,$write_bytes_per_sec;"
			fi
		done
	fi
fi
IOPS=$(echo -ne "$IOPS" | base64 | tr -d '\n\r\t ')

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) lsblk: $(lsblk -l | base64 | tr -d '\n\r\t ') Disks: $DISKs Inodes: $INODEs IOPS: $IOPS" >> "$ScriptPath"/debug.log; fi

# Total network usage and IP addresses
RX=0
TX=0
NICS=""
IPv4=""
IPv6=""
declare -A RXBPS
declare -A TXBPS
for NIC in "${NetworkInterfacesArray[@]}"
do
	# Individual NIC network usage, averaged over the X samples. Stored per
	# NIC so the line-protocol assembly below reuses them without recomputing.
	read -r RX TX <<< "$(awk -v rx="${tRX[$NIC]:-0}" -v tx="${tTX[$NIC]:-0}" -v x="$X" 'BEGIN{printf "%.0f %.0f", rx / x, tx / x}')"
	RXBPS[$NIC]=$RX
	TXBPS[$NIC]=$TX
	NICS="$NICS$NIC,$RX,$TX;"
	# Individual NIC IP addresses
	IPv4="$IPv4$NIC,$(ip -4 addr show "$NIC" | grep -oP 'inet \K[\d.]+' | xargs | sed 's/ /,/g');"
	IPv6="$IPv6$NIC,$(ip -6 addr show "$NIC" | grep -w "global" | grep -oP 'inet6 \K[0-9a-fA-F:]+' | xargs | sed 's/ /,/g');"
done
NICS=$(echo -ne "$NICS" | base64 | tr -d '\n\r\t ')
IPv4=$(echo -ne "$IPv4" | base64 | tr -d '\n\r\t ')
IPv6=$(echo -ne "$IPv6" | base64 | tr -d '\n\r\t ')

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Network Interfaces: $NICS IPv4: $IPv4 IPv6: $IPv6" >> "$ScriptPath"/debug.log; fi

# Check Services
SRVCS=""
if [ -n "$CheckServices" ]
then
	PSEF=$(ps -ef)
	for i in "${CheckServicesArray[@]}"
	do
		SRVCSR[$i]=$(( ${SRVCSR[$i]} + $(servicestatus "$i") ))
		if [ "${SRVCSR[$i]}" -eq "0" ]
		then
			SRVCS="$SRVCS$i,0;"
		else
			SRVCS="$SRVCS$i,1;"
		fi
	done
fi
SRVCS=$(echo -ne "$SRVCS" | base64 | tr -d '\n\r\t ')

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Services: $SRVCS" >> "$ScriptPath"/debug.log; fi

# Disks usage
DISKs=""
IFS=$'\n' read -d '' -r -a DISKsArray < <(timeout 3 df -TPB1 | sed 1d | grep -v -E 'tmpfs' | awk '{print $(NF)","$2","$3","$4","$5";"}')
for i in "${DISKsArray[@]}"
do
	IFS=',' read -r mount_point filesystem_type total_size used_size available_size <<< "$i"
	DISKs="$DISKs$mount_point,$filesystem_type,$total_size,$used_size,$available_size;"
done
DISKs=$(echo -ne "$DISKs" | base64 | tr -d '\n\r\t ')

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) DISKs: $DISKs" >> "$ScriptPath"/debug.log; fi

# Custom Variables
CV=""
if [ -n "$CustomVars" ]
then
	if [ -s "$ScriptPath"/"$CustomVars" ]
	then
		CV=$(< "$ScriptPath"/"$CustomVars" base64 | tr -d '\n\r\t ')
	fi
fi

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) CV: $CV" >> "$ScriptPath"/debug.log; fi

# Running Processes
RPS1=""
RPS2=""
if [ "$RunningProcesses" -gt 0 ]
then
	if [ -f "$ScriptPath"/running_proc.txt ]
	then
		# Get initial 'running processes' snapshot, saved from last run
		RPS1=$(cat "$ScriptPath"/running_proc.txt)
	fi
	# Get the current 'running processes' snapshot
	RPS2=$(ps -Ao pid,ppid,uid,user:20,pcpu,pmem,cputime,etime,comm,cmd --no-headers)
	RPS2=$(echo -ne "$RPS2" | base64 -w 0 | sed 's/ //g')
	# Save the current snapshot for next run
	echo "$RPS2" > "$ScriptPath"/running_proc.txt
fi
# Secured Connection
if [ "$SecuredConnection" -gt 0 ]
then
	SecuredConnection=""
else
	SecuredConnection="--no-check-certificate"
fi

# Current time/date
Time=$(date +%Y-%m-%d\ %T\ %Z | base64 | tr -d '\n\r\t ')

TIMESTAMP=$(date +%s)

LINE_CPU="cpu_stats,sid=$SID,host=$HOST cpu=$CPU,idle=$CPUidle,wa=$CPUwa,st=$CPUst,us=$CPUus,sy=$CPUsy,cpuspeed=$CPUSpeed $TIMESTAMP"
LINE_LOAD="load_stats,sid=$SID load1=$loadavg1,load5=$loadavg5,load15=$loadavg15 $TIMESTAMP"
LINE_MEM="memory_stats,sid=$SID,host=$HOST ram_used_bytes=${RAMUsedBytes}i,ram_free_bytes=${RAMFreeBytes}i $TIMESTAMP"
LINE_SYS="system_stats,sid=$SID,host=$HOST uptime=${Uptime}i,reqreboot=${RequiresReboot}i,alive=1i $TIMESTAMP"

# Start assembling all lines into one variable
LINES="$LINE_CPU
$LINE_LOAD
$LINE_MEM
$LINE_SYS"

# Add network interfaces (rates were already averaged into RXBPS/TXBPS above)
for NIC in "${NetworkInterfacesArray[@]}"; do
  LINES="$LINES
network_stats,sid=$SID,host=$HOST,interface=$NIC rx_bps=${RXBPS[$NIC]:-0}i,tx_bps=${TXBPS[$NIC]:-0}i $TIMESTAMP"
done

# Add service statuses
for SERVICE in "${!SRVCSR[@]}"; do
  STATUS="${SRVCSR[$SERVICE]}"
  LINES="$LINES
service_status,sid=$SID,host=$HOST,service=$SERVICE status=${STATUS}i $TIMESTAMP"
done

# Add disk IOPS stats
for DISK in "${!IOPSRead[@]}"; do
  READ_BPS=${IOPSRead[$DISK]}
  WRITE_BPS=${IOPSWrite[$DISK]}
  LINES="$LINES
disk_throughput,sid=$SID,host=$HOST,mountpoint=$DISK,device=${vDISKs[$DISK]} read_bps=${READ_BPS}i,write_bps=${WRITE_BPS}i $TIMESTAMP"
done

# Add TRUE disk IOPS stats (ops/sec from operation counters)
for DISK in "${!IOPSReadOps[@]}"; do
  READ_IOPS=${IOPSReadOps[$DISK]}
  WRITE_IOPS=${IOPSWriteOps[$DISK]}
  TOTAL_IOPS=$(awk -v x="$READ_IOPS" -v y="$WRITE_IOPS" 'BEGIN{printf "%.2f", x+y}')
  LINES="$LINES
disk_iops,sid=$SID,host=$HOST,mountpoint=$DISK,device=${vDISKs[$DISK]} read_iops=$READ_IOPS,write_iops=$WRITE_IOPS,total_iops=$TOTAL_IOPS $TIMESTAMP"
done

# Add disk size & usage
for entry in "${DISKsArray[@]}"; do
  # strip any trailing semicolon from the CSV entry
  clean_entry="${entry%;}"
  IFS=',' read -r MNT FSTYPE TOTAL USED AVAIL <<< "$clean_entry"
  LINES="$LINES
disk_size,sid=$SID,host=$HOST,mountpoint=$MNT,fstype=$FSTYPE total_bytes=${TOTAL}i,used_bytes=${USED}i,avail_bytes=${AVAIL}i $TIMESTAMP"
done

# Print to console for debug
echo "InfluxDB Line Protocol Payload (timestamp=$TIMESTAMP):"
echo "$LINES"

# Send line protocol to the gateway.
# Use a private per-run temp file (not a fixed /tmp path) so a file left behind
# by another user can never block or hijack the response capture.
GW_RESPONSE_FILE=$(mktemp "${TMPDIR:-/tmp}/ips1_gw_response.XXXXXX") || GW_RESPONSE_FILE=/dev/null
GW_HTTP_CODE=$(curl -s -o "$GW_RESPONSE_FILE" -w "%{http_code}" --max-time 15 \
  -XPOST "$GATEWAY_URL/v1/write" \
  -H "Authorization: Bearer $SERVER_TOKEN" \
  -H "Content-Type: text/plain; charset=utf-8" \
  --data-binary "$LINES")

if [ "$GW_HTTP_CODE" = "204" ]; then
  echo "Metrics accepted by gateway."
elif [ "$GW_HTTP_CODE" = "401" ]; then
  # The gateway no longer recognizes this token (e.g. the server row was
  # re-tokenized by a later enrollment, revoked, or lost to a DB reset). Self-heal
  # by dropping the sealed credentials so the next timer tick re-enrolls and seals
  # a fresh token — no manual reinstall needed. The gateway's live Nova check at
  # enroll time remains the security boundary, so a deauthorized host stays out.
  echo "ERROR: gateway rejected SERVER_TOKEN (401); dropping stale credentials to re-enroll on the next run."
  if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Gateway 401, token rejected; resetting enrollment" >> "$ScriptPath"/debug.log; fi
  reset_enrollment
else
  echo "ERROR: gateway returned HTTP $GW_HTTP_CODE: $(cat "$GW_RESPONSE_FILE")"
  if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Gateway HTTP $GW_HTTP_CODE: $(cat "$GW_RESPONSE_FILE")" >> "$ScriptPath"/debug.log; fi
fi
rm -f "$GW_RESPONSE_FILE"
