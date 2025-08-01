# Repro: mysql + hammerdb before and after EEVDF
# source this file, don't run it

: ${SCENARIO_AUTOBUILD_KERNELS:=true}        # automatically build kernel as needed (otherwise, just warn and allow user to build manually)
: ${SCENARIO_SKIP_BUILD_ACTIVE_KERNEL:=true} # skip kernel build step when the active kernel matches the required version (the AUTOBUILD flag is also respected no matter what)
: ${SCENARIO_REUSE_BUILT_KERNELS:=true}      # if the required kernel version was built before, reuse it (this will cause wrong results if testing the same kernel multiple times but with different config options)
: ${SCENARIO_BASELINE:=6.5.13}               # kernel version to use as baseline when printing final results

_SCENARIO_CONST_KERNELS_BASE="6.5 6.6 6.8 6.12 6.13 6.14 6.15"
_SCENARIO_CONST_KERNELS_LATEST="6.5.13 6.6.96 6.8.12 6.12.36 6.13.12 6.14.11 6.15.5 6.16-rc5"
declare -A SCENARIO_CONFIG_VARS=( # format: [sched_policy [sched_feature ...]]
    [default]=""
    [NOx2]="SCHED_OTHER NO_PLACE_LAG NO_RUN_TO_PARITY"
    [batch]="SCHED_BATCH PLACE_LAG RUN_TO_PARITY"
)
# treat the above definitions as constants; if you want to specify which kernels to run, override SCENARIO_KERNELS and SCENARIO_CONFIGS from the command line
# e.g.:
#SCENARIO_KERNELS="6.5.13 6.6.96 6.12.36 6.14.11 6.15.5 6.16-rc5"
#SCENARIO_CONFIGS="default batch"

#: ${SCENARIO_KERNELS:="${_SCENARIO_CONST_KERNELS_BASE} ${_SCENARIO_CONST_KERNELS_LATEST}"} # list of kernels to test
: ${SCENARIO_KERNELS:="${_SCENARIO_CONST_KERNELS_LATEST}"} # only test latest by default
: ${SCENARIO_CONFIGS:="default NOx2 batch"}  # which configs to run for each kernel version
: ${SCENARIO_BASE_SLICES:="3"}               # base slice values to use, in ms; multiple values e.g.: "3 6"
: ${SCENARIO_ITERATIONS_PER_RUN:=1}          # how many times to run each kernel+config variant

function scenario:help()
{
    echo "Repro scenario: EEVDF regression from kernel 6.5 to 6.6-14, with and without proposed mitigations"
    echo "                (kernel 6.12+ has a different profile than 6.8 through 6.11)"
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
    local tag="$1" reuse_build
    shift
    local build_args="CONFIG_SCHED_DEBUG=y CONFIG_PROC_SYSCTL=y CONFIG_SYSCTL=y"
    build_args+=" CONFIG_HZ_100= CONFIG_HZ_250=y CONFIG_HZ_300= CONFIG_HZ_1000= CONFIG_HZ=250 $*"
    $SCENARIO_REUSE_BUILT_KERNELS && reuse_build="--reuse-build"
    pushd "${REPROCFG_TMP}"
    repro:cmd "${REPROCFG_ROOT}/util/kernel_from_src.sh" --offline-mode --install $reuse_build "--version=$tag" "--patch-dir=${SCENARIO_PATH}/patches" $build_args
    popd
}

