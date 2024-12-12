#!/usr/bin/env bash
# Repro: mysql + hammerdb

# test configuration
[ -f ./config.sh ] && . ./config.sh
: ${PARAM_RESULTS_FILE:=~/results.json} # where the repro writes the parsed results
: ${PARAM_VUSERS_PER_CORE:=4} # number of "virtual users" per core
: ${PARAM_WH:=24} # total number of "warehouses"; a good ballpark is (SUT_RAM_GB * 25 / 32)
: ${PARAM_RAMPUP_MIN:=5} # ramp up time, in minutes
: ${PARAM_DURATION_MIN:=20} # test duration, in minutes
: ${PARAM_RAMPDOWN_MIN:=5} # ramp down time, in minutes
: ${DB_RAMDISK_SIZE:=16G}
: ${DB_RAMDISK_MOUNTPOINT:=/tmp/ramdisk}
: ${MYSQL_REPO:=https://github.com/mysql/mysql-server.git}
: ${MYSQL_VERSION:=05e4357f78790766fea8342ecf072645b8310f94}
: ${HAMMERDB_REPO:=https://github.com/TPC-Council/HammerDB.git}
: ${HAMMERDB_VERSION:=4.4} # SHA: 64db67981d945c92919c6b3e1b192498077b658d
: ${HAMMERDB_PATH:=~/HammerDB}
: ${MYSQL_MOUNTPOINT:=/mnt/mysql}
: ${MYSQL_MALLOC:=jemalloc} # jemalloc, tcmalloc_minimal, etc
: ${MYSQLD_PATH:=/usr/sbin/mysqld}
: ${MYSQLD_RAMDISK_SIZE:=16G}
: ${MYSQL_USERNAME:=mysql_user}
: ${MYSQL_PASSWORD:=mysql}
: ${MYSQL_PORT:=3306}

function mysql:install:sut() {
    repro:debug SUT install
    repro:package:update
    repro:package:install mysql-server libmysqlclient-dev acl ssl-cert pkg-config build-essential linux-tools-$(uname -r)
    case "$MYSQL_MALLOC" in
        jemalloc) repro:package:install libjemalloc2;;
        tcmalloc*) repro:package:install google-perftools;;
    esac
    MYSQL_MALLOC_PATH=$(find /usr/lib/ -name "lib${MYSQL_MALLOC}\.so[.0-9]*" -print -quit)
    mysql:create_raid "$@"
    mysql:mount_raid "$@"
    repro:cmd <<-EOT
        [ -L /tmp/mysql.sock ] || sudo ln -sf \$(mysql_config --socket) /tmp/mysql.sock  # needed if HammerDB is running on the SUT

        sudo systemctl disable mysql
        sudo service mysql stop

        #sudo rm -f /etc/mysql/my.cnf /lib/systemd/system/mysql.service
        repro:template <${REPRO_ROOT}/files/my.cnf.tmpl MYSQL_MOUNTPOINT MYSQL_PORT | sudo bash -c 'cat >/etc/mysql/my.cnf'
        repro:template <${REPRO_ROOT}/files/mysqld.service.tmpl MYSQL_MALLOC MYSQLD_PATH SCHED_POLICY SCHED_PRIORITY | sudo bash -c 'cat >/lib/systemd/system/mysql.service'
        umask 022
        sudo rm -rf ${MYSQL_MOUNTPOINT}/{data,tmp}
        sudo mkdir -p ${MYSQL_MOUNTPOINT}/tmp

        [ -d /var/lib/mysql.orig ] || sudo mv /var/lib/mysql /var/lib/mysql.orig
        sudo mkdir -p ${DB_RAMDISK_MOUNTPOINT}
        mountpoint -q ${DB_RAMDISK_MOUNTPOINT} || sudo mount -t tmpfs -o size=${MYSQLD_RAMDISK_SIZE} myramdisk ${DB_RAMDISK_MOUNTPOINT}
        sudo rm -rf ${DB_RAMDISK_MOUNTPOINT}/mysql /var/lib/mysql
        sudo cp -R /var/lib/mysql.orig ${DB_RAMDISK_MOUNTPOINT}/mysql
        sudo ln -s ${DB_RAMDISK_MOUNTPOINT}/mysql /var/lib/mysql

        sudo chown -R mysql:mysql ${MYSQL_MOUNTPOINT} ${DB_RAMDISK_MOUNTPOINT} /var/lib/mysql
        sudo chmod -R 755 ${MYSQL_MOUNTPOINT} ${DB_RAMDISK_MOUNTPOINT}/mysql

        [ -d /etc/apparmor.d ] && {
            sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld
            sudo ln -sf /etc/apparmor.d/usr.sbin.mysqld /etc/apparmor.d/disable/usr.sbin.mysqld
        }

        sudo sh -c 'echo always >/sys/kernel/mm/transparent_hugepage/enabled'
        sudo sysctl net.core.somaxconn=65535
        sudo sysctl net.ipv4.tcp_max_syn_backlog=10000
        sudo sysctl fs.aio-max-nr=1048576
        sudo sysctl vm.max_map_count=2147483647

        sudo ${MYSQLD_PATH} --initialize-insecure
        sudo service mysql start

        # Set mysql user and password to match tcl files
        repro:wait_for_file \$(mysql_config --socket) 90
        for host in ${REPROMARK_LOADGEN:-%}; do
            sudo mysql --execute "CREATE USER '${MYSQL_USERNAME}'@'\${host}' IDENTIFIED BY '${MYSQL_PASSWORD}';"
            sudo mysql --execute "GRANT ALL PRIVILEGES ON * . * TO '${MYSQL_USERNAME}'@'\${host}';"
        done
        sudo mysql --execute "FLUSH PRIVILEGES;"
EOT
}

