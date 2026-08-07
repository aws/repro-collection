# Workload: memcached + Lancet, ported from an internal AWS benchmarking harness.
# source this file, don't run it
#
# Open-loop by design: throughput agents saturate the server while a SEPARATE,
# lightly loaded latency agent measures tail latency. That separation is what
# resolves the newidle-balance regression a closed-loop client averages away.
# Score is the max QPS sustained under a p99 SLO, by binary search over offered
# rates.
#
# Hosts (5): SUT (memcached), SUP (coordinator: builds Lancet, deploys the agents
# over SSH, runs the search), and 3 LDG -- 2 throughput agents then 1 latency
# agent, in that order. The coordinator needs SSH to every agent; that is
# Lancet's own agent-manager requirement, not the framework's.

# ---- memcached (SUT): reuse the `memcached` workload's build + tuning ----
: ${MEMCACHED_VERSION:=1.6.31}
: ${MEMCACHED_SRC_URL:=https://www.memcached.org/files/memcached-${MEMCACHED_VERSION}.tar.gz}
# The tarball is compiled and run as a service, so verify it. Empty to skip.
: ${MEMCACHED_SRC_SHA256:=20d8d339b8fb1f6c79cee20559dc6ffb5dfee84db9e589f4eb214f6d2c873ef5}   # memcached 1.6.31
: ${MEMCACHED_PREFIX:=$HOME/memcached}
: ${MEMCACHED_BIN:=${MEMCACHED_PREFIX}/memcached}
: ${MEMCACHED_USER:=$USER}
: ${MEMCACHED_PORT:=11211}
: ${MEMCACHED_MEMORY_LIMIT:=2048}
: ${MEMCACHED_CONN_LIMIT:=2048}
: ${MEMCACHED_THREADS:=}
: ${MEMCACHED_EXTENDED:=hashpower=20,no_lru_crawler,no_lru_maintainer}
: ${MEMCACHED_MAX_REQS_PER_EVENT:=320}
# What the committed results were measured at. memcached runs with
# --disable-evictions, so a dataset over the memory limit makes it refuse writes.
: ${MEMCACHED_RECORDS:=2000000}
: ${MEMCACHED_KEY_SIZE:=16}
: ${MEMCACHED_VALUE_SIZE:=128}
: ${MEMCACHED_KEY_PREFIX:=lancet-}
: ${MEMCACHED_SET_TO_GET_RATIO:=0.2}

# /proc/schedstat snapshots: the newidle cross-LLC counters, compared per kernel.
: ${MEMCACHED_SCHEDSTAT_DIR:=$HOME}   # where the schedstat snapshots are written

# ---- Lancet build (SUP) ----
: ${LANCET_REPO:=https://github.com/geoffreyblake/lancet-tool.git}
: ${LANCET_VERSION:=719dfd95413316ce6635078f91ec9f156cb70cba}
: ${LANCET_DIR:=$HOME/lancet-tool}
: ${GO_VERSION:=1.21.13}
# Immutable commit, not the v0.8.0 tag: this library is compiled into the
# coordinator, which is the component that loads LANCET_SSH_KEY.
: ${XCRYPTO_COMMIT:=00fd4ff485c675984a5b4b7b4837e72dadbf5103}   # tag v0.8.0
: ${LANCET_SSH_KEY:=$HOME/.ssh/id_rsa}   # key the coordinator uses to reach the agents

# ---- Lancet run params (mirror the original memcached workload's defaults) ----
: ${LANCET_PROTOCOL:=memcache-bin}
: ${LANCET_NUM_RUNS:=2}
: ${LANCET_RUN_LENGTH:=60}
: ${LANCET_SLO_VALUE:=1000}              # us; p99 SLO ceiling
: ${LANCET_SLO_PARAMETER:=latency_p99}
: ${LANCET_GRANULARITY:=1000}
: ${LANCET_QPS_TOLERANCE:=10}
: ${LANCET_LOAD_THREADS:=-1}             # -1 = agent nproc
: ${LANCET_LOAD_CONNS:=288}
: ${LANCET_LAT_THREADS:=-1}
: ${LANCET_LAT_CONNS:=72}
: ${LANCET_REQ_PER_CONN:=4}

function memcached-lancet:help() {
    echo "Runs memcached + Lancet (open-loop, separate latency agent). Hosts: 1 SUT, 1 SUP (coordinator), 3 LDG (2 throughput + 1 latency)."
    echo "The SUP builds Lancet and must be able to SSH to every LDG (set LANCET_SSH_KEY)."
    echo "SUT builds memcached ${MEMCACHED_VERSION}, tunes + preloads ${MEMCACHED_RECORDS} records."
    echo "Search: max QPS with ${LANCET_SLO_PARAMETER} <= ${LANCET_SLO_VALUE}us. Results on the SUP."
    echo "This is the high-fidelity counterpart of the 'memcached' workload; use it when the"
    echo "measurement must match the original Lancet setup (e.g. reproducing the newidle-balance regression)."
}

# memcached server (SUT)

# The framework's control channel uses nc, absent by default on some distros
# (e.g. AL2023). A silent failure here surfaces later as a handshake hang.
function memcached-lancet:_ensure_netcat() {
    command -v nc >/dev/null && return 0
    repro:info "nc not found; installing netcat for the framework control channel"
    repro:package:install nmap-ncat || true      # RHEL/AL/Fedora
    repro:package:install netcat-openbsd || true # Debian/Ubuntu
    command -v nc >/dev/null || repro:warn "nc still not available; SUT/LDG handshake will fail"
}

function memcached-lancet:install:sut() {
    repro:info "SUT install: memcached ${MEMCACHED_VERSION}"
    repro:package:update
# python3 is a hard dependency: the preloader and the score parser are python.
    repro:package:install python3 || true
    repro:package:install gcc make || true
    repro:package:install build-essential libevent-dev || true
    repro:package:install libevent-devel || true
    memcached-lancet:_ensure_netcat
    repro:cmd <<-EOT
        set -e
        cd "$HOME"
        [ -f memcached-${MEMCACHED_VERSION}.tar.gz ] || curl -fsSLO ${MEMCACHED_SRC_URL}
        if [ -n "${MEMCACHED_SRC_SHA256}" ]; then
            echo "${MEMCACHED_SRC_SHA256}  memcached-${MEMCACHED_VERSION}.tar.gz" | sha256sum -c - \
                || { echo "memcached tarball does not match the expected SHA256 -- refusing to build it" >&2; exit 1; }
        else
            echo "MEMCACHED_SRC_SHA256 is empty; skipping integrity check of the memcached tarball" >&2
        fi
        rm -rf memcached-${MEMCACHED_VERSION} ${MEMCACHED_PREFIX}
        tar xzf memcached-${MEMCACHED_VERSION}.tar.gz
        mv memcached-${MEMCACHED_VERSION} ${MEMCACHED_PREFIX}
EOT
    local cflags="-O2"
    case "$(uname -m)" in
        aarch64|arm64) cflags="-O2 -march=armv8.2-a -falign-jumps=32 -falign-loops=32 -falign-functions=32" ;;
    esac
    repro:cmd <<-EOT
        set -e
        cd ${MEMCACHED_PREFIX}
        CFLAGS="${cflags}" ./configure
        make memcached
EOT
}

function memcached-lancet:configure:sut() {
    repro:info "SUT configure: memcached service + preload"
    [ -z "$MEMCACHED_THREADS" ] && MEMCACHED_THREADS=$(nproc)
    repro:template <${REPRO_ROOT}/files/memcached.service.tmpl \
        MEMCACHED_BIN MEMCACHED_USER MEMCACHED_PORT MEMCACHED_MEMORY_LIMIT \
        MEMCACHED_CONN_LIMIT MEMCACHED_THREADS MEMCACHED_EXTENDED MEMCACHED_MAX_REQS_PER_EVENT \
        | sudo bash -c 'cat >/lib/systemd/system/memcached.service'
    repro:cmd <<-EOT
        set -e
        sudo systemctl daemon-reload
        sudo systemctl enable memcached
        sudo systemctl restart memcached
EOT
    REPROCFG_SUT=127.0.0.1 REPROCFG_PORT=${MEMCACHED_PORT} repro:wait_for_sut "" 60
    repro:info "Preloading ${MEMCACHED_RECORDS} records"
    repro:cmd "${REPRO_ROOT}/files/load_memcached.py 127.0.0.1 ${MEMCACHED_PORT} ${MEMCACHED_RECORDS} ${MEMCACHED_KEY_PREFIX} ${MEMCACHED_VALUE_SIZE}"
}

function memcached-lancet:run:sut() {
    # /proc/schedstat around the measurement window: the newidle counters are the
    # mechanism evidence, and they only accumulate while the sysctl is on.
    local ss="${MEMCACHED_SCHEDSTAT_DIR}/schedstat-${WORKLOAD_RUN_LABEL:-standalone}"
    repro:cmd "sudo sh -c 'echo 1 >/proc/sys/kernel/sched_schedstats'"
    repro:cmd "cat /proc/schedstat >${ss}-before"
    repro:cmd "printf 'kernel=%s\narch=%s\nvcpus=%s\nrecords=%s\n' \
        \"\$(uname -r)\" \"\$(uname -m)\" \"\$(nproc)\" \"${MEMCACHED_RECORDS}\" >${ss%/*}/sut-provenance-${WORKLOAD_RUN_LABEL:-standalone}.txt"

    repro:info "SUT ready; waiting for the coordinator to finish"
    repro:wait_for_ldg "DONE"

    repro:cmd "cat /proc/schedstat >${ss}-after"
    repro:cmd "sudo sh -c 'echo 0 >/proc/sys/kernel/sched_schedstats'"
}

function memcached-lancet:cleanup:sut() {
    # Disable as well as stop: this scenario reboots the SUT for the kernel A/B,
    # so leaving the unit enabled would bring memcached back up on every boot.
    repro:cmd "sudo systemctl stop memcached 2>/dev/null || true; sudo systemctl disable memcached 2>/dev/null || true; sync"
}

# Throughput / latency agents (LDG). Lancet deploys and controls them over SSH from
# the coordinator, so this side only needs the build deps present.

function memcached-lancet:install:loadgen() {
    repro:info "LDG install: Lancet agent runtime deps"
    repro:package:update
    memcached-lancet:_ensure_netcat
    repro:package:install gcc make cmake virtualenv || true          # common
    repro:package:install libpython3-dev python3-virtualenv || true  # Debian/Ubuntu
    repro:package:install python3-devel || true                      # RHEL/AL/Fedora
}

function memcached-lancet:run:loadgen() {
    repro:info "LDG (Lancet agent) ready; controlled by the coordinator over SSH"
    repro:wait_for_ldg "DONE"   # wait until the coordinator signals completion
}

# Coordinator (SUP)

function memcached-lancet:install:support() {
    repro:info "SUP install: build Lancet coordinator + agents + manager"
    repro:package:update
    memcached-lancet:_ensure_netcat
    # Per component, in separate best-effort calls so an unknown package name on
    # one distro does not fail the whole transaction.
    repro:package:install make unzip git cmake gcc || true                       # common
    repro:package:install build-essential g++ libssl-dev virtualenv libpython3-dev python3-pip python3-wheel || true  # Debian/Ubuntu
    repro:package:install gcc-c++ openssl-devel python3-devel python3-virtualenv python3-pip python3-wheel || true     # RHEL/AL/Fedora

    local goarch=amd64
    [ "$(uname -m)" = aarch64 ] && goarch=arm64
    # The Go tarball is extracted as root into /usr/local, so verify it. Digests
    # are per-architecture; bumping GO_VERSION requires updating both.
    local go_sha=""
    case "${GO_VERSION}:${goarch}" in
        1.21.13:amd64) go_sha=502fc16d5910562461e6a6631fb6377de2322aad7304bf2bcd23500ba9dab4a7 ;;
        1.21.13:arm64) go_sha=2ca2d70dc9c84feef959eb31f2a5aac33eefd8c97fe48f1548886d737bffabd4 ;;
    esac
    [ -z "$go_sha" ] && repro:warn "No pinned SHA256 for go${GO_VERSION}.linux-${goarch}; the toolchain download will not be integrity-checked"
    repro:cmd <<-EOT
        set -e
        cd "$HOME"
        [ -x /usr/local/go/bin/go ] || {
            curl -fsSLO https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz
            # Verify before extracting as root into /usr/local.
            if [ -n "${go_sha}" ]; then
                echo "${go_sha}  go${GO_VERSION}.linux-${goarch}.tar.gz" | sha256sum -c - \
                    || { echo "Go tarball does not match the expected SHA256 -- refusing to install it" >&2; exit 1; }
            else
                echo "No pinned SHA256 for go${GO_VERSION}.linux-${goarch}; skipping integrity check" >&2
            fi
            sudo rm -rf /usr/local/go
            sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-${goarch}.tar.gz
        }
    # cgo must be ON: the coordinator imports "C".
        export PATH=\$PATH:/usr/local/go/bin GOPATH=\$HOME/go GO111MODULE=off CGO_ENABLED=1
        # golang.org/x/crypto is vendored under GOPATH (Lancet builds with modules off)
        mkdir -p \$HOME/go/src/golang.org/x
        [ -d \$HOME/go/src/golang.org/x/crypto ] || { git clone https://go.googlesource.com/crypto \$HOME/go/src/golang.org/x/crypto && ( cd \$HOME/go/src/golang.org/x/crypto && git checkout --detach ${XCRYPTO_COMMIT} ); }
        [ -d ${LANCET_DIR} ] || git clone ${LANCET_REPO} ${LANCET_DIR}
        cd ${LANCET_DIR} && git checkout ${LANCET_VERSION}
        make coordinator agents manager
EOT
    # Copy the runner scripts next to where the coordinator runs.
    repro:cmd "cp ${REPRO_ROOT}/files/lancet_runner.py ${REPRO_ROOT}/files/lancet_regexp.py ${REPRO_ROOT}/files/binarysearch.py ${LANCET_DIR}/"
}

