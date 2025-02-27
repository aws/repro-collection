# Repro: mysql + hammerdb before and after EEVDF
# source this file, don't run it

: ${SCENARIO_AUTOBUILD_KERNELS:=true}

function scenario:help()
{
    echo "Repro scenario: EEVDF regression from kernel 6.5 to 6.8-12, with and without proposed mitigations"
    echo "                (kernel 6.12 has a different profile than 6.8 through 6.11)"
    echo "                In order to better compare to 6.5, all other kernels also need to use CONFIG_HZ_250=y"
    echo "Repro steps:"
    echo "  1. Create 1 SUT and 1 LDG instance, running e.g. Ubuntu 22.04, with a default user that has sudo access."
    echo "  2. Create a RAID array on the SUT to use for the database. The workload will attempt to mount the first /dev/md<N> it finds under ${MYSQL_DB_MOUNTPOINT} (this step is optional)."
    echo "  3. Configure the SUT to accept TCP connections on ports ${MYSQL_PORT} and ${REPROCFG_PORT} from the LDG."
    echo "  4. Start the repro scenario on the SUT and LDG in parallel:"
    echo "    4a. On the SUT, run: repro.sh ${SCENARIO_NAME} SUT --ldg=<LDG_address>"
    echo "    4b. On the LDG, run: repro.sh ${SCENARIO_NAME} LDG --sut=<LDG_address>"
    echo "  5. The SUT will stop whenever a different kernel version is required."
    echo "     The kernel should install automatically for you. If it fails, replace it manually before proceeding."
    echo "     Next, reboot the SUT to activate the new kernel version, then rerun the (4a) step to continue the scenario."
    echo "  6. The LDG will collect all results and print a report when all the tests are finished."
    echo "  7. Terminate the SUT and LDG instances."
    echo
    echo "To run a single test, replace step 4a with (please note the quoted final argument):"
    echo "  repro.sh ${SCENARIO_NAME} SUT --ldg=<LDG_IP_ADDRESS> run_mysql --\"<title> <LDG_output_file_label> <kernel_version> <sched_policy> <sched_feature [...]>\""
    echo "  E.g: repro.sh ${SCENARIO_NAME} SUT --ldg=1.2.3.4 run_mysql --\"Manual_run my_k6.12 6.12 SCHED_OTHER NO_PLACE_LAG NO_RUN_TO_PARITY\""
}

function scenario:workloads() {
    echo "mysql"
}

# build and install kernel; args: <kernel_tag> [config_options]
function scenario:build_kernel() {
    local tag="$1"
    shift
    local build_args="CONFIG_SCHED_DEBUG=y CONFIG_PROC_SYSCTL=y CONFIG_SYSCTL=y"
    build_args+=" CONFIG_HZ_100= CONFIG_HZ_250=y CONFIG_HZ_300= CONFIG_HZ_1000= CONFIG_HZ=250 $*"
    pushd ${REPROCFG_TMP}
    repro:cmd ${REPROCFG_ROOT}/util/kernel_from_src.sh --install --version=$tag $build_args
    popd
}

# make sure the kernel is the expected version; args: <kernel_version> [config_options]
function scenario:require_kernel() {
    local msg kernel="$(uname -r)"
    repro:info "Current kernel: $kernel"
    [[ ! "$kernel" =~ ^${1}[0-9] ]] && [[ "$kernel" =~ ^${1} || "$kernel" =~ ^${1/-/.*-} ]] && return 0
    repro:info "Looking for kernel: $1"
    if $SCENARIO_AUTOBUILD_KERNELS; then
        scenario:build_kernel v"$@"
        msg="Please reboot to activate kernel $1."
    else
        msg="Please build and install kernel $1, then reboot to activate it."
    fi
    msg+=" After rebooting, rerun this repro scenario to continue."
    repro:fatal "$msg"
}

# run one mysql test; args: <title> <data_label> <kernel_version> [scheduler_policy] [scheduler_feature [...]] [-- workload_args]
function scenario:run_mysql()
{
    repro:info "MySQL on $1"
    scenario:require_kernel "$3"
    repro:wait_for_ldg "STEP" "$2"
    export WORKLOAD_SCHED_POLICY="${4:-SCHED_OTHER}"
    shift 3 # shift 4 will do nothing if the optional 4th argument is missing
    shift
    local feature
    for feature; do
        shift
        [ "$feature" = "--" ] && break
        repro:cmd sudo bash -c "'echo $feature >/sys/kernel/debug/sched/features'"
    done
    repro:run mysql SUT "$@"
}

