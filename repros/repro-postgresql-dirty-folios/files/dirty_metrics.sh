#!/usr/bin/env bash
#
# Sample the SUT's dirty/writeback state until ~/.folio_metrics_stop appears.
# Usage: $0 [interval_seconds]   (default 5)
#
# Output goes to ~/folio-metrics/dirty_metrics_iter_<iter>_<phase>.log, where
# "<iter>:<phase>" is read from ~/.folio_metrics_phase (written by
# scenario:start_phase in ../main.sh).
set -u

interval="${1:-5}"
outdir="${HOME}/folio-metrics"
phase_file="${HOME}/.folio_metrics_phase"
stop_file="${HOME}/.folio_metrics_stop"

mkdir -p "${outdir}"
rm -f "${stop_file}"

while [ ! -f "${stop_file}" ]; do
    label="$(cat "${phase_file}" 2>/dev/null)"
    case "${label}" in
        *:*) iter="${label%%:*}"; phase="${label#*:}" ;;
        *)   iter=0; phase=pre ;;
    esac
    out="${outdir}/dirty_metrics_iter_${iter}_${phase}.log"
    {
        echo "=== TS $(date -u '+%Y-%m-%dT%H:%M:%SZ') iter=${iter} phase=${phase} ==="
        echo "=== VMSTAT ==="
        grep -E "^nr_dirty|^nr_dirtied|^nr_writeback|^nr_written|^nr_dirty_threshold|^nr_dirty_background_threshold|^pgpgout" /proc/vmstat
        echo "=== MEMINFO ==="
        grep -E "^Dirty:|^Writeback:|^WritebackTmp:" /proc/meminfo
        echo "=== VM PARAMS ==="
        cat /proc/sys/vm/dirty_ratio /proc/sys/vm/dirty_background_ratio /proc/sys/vm/dirty_bytes /proc/sys/vm/dirty_background_bytes 2>/dev/null
        echo "=== WBT ==="
        for q in /sys/block/[snvmx]*/queue/wbt_lat_usec; do
            [ -e "$q" ] && echo "$q: $(cat "$q" 2>/dev/null)"
        done
        echo "=== BLOCK STATS ==="
        for d in /sys/block/[snvmx]*/stat; do echo "$d:"; cat "$d"; done
    } >> "${out}" 2>/dev/null
    sleep "${interval}"
done
