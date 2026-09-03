#!/usr/bin/env bash
# host-probe.sh -- host reading for reactive live-admission (ADR-0005, #163).
#
# Emits `key value` lines on stdout for the Go listener's CommandHostProbe, which
# turns them into per-resource free-headroom fractions and runs the admission
# arithmetic. Host inspection is bash's job (ADR-0003); Go holds only the numbers.
#
# Contract (all four required; a missing key or non-numeric value makes the Go
# side error and fall back to the conservative path):
#   loadavg1 <1-minute load average>
#   nproc <online CPU count>
#   mem_total_kb <MemTotal from /proc/meminfo>
#   mem_available_kb <MemAvailable from /proc/meminfo>
set -euo pipefail

read -r loadavg1 _rest </proc/loadavg
printf 'loadavg1 %s\n' "${loadavg1}"
printf 'nproc %s\n' "$(nproc)"

printf 'mem_total_kb %s\n' "$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
printf 'mem_available_kb %s\n' "$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)"
