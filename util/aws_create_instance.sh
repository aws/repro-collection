#!/usr/bin/env bash
#
# Launch an EC2 instance for repro/benchmark work. Configured entirely by
# environment variables; AMI, subnet and security group are discovered from the
# target account when not given.
#
# Example:
#   AWS_PROFILE=database AWS_REGION=us-west-2 INSTANCE_TYPE=m8g.2xlarge \
#   EBS_DISKS_NUMBER=12 EBS_DISKS_SIZE=1024 EBS_DISKS_TYPE=IO2 EBS_DISKS_IOPS=32000 \
#   KEYPAIR="mykey" AMI=AL2023_K6.12 EXPNAME=test1 \
#   util/aws_create_instance.sh
#
# Required:
#   INSTANCE_TYPE       EC2 instance type, e.g. m8g.2xlarge
#   KEYPAIR             EC2 key pair to attach (SSH login)
#   EXPNAME             Experiment name, used in the instance Name tag
#
# AMI:
#   AMI                 An "ami-..." id, or an alias: AL2023_K6.12 AL2023_K6.1
#                       AL2023 UBUNTU2404 UBUNTU2204 UBUNTU2004 (default: latest
#                       AL2023 for the arch). The alias also picks LOGIN_USER.
#   AMI_NAME_FILTER     describe-images "Name" pattern, for distros/kernels with
#                       no alias; overrides the alias table (newest match wins)
#   AMI_OWNER           AMI owner for the search (default 137112412989, AL2023)
#   LOGIN_USER          SSH login user (default ec2-user; Ubuntu aliases: ubuntu)
#
# Disks:
#   EBS_DISKS_NUMBER    extra data volumes, 0..25 (default 0)
#   EBS_DISKS_SIZE      GiB per data volume (default 1024)
#   EBS_DISKS_TYPE      gp3 | gp2 | io1 | io2 | st1 | sc1 (default gp3)
#   EBS_DISKS_IOPS      io1/io2/gp3 only (default 3000 gp3, 16000 io*)
#   EBS_DISKS_THROUGHPUT  gp3 only, MiB/s
#   ROOT_DISK_SIZE      GiB (default 256)
#   ROOT_DISK_TYPE      default gp3
#   ROOT_DISK_IOPS      default 16000 for an io1/io2 root
#
# Networking / placement (discovered from the default VPC if unset):
#   AWS_REGION          falls back to the profile/default config
#   AWS_PROFILE         AWS CLI profile
#   SUBNET_ID           default: a random available subnet of the default VPC
#   SG_ID               default: the default SG of the subnet's VPC. That SG
#                       normally has no tcp/22 ingress, so set SG_ID explicitly
#                       if you need to SSH in.
#   TENANCY             default | dedicated | host (default dedicated). Burstable
#                       types (t2/t3/t4g) are shared-tenancy only and need
#                       TENANCY=default; host tenancy cannot use a placement group.
#   ARCH                arm64 | x86_64 (default: inferred from INSTANCE_TYPE)
#   ASSOCIATE_PUBLIC_IP true | false (default false)
#   PLACEMENT_GROUP_NAME  launch into this group, creating it if missing. A cluster
#                       group pins all members to one subnet/AZ, so the subnet is
#                       reused from the resource file when known.
#   PLACEMENT_GROUP_STRATEGY  cluster | partition | spread (default cluster)
#   PLACEMENT_GROUP_PARTITION_COUNT  default 2
#
# Other:
#   OWNER_TAG           Owner tag value (default: whoami)
#   SAVE_RESOURCES      record the instance (id, type, subnet/AZ, IPs, placement
#                       group) as a flat KEY=value file (default true)
#   RESOURCE_FILE       default ${SCENARIO_RESULTS_PATH}/${EXPNAME}.resources.env
#   CLONE_REPO          clone repro-collection at boot (default true)
#   REPO_URL            default https://github.com/aws/repro-collection.git; must
#                       be anonymously clonable (the instance has no credentials)
#   REPO_DEST_NAME      clone dir under ~ (default repro-collection)
#   REPO_BRANCH         branch/tag to check out (default: the repo default)
#   REPROCFG_DYRUN=true validate the run-instances call without creating anything
#   NO_WAIT=true        do not wait for the instance to reach "running"
#
set -euo pipefail

# The framework runs commands that trip errexit/nounset at source time, and wires
# logging to a dedicated fd, so it must be sourced with stdout intact.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set +eu
. "${_SELF_DIR}/../repro.sh" --init-only 2>/dev/null
set -eu
command -v repro:fatal >/dev/null 2>&1 || {
    printf '\033[31m[ERROR]\033[0m Could not load the Repro Framework (%s)\n' \
        "${_SELF_DIR}/../repro.sh" >&2
    exit 1
}

# Injects --region/--profile only when set, and never uses a pager.
aws_cli() {
    local extra=()
    [ -n "${AWS_REGION:-}"  ] && extra+=(--region  "${AWS_REGION}")
    [ -n "${AWS_PROFILE:-}" ] && extra+=(--profile "${AWS_PROFILE}")
    command aws "${extra[@]}" --no-cli-pager "$@"
}

