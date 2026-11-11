# Bash
Simple Bash Script for System Administration and More

## Disk Monitor Dashboard

A live terminal dashboard for Linux that displays:
- Physical disks and mounted filesystem capacity.
- Capacity bars: **red = used**, **green = free**, **grey = remaining/unallocated display width**.
- Read/write throughput sampled from `/proc/diskstats`.
- Top processes by per-process read/write byte deltas, sorted ascending or descending.

### Requirements
- Bash 4+
- Linux with `/proc` and `lsblk`
- `util-linux` (`lsblk`), `coreutils` (`df`), `awk`, `sort`

### Run
```bash
chmod +x disk-monitor.sh
sudo ./disk-monitor.sh
```

Options:
```bash
./disk-monitor.sh --asc
./disk-monitor.sh --desc --interval=3 --top=15
```

Press `Ctrl+C` to exit.

### Notes
- The capacity section reports mounted filesystems found below each physical disk. A disk may show no capacity breakdown if it has no mounted filesystem.
- Device throughput is sampled from Linux `/proc/diskstats`; sectors are converted using the kernel's 512-byte sector accounting.
- Process I/O is read from `/proc/<pid>/io`. It is process-level accounting and does not necessarily equal physical-device I/O (for example, due to caching, buffering, or filesystem writeback).
- Run as root for the most complete process visibility. The dashboard is read-only; it does not modify disks or filesystems.
