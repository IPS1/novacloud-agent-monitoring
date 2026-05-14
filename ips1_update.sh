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

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

GITHUB_REPO="${IPS1_GITHUB_REPO:-IPS1/novacloud-agent-monitoring}"
BRANCH="${IPS1_AGENT_BRANCH:-main}"
INSTALL_DIR="${IPS1_INSTALL_DIR:-/etc/ips1}"
BASE_URL="${IPS1_AGENT_BASE_URL:-https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH}"

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

fetch_file() {
	local source_url="$1"
	local destination="$2"

	if command -v wget >/dev/null 2>&1; then
		wget -t 1 -T 30 -qO "$destination" "$source_url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 30 "$source_url" -o "$destination"
	else
		fail "wget or curl is required to download updates."
	fi
}

read_version() {
	sed -n 's/^Version="\([^"]*\)".*/\1/p' "$1" | head -n 1
}

merge_missing_config_keys() {
	local default_config="$1"
	local installed_config="$2"
	local added_header=0
	local line key

	while IFS= read -r line; do
		case "$line" in
			""|\#*) continue ;;
		esac

		if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
			key="${line%%=*}"
			if ! grep -qE "^[[:space:]]*$key=" "$installed_config"; then
				if [ "$added_header" -eq 0 ]; then
					printf '\n# Added by ips1_update.sh from the default config on %s\n' "$(date +%Y-%m-%d)" >> "$installed_config"
					added_header=1
				fi
				printf '%s\n' "$line" >> "$installed_config"
			fi
		fi
	done < "$default_config"
}

stop_running_agents() {
	local pids pid

	pids=$(pgrep -f "$INSTALL_DIR/ips1_agent.sh" 2>/dev/null || true)
	if [ -z "$pids" ]; then
		return
	fi

	for pid in $pids; do
		if [ "$pid" != "$$" ]; then
			kill "$pid" 2>/dev/null || true
		fi
	done

	sleep 2

	for pid in $pids; do
		if kill -0 "$pid" 2>/dev/null; then
			kill -9 "$pid" 2>/dev/null || true
		fi
	done
}

echo "Checking root privileges..."
[ "$EUID" -eq 0 ] || fail "Please run this update script as root."
echo "... done."

echo "Checking current IPS1 installation..."
[ -d "$INSTALL_DIR" ] || fail "$INSTALL_DIR does not exist. Run ips1_install.sh first."
[ -f "$INSTALL_DIR/ips1.cfg" ] || fail "$INSTALL_DIR/ips1.cfg is missing. Run ips1_install.sh first."
[ -f "$INSTALL_DIR/credentials.cfg" ] || fail "$INSTALL_DIR/credentials.cfg is missing. Run ips1_install.sh first."
grep -q '^GATEWAY_URL=' "$INSTALL_DIR/credentials.cfg" || \
	fail "credentials.cfg is missing GATEWAY_URL. Re-run ips1_install.sh with IPS1_GATEWAY_URL and IPS1_ENROLL_CODE."
echo "... done."

CURRENT_VERSION="$(read_version "$INSTALL_DIR/ips1_agent.sh")"
[ -n "$CURRENT_VERSION" ] || CURRENT_VERSION="unknown"

TMP_DIR="$(mktemp -d)"
BACKUP_DIR="$INSTALL_DIR/backups/update-$(date +%Y%m%d%H%M%S)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading latest agent files from $GITHUB_REPO/$BRANCH..."
fetch_file "$BASE_URL/ips1_agent.sh" "$TMP_DIR/ips1_agent.sh" || fail "Failed to download ips1_agent.sh."
fetch_file "$BASE_URL/ips1.cfg" "$TMP_DIR/ips1.cfg" || fail "Failed to download ips1.cfg."
fetch_file "$BASE_URL/ips1_update.sh" "$TMP_DIR/ips1_update.sh" || fail "Failed to download ips1_update.sh."
echo "... done."

echo "Validating downloaded scripts..."
sed -i 's/\r$//' "$TMP_DIR/ips1_agent.sh" "$TMP_DIR/ips1.cfg" "$TMP_DIR/ips1_update.sh"
bash -n "$TMP_DIR/ips1_agent.sh" || fail "Downloaded ips1_agent.sh failed bash syntax validation."
bash -n "$TMP_DIR/ips1_update.sh" || fail "Downloaded ips1_update.sh failed bash syntax validation."
NEW_VERSION="$(read_version "$TMP_DIR/ips1_agent.sh")"
[ -n "$NEW_VERSION" ] || NEW_VERSION="unknown"
echo "... done."

echo "Backing up current installation files..."
mkdir -p "$BACKUP_DIR" || fail "Failed to create backup directory $BACKUP_DIR."
cp -p "$INSTALL_DIR/ips1_agent.sh" "$BACKUP_DIR/ips1_agent.sh" 2>/dev/null || true
cp -p "$INSTALL_DIR/ips1.cfg" "$BACKUP_DIR/ips1.cfg" 2>/dev/null || true
cp -p "$INSTALL_DIR/ips1_update.sh" "$BACKUP_DIR/ips1_update.sh" 2>/dev/null || true
echo "... done."

echo "Stopping running IPS1 agent processes..."
stop_running_agents
echo "... done."

echo "Installing updated agent files..."
cp "$TMP_DIR/ips1_agent.sh" "$INSTALL_DIR/ips1_agent.sh" || fail "Failed to install ips1_agent.sh."
cp "$TMP_DIR/ips1_update.sh" "$INSTALL_DIR/ips1_update.sh" || fail "Failed to install ips1_update.sh."
merge_missing_config_keys "$TMP_DIR/ips1.cfg" "$INSTALL_DIR/ips1.cfg"
chmod 700 "$INSTALL_DIR/ips1_agent.sh" "$INSTALL_DIR/ips1_update.sh"
chmod 600 "$INSTALL_DIR/credentials.cfg"
if command -v chown >/dev/null 2>&1; then
	chown --reference="$INSTALL_DIR" "$INSTALL_DIR/ips1_agent.sh" "$INSTALL_DIR/ips1_update.sh" "$INSTALL_DIR/ips1.cfg" 2>/dev/null || true
fi
echo "... done."

echo "Checking cron configuration..."
if crontab -u root -l 2>/dev/null | grep -q "$INSTALL_DIR/ips1_agent.sh"; then
	echo "Cron entry found for root."
elif id -u ips1 >/dev/null 2>&1 && crontab -u ips1 -l 2>/dev/null | grep -q "$INSTALL_DIR/ips1_agent.sh"; then
	echo "Cron entry found for ips1."
else
	echo "WARNING: No IPS1 cron entry found. The agent was updated, but scheduled execution may not be configured."
fi
echo "... done."

echo "IPS1 agent update completed: $CURRENT_VERSION -> $NEW_VERSION"
echo "Backup saved to: $BACKUP_DIR"