# args: <value> <error message>  - "None" is what `--output text` prints for a
# missing field, so it counts as empty.
require_aws_value() {
    [ -n "$1" ] && [ "$1" != "None" ] || repro:fatal "$2"
}

# Resource tracking uses flat `KEY=value` shell assignments, like the framework's
# repro:set_persistent_var: no jq needed and the file can be sourced directly.
res_get() { repro:resource:get "${RESOURCE_FILE}" "$1"; }
res_set() {
    [ "${SAVE_RESOURCES}" = "true" ] || return 0
    repro:resource:set "${RESOURCE_FILE}" "$1" "$2"
}

# Print the header comment block, i.e. everything up to the first code line.
usage() {
    local line
    while IFS= read -r line; do
        case "${line}" in
            '#!'*) continue ;;
            '#') printf '\n' ;;
            '# '*) printf '%s\n' "${line#\# }" ;;
            '#'*)  printf '%s\n' "${line#\#}" ;;
            *) break ;;
        esac
    done < "$0"
}
case "${1:-}" in
    "")        ;;
    -h|--help) usage; exit 0 ;;
    *)         repro:fatal "Unexpected argument '$1'. This script is configured via environment variables; run --help." ;;
esac

command -v aws >/dev/null 2>&1 || repro:fatal "aws CLI not found in PATH"

: "${INSTANCE_TYPE:?Set INSTANCE_TYPE (e.g. m8g.2xlarge)}"
: "${KEYPAIR:?Set KEYPAIR (EC2 key pair name)}"
: "${EXPNAME:?Set EXPNAME (experiment name used in the Name tag)}"

: "${EBS_DISKS_NUMBER:=0}"
: "${EBS_DISKS_SIZE:=1024}"
: "${EBS_DISKS_TYPE:=gp3}"
: "${EBS_DISKS_IOPS:=}"
: "${EBS_DISKS_THROUGHPUT:=}"
: "${ROOT_DISK_SIZE:=256}"
: "${ROOT_DISK_TYPE:=gp3}"
: "${ROOT_DISK_IOPS:=}"
: "${TENANCY:=dedicated}"
: "${ASSOCIATE_PUBLIC_IP:=false}"
: "${OWNER_TAG:=$(whoami)}"
: "${CLONE_REPO:=true}"
: "${REPO_URL:=https://github.com/aws/repro-collection.git}"
: "${REPO_DEST_NAME:=repro-collection}"
: "${REPO_BRANCH:=}"
: "${PLACEMENT_GROUP_NAME:=}"
: "${PLACEMENT_GROUP_STRATEGY:=cluster}"
: "${PLACEMENT_GROUP_PARTITION_COUNT:=2}"
: "${SAVE_RESOURCES:=true}"
: "${RESOURCE_FILE:=${SCENARIO_RESULTS_PATH%/}/${EXPNAME}.resources.env}"

# Data disks are named /dev/sdb../dev/sdz, hence at most 25.
[[ "${EBS_DISKS_NUMBER}" =~ ^[0-9]+$ ]] && [ "${EBS_DISKS_NUMBER}" -le 25 ] \
    || repro:fatal "EBS_DISKS_NUMBER must be an integer 0..25 (device names /dev/sdb../dev/sdz), got '${EBS_DISKS_NUMBER}'"

case "${ASSOCIATE_PUBLIC_IP}" in true|false) ;; *) repro:fatal "ASSOCIATE_PUBLIC_IP must be 'true' or 'false', got '${ASSOCIATE_PUBLIC_IP}'" ;; esac

# The disk sizes go unquoted into the block-device JSON, so a non-numeric value
# would corrupt the request.
require_int()  { [[ "$2" =~ ^[0-9]+$ ]]     || repro:fatal "$1 must be a non-negative integer, got '$2'"; }
optional_int() { [ -z "$2" ] || [[ "$2" =~ ^[0-9]+$ ]] || repro:fatal "$1 must be a non-negative integer when set, got '$2'"; }
require_int  EBS_DISKS_SIZE       "${EBS_DISKS_SIZE}"
require_int  ROOT_DISK_SIZE       "${ROOT_DISK_SIZE}"
optional_int EBS_DISKS_IOPS       "${EBS_DISKS_IOPS}"
optional_int EBS_DISKS_THROUGHPUT "${EBS_DISKS_THROUGHPUT}"
optional_int ROOT_DISK_IOPS       "${ROOT_DISK_IOPS}"

