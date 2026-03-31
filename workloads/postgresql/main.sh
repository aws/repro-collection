# Workload: PostgreSQL 17 + pgbench
# source this file, don't run it

# --- RAID / Storage ---
: ${PG_DB_MOUNTPOINT:=/var/lib/pgsql}
: ${PG_DB_DATADIR:=${PG_DB_MOUNTPOINT}/data}
: ${PG_DB_FILESYSTEM:=xfs}

# --- PostgreSQL ---
: ${PG_VERSION:=17}
: ${PG_PORT:=5432}
: ${PG_USERNAME:=pgbench_user}
: ${PG_PASSWORD:=pgbench}
: ${PG_DBNAME:=pgbenchdb}
: ${PG_HUGE_PAGES:=off}                    # off, try, on
: ${PG_MAX_CONNECTIONS:=4096}
: ${PG_WAL_LEVEL:=replica}
: ${PG_MAX_WAL_SENDERS:=10}
: ${PG_CHECKPOINT_TIMEOUT:=5min}
: ${PG_CHECKPOINT_COMPLETION_TARGET:=0.9}
: ${PG_EFFECTIVE_IO_CONCURRENCY:=300}
: ${PG_MAX_WORKER_PROCESSES:=}             # auto: nproc
: ${PG_MAX_PARALLEL_WORKERS:=}             # auto: nproc
: ${PG_MAX_PARALLEL_WORKERS_PER_GATHER:=4}
: ${PG_RANDOM_PAGE_COST:=1.1}
: ${PG_SHARED_BUFFERS:=}                   # auto: ~25% RAM
: ${PG_EFFECTIVE_CACHE_SIZE:=}             # auto: ~50% RAM
: ${PG_WORK_MEM:=1024MB}
: ${PG_MAINTENANCE_WORK_MEM:=2GB}
: ${PG_INITDB_OPTIONS:=--data-checksums --wal-segsize=64}
: ${PG_FSYNC:=on}                          # on/off
: ${PG_FULL_PAGE_WRITES:=on}               # on/off
: ${PG_MAX_WAL_SIZE:=512GB}
: ${PG_MIN_WAL_SIZE:=1GB}
: ${PG_WAL_BUFFERS:=64MB}

# --- pgbench ---
: ${PGBENCH_SCALE:=100}                    # scale factor (-s); ~16MB per unit
: ${PGBENCH_CLIENTS:=64}                   # number of concurrent clients (-c)
: ${PGBENCH_THREADS:=}                     # auto: nproc on LDG
: ${PGBENCH_DURATION:=300}                 # run duration in seconds (-T)
: ${PGBENCH_BUILTIN:=tpcb-like}            # tpcb-like, simple-update, select-only
: ${PGBENCH_INIT_EXTRA_ARGS:=}             # extra args for pgbench -i
: ${PGBENCH_RUN_EXTRA_ARGS:=}              # extra args for pgbench run
: ${PGBENCH_PROTOCOL:=prepared}            # simple, extended, prepared
: ${PGBENCH_REPORT_PER_COMMAND:=true}      # --report-per-command / -r

# ============================================================
# SUT functions
# ============================================================

function postgresql:help() {
    echo "Runs a PostgreSQL ${PG_VERSION} + pgbench benchmark."
    echo "Hosts required: 1 SUT (database) and 1 LDG (pgbench client)."
    echo "Results are measured on the LDG and written to \${WORKLOAD_RESULTS_FILE}."
    echo "Recommended: 2+ fast NVMe disks on the SUT for RAID0 on ${PG_DB_MOUNTPOINT}."
    echo "If no RAID is found, available disks are auto-detected and assembled."
}

function postgresql:install:sut() {
    repro:info "SUT install: PostgreSQL ${PG_VERSION}"
    repro:package:update
    repro:package:install postgresql${PG_VERSION}-server postgresql${PG_VERSION} postgresql${PG_VERSION}-contrib mdadm xfsprogs
    postgresql:create_and_mount_raid
}

function postgresql:install:loadgen() {
    repro:info "LDG install: pgbench client"
    repro:package:update
    repro:package:install postgresql${PG_VERSION}
}

