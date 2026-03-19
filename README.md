# baseliner
Baseline networks

## ip_baseliner
```
Usage:
  ./ip_baseliner.sh -m <baseline|monitor> -t <targets> [options]

Modes:
  baseline   Generate or refresh the baseline from one or more scan passes
  monitor    Scan current targets and compare against an existing baseline

Required:
  -m  Mode: baseline or monitor
  -t  Targets (CIDR list, comma-separated)

Optional:
  -o  Output directory (default: .)
  -r  Rate in packets per second (default: 10000)
  -w  Wait time in seconds (default: 3)
  -R  Retries (default: 2)
  -p  Passes for baseline mode (default: 3)
  -i  Network interface (optional)
  -s  Shard in X/Y format (optional)
  -S  Seed (default: 42)
  -P  Ports to scan (default: 1-65535)
  -n  Enable notify on anomalies in monitor mode
  -c  Notify provider config file (default: provider.yaml)
  -h  Show this help

Files created in output directory:
  network_baseline.json
  network_baseline.txt
  network_scan_tmp.json
  network_scan_tmp.txt
  network_result.txt
  network_scan.log
  baseline_runs/

Examples:
  Generate baseline:
    ./ip_baseliner.sh -m baseline -t "192.168.0.0/24" -r 10000 -p 3

  Monitor with existing baseline:
    ./ip_baseliner.sh -m monitor -t "192.168.0.0/24" -r 10000

  Monitor with notify enabled:
    ./ip_baseliner.sh -m monitor -t "192.168.0.0/24" -r 10000 -n -c provider.yaml
```