function memcached-lancet:configure:support() {
    repro:info "SUP configure: deploy Lancet agents to the LDG hosts over SSH"
    # LDG addresses come from REPROCFG_LOADGEN (space-separated). First two are
    # throughput agents, the last is the latency agent -- the original's split.
    local -a ldgs=(${REPROCFG_LOADGEN})
    # With a single LDG the split below would leave the throughput list EMPTY and
    # hand Lancet `--load-agents ""`, so fail instead of driving no load at all.
    [ ${#ldgs[@]} -lt 2 ] && repro:fatal "Lancet needs at least 2 LDGs (>=1 throughput + 1 latency); got ${#ldgs[@]}. Pass one --loadgen=<host> per agent."
    [ ${#ldgs[@]} -lt 3 ] && repro:warn "Lancet expects >=3 LDGs (2 throughput + 1 latency); got ${#ldgs[@]}"
    SUPPORT_THR_AGENTS=$(IFS=,; echo "${ldgs[*]:0:${#ldgs[@]}-1}")   # all but last
    SUPPORT_LAT_AGENT="${ldgs[-1]}"                                  # last
    # The latency agent MUST be its own host: measuring tail latency from a box that is
    # also saturating the server destroys the lightly-loaded-probe property, while
    # still producing a plausible number. A repeated --loadgen passes the count check.
    local _h
    for _h in ${SUPPORT_THR_AGENTS//,/ }; do
        [ "$_h" = "$SUPPORT_LAT_AGENT" ] && repro:fatal "Host '${_h}' is listed as both a throughput agent and the latency agent. The latency agent must be a dedicated host; pass distinct --loadgen= values (the LAST one is the latency agent)."
    done
    # Duplicated throughput agents are not a validity error, but they mean fewer
    # distinct load sources than the operator probably intended.
    [ "$(echo "${SUPPORT_THR_AGENTS//,/ }" | tr ' ' '\n' | sort -u | wc -l)" -ne "$(echo "${SUPPORT_THR_AGENTS//,/ }" | wc -w)" ] && \
        repro:warn "Throughput agent list contains duplicates (${SUPPORT_THR_AGENTS}); load will come from fewer distinct hosts than requested"
    repro:info "throughput agents: ${SUPPORT_THR_AGENTS}; latency agent: ${SUPPORT_LAT_AGENT}"
    # Persist so the run step (separate op subshell) can read them.
    { echo "thr=${SUPPORT_THR_AGENTS}"; echo "lat=${SUPPORT_LAT_AGENT}"; } >"${REPROCFG_TMP}/lancet_agents"

    # NOTE: ssh-agent forks a daemon that inherits its parent's stdout. Under
    # repro:cmd (which pipes the command's stdout into repro:log), a bare
    # `eval "$(ssh-agent)"` leaves that daemon holding the pipe's write end open,
    # so repro:log's reader never sees EOF and the step hangs forever. Redirect
    # the agent's fds to /dev/null so it does not keep the log pipe open, and
    # kill it when done.
    repro:cmd <<-EOT
        set -e
        export PATH=\$PATH:/usr/local/go/bin
        cd ${LANCET_DIR}
        eval "\$(ssh-agent -s)" >/dev/null 2>&1
        trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT
        ssh-add ${LANCET_SSH_KEY} >/dev/null 2>&1
        make deploy HOSTS=${SUPPORT_THR_AGENTS},${SUPPORT_LAT_AGENT} </dev/null
EOT
}

function memcached-lancet:run:support() {
    repro:info "SUP run: Lancet binary search against ${REPROCFG_SUT}:${MEMCACHED_PORT}"
    # The SLO gates pass/fail and is interpolated bare into the results JSON, so a
    # unit suffix would break the comparison and produce invalid JSON.
    case "$LANCET_SLO_VALUE" in
        ''|*[!0-9]*) repro:fatal "LANCET_SLO_VALUE must be a positive integer number of microseconds with no unit suffix, got '${LANCET_SLO_VALUE}'" ;;
    esac
    [ "$LANCET_SLO_VALUE" -gt 0 ] || repro:fatal "LANCET_SLO_VALUE must be greater than 0, got '${LANCET_SLO_VALUE}'"

    # Validate the agent list before the port wait: it is an instant local check.
    local thr lat
    thr=$(sed -n 's/^thr=//p' "${REPROCFG_TMP}/lancet_agents" 2>/dev/null)
    lat=$(sed -n 's/^lat=//p' "${REPROCFG_TMP}/lancet_agents" 2>/dev/null)
    # Interpolated unquoted into the runner's argv, so an empty value disappears
    # rather than becoming an empty argument and argparse binds the NEXT flag.
    [ -n "$thr" ] && [ -n "$lat" ] || \
        repro:fatal "Lancet agent list missing or empty (${REPROCFG_TMP}/lancet_agents); configure:support must run before run:support"

    # Wait for memcached before driving load, so a fast build/deploy never runs
    # Lancet against an unpreloaded server. Also correct when run standalone.
    REPROCFG_PORT=${MEMCACHED_PORT} repro:wait_for_sut "" 300
    local proto="${LANCET_PROTOCOL}_fixed:${MEMCACHED_KEY_SIZE}_fixed:${MEMCACHED_VALUE_SIZE}_${MEMCACHED_RECORDS}_$(awk "BEGIN{print 1-${MEMCACHED_SET_TO_GET_RATIO}}")_uni"

    $REPROCFG_DYRUN && { repro:info "[dry-run] would run lancet_runner.py"; echo 0 >"${REPROCFG_TMP}/lancet_score"; return 0; }

    # The heredoc form of repro:cmd cannot report failure (status is always 0), so
    # a stale lancet_out.json would be scored as this variant's result.
    rm -f "${REPROCFG_TMP}/lancet_out.json" "${REPROCFG_TMP}/lancet_score"

    repro:cmd --force <<-EOT
        export PATH=\$PATH:/usr/local/go/bin
        cd ${LANCET_DIR}
        ./lancet_runner.py --debug \
          --num-runs ${LANCET_NUM_RUNS} \
          --run-length ${LANCET_RUN_LENGTH} \
          --bs-slo-value ${LANCET_SLO_VALUE} \
          --bs-slo-parameter ${LANCET_SLO_PARAMETER} \
          --bs-granularity ${LANCET_GRANULARITY} \
          --qps-tolerance ${LANCET_QPS_TOLERANCE} \
          --load-agents ${thr} \
          --lt-agents ${lat} \
          --private-key ${LANCET_SSH_KEY} \
          ${LANCET_DIR}/coordinator/coordinator \
          -targetHost ${REPROCFG_SUT}:${MEMCACHED_PORT} \
          -appProto ${proto} \
          -loadThreads ${LANCET_LOAD_THREADS} \
          -loadConns ${LANCET_LOAD_CONNS} \
          -ltThreads ${LANCET_LAT_THREADS} \
          -ltConns ${LANCET_LAT_CONNS} \
          -reqPerConn ${LANCET_REQ_PER_CONN} \
          >"${REPROCFG_TMP}/lancet_out.json" 2>"${REPROCFG_TMP}/lancet_run.log"
EOT
    # The run must have produced output. Because the heredoc above cannot report
    # failure, this is the only place a dead run is detectable.
    [ -s "${REPROCFG_TMP}/lancet_out.json" ] || {
        repro:error "Lancet produced no output (${REPROCFG_TMP}/lancet_out.json missing or empty); see ${REPROCFG_TMP}/lancet_run.log"
        return 1
    }
    # lancet_runner prints a JSON list of the winning run's stdout. The scorer
    # exits non-zero rather than printing 0, so a failed parse is not scored.
    if ! "${REPRO_ROOT}/files/lancet_score.py" "${REPROCFG_TMP}/lancet_out.json" \
            "${LANCET_SLO_PARAMETER}" \
            >"${REPROCFG_TMP}/lancet_score" 2>"${REPROCFG_TMP}/lancet_score.err"; then
        cat "${REPROCFG_TMP}/lancet_score.err" >&2 2>/dev/null || true
        rm -f "${REPROCFG_TMP}/lancet_score"
        repro:error "Could not score the Lancet run; see ${REPROCFG_TMP}/lancet_run.log"
        return 1
    fi
    repro:info "max QPS under ${LANCET_SLO_PARAMETER} <= ${LANCET_SLO_VALUE}us: $(cat "${REPROCFG_TMP}/lancet_score")"
    # Lancet's confidence interval for the scored percentile: the only spread it
    # reports. A bare score hides whether the measurement was tight or marginal.
    if grep -q '^CI-NOTE' "${REPROCFG_TMP}/lancet_score.err" 2>/dev/null; then
        repro:info "$(sed -n 's/^CI-NOTE //p' "${REPROCFG_TMP}/lancet_score.err")"
        sed -n 's/^CI-NOTE //p' "${REPROCFG_TMP}/lancet_score.err" >"${REPROCFG_TMP}/lancet_ci"
    fi
    # Short timeout: repro:wait_for_sut BLOCKS with an 86400s default and `|| true`
    # cannot rescue a call that never returns. Agents exit after their first DONE.
    for h in ${REPROCFG_SUT} ${REPROCFG_LOADGEN}; do
        REPROCFG_SUT="$h" repro:wait_for_sut "DONE" 30 2>/dev/null || \
            repro:debug "No listener on ${h}:${REPROCFG_PORT} for the DONE signal (already finished?)"
    done
}

function memcached-lancet:results:support() {
    repro:info "Parsing Lancet results"
    [ "$WORKLOAD_RESULTS_FORMAT" != json ] && repro:error "Unsupported results format" && return 1
    # A missing or zero score means the run or the parse failed; writing it would
    # look like a real measurement (0 against a healthy variant reads as -100%).
    local _slo_us
    _slo_us=$(sed -n 's/^[a-z_0-9]*=\([0-9.][0-9.]*\)us.*/\1/p' "${REPROCFG_TMP}/lancet_ci" 2>/dev/null | head -1)
    local score; score=$(cat "${REPROCFG_TMP}/lancet_score" 2>/dev/null)
    if [ -z "$score" ] || [ "$score" = 0 ]; then
        $REPROCFG_DYRUN || { repro:error "No valid Lancet score to report (got '${score:-<none>}'); not writing ${WORKLOAD_RESULTS_FILE}"; return 1; }
        score=0
    fi
    {
        echo "{"
        echo "    \"score\": [${score}],"
        echo "    \"score_units\": \"max QPS under ${LANCET_SLO_PARAMETER} <= ${LANCET_SLO_VALUE}us\","
        echo "    \"qps\": [${score}],"
        echo "    \"slo_parameter\": \"${LANCET_SLO_PARAMETER}\","
        echo "    \"slo_value_us\": ${LANCET_SLO_VALUE},"
        echo "    \"records\": ${MEMCACHED_RECORDS},"
        echo "    \"value_size\": ${MEMCACHED_VALUE_SIZE},"
        echo "    \"set_to_get_ratio\": ${MEMCACHED_SET_TO_GET_RATIO},"
        echo "    \"protocol\": \"${LANCET_PROTOCOL}\","
        echo "    \"load_generator\": \"lancet\","
        # Provenance, so two results files can be checked for describing the same
        # experiment before being compared as an A/B.
        echo "    \"run_label\": \"${WORKLOAD_RUN_LABEL:-standalone}\","
        echo "    \"slo_percentile_ci\": \"$(cat "${REPROCFG_TMP}/lancet_ci" 2>/dev/null || echo 'not reported')\","
    # The p99 at the winning point with its interval: the regression is a tail-latency
    # effect and the QPS score is downstream of it. sed exits 0 on no-match, so
    # capture into a variable rather than relying on a fallback after ||.
        echo "    \"slo_percentile_us\": ${_slo_us:-null}"
        echo "}"
    } >"${WORKLOAD_RESULTS_FILE}"
    repro:info "Results written to $(realpath "${WORKLOAD_RESULTS_FILE}")"
    repro:info "Test score: ${score}"
}

function memcached-lancet:cleanup:support() {
    repro:cmd "rm -f ${REPROCFG_TMP}/lancet_out.json ${REPROCFG_TMP}/lancet_score ${REPROCFG_TMP}/lancet_score.err ${REPROCFG_TMP}/lancet_ci ${REPROCFG_TMP}/lancet_agents ${REPROCFG_TMP}/lancet_run.log"
    return 0
}