function mysql:install:loadgen() {
    repro:debug Loadgen install
    repro:package:update
    repro:package:install tclsh wish tcl-thread mysqltcl libmysqlclient-dev postgresql-client-common
    repro:cmd <<-EOT
        [ -d ${HAMMERDB_PATH} ] || git clone --branch v${HAMMERDB_VERSION} ${HAMMERDB_REPO} ${HAMMERDB_PATH}
        mkdir -p ${HAMMERDB_PATH}/bin
        ln -sf /bin/tclsh ${HAMMERDB_PATH}/bin/tclsh8.6
        sudo sysctl net.core.somaxconn=4096
        sudo sysctl net.ipv4.tcp_max_syn_backlog=4096
        sudo sysctl net.ipv4.ip_local_port_range="1024 65000"
EOT
}

function mysql:configure:loadgen() {
    repro:debug Loadgen configure
    PARAM_VUSERS=$((PARAM_VUSERS_PER_CORE * $(nproc)))
    PARAM_DURATION_TOTAL_SEC=$((PARAM_RAMPUP_MIN * 60 + PARAM_DURATION_MIN * 60 + 120))
    PARAM_RAMPDOWN_MSEC=$((PARAM_RAMPDOWN_MIN * 60 * 1000))
    repro:template <${REPRO_ROOT}/files/mysql_tpcc_run.tcl >${HAMMERDB_PATH}/mysql_tpcc_run.tcl
}

function mysql:run:sut() {
    repro:debug SUT run
    repro:info SUT ready for workload
    repro:wait_for_ldg "DONE"
#    sleep 86400 &>/dev/null &
#    local PID=$!
#    repro:info "To end run, type 'kill $PID' when the Loadgen is done testing"
#    wait $PID
}

function mysql:run:loadgen() {
    repro:debug Loadgen run
    REPROMARK_PORT=$MYSQL_PORT repro:wait_for_sut ""
    sleep 5
    repro:cmd "cd ${HAMMERDB_PATH}; ./hammerdbcli auto mysql_tpcc_run.tcl"
}

