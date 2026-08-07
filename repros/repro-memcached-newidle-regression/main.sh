# Repro: memcached tail latency before and after "sched/fair: Proportional newidle balance"
# source this file, don't run it
#
# The culprit scales newidle load balancing by a domain's average load, which on a
# multi-LLC part stops the balancer pulling waking tasks across LLCs near
# saturation. Lancet is the load generator because the effect is an open-loop
# tail-latency shift; memtier's closed-loop measurement averages it away. See
# results/ and README.md.

: ${SCENARIO_CULPRIT_SHA:=33cf66d88306663d16e4759e9d24766b0aaa2e17}
: ${SCENARIO_KERNEL_TAG:=v6.19}                # mainline tag that contains the culprit
: ${SCENARIO_KERNEL_MODE:=al2023}              # al2023 = dnf-install the exact pair, no compile (the evidenced default)
                                               # build  = compile the tag +/- revert (EXPERIMENTAL, no committed results)
: ${SCENARIO_AL2023_BAD:=6.1.150-174.273.amzn2023}
: ${SCENARIO_AL2023_GOOD:=6.1.148-173.267.amzn2023}
: ${SCENARIO_AUTOBUILD_KERNELS:=true}
: ${SCENARIO_REUSE_BUILT_KERNELS:=true}        # build mode: reuse an already-compiled kernel; this measures the same
                                               # kernel twice if the revert did not apply
: ${SCENARIO_LINUX_DIR:=$HOME/linux}
: ${SCENARIO_VARIANTS:="bad good"}
: ${SCENARIO_WORKLOAD:=memcached-lancet}       # must have a support (coordinator) role

function scenario:help() {
    echo "Repro scenario: memcached regression from 'sched/fair: Proportional newidle balance' (${SCENARIO_CULPRIT_SHA})"
    echo "Compares BAD (culprit present) vs GOOD (culprit absent): max QPS under a p99 latency SLO."
    echo
    echo "REQUIRES a multi-LLC SUT (e.g. AMD c7a.4xlarge, 2 CCDs). Single-LLC parts do not reproduce it."
    echo "Hosts: 1 SUT + 1 SUP (coordinator) + 3 LDG (2 throughput agents, then 1 latency agent)."
    echo "The coordinator reaches the agents over SSH -- Lancet's own requirement, not the framework's."
    echo
    echo "Kernel modes (SCENARIO_KERNEL_MODE):"
    echo "  al2023 (default) -- dnf-install ${SCENARIO_AL2023_BAD} (bad) vs ${SCENARIO_AL2023_GOOD} (good); the path the committed results used"
    echo "  build            -- compile ${SCENARIO_KERNEL_TAG}; GOOD adds the revert in patches/. EXPERIMENTAL, ~40min per kernel"
    echo
    echo "Repro steps:"
    echo "  1. Create 5 instances of a multi-LLC type, with a default user that has sudo access."
    echo "  2. Allow TCP on ports ${MEMCACHED_PORT} and ${REPROCFG_PORT} between them, plus SSH from the coordinator to the agents."
    echo "  3. Start all five in parallel:"
    echo "    3a. SUT:         repro.sh ${SCENARIO_NAME} SUT --sup=<coordinator>"
    echo "    3b. agents (x3): repro.sh ${SCENARIO_NAME} LDG --sup=<coordinator>"
    echo "    3c. coordinator: repro.sh ${SCENARIO_NAME} SUP --sut=<sut> --ldg=<thr1> --ldg=<thr2> --ldg=<lat>"
    echo "  4. The SUT stops whenever it needs a different kernel. Reboot it, then rerun (3a) to continue."
    echo "  5. The coordinator prints the comparison once both variants are measured."
    echo
    echo "To measure a single variant: repro.sh ${SCENARIO_NAME} SUT --sup=<coordinator> run_variant --\"bad\""
}

function scenario:workloads() {
    echo "${SCENARIO_WORKLOAD}"
}

# configure/run/cleanup are driven per variant inside the run step, so the
# framework's own defaults for them would fire a second time out of sequence.
unset -f scenario:configure scenario:cleanup