# EXPNAME feeds a tag and the RESOURCE_FILE path; OWNER_TAG and
# PLACEMENT_GROUP_NAME feed the tag/placement shorthand strings. Restrict all
# three so a value cannot inject extra keys or path separators. (Keep the
# space-allowing OWNER_TAG pattern in a variable: an inline regex with a literal
# space is mis-tokenized by [[ =~ ]].)
[[ "${EXPNAME}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || repro:fatal "EXPNAME must match ^[A-Za-z0-9._-]+$ (used in a tag and a file path), got '${EXPNAME}'"
_owner_re='^[A-Za-z0-9._@ -]+$'
[[ "${OWNER_TAG}" =~ $_owner_re ]] \
    || repro:fatal "OWNER_TAG may contain only letters, digits, space, and . _ @ - ; got '${OWNER_TAG}'"
if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
    [[ "${PLACEMENT_GROUP_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] \
        || repro:fatal "PLACEMENT_GROUP_NAME must match ^[A-Za-z0-9._-]+$, got '${PLACEMENT_GROUP_NAME}'"
    case "${PLACEMENT_GROUP_STRATEGY}" in cluster|partition|spread) ;; *) repro:fatal "Invalid PLACEMENT_GROUP_STRATEGY='${PLACEMENT_GROUP_STRATEGY}'. Use one of: cluster partition spread" ;; esac
fi

# SUBNET_ID/SG_ID go verbatim into the network-interface JSON.
[ -z "${SUBNET_ID:-}" ] || [[ "${SUBNET_ID}" =~ ^subnet-[0-9a-f]+$ ]] \
    || repro:fatal "SUBNET_ID must look like 'subnet-...', got '${SUBNET_ID}'"
[ -z "${SG_ID:-}" ] || [[ "${SG_ID}" =~ ^sg-[0-9a-f]+$ ]] \
    || repro:fatal "SG_ID must look like 'sg-...', got '${SG_ID}'"

# REPO_* are interpolated into user-data that runs as root on the instance.
if [ "${CLONE_REPO}" = "true" ]; then
    [[ "${REPO_URL}" =~ ^[A-Za-z0-9._:/@+-]+$ ]] \
        || repro:fatal "REPO_URL contains characters not allowed in boot user-data: '${REPO_URL}'"
    { [[ "${REPO_DEST_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] && [ "${REPO_DEST_NAME}" != "." ] && [ "${REPO_DEST_NAME}" != ".." ]; } \
        || repro:fatal "REPO_DEST_NAME must match ^[A-Za-z0-9._-]+$ and not be '.' or '..' (no path traversal), got '${REPO_DEST_NAME}'"
    if [ -n "${REPO_BRANCH}" ]; then
        [[ "${REPO_BRANCH}" =~ ^[A-Za-z0-9._/-]+$ ]] \
            || repro:fatal "REPO_BRANCH must match ^[A-Za-z0-9._/-]+$, got '${REPO_BRANCH}'"
    fi
fi

# Accept IO2, io2, GP3, ... for the API.
EBS_DISKS_TYPE="$(printf '%s' "${EBS_DISKS_TYPE}" | tr '[:upper:]' '[:lower:]')"
ROOT_DISK_TYPE="$(printf '%s' "${ROOT_DISK_TYPE}" | tr '[:upper:]' '[:lower:]')"

# Normalize Iops/Throughput per volume type once, so ebs_json can emit fields
# purely on non-emptiness.
case "${EBS_DISKS_TYPE}" in
    io1|io2)
        EBS_DISKS_IOPS="${EBS_DISKS_IOPS:-16000}"
        [ -n "${EBS_DISKS_THROUGHPUT}" ] && { repro:warn "EBS_DISKS_THROUGHPUT applies only to gp3; ignoring for ${EBS_DISKS_TYPE}"; EBS_DISKS_THROUGHPUT=""; } ;;
    gp3)
        EBS_DISKS_IOPS="${EBS_DISKS_IOPS:-3000}" ;;
    *)
        [ -n "${EBS_DISKS_IOPS}" ] && repro:warn "EBS_DISKS_IOPS does not apply to ${EBS_DISKS_TYPE}; ignoring it"
        EBS_DISKS_IOPS=""
        [ -n "${EBS_DISKS_THROUGHPUT}" ] && { repro:warn "EBS_DISKS_THROUGHPUT applies only to gp3; ignoring for ${EBS_DISKS_TYPE}"; EBS_DISKS_THROUGHPUT=""; } ;;
esac
case "${ROOT_DISK_TYPE}" in
    io1|io2)
        # io1 caps at 50 IOPS/GiB, so a default-size io1 root would fail the ratio check.
        if [ -z "${ROOT_DISK_IOPS}" ]; then
            ROOT_DISK_IOPS=16000
            [ "${ROOT_DISK_TYPE}" = "io1" ] && [ $(( 50 * ROOT_DISK_SIZE )) -lt "${ROOT_DISK_IOPS}" ] \
                && ROOT_DISK_IOPS=$(( 50 * ROOT_DISK_SIZE ))
        fi ;;
    gp3) ;;   # optional Iops; keep a user-supplied value, no default
    *)
        [ -n "${ROOT_DISK_IOPS}" ] && repro:warn "ROOT_DISK_IOPS does not apply to ${ROOT_DISK_TYPE}; ignoring it"
        ROOT_DISK_IOPS="" ;;
esac

INSTANCE_FAMILY="${INSTANCE_TYPE%%.*}"
# Graviton families end in 'g' before the size (m8g, r8g, c7g, i4g, ...).
if [ -z "${ARCH:-}" ]; then
    [[ "${INSTANCE_FAMILY}" =~ g[a-z]*$ ]] && ARCH="arm64" || ARCH="x86_64"
fi
repro:info "Architecture: ${ARCH} (instance type ${INSTANCE_TYPE})"

