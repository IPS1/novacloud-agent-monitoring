# NovaCloud Monitoring Agent

## Overview

A lightweight Linux monitoring agent that runs on your virtual machine and collects
system health metrics so you can view them on our IP ServerOne Solutions monitoring dashboard.

The agent is intentionally minimal: it samples standard operating-system counters
(CPU, memory, disk, network, temperature, and — if you installed),
then sends those numbers to the monitoring dashboard once a minute. It runs as an
unprivileged user, collects only numeric system metrics, and never reads the
contents of your files, databases, or application traffic.

## How It Works

- **Frequency:** metrics are sampled and sent **once per minute** via a systemd timer.
- **Runs as:** a dedicated, unprivileged `ips1` user by default (no root access to your data).
- **Footprint:** a single shell script; it starts, takes its readings, sends them, and exits.
- **Location:** installed under `/etc/ips1`.

## Metrics Collected

Every minute the agent reports the following measurements to the dashboard.

### CPU
| Metric | Description |
|--------|-------------|
| Usage | Overall CPU utilization (%) |
| User / System | Time spent in user vs. kernel space (%) |
| I/O wait | Time the CPU waited on disk/network I/O (%) |
| Steal | Time taken by the hypervisor for other tenants (%) |
| Idle | Idle time (%) |
| Clock speed | Average core clock (MHz) |

### Load
| Metric | Description |
|--------|-------------|
| Load average | System load over 1, 5, and 15 minutes |

### Memory
| Metric | Description |
|--------|-------------|
| Used | RAM in use (bytes) |
| Free | RAM available (bytes) |

### Disk
| Metric | Description |
|--------|-------------|
| Throughput | Read/write bytes per second, per device |
| IOPS | Read/write/total operations per second, per device |
| Capacity | Total, used, and available space per mount point (bytes) |

### Network
| Metric | Description |
|--------|-------------|
| Traffic | Received (RX) and transmitted (TX) bytes per second, per interface |

### System
| Metric | Description |
|--------|-------------|
| Uptime | Seconds since last boot |
| Reboot required | Whether a pending reboot is flagged |
| Alive | Heartbeat confirming the agent reported this minute |

### Service health (optional)
| Metric | Description |
|--------|-------------|
| Status | Up/down state of the services you chose to monitor |

## Verifying the Agent

Check that the timer is active and see the last run:

```bash
systemctl status ips1-agent.timer
systemctl status ips1-agent.service
```

## Data & Privacy

- Only **numeric system metrics** listed above are collected.
- The agent does **not** read file contents, application data, or network payloads.
- Credentials used to send metrics are stored encrypted and bound to the individual machine.
- Metrics are transmitted over an authenticated connection to the monitoring dashboard.

## Support

For assistance, contact IP ServerOne Solutions
