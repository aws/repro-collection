# fake_aws.bash - shared Bats helper: fake `aws` CLI + script runner.
#
# Shadows the real AWS CLI with a deterministic fake placed first on PATH so
# the scripts under test never reach AWS. Behaviour is driven by FAKE_* env
# vars passed per test. Provides:
#   make_fake_aws   - build the fake `aws` binary (call from setup_file)
#   run_script      - run a script under `env -i` isolation; sets RC/OUTPUT/OPLOG
#   get_arg <opt>   - print the argv token following <opt> in the captured
#                     `ec2 run-instances` call
#
# Usage in a .bats file:
#   load '../helpers/fake_aws'
#   setup_file() { make_fake_aws; }
#   setup()      { fake_aws_reset; }

make_fake_aws() {
    export FAKEBIN="${BATS_FILE_TMPDIR}/bin"
    mkdir -p "${FAKEBIN}"
    cat > "${FAKEBIN}/aws" <<'FAKE'
#!/usr/bin/env bash
# Minimal deterministic stand-in for the AWS CLI.
args=("$@"); n=${#args[@]}
service=""; op=""
for ((i=0; i<n; i++)); do
    case "${args[i]}" in
        ec2|sts|configure) service="${args[i]}"; op="${args[i+1]:-}"; break ;;
    esac
done
echo "${service} ${op}" >> "${AWS_OPLOG:-/dev/null}"

# Record the --region/--profile the aws_cli wrapper injected, so a test can
# assert the flags are actually passed (regression guard for wrong account).
for ((i=0; i<n; i++)); do
    case "${args[i]}" in
        --region)  echo "region ${args[i+1]:-}"  >> "${AWS_FLAGLOG:-/dev/null}" ;;
        --profile) echo "profile ${args[i+1]:-}" >> "${AWS_FLAGLOG:-/dev/null}" ;;
    esac
done

case "${service} ${op}" in
    "configure get")
        printf '%s\n' "${FAKE_REGION:-}" ;;
    "sts get-caller-identity")
        printf '%s\n' "${FAKE_ARN:-arn:fake}" ;;
    "ec2 describe-images")
        # Two uses: alias resolution (--owners/--filters -> ImageId) and the
        # root-device lookup (--image-ids <ami> -> RootDeviceName).
        _by_ids=0
        for a in "${args[@]}"; do
            case "$a" in --image-ids) _by_ids=1 ;; esac
        done
        if [ "${_by_ids}" = "1" ]; then
            printf '%s\n' "${FAKE_ROOT_DEVICE:-/dev/xvda}"
        else
            printf '%s\n' "${FAKE_AMI:-ami-fake}"
        fi ;;
    "ec2 describe-vpcs")
        printf '%s\n' "${FAKE_VPC:-vpc-fake}" ;;
    "ec2 describe-subnets")
        # Two uses: resolve a provided subnet's VPC (--subnet-ids ... -> VpcId),
        # or discover a subnet in a VPC (--filters vpc-id ... -> SubnetId).
        _by_id=0
        for a in "${args[@]}"; do
            case "$a" in --subnet-ids) _by_id=1 ;; esac
        done
        if [ "${_by_id}" = "1" ]; then
            printf '%s\n' "${FAKE_SUBNET_VPC:-vpc-fromsubnet}"
        else
            printf '%s\n' "${FAKE_SUBNET:-subnet-fake}"
        fi ;;
    "ec2 describe-security-groups")
        printf '%s\n' "${FAKE_SG:-sg-fake}" ;;
    "ec2 run-instances")
        : > "${AWS_CAPTURE:-/dev/null}"
        for a in "${args[@]}"; do printf '%s\0' "$a" >> "${AWS_CAPTURE:-/dev/null}"; done
        for a in "${args[@]}"; do
            if [ "$a" = "--dry-run" ]; then
                # FAKE_DRYRUN_ERROR simulates a real EC2 rejection (e.g. an
                # authorization failure) instead of the DryRunOperation success.
                if [ -n "${FAKE_DRYRUN_ERROR:-}" ]; then
                    echo "An error occurred (${FAKE_DRYRUN_ERROR}) when calling the RunInstances operation: not authorized." >&2
                else
                    echo "An error occurred (DryRunOperation) when calling the RunInstances operation: Request would have succeeded, but DryRun flag is set." >&2
                fi
                exit 254
            fi
        done
        printf '%s\n' "${FAKE_INSTANCE_ID:-i-fake}" ;;
    "ec2 wait")
        exit 0 ;;
    "ec2 describe-placement-groups")
        # Existing group -> its id; otherwise "None" (script then creates one).
        printf '%s\n' "${FAKE_PG_ID:-None}" ;;
    "ec2 create-placement-group")
        # Capture the full argv so a test can assert --strategy/--partition-count.
        : > "${PG_CREATE_CAPTURE:-/dev/null}"
        for a in "${args[@]}"; do printf '%s\0' "$a" >> "${PG_CREATE_CAPTURE:-/dev/null}"; done
        printf '%s\n' "${FAKE_PG_CREATE_ID:-pg-0newpg}" ;;
    "ec2 describe-instances")
        # FAKE_DESCRIBE_INSTANCES_FAIL simulates a transient post-launch failure
        # (throttling / eventual consistency) on the final summary describe.
        _is_pg_member=0
        for a in "${args[@]}"; do
            case "$a" in *placement-group-name*) _is_pg_member=1 ;; esac
        done
        if [ "${_is_pg_member}" = "1" ]; then
            printf '%s\n' "${FAKE_PG_MEMBER_SUBNET:-None}"
        else
            if [ -n "${FAKE_DESCRIBE_INSTANCES_FAIL:-}" ]; then
                echo "An error occurred (RequestLimitExceeded) when calling the DescribeInstances operation." >&2
                exit 255
            fi
            printf '%s\t%s\t%s\t%s\n' "${FAKE_STATE:-running}" "${FAKE_AZ:-az}" "${FAKE_PRIV:-10.0.0.1}" "${FAKE_PUB:-1.1.1.1}"
        fi ;;
    *)
        echo "fake-aws: unhandled command: ${service} ${op}" >&2; exit 1 ;;