# EC2 only runs burstable types on shared hardware, so the default
# TENANCY=dedicated would have the launch rejected.
if [ "${TENANCY}" != "default" ] && [[ "${INSTANCE_FAMILY}" =~ ^t[0-9] ]]; then
    repro:warn "Burstable instance type '${INSTANCE_TYPE}' does not support Tenancy=${TENANCY}; EC2 only runs t2/t3/t4g on shared hardware. Set TENANCY=default for this type."
fi

if [ -z "${AWS_REGION:-}" ]; then
    AWS_REGION="$(command aws configure get region ${AWS_PROFILE:+--profile "$AWS_PROFILE"} 2>/dev/null || true)"
fi
[ -n "${AWS_REGION:-}" ] || repro:fatal "AWS_REGION is not set and no default region is configured"

repro:info "Verifying credentials ..."
CALLER_ARN="$(aws_cli sts get-caller-identity --query 'Arn' --output text)" \
    || repro:fatal "Unable to authenticate with AWS (profile='${AWS_PROFILE:-default}', region='${AWS_REGION}')"
repro:info "Authenticated as: ${CALLER_ARN}"

# Each alias owns its login user, so a new distro only needs a case here. Root
# device names differ per AMI (AL2023 /dev/xvda, Ubuntu /dev/sda1) and the wrong
# one makes EC2 attach an extra volume, so it is read from the AMI itself.
resolve_ami() {
    local alias="$1" owners filter
    LOGIN_USER="${LOGIN_USER:-ec2-user}"
    case "${alias}" in
        # A raw id: no name search, so ROOT_DEVICE is read separately below.
        ami-*) AMI_ID="${alias}"; ROOT_DEVICE=""; return 0 ;;
    esac
    if [ -n "${AMI_NAME_FILTER:-}" ]; then
        owners="${AMI_OWNER:-137112412989}"; filter="${AMI_NAME_FILTER}"
    else
        alias="${alias^^}"     # aliases are case-insensitive
        case "${alias}" in
            AL2023_K6.12)
                owners="137112412989"; filter="al2023-ami-2023*-kernel-6.12-*" ;;
            AL2023_K6.1)
                owners="137112412989"; filter="al2023-ami-2023*-kernel-6.1-*" ;;
            AL2023|"")
                owners="137112412989"; filter="al2023-ami-2023*-kernel-*" ;;
            UBUNTU2404)
                owners="099720109477"; filter="ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-*-server-*"; LOGIN_USER="ubuntu" ;;
            UBUNTU2204)
                owners="099720109477"; filter="ubuntu/images/hvm-ssd*/ubuntu-jammy-22.04-*-server-*"; LOGIN_USER="ubuntu" ;;
            UBUNTU2004)
                owners="099720109477"; filter="ubuntu/images/hvm-ssd/ubuntu-focal-20.04-*-server-*"; LOGIN_USER="ubuntu" ;;
            *)
                repro:fatal "Unknown AMI alias '$1'. Use an ami-... id, one of: AL2023_K6.12 AL2023_K6.1 AL2023 UBUNTU2404 UBUNTU2204 UBUNTU2004, or set AMI_NAME_FILTER (+ optional AMI_OWNER)" ;;
        esac
        [ -n "${AMI_OWNER:-}" ] && owners="${AMI_OWNER}"
    fi

    repro:info "Resolving AMI: filter='${filter}' owners='${owners}' arch='${ARCH}'"
    read -r AMI_ID ROOT_DEVICE < <(aws_cli ec2 describe-images \
        --owners ${owners} \
        --filters "Name=name,Values=${filter}" \
                  "Name=architecture,Values=${ARCH}" \
                  "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].[ImageId,RootDeviceName]' \
        --output text)
    require_aws_value "${AMI_ID}" "No AMI found for '$1' (filter '${filter}', arch ${ARCH}) in ${AWS_REGION}"
}
resolve_ami "${AMI:-}"
repro:info "AMI: ${AMI_ID} (login user ${LOGIN_USER})"

if [ -z "${ROOT_DEVICE}" ] || [ "${ROOT_DEVICE}" = "None" ]; then
    ROOT_DEVICE="$(aws_cli ec2 describe-images --image-ids "${AMI_ID}" \
        --query 'Images[0].RootDeviceName' --output text 2>/dev/null || true)"
fi
if [ -z "${ROOT_DEVICE}" ] || [ "${ROOT_DEVICE}" = "None" ]; then
    repro:warn "Could not read RootDeviceName of ${AMI_ID}; assuming /dev/xvda"
    ROOT_DEVICE="/dev/xvda"
fi
repro:info "Root device: ${ROOT_DEVICE}"