# In build mode the SUT compiles a kernel, and kernel_from_src.sh treats a perf
# build failure as fatal BEFORE installing the kernel.
function scenario:install:sut() {
    scenario:install
    [ "$SCENARIO_KERNEL_MODE" = build ] && {
# --path is required: without it the util picks its own LINUX_DIR and clones.
        pushd "${REPROCFG_TMP}"
        repro:cmd "${REPROCFG_ROOT}/util/kernel_from_src.sh" --setup-only "--path=${SCENARIO_LINUX_DIR}"
        popd
# Verified on AL2023 2023.12: perf needs these or it stops on "No python
# interpreter" then "libtraceevent is missing", and the kernel never installs.
        local pkg
        for pkg in python3 python3-devel python3-dev libtraceevent-devel \
                   libtraceevent-dev slang-devel libslang2-dev libunwind-devel \
                   numactl-devel zlib-devel libzstd-devel libcap-devel; do
            repro:package:install "$pkg" || true
        done
        # perf's jevents step invokes `python`; AL2023 provides only `python3`.
        [ -x /usr/bin/python ] || repro:cmd "sudo ln -sf /usr/bin/python3 /usr/bin/python"
    }
    return 0
}

# Make sure the running kernel is the requested variant; install or build it and
# ask for a reboot if not. Args: <variant: bad|good>
function scenario:require_variant() {
    local variant="$1" want
    repro:info "Current kernel: $(uname -r) (want: $variant)"
    case "$variant" in bad|good) ;; *) repro:fatal "Unknown variant '$variant' (use bad or good)";; esac

    if [ "$SCENARIO_KERNEL_MODE" = al2023 ]; then
        [ "$variant" = bad ] && want="$SCENARIO_AL2023_BAD" || want="$SCENARIO_AL2023_GOOD"
        case "$(uname -r)" in *"${want}"*) repro:info "Running the '$variant' kernel"; return 0;; esac
        $SCENARIO_AUTOBUILD_KERNELS || {
            repro:state:set_manual_needed "Install kernel ${want} and reboot"
            repro:fatal "Kernel ${want} is not active and autobuild is disabled; install it and reboot."
        }
# The SUT must already be on the pinned pair's kernel major line: installing a 6.1
# kernel on a 6.12 image fails because kernel6.12-tools conflicts.
        case "$(uname -r)" in
            "${want%%-*}"*|6.1.*) ;;
            *) repro:fatal "Running kernel $(uname -r) is not on the ${want%%.*}.${want#*.} line, so dnf cannot install kernel-${want} (kernel<major>-tools conflicts). Launch the SUT from an AL2023 kernel-${want%%-*} AMI (e.g. al2023-ami-*-kernel-6.1-x86_64), or use SCENARIO_KERNEL_MODE=build." ;;
        esac
        repro:info "Installing kernel-${want} (${variant}) and making it the grub default"
        # AL2023 has no kernel-modules subpackage; the kernel package carries them.
        repro:cmd sudo dnf install -y "kernel-${want}"
        repro:cmd sudo grubby --set-default "/boot/vmlinuz-${want}.$(uname -m)"
# Verify the outcome, not the status: a heredoc repro:cmd always returns 0.
        case "$(sudo grubby --default-kernel 2>/dev/null)" in
            *"${want}"*) ;;
            *) repro:fatal "kernel-${want} did not install or grub did not default to it; the pinned package may have aged out of the repos. Use SCENARIO_KERNEL_MODE=build." ;;
        esac
    else
