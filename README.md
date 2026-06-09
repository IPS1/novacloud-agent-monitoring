# NovaCloud Agent Monitoring

## Overview

A lightweight Linux monitoring agent that collects system metrics from servers and forwards them to IpServerOne Portal for VM visualization. The agent runs every minute via a systemd timer, sampling CPU, memory, disk, network, temperature, and service health. All metrics are sent to our IpServerOne Portal for visualization.

## Metrics Collected

| Category | Metrics |
|----------|---------|
| **CPU** | Usage, idle, I/O wait, steal, user/system time, clock speed, load averages (1/5/15 min) |
| **Memory** | Total, used, free, swap, buffers, cache (in bytes) |
| **Disk I/O** | Read/write throughput (bytes/sec), IOPS per device |
| **Disk Usage** | Used/free space and inodes per mount point |
| **Network** | RX/TX traffic per interface, IPv4/IPv6 addresses |
| **Drive Health** | S.M.A.R.T. (HDD/SSD) and NVMe diagnostics |
| **System** | Uptime, OS/kernel version, hostname, reboot pending |

## Debugging

Debug output is written to `/etc/ips1/debug.log` when `DEBUG=1` (default). The log is cleared automatically at midnight to prevent unbounded growth.

```bash
tail -f /etc/ips1/debug.log
```

## License

MIT License — Copyright 2026 IP ServerOne Solutions