# Placement group: create it if missing and, for a cluster group, keep every
# member in one subnet/AZ. The subnet comes from, in order: an explicit
# SUBNET_ID, the AZ of instances already in the group, the subnet recorded in the
# resource file, or the discovery below (recorded afterwards).
PG_GROUP_ID=""
PG_CREATED="false"
PG_DRYRUN_MISSING="false"  # true when the dry run skipped creating a missing group
if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
    PG_GROUP_ID="$(aws_cli ec2 describe-placement-groups \
        --filters "Name=group-name,Values=${PLACEMENT_GROUP_NAME}" \
        --query 'PlacementGroups[0].GroupId' --output text 2>/dev/null || true)"

    if [ -z "${PG_GROUP_ID}" ] || [ "${PG_GROUP_ID}" = "None" ]; then
        if [ "${REPROCFG_DYRUN}" = "true" ]; then
            repro:info "REPROCFG_DYRUN=true: placement group '${PLACEMENT_GROUP_NAME}' does not exist and would be created (${PLACEMENT_GROUP_STRATEGY}); skipping creation"
            PG_GROUP_ID=""
            PG_DRYRUN_MISSING="true"
        else
            repro:info "Placement group '${PLACEMENT_GROUP_NAME}' not found; creating (${PLACEMENT_GROUP_STRATEGY}) ..."
            _pg_create=(ec2 create-placement-group
                --group-name "${PLACEMENT_GROUP_NAME}"
                --strategy "${PLACEMENT_GROUP_STRATEGY}"
                --tag-specifications "ResourceType=placement-group,Tags=[{Key=Name,Value=${PLACEMENT_GROUP_NAME}},{Key=Owner,Value=${OWNER_TAG}}]")
            [ "${PLACEMENT_GROUP_STRATEGY}" = "partition" ] \
                && _pg_create+=(--partition-count "${PLACEMENT_GROUP_PARTITION_COUNT}")
            PG_GROUP_ID="$(aws_cli "${_pg_create[@]}" \
                --query 'PlacementGroup.GroupId' --output text)"
            require_aws_value "${PG_GROUP_ID}" "Failed to create placement group '${PLACEMENT_GROUP_NAME}'"
            repro:info "Created placement group '${PLACEMENT_GROUP_NAME}' (${PG_GROUP_ID})"
            PG_CREATED="true"
        fi
    else
        repro:info "Placement group '${PLACEMENT_GROUP_NAME}' exists (${PG_GROUP_ID}); reusing"
    fi

    PG_MEMBER_SUBNET="$(aws_cli ec2 describe-instances \
        --filters "Name=placement-group-name,Values=${PLACEMENT_GROUP_NAME}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].SubnetId' --output text 2>/dev/null || true)"
    [ "${PG_MEMBER_SUBNET}" = "None" ] && PG_MEMBER_SUBNET=""

    if [ -z "${SUBNET_ID:-}" ]; then
        if [ -n "${PG_MEMBER_SUBNET}" ]; then
            SUBNET_ID="${PG_MEMBER_SUBNET}"
            repro:info "Reusing subnet ${SUBNET_ID} from existing members of '${PLACEMENT_GROUP_NAME}'"
        else
            _pg_subnet="$(res_get PLACEMENT_GROUP_SUBNET)"
            _pg_az="$(res_get PLACEMENT_GROUP_AZ)"
            _rec_region="$(res_get REGION)"
            # A subnet recorded in another region is useless in this one.
            if [ -n "${_pg_subnet}" ] && [ -n "${_rec_region}" ] && [ "${_rec_region}" != "${AWS_REGION}" ]; then
                repro:warn "Resource file ${RESOURCE_FILE} was recorded in region ${_rec_region}, not ${AWS_REGION}; ignoring its recorded subnet ${_pg_subnet}"
                _pg_subnet=""
            fi
            if [ -n "${_pg_subnet}" ]; then
                SUBNET_ID="${_pg_subnet}"
                repro:info "Reusing subnet ${SUBNET_ID}${_pg_az:+ (AZ ${_pg_az})} recorded for placement group '${PLACEMENT_GROUP_NAME}'"
            else
                repro:info "No subnet recorded yet for '${PLACEMENT_GROUP_NAME}'; the chosen subnet/AZ will be recorded for follow-up launches"
            fi
        fi
    elif [ -n "${PG_MEMBER_SUBNET}" ] && [ "${SUBNET_ID}" != "${PG_MEMBER_SUBNET}" ]; then
        repro:warn "SUBNET_ID=${SUBNET_ID} differs from existing members' subnet ${PG_MEMBER_SUBNET} of '${PLACEMENT_GROUP_NAME}'; a cluster group requires one AZ and the launch may fail"
    fi
fi

# A given SUBNET_ID resolves the VPC (and hence its default SG) even where there
# is no default VPC.
VPC_ID=""
get_vpc() {
    [ -n "${VPC_ID}" ] && return 0
    if [ -n "${SUBNET_ID:-}" ]; then
        VPC_ID="$(aws_cli ec2 describe-subnets \
            --subnet-ids "${SUBNET_ID}" \
            --query 'Subnets[0].VpcId' --output text 2>/dev/null || true)"
        require_aws_value "${VPC_ID}" "Could not resolve VPC for SUBNET_ID=${SUBNET_ID} (check the id and region ${AWS_REGION})"
        return 0
    fi
    VPC_ID="$(aws_cli ec2 describe-vpcs \
        --filters "Name=isDefault,Values=true" \
        --query 'Vpcs[0].VpcId' --output text)"
    require_aws_value "${VPC_ID}" "No default VPC in ${AWS_REGION}; set SUBNET_ID (and optionally SG_ID) explicitly"
}

