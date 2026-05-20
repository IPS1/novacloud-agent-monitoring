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
for var in IPS1_GATEWAY_URL IPS1_ENROLL_CODE; do
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

# Fetch Server Unique ID
SID=$1

# Make sure SID is not empty
echo "Checking Server ID (SID)..."
if [ -z "$SID" ]
	then echo "ERROR: First parameter missing."
	exit
fi
echo "... done."

# Check if user has selected to run agent as 'root' or as 'ips1' user
if [ -z "$2" ]
	then echo "ERROR: Second parameter missing."
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
echo "Fetching ips1-creds..."
fetch_file "https://github.com/$GITHUB_REPO/releases/latest/download/ips1-creds-linux-amd64" /usr/local/bin/ips1-creds
chmod 711 /usr/local/bin/ips1-creds
echo "... done."

# Strip Windows line endings (CRLF → LF) if present
echo "Ensuring Unix (LF) line endings..."
sed -i 's/\r$//' /etc/ips1/ips1_agent.sh
sed -i 's/\r$//' /etc/ips1/ips1.cfg
sed -i 's/\r$//' /etc/ips1/ips1_update.sh
echo "... done."

# Enroll this server at the gateway to obtain a server-scoped token.
# The gateway holds all InfluxDB credentials — they never reach the customer VM.
echo "Enrolling server at $IPS1_GATEWAY_URL..."
ENROLL_RESPONSE=$(curl -fsS --max-time 30 -XPOST "$IPS1_GATEWAY_URL/v1/enroll" \
	-H "Content-Type: application/json" \
	-d "{\"sid\":\"$SID\",\"code\":\"$IPS1_ENROLL_CODE\"}") || {
	echo "ERROR: enrollment request failed. Check IPS1_GATEWAY_URL and IPS1_ENROLL_CODE." >&2
	exit 1
}
SERVER_TOKEN=$(printf '%s' "$ENROLL_RESPONSE" | sed -n 's/.*"server_token":"\([^"]*\)".*/\1/p')
if [ -z "$SERVER_TOKEN" ]; then
	echo "ERROR: gateway did not return a server_token. Response: $ENROLL_RESPONSE" >&2
	exit 1
fi
echo "... done."

# Seal credentials into an AES-256-GCM encrypted store bound to this machine's
# hardware identity (/etc/machine-id). No plaintext credential file is written.
# The gateway also enforces the canonical SID server-side, so the encrypted SID
# cannot be tampered with to corrupt InfluxDB data.
echo "Sealing credentials..."
ips1-creds seal \
	--gateway "$IPS1_GATEWAY_URL" \
	--token   "$SERVER_TOKEN" \
	--sid     "$SID" || {
	echo "ERROR: credential sealing failed. Make sure ips1-creds is installed and /etc/machine-id exists." >&2
	exit 1
}
echo "... done."

# Check if any services are to be monitored
echo "Checking if any services should be monitored..."
if [ "$3" != "0" ]
then
	echo "Services found, inserting them into the agent config..."
	sed -i "s/CheckServices=\"\"/CheckServices=\"$3\"/" /etc/ips1/ips1.cfg
fi
echo "... done."

# Check if software RAID should be monitored
echo "Checking if software RAID should be monitored..."
if [ "$4" -eq "1" ]
then
	echo "Enabling software RAID monitoring in the agent config..."
	sed -i "s/CheckSoftRAID=0/CheckSoftRAID=1/" /etc/ips1/ips1.cfg
fi
echo "... done."

# Check if Drive Health should be monitored
echo "Checking if Drive Health should be monitored..."
if [ "$5" -eq "1" ]
then
	echo "Enabling Drive Health monitoring in the agent config..."
	sed -i "s/CheckDriveHealth=0/CheckDriveHealth=1/" /etc/ips1/ips1.cfg
fi
echo "... done."

# Check if 'View running processes' should be enabled
echo "Checking if 'View running processes' should be enabled..."
if [ "$6" -eq "1" ]
then
	echo "Enabling 'View running processes' in the agent config..."
	sed -i "s/RunningProcesses=0/RunningProcesses=1/" /etc/ips1/ips1.cfg
fi
echo "... done."

# Check if any ports to monitor number of connections on
echo "Checking if any ports to monitor number of connections on..."
if [ "$7" != "0" ]
then
	echo "Ports found, inserting them into the agent config..."
	sed -i "s/ConnectionPorts=\"\"/ConnectionPorts=\"$7\"/" /etc/ips1/ips1.cfg
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

# Removing old cronjob (if exists)
echo "Removing any old ips1 cronjob, if exists..."
crontab -u root -l | grep -v 'ips1_agent.sh'  | crontab -u root - >/dev/null 2>&1
crontab -u ips1 -l | grep -v 'ips1_agent.sh'  | crontab -u ips1 - >/dev/null 2>&1
echo "... done."

# Setup the new cronjob to run the agent either as 'root' or as 'ips1' user, depending on client's installation choice.
# Default is running the agent as 'ips1' user, unless chosen otherwise by the client when fetching the installation code from the ips1 website.
if [ "$2" -eq "1" ]
then
	echo "Setting up the new cronjob as 'root' user..."
	crontab -u root -l 2>/dev/null | { cat; echo "* * * * * bash /etc/ips1/ips1_agent.sh >> /etc/ips1/ips1_cron.log 2>&1"; } | crontab -u root - >/dev/null 2>&1
else
	echo "Setting up the new cronjob as 'ips1' user..."
	crontab -u ips1 -l 2>/dev/null | { cat; echo "* * * * * bash /etc/ips1/ips1_agent.sh >> /etc/ips1/ips1_cron.log 2>&1"; } | crontab -u ips1 - >/dev/null 2>&1
fi
echo "... done."

# Cleaning up install file
echo "Cleaning up the installation file..."
# Only remove when $0 is an actual file on disk (not a pipe/process-substitution run)
if [ -f "$0" ]; then
	rm -f "$0"
fi
echo "... done."

# Let IPS1 platform know install has been completed
# TODO: re-enable once backend coverage exists for this endpoint
#echo "Letting IPS1 platform know the installation has been completed..."
#POST="v=install&s=$SID"
#wget -t 1 -T 30 -qO- --post-data "$POST" https://sm.ips1.net/ &> /dev/null
#echo "... done."

# Start the agent
if [ "$2" -eq "1" ]
then
	echo "Starting the agent under the 'root' user..."
	bash /etc/ips1/ips1_agent.sh > /dev/null 2>&1 &
else
	echo "Starting the agent under the 'ips1' user..."
	sudo -u ips1 bash /etc/ips1/ips1_agent.sh > /dev/null 2>&1 &
fi
echo "... done."

# All done
echo "IPS1 agent installation completed."