# make sure the kernel is the expected version; args: <kernel_version> [config_options]
function scenario:require_kernel() {
    local msg kernel="$(uname -r)"
    repro:info "Current kernel: $kernel"
    $SCENARIO_SKIP_BUILD_ACTIVE_KERNEL && [[ ! "$kernel" =~ ^${1}[0-9] ]] && [[ "$kernel" =~ ^${1} || "$kernel" =~ ^${1/-/.*-} ]] && return 0
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

# these are done as part of the run step loop
unset -f scenario:configure scenario:cleanup

function scenario:install:sut() {
    scenario:install
    pushd "${REPROCFG_TMP}"
    repro:cmd "${REPROCFG_ROOT}/util/kernel_from_src.sh" --setup-only
    popd
}

# run iterations of a mysql test; args: <title> <data_label> <kernel_version> <config> <slice_ms> [scheduler_feature [...]] [-- workload_args]
function scenario:run_mysql()
{
    repro:info "MySQL on $1"
    scenario:require_kernel "$3"
    local label="$2"
    local config="$4"
    local slice="$5"
    shift 5
    local sched=${SCENARIO_CONFIG_VARS[$config]:-SCHED_OTHER}
    export WORKLOAD_SCHED_POLICY="${sched%% *}"
    local feature
    for feature in ${SCENARIO_CONFIG_VARS[$config]#* }; do
        repro:cmd sudo bash -c "'echo $feature >/sys/kernel/debug/sched/features'"
    done
    for feature; do
        shift
        [ "$feature" = "--" ] && break
        repro:cmd sudo bash -c "'echo $feature >/sys/kernel/debug/sched/features'"
    done
    repro:cmd sudo bash -c "'echo ${slice} >/sys/kernel/debug/sched/base_slice_ns'"
    local iteration it_label
    for ((iteration = 1; iteration <= ${SCENARIO_ITERATIONS_PER_RUN}; iteration++)); do
        it_label="${label}-${iteration}"
        repro:info "Starting iteration #${iteration}/${SCENARIO_ITERATIONS_PER_RUN} for ${it_label}"
        repro:wait_for_ldg "STEP" "${it_label}"
        repro:info "Starting perf sched stats with wait=${SCENARIO_PERF_WAIT} and duration=${SCENARIO_PERF_DURATION}"
        {
            sleep "${SCENARIO_PERF_WAIT}"
            cat /proc/schedstat >"schedstat-${it_label}-before"
            repro:cmd sudo bash -c "'echo 1 >/proc/sys/kernel/sched_schedstats'"
            repro:cmd sudo perf sched stats record "--output=perf-${it_label}.data" -- sleep "${SCENARIO_PERF_DURATION}"
            repro:cmd sudo bash -c "'echo 0 >/proc/sys/kernel/sched_schedstats'"
            cat /proc/schedstat >"schedstat-${it_label}-after"
            sudo chown "$USER" "perf-${it_label}.data"
            perf sched stats report -i "perf-${it_label}.data" >"perf-${it_label}.report"
            repro:cmd sed -n '"/CPU 0/q;p"' '"perf-${it_label}.report"'
        }&
        repro:run mysql SUT "$@" configure run cleanup
    done
}

# run all the test cases in sequence; if needed, build+install required kernel version and wait for manual reboot
function scenario:run:sut()
{
    # these can't be defined at the top of the file, because they depend on workload variables,
    # which are only initialized after this file is sourced
    : ${SCENARIO_PERF_WAIT:=$((60 * HAMMERDB_PARAM_RAMPUP_MIN * 2))}
    : ${SCENARIO_PERF_DURATION:=$((60 * HAMMERDB_PARAM_DURATION_MIN / 2))}

    {
        local kernel config slice
        # initial steps
        cat <<-EOT
        repro:package:update
        # Removing cryptsetup to avoid "couldn't resolve device /dev/root" errors with custom kernel builds
        repro:package:remove cryptsetup
        #repro:cmd sudo apt-get purge flash-kernel -y
EOT
        # loop steps for each tested kernel
        for kernel in ${SCENARIO_KERNELS}; do
            for config in ${SCENARIO_CONFIGS}; do
                for slice in ${SCENARIO_BASE_SLICES}; do
                    for workload in $(scenario:workloads); do
                        cat <<-EOT
                        scenario:run_mysql "kernel ${kernel} ${config} ${slice}ms" k${kernel//-/.}-${config} ${kernel} ${config} ${slice}
EOT
                    done
                done
            done
        done
        # final steps
        cat <<-EOT
        repro:wait_for_ldg "STEP" "DONE"
        repro:info "Done"
EOT
    } | repro:persistent_steps "${SCENARIO_NAME}"
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
        WORKLOAD_RESULTS_FILE="${SCENARIO_RESULTS_PATH}/results-${tag}.json" repro:run mysql LDG "$@" configure run results cleanup
    done
}

function scenario:results:loadgen()
{
    pushd "${SCENARIO_RESULTS_PATH}"
    repro:info "Results: ${SCENARIO_RESULTS_PATH}/results-k*.json"

    for r in results-*.json; do
        repro:info "Results for $(basename "${r#*-}" .json)"
        repro:cmd cat "$r"
    done

    repro:cmd "${SCENARIO_PATH}/report.py" "${SCENARIO_BASELINE}-default-1" results-k6.{5,6,8,1}*-[^b]*-*.json
    repro:cmd "${SCENARIO_PATH}/report.py" "${SCENARIO_BASELINE}-batch-1" results-k6.{5,6,8,1}*-batch*.json

    popd
}