# run all the test cases in sequence; if needed, build+install required kernel version and wait for manual reboot
function scenario:run:sut()
{
    repro:persistent_steps ${SCENARIO_NAME} <<-EOT
        repro:package:update
        # Removing cryptsetup to avoid "couldn't resolve device /dev/root" errors with custom kernel builds
        repro:package:remove cryptsetup
        #repro:cmd sudo apt-get purge flash-kernel -y

        scenario:run_mysql "MySQL on default kernel 6.5" k6.5 6.5
        scenario:run_mysql "MySQL on default kernel 6.5" k6.5.13 6.5.13
        scenario:run_mysql "MySQL on kernel 6.5.13 SCHED_BATCH" k6.5.13-batch 6.5.13 SCHED_BATCH PLACE_LAG RUN_TO_PARITY

        scenario:run_mysql "MySQL on default kernel 6.6" k6.6 6.6
        scenario:run_mysql "MySQL on default kernel 6.6.80" k6.6.80 6.6.80
        scenario:run_mysql "MySQL on kernel 6.6.80 NO_PLACE_LAG NO_RUN_TO_PARITY" k6.6.80-NOx2 6.6.80 SCHED_OTHER NO_PLACE_LAG NO_RUN_TO_PARITY
        scenario:run_mysql "MySQL on kernel 6.6.80 SCHED_BATCH" k6.6.80-batch 6.6.80 SCHED_BATCH PLACE_LAG RUN_TO_PARITY

        scenario:run_mysql "MySQL on default kernel 6.8" k6.8 6.8 SCHED_OTHER PLACE_LAG RUN_TO_PARITY
        scenario:run_mysql "MySQL on default kernel 6.8.12" k6.8.12 6.8.12 SCHED_OTHER PLACE_LAG RUN_TO_PARITY
        scenario:run_mysql "MySQL on kernel 6.8.12 NO_PLACE_LAG NO_RUN_TO_PARITY" k6.8.12-NOx2 6.8.12 SCHED_OTHER NO_PLACE_LAG NO_RUN_TO_PARITY
        scenario:run_mysql "MySQL on kernel 6.8.12 SCHED_BATCH" k6.8.12-batch 6.8.12 SCHED_BATCH PLACE_LAG RUN_TO_PARITY

        scenario:run_mysql "MySQL on default kernel 6.12" k6.12 6.12 SCHED_OTHER PLACE_LAG RUN_TO_PARITY
        scenario:run_mysql "MySQL on default kernel 6.12.17" k6.12.17 6.12.17 SCHED_OTHER PLACE_LAG RUN_TO_PARITY
        scenario:run_mysql "MySQL on kernel 6.12.17 NO_PLACE_LAG NO_RUN_TO_PARITY" k6.12.17-NOx2 6.12.17 SCHED_OTHER NO_PLACE_LAG NO_RUN_TO_PARITY
        scenario:run_mysql "MySQL on kernel 6.12.17 SCHED_BATCH" k6.12.17-batch 6.12.17 SCHED_BATCH PLACE_LAG RUN_TO_PARITY

        scenario:run_mysql "MySQL on default kernel 6.13" k6.13 6.13 SCHED_OTHER PLACE_LAG RUN_TO_PARITY
        scenario:run_mysql "MySQL on default kernel 6.13.5" k6.13.5 6.13.5 SCHED_OTHER PLACE_LAG RUN_TO_PARITY
        scenario:run_mysql "MySQL on kernel 6.13.5 NO_PLACE_LAG NO_RUN_TO_PARITY" k6.13.5-NOx2 6.13.5 SCHED_OTHER NO_PLACE_LAG NO_RUN_TO_PARITY
        scenario:run_mysql "MySQL on kernel 6.13.5 SCHED_BATCH" k6.13.5-batch 6.13.5 SCHED_BATCH PLACE_LAG RUN_TO_PARITY

        scenario:run_mysql "MySQL on default kernel 6.14-rc4" k6.14-rc4 6.14-rc4 SCHED_OTHER PLACE_LAG RUN_TO_PARITY
        scenario:run_mysql "MySQL on kernel 6.14-rc4 NO_PLACE_LAG NO_RUN_TO_PARITY" k6.14-NOx2 6.14-rc4 SCHED_OTHER NO_PLACE_LAG NO_RUN_TO_PARITY
        scenario:run_mysql "MySQL on kernel 6.14-rc4 SCHED_BATCH" k6.14-batch 6.14-rc4 SCHED_BATCH PLACE_LAG RUN_TO_PARITY

        repro:wait_for_ldg "STEP" "DONE"
        repro:info "Done"
EOT
}

# LDG: keep sending "STEP" and running one iteration until the SUT sends "DONE"
# anything other than "DONE" is a data label used to name the results file
function scenario:run:loadgen()
{
    mkdir -p "${SCENARIO_RESULTS_PATH}"
    while true; do
        tag=$(repro:wait_for_sut "STEP")
        [ "${tag:-DONE}" = "DONE" ] && break
        repro:info "Running $tag test"
        WORKLOAD_RESULTS_FILE="${SCENARIO_RESULTS_PATH}/results-${tag}.json" repro:run mysql LDG "$@"
    done

    for r in "${SCENARIO_RESULTS_PATH}"/results-*.json; do
        repro:info "Results for $r"
        repro:cmd cat "$r"
    done
}