esac
FAKE
    chmod +x "${FAKEBIN}/aws"
}

# Per-test capture files live in the test's own tmpdir.
fake_aws_reset() {
    export AWS_CAPTURE="${BATS_TEST_TMPDIR}/run_instances_args"
    export AWS_OPLOG="${BATS_TEST_TMPDIR}/oplog"
    export AWS_FLAGLOG="${BATS_TEST_TMPDIR}/flaglog"
    export PG_CREATE_CAPTURE="${BATS_TEST_TMPDIR}/pg_create_args"
    : > "${AWS_CAPTURE}"; : > "${AWS_OPLOG}"; : > "${AWS_FLAGLOG}"; : > "${PG_CREATE_CAPTURE}"
}

# run_script <script-path> KEY=VAL ... -> sets globals: RC, OUTPUT, OPLOG, FLAGLOG
run_script() {
    local script="$1"; shift
    RC=0
    OUTPUT="$(env -i \
        PATH="${FAKEBIN}:/usr/bin:/bin" \
        HOME="${HOME}" \
        AWS_CAPTURE="${AWS_CAPTURE}" \
        AWS_OPLOG="${AWS_OPLOG}" \
        AWS_FLAGLOG="${AWS_FLAGLOG}" \
        PG_CREATE_CAPTURE="${PG_CREATE_CAPTURE}" \
        RESOURCE_FILE="${BATS_TEST_TMPDIR}/resources.json" \
        FAKE_REGION="us-west-2" \
        FAKE_ARN="arn:aws:sts::123456789012:assumed-role/Test/session" \
        FAKE_AMI="ami-deadbeef" \
        FAKE_VPC="vpc-11111111" \
        FAKE_SUBNET="subnet-22222222" \
        FAKE_SG="sg-33333333" \
        FAKE_INSTANCE_ID="i-0abc123def456" \
        FAKE_STATE="running" \
        FAKE_AZ="us-west-2a" \
        FAKE_PRIV="10.0.0.5" \
        FAKE_PUB="52.10.20.30" \
        "$@" \
        bash "${script}" 2>&1)" || RC=$?
    OPLOG="$(cat "${AWS_OPLOG}" 2>/dev/null)"
    FLAGLOG="$(cat "${AWS_FLAGLOG}" 2>/dev/null)"
}

# get_arg <option> -> prints the argv token immediately following <option> in
# the captured run-instances call (e.g. get_arg --image-id).
get_arg() {
    local want="$1" prev="" a
    while IFS= read -r -d '' a; do
        [ "${prev}" = "${want}" ] && { printf '%s' "$a"; return 0; }
        prev="$a"
    done < "${AWS_CAPTURE}"
    return 1
}

# get_pg_create_arg <option> -> like get_arg but over the captured
# create-placement-group call.
get_pg_create_arg() {
    local want="$1" prev="" a
    while IFS= read -r -d '' a; do
        [ "${prev}" = "${want}" ] && { printf '%s' "$a"; return 0; }
        prev="$a"
    done < "${PG_CREATE_CAPTURE}"
    return 1
}

# pg_create_argv -> the full create-placement-group argv as a space-joined
# string (for substring assertions).
pg_create_argv() { tr '\0' ' ' < "${PG_CREATE_CAPTURE}" 2>/dev/null; }