if [ -z "${SUBNET_ID:-}" ]; then
    get_vpc
    # Random subnet: spreading across AZs avoids repeatedly landing on one AZ
    # that may not offer the requested instance type.
    mapfile -t _subnets < <(aws_cli ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
        --query 'Subnets[].SubnetId' --output text | tr '\t' '\n' | grep -v '^$')
    [ "${#_subnets[@]}" -gt 0 ] \
        || repro:fatal "No available subnet found in default VPC ${VPC_ID}"
    SUBNET_ID="${_subnets[$(( RANDOM % ${#_subnets[@]} ))]}"
    repro:info "Discovered subnet: ${SUBNET_ID} (random of ${#_subnets[@]} in default VPC ${VPC_ID})"
else
    repro:info "Using provided subnet: ${SUBNET_ID}"
fi

SG_IS_DEFAULT="false"
if [ -z "${SG_ID:-}" ]; then
    get_vpc
    SG_ID="$(aws_cli ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
        --query 'SecurityGroups[0].GroupId' --output text)"
    require_aws_value "${SG_ID}" "No default security group found in VPC ${VPC_ID}"
    SG_IS_DEFAULT="true"
    repro:info "Discovered security group: ${SG_ID} (default SG of ${VPC_ID})"
    repro:warn "Using the VPC default SG (${SG_ID}), which normally allows inbound traffic only from itself: SSH to the instance will not work unless it has tcp/22 ingress. Set SG_ID to a group that permits SSH if you need to log in."
else
    repro:info "Using provided security group: ${SG_ID}"
fi

# args: <device> <size> <type> <iops> <throughput>  - Iops/Throughput were
# normalized per type above, so non-empty simply means "emit the field".
ebs_json() {
    local device="$1" size="$2" type="$3" iops="$4" throughput="$5"
    local ebs="\"VolumeSize\":${size},\"VolumeType\":\"${type}\",\"DeleteOnTermination\":true"
    [ -n "${iops}" ]       && ebs="${ebs},\"Iops\":${iops}"
    [ -n "${throughput}" ] && ebs="${ebs},\"Throughput\":${throughput}"
    printf '{"DeviceName":"%s","Ebs":{%s}}' "${device}" "${ebs}"
}

DISK_LETTERS="bcdefghijklmnopqrstuvwxyz"
BDM="[$(ebs_json "${ROOT_DEVICE}" "${ROOT_DISK_SIZE}" "${ROOT_DISK_TYPE}" "${ROOT_DISK_IOPS}" "")"
for (( i = 0; i < EBS_DISKS_NUMBER; i++ )); do
    dev="/dev/sd${DISK_LETTERS:i:1}"
    BDM="${BDM},$(ebs_json "${dev}" "${EBS_DISKS_SIZE}" "${EBS_DISKS_TYPE}" "${EBS_DISKS_IOPS}" "${EBS_DISKS_THROUGHPUT}")"
done
BDM="${BDM}]"

NET_IFACE="[{\"DeviceIndex\":0,\"SubnetId\":\"${SUBNET_ID}\",\"Groups\":[\"${SG_ID}\"],\"AssociatePublicIpAddress\":${ASSOCIATE_PUBLIC_IP}}]"

USER_DATA="#!/bin/bash"

# Quoted heredoc: nothing here is expanded by this script, it runs on the instance.
USER_DATA="${USER_DATA}$(cat <<'EOF'

sudo systemctl disable --now snap.amazon-ssm-agent.amazon-ssm-agent || sudo systemctl disable --now amazon-ssm-agent
if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y git nmap-ncat tmux htop mdadm xfsprogs
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y && sudo apt-get install -y git netcat-openbsd tmux htop mdadm xfsprogs
fi
EOF
)"

# Only the REPO_* vars (allowlisted above) expand here; instance-side $_d and
# $(...) stay literal. The clone always fetches the default branch first, so a
# wrong REPO_BRANCH cannot leave the instance without the repo, and retries so a
# first-boot network hiccup does not either.
if [ "${CLONE_REPO}" = "true" ]; then
    CLONE_BLOCK="$(cat <<EOF

# --- Clone repro-collection into ${LOGIN_USER}'s home (user-data runs as root) ---
_d="/home/${LOGIN_USER}/${REPO_DEST_NAME}"
if [ ! -d "\$_d/.git" ]; then
  echo "[create_instance] cloning ${REPO_URL} -> \$_d"
  _cloned=false
  for _try in 1 2 3 4 5; do
    rm -rf "\$_d"
    if sudo -u ${LOGIN_USER} git clone -- '${REPO_URL}' "\$_d"; then _cloned=true; break; fi
    echo "[create_instance] git clone attempt \$_try failed; retrying in 15s ..."
    sleep 15
  done
  if \$_cloned; then
    if [ -n "${REPO_BRANCH}" ]; then
      sudo -u ${LOGIN_USER} git -C "\$_d" checkout '${REPO_BRANCH}' \
        || echo "[create_instance] WARNING: branch '${REPO_BRANCH}' not found on remote; staying on default branch"
    fi
  else
    echo "[create_instance] ERROR: git clone failed after retries"
  fi
fi
EOF
)"
    USER_DATA="${USER_DATA}${CLONE_BLOCK}"
    repro:info "Repo clone enabled: ${REPO_URL}${REPO_BRANCH:+ (branch ${REPO_BRANCH})} -> ~/${REPO_DEST_NAME}"
