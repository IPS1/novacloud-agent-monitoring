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

# Gateway enrollment parameters (passed in via environment from the IPS1 dashboard install command).
# Customer servers do NOT hold InfluxDB credentials. They hold a refresh token scoped to one SID,
# and exchange it at the gateway for short-lived access JWTs used on every metric write.
echo "Validating gateway enrollment parameters from environment..."
for var in IPS1_GATEWAY_URL IPS1_ENROLL_CODE; do
	if [ -z "${!var}" ]; then
		echo "ERROR: environment variable $var is not set."
		echo "Obtain the full install command from the IPS1 customer dashboard."
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

# Check if system has crontab and wget
echo "Checking for crontab and wget..."
command -v crontab >/dev/null 2>&1 || { echo "ERROR: Crontab is required to run this agent." >&2; exit 1; }
command -v wget >/dev/null 2>&1 || { echo "ERROR: wget is required to run this agent." >&2; exit 1; }
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
wget -t 1 -T 30 -qO /etc/ips1/ips1_agent.sh https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/ips1_agent.sh
echo "... done."

# Fetching the config file
echo "Fetching the config file..."
wget -t 1 -T 30 -qO /etc/ips1/ips1.cfg https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/ips1.cfg
echo "... done."

echo "Fetching the updater..."
wget -t 1 -T 30 -qO /etc/ips1/ips1_update.sh https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/ips1_update.sh
echo "... done."

# Strip Windows line endings (CRLF → LF) if present
echo "Ensuring Unix (LF) line endings..."
sed -i 's/\r$//' /etc/ips1/ips1_agent.sh
sed -i 's/\r$//' /etc/ips1/ips1.cfg
sed -i 's/\r$//' /etc/ips1/ips1_update.sh
echo "... done."

# Inserting Server ID (SID) and gateway URL into the agent config
echo "Inserting Server ID (SID) and gateway URL into agent config..."
sed -i "s/SID=\"\"/SID=\"$SID\"/" /etc/ips1/ips1.cfg
GATEWAY_URL_ESCAPED=$(printf '%s\n' "$IPS1_GATEWAY_URL" | sed 's/[\/&|]/\\&/g')
sed -i "s|GatewayURL=\"\"|GatewayURL=\"$GATEWAY_URL_ESCAPED\"|" /etc/ips1/ips1.cfg
echo "... done."

# Redeem the one-time enrollment code at the gateway to get a refresh token + initial access JWT.
# The dashboard generates the code; it is single-use and short-lived (15 min).
echo "Enrolling server at $IPS1_GATEWAY_URL..."
ENROLL_PAYLOAD="{\"sid\":\"$SID\",\"code\":\"$IPS1_ENROLL_CODE\"}"
ENROLL_RESPONSE=$(curl -fsS --max-time 30 -XPOST "$IPS1_GATEWAY_URL/v1/enroll" \
	-H "Content-Type: application/json" \
	-d "$ENROLL_PAYLOAD") || {
	echo "ERROR: enrollment request to $IPS1_GATEWAY_URL/v1/enroll failed." >&2
	echo "Check that IPS1_GATEWAY_URL is reachable and IPS1_ENROLL_CODE is still valid." >&2
	exit 1
}

REFRESH_TOKEN=$(printf '%s' "$ENROLL_RESPONSE" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')
ACCESS_TOKEN=$(printf '%s'  "$ENROLL_RESPONSE" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
ACCESS_TTL=$(printf '%s'    "$ENROLL_RESPONSE" | sed -n 's/.*"access_expires_in":\([0-9]*\).*/\1/p')

if [ -z "$REFRESH_TOKEN" ] || [ -z "$ACCESS_TOKEN" ] || [ -z "$ACCESS_TTL" ]; then
	echo "ERROR: gateway enrollment response did not contain the expected fields." >&2
	echo "Response was: $ENROLL_RESPONSE" >&2
	exit 1
fi

# Subtract a 60s skew buffer so we refresh slightly before the JWT actually expires.
ACCESS_EXPIRES_AT=$(( $(date +%s) + ACCESS_TTL - 60 ))
echo "... done."

# Writing gateway credentials to a separate file (mode 600, kept out of the repo).
# Only the per-server refresh token is durable; the access JWT is rewritten on every refresh.
echo "Writing gateway credentials to /etc/ips1/credentials.cfg..."
umask 077
cat > /etc/ips1/credentials.cfg <<EOF
GATEWAY_URL="$IPS1_GATEWAY_URL"
REFRESH_TOKEN="$REFRESH_TOKEN"
ACCESS_TOKEN="$ACCESS_TOKEN"
ACCESS_EXPIRES_AT="$ACCESS_EXPIRES_AT"
EOF
chmod 600 /etc/ips1/credentials.cfg
umask 022
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
if [ -f $0 ]
then
    rm -f $0
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
