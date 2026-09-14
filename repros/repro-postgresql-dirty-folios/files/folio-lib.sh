# Pure helpers for folio-reproduce.sh — source this, don't run it.

# args: <results-json>  -> the excluding-connections tps ("score"), or ""
tps_from() {
    sed -n 's/.*"score"[[:space:]]*:[[:space:]]*\([0-9.][0-9.]*\).*/\1/p' "$1" 2>/dev/null | head -n1
}

# args: <KEY> <value...>  -> one sourceable KEY='value' line
manifest_kv() {
    local key="$1"; shift
    local val="$*"
    val="${val//$'\n'/ }"
    val="${val//\'/\'\\\'\'}"
    printf "%s='%s'\n" "${key}" "${val}"
}

# args: <running> <built> <previous> <skip_kernel>  -> 0 if the SUT is running
# exactly the kernel just built; the reason goes to stderr otherwise.
kernel_ok() {
    local running="$1" built="$2" previous="$3" skip_kernel="${4:-false}"
    if [ -z "${running}" ] || [ -z "${built}" ]; then
        echo "ERROR: missing kernel release (running='${running}', built='${built}')" >&2
        return 1
    fi
    if [ "${running}" != "${built}" ]; then
        echo "ERROR: SUT is running '${running}', but the build produced '${built}'." >&2
        echo "       The new kernel did not become the default boot entry; aborting before the benchmark." >&2
        return 1
    fi
    if [ "${skip_kernel}" != "true" ] && [ "${running}" = "${previous}" ]; then
        echo "ERROR: SUT kernel is unchanged from before the build (${previous}); it did not reboot into the new kernel." >&2
        return 1
    fi
    return 0
}

# args: <path>  -> 0 if it is safe to interpolate into a remote `rm -rf`
repo_dir_ok() {
    case "$1" in
        ""|"~"|"~/"|"/"|*".."*) return 1 ;;
    esac
    [[ "$1" =~ ^[A-Za-z0-9._/~-]+$ ]]
}