else
    repro:info "Repo clone disabled (CLONE_REPO=false)"
fi

INSTANCE_NAME="repro-${EXPNAME}-sut"
_tag_list="{Key=Name,Value=${INSTANCE_NAME}},{Key=Owner,Value=${OWNER_TAG}}"
TAGS="ResourceType=instance,Tags=[${_tag_list}]"

# Placement groups accept default and dedicated tenancy; only Dedicated Hosts cannot.
PLACEMENT="Tenancy=${TENANCY}"
if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
    [ "${TENANCY}" != "host" ] \
        || repro:warn "Placement group '${PLACEMENT_GROUP_NAME}' with Tenancy=host: EC2 does not allow Dedicated Hosts in placement groups; the launch will fail"
    if [ "${PG_DRYRUN_MISSING}" = "true" ]; then
        # Referencing the uncreated group would fail with a spurious not-found
        # error instead of validating the rest of the request.
        repro:info "REPROCFG_DYRUN=true: omitting GroupName=${PLACEMENT_GROUP_NAME} from the validated request (group not created)"
    else
        PLACEMENT="${PLACEMENT},GroupName=${PLACEMENT_GROUP_NAME}"
    fi
fi

# Shared by the launch plan and the final summary, so the two cannot drift.
if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
    if   [ "${PG_DRYRUN_MISSING}" = "true" ]; then _pg_state="would be created"
    elif [ "${PG_CREATED}" = "true" ];        then _pg_state="created"
    else                                           _pg_state="existing"; fi
    PG_DISPLAY="${PLACEMENT_GROUP_NAME} (${PLACEMENT_GROUP_STRATEGY}, ${_pg_state})"
else
    PG_DISPLAY="(none)"
fi
DATA_DISKS_DISPLAY="${EBS_DISKS_NUMBER} x ${EBS_DISKS_SIZE} GiB ${EBS_DISKS_TYPE}${EBS_DISKS_IOPS:+ (IOPS ${EBS_DISKS_IOPS})}"

cat >&2 <<SUMMARY

============================ Launch plan ============================
  Region / profile : ${AWS_REGION} / ${AWS_PROFILE:-default}
  Instance type    : ${INSTANCE_TYPE}  (arch ${ARCH})
  AMI              : ${AMI_ID}
  Key pair         : ${KEYPAIR}
  Tenancy          : ${TENANCY}
  Subnet / SG      : ${SUBNET_ID} / ${SG_ID}
  Placement group  : ${PG_DISPLAY}
  Public IP        : ${ASSOCIATE_PUBLIC_IP}
  Root disk        : ${ROOT_DISK_SIZE} GiB ${ROOT_DISK_TYPE} (${ROOT_DEVICE})
  Data disks       : ${DATA_DISKS_DISPLAY}
  Name tag         : ${INSTANCE_NAME}  (Owner=${OWNER_TAG})
  Clone repo       : $( [ "${CLONE_REPO}" = "true" ] && printf '%s -> ~/%s%s' "${REPO_URL}" "${REPO_DEST_NAME}" "${REPO_BRANCH:+ (${REPO_BRANCH})}" || printf 'no' )
====================================================================

SUMMARY

RUN_ARGS=(
    ec2 run-instances
    --image-id "${AMI_ID}"
    --instance-type "${INSTANCE_TYPE}"
    --key-name "${KEYPAIR}"
    --network-interfaces "${NET_IFACE}"
    --placement "${PLACEMENT}"
    --block-device-mappings "${BDM}"
    --user-data "${USER_DATA}"
    --tag-specifications "${TAGS}"
)

if [ "${REPROCFG_DYRUN}" = "true" ]; then
    repro:warn "REPROCFG_DYRUN=true: validating with EC2 --dry-run (no instance will be created)"
    _dryrun_out="$(mktemp)"
    if aws_cli "${RUN_ARGS[@]}" --dry-run 2>"${_dryrun_out}"; then
        repro:info "Dry run reported success"
    elif grep -q "DryRunOperation" "${_dryrun_out}"; then
        repro:info "Dry run OK: request is well-formed and authorized (DryRunOperation)"
    else
        cat "${_dryrun_out}" >&2
        rm -f "${_dryrun_out}"
        repro:fatal "Dry run failed"
    fi
    rm -f "${_dryrun_out}"
    repro:info "Block device mappings that would be used:"
    printf '%s\n' "${BDM}" >&2
    exit 0
fi

repro:info "Launching instance ..."
INSTANCE_ID="$(aws_cli "${RUN_ARGS[@]}" --query 'Instances[0].InstanceId' --output text)"
require_aws_value "${INSTANCE_ID}" "run-instances did not return an instance id"
repro:info "Launched: ${INSTANCE_ID}"

