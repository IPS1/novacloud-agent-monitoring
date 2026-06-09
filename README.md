# NovaCloud Agent Monitoring

A lightweight Linux monitoring agent that collects system metrics from servers and forwards them to a centralized gateway for storage and visualization.

## Overview

The agent runs every minute via cron, sampling CPU, memory, disk, network, temperature, and service health. All metrics are sent in InfluxDB line protocol to the IPS1 gateway, where they are stored in InfluxDB and queryable per server via a unique Server ID (SID).

## Architecture

```
Customer Server                     IPS1 Infrastructure
┌────────────────────┐              ┌──────────────────────────────────┐
│  ips1_agent.sh     │   HTTP POST  │  Gateway  ──►  InfluxDB          │
│  (runs every 1min) │ ──────────── │  /v1/write     (metrics storage) │
│                    │              │                                   │
│  /etc/ips1/        │              │  PostgreSQL                       │
│    ips1.cfg        │              │  (server enrollment & tokens)     │
│    credentials.cfg │              └──────────────────────────────────┘
└────────────────────┘
```

Each server enrolls once with the gateway and receives a `SERVER_TOKEN`. All subsequent metric writes are authenticated via that token.

## Files

| File | Purpose |
|------|---------|
| `ips1_agent.sh` | Main monitoring engine — collects and ships metrics |
| `ips1_install.sh` | Installer — enrolls the server and sets up cron |
| `ips1_update.sh` | Updater — pulls latest scripts, preserves config |
| `ips1.cfg` | Agent configuration (tunable parameters) |
| `custom_metrics.sh` | Template for adding custom metrics |

## Metrics Collected

| Category | Metrics |
|----------|---------|
| **CPU** | Usage, idle, I/O wait, steal, user/system time, clock speed, load averages (1/5/15 min) |
| **Memory** | Total, used, free, swap, buffers, cache (in bytes) |
| **Disk I/O** | Read/write throughput (bytes/sec), IOPS per device |
| **Disk Usage** | Used/free space and inodes per mount point |
| **Network** | RX/TX traffic per interface, IPv4/IPv6 addresses |
| **Connections** | Per-port TCP connection counts |
| **Services** | Up/down status for configured services |
| **Temperature** | CPU/board sensors via sysfs, `sensors`, or IPMI |
| **Drive Health** | S.M.A.R.T. (HDD/SSD) and NVMe diagnostics |
| **RAID** | Software RAID (mdadm) array status |
| **Ping** | Latency and packet loss to configured remote targets |
| **System** | Uptime, OS/kernel version, hostname, reboot pending |
| **Processes** | Optional full process snapshot (base64-encoded) |

## Requirements

**System:**
- Linux (Debian, CentOS, CloudLinux, Alpine, and others)
- Bash 4+
- Standard tools: `curl`, `crontab`, `awk`, `sed`, `grep`, `vmstat`, `df`, `ip`, `ss`

**Optional (enables additional metrics):**
- `sensors` / `ipmitool` — temperature readings
- `smartctl` — S.M.A.R.T. drive health
- `nvme` — NVMe diagnostics
- `zpool` / `zfs` — ZFS pool status
- `mdadm` — software RAID status

**Network:**
- Outbound HTTPS to the IPS1 gateway URL
- Outbound HTTPS to `raw.githubusercontent.com` (for installs and updates)

## Installation

```bash
export IPS1_GATEWAY_URL="https://your-gateway-host"
export IPS1_ENROLL_CODE="your-enroll-code"

bash <(curl -fsSL https://raw.githubusercontent.com/IPS1/novacloud-agent-monitoring/main/ips1_install.sh)
```

The installer will:
1. Create the `/etc/ips1/` directory and a dedicated `ips1` system user
2. Enroll the server with the gateway (POST to `/v1/enroll`)
3. Store the returned `SERVER_TOKEN` in `/etc/ips1/credentials.cfg` (mode 600)
4. Install a cron job that runs the agent every minute
5. Start the first collection run immediately

> Requires root. The agent itself runs as the `ips1` user by default.

## Configuration

Edit `/etc/ips1/ips1.cfg` to tune the agent behavior:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CollectEveryXSeconds` | `3` | Sampling interval in seconds (2–10 recommended) |
| `NetworkInterfaces` | auto | Comma-separated list of NICs to monitor |
| `CheckServices` | _(empty)_ | Comma-separated service names to check (max 10) |
| `CheckSoftRAID` | `0` | Enable mdadm RAID monitoring (`1` to enable) |
| `CheckDriveHealth` | `0` | Enable S.M.A.R.T./NVMe checks (`1` to enable) |
| `RunningProcesses` | `0` | Capture process snapshot (`1` to enable) |
| `ConnectionPorts` | _(empty)_ | Comma-separated ports to track connection counts |
| `OutgoingPings` | _(empty)_ | Comma-separated hosts to ping for latency |
| `OutgoingPingsCount` | `20` | Ping packets per target (10–40) |
| `SecuredConnection` | `1` | Verify TLS certificates (`0` to disable) |
| `DEBUG` | `1` | Write debug output to `/etc/ips1/debug.log` |

Restart takes effect on the next cron run (no daemon restart needed).

## Updating

```bash
sudo bash /etc/ips1/ips1_update.sh
```

The update script:
- Downloads the latest scripts from GitHub
- Validates bash syntax before replacing any files
- Creates timestamped backups in `/etc/ips1/backups/`
- Merges new config keys into your existing `ips1.cfg` without overwriting your values
- Reports the version change (e.g., `0.1 -> 0.2`)

## Custom Metrics

Copy `custom_metrics.sh` to the path specified by the `CustomVars` config key, then add your own InfluxDB line protocol output. The file is sourced by the agent at each collection cycle.

```bash
cp custom_metrics.sh /etc/ips1/custom_variables.sh
# Edit /etc/ips1/custom_variables.sh
```

## Security

- No credentials are stored in this repository
- Each server receives a unique `SERVER_TOKEN` during enrollment — tokens are stored at `/etc/ips1/credentials.cfg` (owner `ips1`, mode 600)
- The agent runs as a non-root `ips1` user by default
- InfluxDB credentials are held exclusively by the gateway; the agent never sees them

## Debugging

Debug output is written to `/etc/ips1/debug.log` when `DEBUG=1` (default). The log is cleared automatically at midnight to prevent unbounded growth.

```bash
tail -f /etc/ips1/debug.log
```

## License

MIT License — Copyright 2026 IP ServerOne Solutions