# ---- RAID0 helper (auto-detect unused disks) ----
function postgresql:create_and_mount_raid() {
    repro:debug "postgresql:create_and_mount_raid"
    local dev type pk fs mp raid mountpoint="${PG_DB_MOUNTPOINT}"
    local -a devs in_use
    repro:cmd sudo mkdir -p "$mountpoint"

    while read -r dev type pk fs mp; do
        [ "$mp" = "$mountpoint" ] && {
            repro:info "Already mounted: $dev ($type, $fs) on $mountpoint"
            return 0
        }
        [ "$type" = "raid0" ] && [ -z "$mp" ] && raid=$dev && break
        [ -n "$pk" ] && in_use+=("/dev/$pk")
        [ "$type" = "disk" ] || continue
        [ -z "$pk" ] && devs+=("$dev")
    done < <(lsblk -nro PATH,TYPE,PKNAME,FSTYPE,MOUNTPOINT --sort NAME)

    [ -z "$raid" ] && {
        for dev in "${in_use[@]}"; do
            devs=(${devs[@]/$dev})
        done
        [ ${#devs[@]} -eq 0 ] && {
            repro:warn "No available disks found for RAID0; using mountpoint as-is"
            return 0
        }
        raid=/dev/md0
        fs=${PG_DB_FILESYSTEM}
        repro:info "Found ${#devs[@]} unmounted disks: ${devs[@]}, creating RAID0 as $raid"
        repro:cmd sudo mdadm -CvR $raid -l raid0 --force -n ${#devs[@]} "${devs[@]}"
        repro:cmd sudo mkfs.${fs} $raid
    }

    repro:info "Mounting $raid (${PG_DB_FILESYSTEM}) on $mountpoint"
    repro:cmd sudo mount -t ${PG_DB_FILESYSTEM} -o noatime,nodiratime $raid "$mountpoint"

    # persist in fstab
    local uuid
    uuid=$(sudo blkid -s UUID -o value "$raid" 2>/dev/null)
    if [ -n "$uuid" ]; then
        grep -q "$uuid" /etc/fstab 2>/dev/null || {
            repro:info "Adding $raid (UUID=$uuid) to /etc/fstab"
            repro:cmd sudo bash -c "'echo \"UUID=$uuid $mountpoint ${PG_DB_FILESYSTEM} noatime,nodiratime 0 0\" >> /etc/fstab'"
        }
    fi
    repro:cmd sudo chown postgres:postgres "$mountpoint"
    repro:cmd sudo chmod 700 "$mountpoint"
    return 0
}

# ---- Auto-size helpers ----
function postgresql:_auto_size() {
    local ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    local cpus=$(nproc)
    [ -z "$PG_SHARED_BUFFERS" ]       && PG_SHARED_BUFFERS="$((ram_mb / 4))MB"
    [ -z "$PG_EFFECTIVE_CACHE_SIZE" ]  && PG_EFFECTIVE_CACHE_SIZE="$((ram_mb / 2))MB"
    [ -z "$PG_MAX_WORKER_PROCESSES" ]  && PG_MAX_WORKER_PROCESSES=$cpus
    [ -z "$PG_MAX_PARALLEL_WORKERS" ]  && PG_MAX_PARALLEL_WORKERS=$cpus
    repro:info "Auto-sized: shared_buffers=${PG_SHARED_BUFFERS}, effective_cache_size=${PG_EFFECTIVE_CACHE_SIZE}, workers=${PG_MAX_WORKER_PROCESSES}"
}

function postgresql:configure:sut() {
    repro:info "SUT configure: PostgreSQL ${PG_VERSION}"
    postgresql:_auto_size

    repro:cmd <<-EOT
        sudo systemctl stop postgresql 2>/dev/null || true
        sudo find ${PG_DB_DATADIR} -mindepth 1 -delete 2>/dev/null || true
        sudo mkdir -p ${PG_DB_DATADIR}
        sudo chown postgres:postgres ${PG_DB_DATADIR}
        sudo chmod 700 ${PG_DB_DATADIR}
EOT

    repro:cmd sudo bash -c "'PGSETUP_INITDB_OPTIONS=\"${PG_INITDB_OPTIONS}\" /usr/bin/postgresql-setup --initdb --unit postgresql'"

    # write postgresql.conf from template
    repro:template <${REPRO_ROOT}/files/postgresql.conf.tmpl | sudo bash -c "cat >${PG_DB_DATADIR}/postgresql.conf"
    repro:cmd sudo chown postgres:postgres ${PG_DB_DATADIR}/postgresql.conf

    # write pg_hba.conf to allow LDG connections
    {
        echo "local   all   all                 trust"
        for ldg_host in ${REPROCFG_LOADGEN}; do
            if [[ "$ldg_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "host    all   all   ${ldg_host}/32     md5"
            else
                echo "host    all   all   ${ldg_host}     md5"
            fi
        done
    } | sudo -u postgres bash -c "cat >${PG_DB_DATADIR}/pg_hba.conf"

    # system tuning
    repro:cmd <<-EOT
        sudo sysctl -w net.core.somaxconn=65536
        sudo sysctl -w net.ipv4.tcp_max_syn_backlog=65536
        sudo sysctl -w net.ipv4.ip_local_port_range="1024 65000"
        sudo sysctl -w net.core.rmem_max=8388608
        sudo sysctl -w net.core.wmem_max=8388608
        sudo sysctl -w net.ipv4.tcp_rmem="4096 65536 8388608"
        sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 8388608"
        sudo sysctl -w net.ipv4.tcp_mem="8388608 8388608 8388608"
        sudo sysctl -w vm.hugetlb_shm_group=2048

        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/hugepages-16kB/enabled 2>/dev/null || true
        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/hugepages-64kB/enabled 2>/dev/null || true
        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled 2>/dev/null || true
EOT

    repro:cmd sudo systemctl start postgresql
    repro:cmd sudo systemctl enable postgresql

    # wait for PG to be ready
    local retries=30
    while ! sudo -u postgres psql -p ${PG_PORT} -c "SELECT 1" &>/dev/null; do
        retries=$((retries - 1))
        [ $retries -le 0 ] && repro:fatal "PostgreSQL did not start in time"
        sleep 1
    done
    repro:info "PostgreSQL is up on port ${PG_PORT}"

    # create benchmark user and database
    repro:cmd <<-EOT
        sudo -u postgres psql -p ${PG_PORT} -c "ALTER ROLE postgres WITH PASSWORD '${PG_PASSWORD}';"
        sudo -u postgres psql -p ${PG_PORT} -tc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USERNAME}'" | grep -q 1 || sudo -u postgres psql -p ${PG_PORT} -c "CREATE ROLE ${PG_USERNAME} WITH LOGIN PASSWORD '${PG_PASSWORD}' SUPERUSER;"
        sudo -u postgres psql -p ${PG_PORT} -tc "SELECT 1 FROM pg_database WHERE datname='${PG_DBNAME}'" | grep -q 1 || sudo -u postgres psql -p ${PG_PORT} -c "CREATE DATABASE ${PG_DBNAME} OWNER ${PG_USERNAME};"
EOT

    # signal LDG with SUT nproc
    repro:wait_for_ldg nproc $(nproc)
}

function postgresql:configure:loadgen() {
    repro:info "LDG configure"
    local SUT_vCPUs=$(repro:wait_for_sut nproc)
    repro:info "SUT vCPUs: $SUT_vCPUs, LDG vCPUs: $(nproc)"
    if [ -z "$PGBENCH_THREADS" ]; then
        PGBENCH_THREADS=$(nproc)
    fi
    repro:info "pgbench threads: $PGBENCH_THREADS"
}

# ============================================================
# Run
# ============================================================

function postgresql:run:sut() {
    repro:info "SUT ready, waiting for LDG to finish"
    repro:wait_for_ldg "DONE" "OK"
}

function postgresql:run:loadgen() {
    repro:info "LDG run: pgbench against ${REPROCFG_SUT}:${PG_PORT}"
    if [ -z "$PGBENCH_THREADS" ]; then
        PGBENCH_THREADS=$(nproc)
    fi

    local connstr="host=${REPROCFG_SUT} port=${PG_PORT} dbname=${PG_DBNAME} user=${PG_USERNAME} password=${PG_PASSWORD}"

    # wait for PG to be reachable on SUT
    repro:info "Waiting for PostgreSQL on ${REPROCFG_SUT}:${PG_PORT}"
    local retries=120
    while ! pg_isready -h ${REPROCFG_SUT} -p ${PG_PORT} -q 2>/dev/null; do
        retries=$((retries - 1))
        [ $retries -le 0 ] && repro:fatal "PostgreSQL on SUT not reachable after 120s"
        sleep 1
    done
    repro:info "PostgreSQL on SUT is ready"

    # initialize pgbench tables
    repro:info "pgbench init: scale=${PGBENCH_SCALE}"
    pgbench -i -s ${PGBENCH_SCALE} ${PGBENCH_INIT_EXTRA_ARGS} "${connstr}" 2>&1 | tee /tmp/pgbench_init.log | repro:log info
    local init_rc=${PIPESTATUS[0]}
    [ $init_rc -ne 0 ] && {
        repro:error "pgbench init failed (rc=$init_rc), aborting run"
        return $init_rc
    }

    # run benchmark
    local report_flag=""
    [ "${PGBENCH_REPORT_PER_COMMAND}" = "true" ] && report_flag="-r"

    repro:info "pgbench run: clients=${PGBENCH_CLIENTS} threads=${PGBENCH_THREADS} duration=${PGBENCH_DURATION}s builtin=${PGBENCH_BUILTIN}"
    pgbench \
        -c ${PGBENCH_CLIENTS} \
        -j ${PGBENCH_THREADS} \
        -T ${PGBENCH_DURATION} \
        -b ${PGBENCH_BUILTIN} \
        -M ${PGBENCH_PROTOCOL} \
        ${report_flag} \
        --progress=10 \
        ${PGBENCH_RUN_EXTRA_ARGS} \
        "${connstr}" 2>&1 | tee /tmp/pgbench_run.log | repro:log info
    local run_rc=${PIPESTATUS[0]}

    [ $run_rc -ne 0 ] && repro:warn "pgbench exited with rc=$run_rc"

    # parse results immediately (before signaling SUT) so they're saved even if handshake fails
    postgresql:results:loadgen

    # signal SUT that we're done
    repro:wait_for_sut "DONE" || repro:warn "SUT handshake failed, but results were already saved"
}

# ============================================================
# Results
# ============================================================

function postgresql:results:loadgen() {
    repro:info "Parsing pgbench results"

    [ "$WORKLOAD_RESULTS_FORMAT" != json ] && repro:error "Unsupported results format: $WORKLOAD_RESULTS_FORMAT" && return 1

    local logfile=/tmp/pgbench_run.log

    [ ! -f "$logfile" ] && repro:error "pgbench log not found at $logfile" && return 1

    local tps_incl tps_excl latency_avg latency_stddev
    # PG17: "tps = 109587.158786 (without initial connection time)"
    # PG<17: "tps = 109587.158786 (excluding connections establishing)"
    tps_excl=$(grep -oP 'tps = \K[0-9.]+(?= \((?:without|excluding))' "$logfile" | tail -1)
    tps_incl=$(grep -oP 'tps = \K[0-9.]+(?= \((?:including|with initial))' "$logfile" | tail -1)
    latency_avg=$(grep -oP 'latency average = \K[0-9.]+' "$logfile" | tail -1)
    latency_stddev=$(grep -oP 'latency stddev = \K[0-9.]+' "$logfile" | tail -1)

    local num_transactions
    num_transactions=$(sed -n 's/.*number of transactions actually processed: \([0-9]*\).*/\1/p' "$logfile" | tail -1)

    {
        echo "{"
        echo "    \"score\": ${tps_excl:-0},"
        echo "    \"score_units\": \"tps\","
        echo "    \"tps_including_conn\": ${tps_incl:-0},"
        echo "    \"tps_excluding_conn\": ${tps_excl:-0},"
        echo "    \"latency_avg_ms\": ${latency_avg:-0},"
        echo "    \"latency_stddev_ms\": ${latency_stddev:-0},"
        echo "    \"transactions\": ${num_transactions:-0},"
        echo "    \"scale_factor\": ${PGBENCH_SCALE},"
        echo "    \"clients\": ${PGBENCH_CLIENTS},"
        echo "    \"threads\": ${PGBENCH_THREADS:-0},"
        echo "    \"duration_sec\": ${PGBENCH_DURATION},"
        echo "    \"builtin\": \"${PGBENCH_BUILTIN}\","
        echo "    \"protocol\": \"${PGBENCH_PROTOCOL}\""
        echo "}"
    } >${WORKLOAD_RESULTS_FILE}

    repro:info "Results written to $(realpath "${WORKLOAD_RESULTS_FILE}")"
    repro:info "Score: ${tps_excl:-N/A} tps (excl conn), latency avg: ${latency_avg:-N/A} ms"
}

# ============================================================
# Cleanup
# ============================================================

function postgresql:cleanup:sut() {
    repro:info "SUT cleanup"
    repro:cmd <<-EOT
        sudo -u postgres psql -p ${PG_PORT} -c "DROP DATABASE IF EXISTS ${PG_DBNAME};" 2>/dev/null || true
        sudo systemctl stop postgresql
        sync
EOT
}

function postgresql:cleanup:loadgen() {
    repro:info "LDG cleanup"
    rm -f /tmp/pgbench_run.log
    return 0
}