function mysql:results:loadgen() {
    repro:debug mysql:results "$@"

    # format: Vuser 1:TEST RESULT : System achieved 123456 NOPM from 456789 MySQL TPM
    local -a nopm tpm
    local val_nopm val_tpm
    while read -r val_nopm val_tpm; do
        nopm+=($val_nopm)
        tpm+=($val_tpm)
    done < <(sed -n 's/.*:TEST RESULT.* \([0-9]*\) NOPM from \([0-9]*\) .*/\1 \2/p' /tmp/hammerdb.log)

    # format:
    # CALLS: 1234567  MIN: 1.234ms    AVG: 12.345ms   MAX: 12.345ms   TOTAL: 123456789.123ms
    # P99: 12.345ms   P95: 12.345ms   P50: 12.345ms   SD: 12345.678   RATIO: 12.345%
    local -a latency_min latency_avg latency_max latency_p99 latency_p95 latency_p50 latency_ratios
    local val_min val_avg val_max val_p99 val_p95 val_p50 val_ratio
    while read -r _ _ _ val_min _ val_avg _ val_max _ && read -r _ val_p99 _ val_p95 _ val_p50 _ _ _ val_ratio; do
        latency_min+=(${val_min//ms})
        latency_avg+=(${val_avg//ms})
        latency_max+=(${val_max//ms})
        latency_p99+=(${val_p99//ms})
        latency_p95+=(${val_p95//ms})
        latency_p50+=(${val_p50//ms})
        latency_ratios+=(${val_ratio//%})
    done < <(sed -n '/SUMMARY/,/^\+-\+/{/^[CP]/p}' /tmp/hdbxtprofile.log)

    {
        local var
        echo "{"
        for var in nopm tpm latency_min latency_avg latency_max latency_p99 latency_p95 latency_p50 latency_ratios; do
            echo -n "    \"${var}\": ["
            var=${var}[@]
            echo "${!var}]," | sed 's/ /,/g'
        done
        echo "}"
    } >${PARAM_RESULTS_FILE}
    repro:info "Results written to $(realpath "${PARAM_RESULTS_FILE}")"
}

function mysql:cleanup:sut() {
    repro:debug SUT cleanup "$@"
    repro:cmd <<-EOT
        sudo mysql --execute "DROP DATABASE hammerdbtest;"
        sudo -i sh -c 'rm /tmp/ramdisk/mysql/{1,binlog}.*' &>/dev/null
        sync
EOT
}

function mysql:cleanup:loadgen() {
    repro:debug Loadgen cleanup "$@"
    repro:wait_for_sut "DONE"
    repro:cmd sudo rm /tmp/hammerdb.log /tmp/hdbxtprofile.log
}

function mysql:create_raid() {
    repro:debug mysql:create_raid "$@"
    repro:cmd sudo mkdir -p "${MYSQL_MOUNTPOINT}"
    repro:cmd --force mountpoint "${MYSQL_MOUNTPOINT}" && return
    local i dev devlist=() dry_run=true
    for dev in /dev/nvme[0-9]n[0-9]; do
        [ -e /proc/mdstat ] && grep -q " ${dev#/dev/}\[" /proc/mdstat && continue
        mount -l | grep -q "^$dev" || devlist+=("$dev")
    done
    for i; do [ "$i" = "--create-raid" ] && dry_run=false && break; done
    $dry_run && repro:info "Skipping RAID creation" && return 0
    for i in {0..9} ''; do [ -e /dev/md${i} ] || break; done
    [ -z "$i" ] && repro:error "No free md devices found" && return 1
    [ ${#devlist[@]} -eq 0 ] && repro:warn "create_raid: No available devices found" && return 0
    repro:info "Found ${#devlist[@]} unmounted devices: ${devlist[@]}, can create as /dev/md$i"
    repro:cmd sudo mdadm -CvR /dev/md$i -l raid0 --force -n ${#devlist[@]} "${devlist[@]}"
    repro:cmd sudo mkfs.ext4 -j -m 1 /dev/md$i
}

function mysql:mount_raid() {
    repro:debug mysql:mount_raid "$@"
    repro:cmd sudo mkdir -p ${MYSQL_MOUNTPOINT}
    repro:cmd --force mountpoint "${MYSQL_MOUNTPOINT}" && return
    local i=0
    for i in {9..0} ''; do [ -e /dev/md${i} ] && break; done
    [ -z "$i" ] && repro:error "No md device available to mount" && return 1
    repro:info "Mounting /dev/md$i on ${MYSQL_MOUNTPOINT}"
    repro:cmd sudo mount -t ext4 -o rw,noatime,nodiratime,data=ordered,nobarrier,nodelalloc,stripe=64 /dev/md$i ${MYSQL_MOUNTPOINT}
}

function mysql:help() {
    echo "Runs a mysql + hammerdb test. Hosts required: 1 SUT and 1 loadgen."
    echo "Run the repro on SUT first to install and configure, then on loadgen to measure performance."
    echo "Prereqs: fast storage mounted on ${MYSQL_MOUNTPOINT} on the SUT (recommended: 2 x NVME in RAID0)."
    echo "If the mount is not active and the --create-raid argument is given, the repro will try to create a RAID0 array from all unmounted nvme devices."
}

#hammerdb_git_location: https://github.com/TPC-Council/HammerDB.git
#hammerdb_binary_location: https://github.com/TPC-Council/HammerDB/releases/download/v3.3/HammerDB-3.3-Linux.tar.gz