# Record the id before waiting/describing: if anything below fails, the running,
# billed instance must not be left untracked. Instances accumulate under an
# INSTANCE_<n>_* prefix so a follow-up run appends rather than overwrites.
if [ "${SAVE_RESOURCES}" = "true" ]; then
    INSTANCE_INDEX=$(( $(res_get INSTANCE_COUNT) + 1 ))    # res_get "" -> 0 + 1
    res_set EXPNAME "${EXPNAME}"
    res_set REGION  "${AWS_REGION}"
    [ -n "${AWS_PROFILE:-}" ] && res_set PROFILE "${AWS_PROFILE}"
    res_set INSTANCE_COUNT "${INSTANCE_INDEX}"
    res_set "INSTANCE_${INSTANCE_INDEX}_ID"    "${INSTANCE_ID}"
    res_set "INSTANCE_${INSTANCE_INDEX}_NAME"  "${INSTANCE_NAME}"
    res_set "INSTANCE_${INSTANCE_INDEX}_TYPE"  "${INSTANCE_TYPE}"
    res_set "INSTANCE_${INSTANCE_INDEX}_ARCH"  "${ARCH}"
    res_set "INSTANCE_${INSTANCE_INDEX}_AMI"   "${AMI_ID}"
    # So callers that ssh in need not re-derive it from the AMI alias.
    res_set "INSTANCE_${INSTANCE_INDEX}_LOGIN_USER" "${LOGIN_USER}"
    repro:info "Recorded instance id in ${RESOURCE_FILE}"
fi

if [ "${NO_WAIT:-false}" != "true" ]; then
    repro:info "Waiting for instance to reach 'running' ..."
    aws_cli ec2 wait instance-running --instance-ids "${INSTANCE_ID}" \
        || repro:warn "wait failed; the instance may still be initialising"
fi

# The instance is already running, so a failed describe only leaves these empty.
STATE="" AZ="" PRIV_IP="" PUB_IP=""
read -r STATE AZ PRIV_IP PUB_IP < <(aws_cli ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].[State.Name,Placement.AvailabilityZone,PrivateIpAddress,PublicIpAddress]' \
    --output text) \
    || repro:warn "describe-instances failed; instance details in the summary may be empty"

[ "${PUB_IP}" = "None" ] && PUB_IP=""
PUB_IP_DISPLAY="${PUB_IP:-(none)}"

if [ "${SAVE_RESOURCES}" = "true" ]; then
    res_set "INSTANCE_${INSTANCE_INDEX}_AZ"       "${AZ}"
    res_set "INSTANCE_${INSTANCE_INDEX}_SUBNET"   "${SUBNET_ID}"
    res_set "INSTANCE_${INSTANCE_INDEX}_SG"       "${SG_ID}"
    res_set "INSTANCE_${INSTANCE_INDEX}_PRIVATE_IP" "${PRIV_IP}"
    res_set "INSTANCE_${INSTANCE_INDEX}_PUBLIC_IP"  "${PUB_IP}"
    res_set "INSTANCE_${INSTANCE_INDEX}_PLACEMENT_GROUP" "${PLACEMENT_GROUP_NAME}"
    if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
        res_set PLACEMENT_GROUP_NAME     "${PLACEMENT_GROUP_NAME}"
        res_set PLACEMENT_GROUP_STRATEGY "${PLACEMENT_GROUP_STRATEGY}"
        [ -n "${PG_GROUP_ID}" ] && res_set PLACEMENT_GROUP_ID "${PG_GROUP_ID}"
        # Where the (cluster) group landed, for the next launch to reuse.
        res_set PLACEMENT_GROUP_SUBNET "${SUBNET_ID}"
        res_set PLACEMENT_GROUP_AZ     "${AZ}"
    fi
    repro:info "Recorded resources in ${RESOURCE_FILE}"
fi

cat <<SUMMARY

======================= Instance summary =======================
  Instance ID   : ${INSTANCE_ID}
  Name          : ${INSTANCE_NAME}
  State         : ${STATE}
  Type / arch   : ${INSTANCE_TYPE} / ${ARCH}
  AMI           : ${AMI_ID}
  Region / AZ   : ${AWS_REGION} / ${AZ}
  Subnet / SG   : ${SUBNET_ID} / ${SG_ID}
  Tenancy       : ${TENANCY}
  Placement grp : ${PG_DISPLAY}
  Private IP    : ${PRIV_IP}
  Public  IP    : ${PUB_IP_DISPLAY}
  Data disks    : ${DATA_DISKS_DISPLAY}
  Repo          : $( [ "${CLONE_REPO}" = "true" ] && printf '~/%s (%s)' "${REPO_DEST_NAME}" "${REPO_URL}" || printf 'not cloned' )
  Resource file : $( [ "${SAVE_RESOURCES}" = "true" ] && printf '%s' "${RESOURCE_FILE}" || printf 'disabled' )
================================================================

  SSH:  ssh ${LOGIN_USER}@${PUB_IP_DISPLAY}$( [ "${SG_IS_DEFAULT}" = "true" ] && printf '   (WARNING: SG %s is the VPC default and likely has no tcp/22 ingress; SSH may fail)' "${SG_ID}" )
  Tail cloud-init:  ssh ${LOGIN_USER}@${PUB_IP_DISPLAY} 'sudo tail -f /var/log/cloud-init-output.log'
  Terminate:  aws ${AWS_PROFILE:+--profile ${AWS_PROFILE}} --region ${AWS_REGION} ec2 terminate-instances --instance-ids ${INSTANCE_ID}

SUMMARY