# GOOD is BAD plus the revert in patches/. kernel_from_src.sh stamps
# LOCALVERSION=-<gitrev>, so the two builds differ in uname.
        want=$(repro:get_persistent_var "${SCENARIO_NAME}" "rev_${variant}")
        [ -n "$want" ] && case "$(uname -r)" in
            *"${want}"*) repro:info "Running the '$variant' build (${want})"; return 0 ;;
        esac
        local patchdir reuse
        [ "$variant" = good ] && patchdir="--patch-dir=${SCENARIO_PATH}/patches"
        $SCENARIO_REUSE_BUILT_KERNELS && reuse="--reuse-build"
        pushd "${REPROCFG_TMP}"
        repro:cmd "${REPROCFG_ROOT}/util/kernel_from_src.sh" --install $reuse \
            "--version=${SCENARIO_KERNEL_TAG}" "--path=${SCENARIO_LINUX_DIR}" $patchdir
        popd
        local rev; rev=$(git -C "${SCENARIO_LINUX_DIR}" rev-parse --short HEAD 2>/dev/null)
        # If the revert stops applying, GOOD keeps BAD's revision and both variants
        # would be the same kernel.
        [ "$variant" = good ] && [ -n "$rev" ] && \
            [ "$rev" = "$(repro:get_persistent_var "${SCENARIO_NAME}" rev_bad)" ] && \
            repro:fatal "The revert did not apply: GOOD is at the same revision as BAD (${rev}), so both variants would be the same kernel. Check patches/${SCENARIO_KERNEL_TAG}/."
        repro:set_persistent_var "${SCENARIO_NAME}" "rev_${variant}" "$rev"
    fi
    # Signal the reboot the same way the sibling scenario does, so an external
    # controller can see why the run stopped.
    repro:state:set_reboot_needed "Activate the '$variant' kernel instead of $(uname -r)"
    repro:fatal "Prepared the '$variant' kernel. Reboot the SUT into it, then rerun this scenario to continue."
}

# Serve one variant: ensure the kernel, announce it, then run until the
# coordinator signals it is done. Args: <variant: bad|good>
function scenario:run_variant() {
    # repro.sh passes step arguments as `--"<args>"`, so the leading -- arrives
    # attached to the first word (see scenario:help). Strip it.
    local variant="${1#--}"
    scenario:require_variant "$variant"
    repro:run ${SCENARIO_WORKLOAD} SUT configure
    # repro:run always returns 0 (it ends with `cd $saved_cwd`), so check the
    # outcome: never announce a variant this SUT cannot actually serve.
    (exec 3<>/dev/tcp/127.0.0.1/${MEMCACHED_PORT}) 2>/dev/null || \
        repro:fatal "memcached is not accepting connections on port ${MEMCACHED_PORT} for variant '$variant'."
    repro:info "Signalling the coordinator: '$variant' is ready"
    repro:wait_for_ldg "STEP" "$variant"
    WORKLOAD_RUN_LABEL="${variant}" repro:run ${SCENARIO_WORKLOAD} SUT run cleanup
}

# The SUT owns the sequence because only it can change kernels, by reboot + rerun.
# repro:persistent_steps records each completed step so the rerun resumes.
function scenario:run:sut() {
    {
        echo "scenario:install:sut"
        local variant
        for variant in ${SCENARIO_VARIANTS}; do
            echo "scenario:run_variant ${variant}"
        done
        echo 'repro:wait_for_ldg "STEP" "DONE"'
    } | repro:persistent_steps "${SCENARIO_NAME}"
}

# One pass per variant: the agent role returns on each DONE broadcast, which the
# coordinator sends per variant.
function scenario:run:loadgen() {
    # repro:wait_for_ldg has no dry-run guard of its own, so it would block in
    # `nc -l` and a dry run could never finish.
    $REPROCFG_DYRUN && { repro:info "[dry-run] agent: would install, then serve each variant"; return 0; }
    local variant
    for variant in ${SCENARIO_VARIANTS}; do
        repro:run ${SCENARIO_WORKLOAD} LDG run
    done
}

# The coordinator measures whichever variant the SUT reports, because only the SUT
# knows which kernel actually booted. Its label names the results file.
function scenario:run:support() {
    mkdir -p "${SCENARIO_RESULTS_PATH}"
    local tag
    while :; do
        tag=$(repro:wait_for_sut "STEP")
        [ "${tag:-DONE}" = DONE ] && break
        repro:info "Measuring '${tag}'"
        WORKLOAD_RESULTS_FILE="${SCENARIO_RESULTS_PATH}/results-${tag}.json" \
            WORKLOAD_RUN_LABEL="${tag}" \
            repro:run ${SCENARIO_WORKLOAD} SUP configure run results cleanup
    done
}

function scenario:results:support() {
    pushd "${SCENARIO_RESULTS_PATH}"
    repro:cmd "${SCENARIO_PATH}/report.py" results-bad.json results-good.json
    popd
}
