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

# Set PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# GitHub repository (public)
GITHUB_REPO="IPS1/novacloud-agent-monitoring"

# Branch
BRANCH="main"

fetch_file() {   # fetch_file <url> <dest>
	if command -v wget >/dev/null 2>&1; then
		wget -t 1 -T 30 -qO "$2" "$1"
	else
		curl -fsSL --max-time 30 -o "$2" "$1"
	fi
}

# Validate gateway parameters from environment
echo "Validating gateway parameters from environment..."
for var in IPS1_GATEWAY_URL; do
	if [ -z "${!var}" ]; then
		echo "ERROR: environment variable $var is not set."
		exit 1
	fi
done
echo "... done."

# Check if install script is run by root
echo "Checking root privileges..."
if [ "$EUID" -ne 0 ]
  then echo "ERROR: Please run the install script as root."
  exit
fi
echo "... done."

# Check if user has selected to run agent as 'root' or as 'ips1' user
if [ -z "$1" ]
	then echo "ERROR: First parameter (RunAsRoot) missing."
	exit
fi

# Check if system has crontab and a download tool
echo "Checking for crontab and a download tool (wget or curl)..."
command -v crontab >/dev/null 2>&1 || { echo "ERROR: crontab is required to run this agent." >&2; exit 1; }
{ command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; } \
	|| { echo "ERROR: wget or curl is required to run this agent." >&2; exit 1; }
echo "... done."

# Remove old agent (if exists)
echo "Checking if there's any old IPS1 agent already installed..."
if [ -d /etc/ips1 ]
then
	echo "Old IPS1 agent found, deleting it..."
	rm -rf /etc/ips1
else
	echo "No old IPS1 agent found..."
fi
echo "... done."

# Creating agent folder
echo "Creating the IPS1 agent folder..."
mkdir -p /etc/ips1
echo "... done."

# Fetching the agent
echo "Fetching the agent..."
fetch_file "https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/ips1_agent.sh" /etc/ips1/ips1_agent.sh
echo "... done."

# Fetching the config file
echo "Fetching the config file..."
fetch_file "https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/ips1.cfg" /etc/ips1/ips1.cfg
echo "... done."

echo "Fetching the updater..."
fetch_file "https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/ips1_update.sh" /etc/ips1/ips1_update.sh
echo "... done."

# Fetch the credential loader binary (pre-built, salt embedded at release time)
echo "Fetching creds..."
fetch_file "$IPS1_GATEWAY_URL/downloads/creds-linux-amd64" /usr/local/bin/creds
if [ ! -s /usr/local/bin/creds ]; then
	echo "ERROR: creds download failed or produced an empty file. Check that the gateway server is reachable." >&2
	exit 1
fi
chmod 711 /usr/local/bin/creds
echo "... done."

# Strip Windows line endings (CRLF → LF) if present
echo "Ensuring Unix (LF) line endings..."
sed -i 's/\r$//' /etc/ips1/ips1_agent.sh
sed -i 's/\r$//' /etc/ips1/ips1.cfg
sed -i 's/\r$//' /etc/ips1/ips1_update.sh
echo "... done."

# Record the gateway URL in the agent config for first-run self-enrollment.
echo "Recording gateway URL for agent self-enrollment..."
sed -i "s|^GATEWAY_URL=\"\"|GATEWAY_URL=\"$IPS1_GATEWAY_URL\"|" /etc/ips1/ips1.cfg
echo "... done."

# Check if any services are to be monitored
echo "Checking if any services should be monitored..."
if [ "$2" != "0" ]
then
	echo "Services found, inserting them into the agent config..."
	sed -i "s/CheckServices=\"\"/CheckServices=\"$2\"/" /etc/ips1/ips1.cfg
fi
echo "... done."

# NOTE: software RAID (CheckSoftRAID) and Drive Health (CheckDriveHealth) are not
# offered to customers. They stay OFF (0) in ips1.cfg and are intentionally not
# wired to any install argument.

# Check if 'View running processes' should be enabled
echo "Checking if 'View running processes' should be enabled..."
if [ "$3" -eq "1" ]
then
	echo "Enabling 'View running processes' in the agent config..."
	sed -i "s/RunningProcesses=0/RunningProcesses=1/" /etc/ips1/ips1.cfg
fi
echo "... done."

# Check if any ports to monitor number of connections on
echo "Checking if any ports to monitor number of connections on..."
if [ "$4" != "0" ]
then
	echo "Ports found, inserting them into the agent config..."
	sed -i "s/ConnectionPorts=\"\"/ConnectionPorts=\"$4\"/" /etc/ips1/ips1.cfg
fi
echo "... done."

# Killing any running IPS1 agents
echo "Making sure no IPS1 agent scripts are currently running..."
ps aux | grep -ie ips1_agent.sh | awk '{print $2}' | xargs -r kill -9
echo "... done."

# Checking if ips1 user exists
echo "Checking if ips1 user already exists..."
if id -u ips1 >/dev/null 2>&1
then
	echo "The ips1 user already exists, killing its processes..."
	pkill -9 -u `id -u ips1`
	echo "Deleting ips1 user..."
	userdel ips1
	echo "Creating the new ips1 user..."
	useradd ips1 -r -d /etc/ips1 -s /bin/false
	echo "Assigning permissions for the ips1 user..."
	chown -R ips1:ips1 /etc/ips1
	chmod -R 700 /etc/ips1
else
	echo "The ips1 user doesn't exist, creating it now..."
	useradd ips1 -r -d /etc/ips1 -s /bin/false
	echo "Assigning permissions for the ips1 user..."
	chown -R ips1:ips1 /etc/ips1
	chmod -R 700 /etc/ips1
fi
echo "... done."

# Removing any old ips1 cronjob (if exists from prior installs)
echo "Removing any old ips1 cronjob, if exists..."
crontab -u root -l 2>/dev/null | grep -v 'ips1_agent.sh' | crontab -u root - >/dev/null 2>&1
crontab -u ips1  -l 2>/dev/null | grep -v 'ips1_agent.sh' | crontab -u ips1  - >/dev/null 2>&1
echo "... done."

# Install systemd service + timer
echo "Installing systemd service and timer..."
SYSTEMD_SERVICE_USER="ips1"
if [ "$1" -eq "1" ]; then
	SYSTEMD_SERVICE_USER="root"
fi

cat > /etc/systemd/system/ips1-agent.service <<EOF
[Unit]
Description=IPS1 Monitoring Agent (single run)
After=network.target

[Service]
Type=oneshot
User=${SYSTEMD_SERVICE_USER}
ExecStart=/bin/bash /etc/ips1/ips1_agent.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ips1-agent.timer <<EOF
[Unit]
Description=IPS1 Monitoring Agent - run every minute
Requires=ips1-agent.service

[Timer]
OnCalendar=minutely
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ips1-agent.timer
systemctl enable --now ips1-agent.service
systemctl start ips1-agent.service
echo "... done."

# Cleaning up install file
echo "Cleaning up the installation file..."
# Only remove when $0 is an actual file on disk (not a pipe/process-substitution run)
if [ -f "$0" ]; then
	rm -f "$0"
fi
echo "... done."

# All done
echo "IPS1 agent installation completed."