# Workload: repromain unit tests
# source this file, don't run it

# If we needed to define custom steps, this is how it would be done:
#function selftest:default_steps() {
#    repro:info Default steps for ${REPRO_MODE}
#    echo "install configure run results cleanup"
#}
# Absent explicit definition, the framework will detect which of the default steps are implemented and call them

# test configuration and global variables
# note that these variables are reset to the values below before each operation (install configure run etc)
SELFTEST_COUNT_PASS=0
SELFTEST_COUNT_FAIL=0
SELFTEST_FAIL_LIST=""

# this function need not be defined; it's here only as an example for creating a workload
function selftest:install() {
    repro:debug ${REPRO_MODE} install
    # do nothing
}

# this function need not be defined; it's here only as an example for creating a workload
function selftest:configure() {
    repro:debug ${REPRO_MODE} configure
    # do nothing
}

function selftest:run:sut() {
    repro:debug SUT run
    selftest:run_all_tests "$@" "${REPRO_NAME}:test:*"
}
function selftest:run:loadgen() {
    repro:debug Loadgen run
    selftest:run_all_tests "$@" "${REPRO_NAME}:test_ldg:*"
}
function selftest:run:support() {
    repro:debug Support run
    selftest:run_all_tests "$@" "${REPRO_NAME}:test_sup:*"
}

function selftest:results:sut() {
    repro:debug SUT results
    {
        # Since each operation (run, results, etc) is run in a subshell, we can't directly modify and pass variables from one step to another
        # Instead, we use the persistent variables feature to store the results across operations
        local pass=$(repro:get_persistent_var ${REPRO_NAME}_${REPRO_MODE} SELFTEST_COUNT_PASS 0)
        local fail=$(repro:get_persistent_var ${REPRO_NAME}_${REPRO_MODE} SELFTEST_COUNT_FAIL 0)
        local fail_list=$(repro:get_persistent_var ${REPRO_NAME}_${REPRO_MODE} SELFTEST_FAIL_LIST "")

        local score=0 total=$((pass + fail))
        [ $total -gt 0 ] && score=$((100 * pass / total ))
        echo "{"
        echo "    \"score\": ${score},"
        echo "    \"score_units\": \"Percentage of passed tests\","
        echo "    \"failed_tests\": [${fail_list#,}],"
        echo "}"
    } >"${WORKLOAD_RESULTS_FILE}"
    repro:info "Results written to $(realpath "${WORKLOAD_RESULTS_FILE}")"
    repro:info "Test score: ${score}% ($pass / $total)"
}

function selftest:cleanup() {
    repro:debug ${REPRO_MODE} cleanup
    repro:delete_persistent_state ${REPRO_NAME}_${REPRO_MODE}
}

function selftest:help() {
    echo "Runs the repromain unit tests."
    echo "Hosts required: 1 SUT. Optional: any number of additional hosts (SUT, loadgen, support)."
    echo "Usage: ./run.sh selftest SUT|LDG|SUP [--list] [--test=<name_of_test> [...]]"
}

function selftest:run_all_tests() {
    local test_name test_pattern
    [ "$1" = "--list" ] && {
        compgen -A function -X "!${@: -1}" | sed -E 's/^.*:test(_...)?:/* '${REPRO_MODE}' test: /'
        return 0
    }
    [[ "$1" = --test=* ]] || test_pattern="$1"
    while [ $# -gt 0 ]; do
        if [[ "$1" = --test=* ]]; then
            selftest:run_test "${1#--test=}"
        else
            for test_name in $(compgen -A function -X "!${test_pattern}"); do
                selftest:run_test "${test_name#*:test:}"
            done
        fi
        shift
    done
    repro:set_persistent_var ${REPRO_NAME}_${REPRO_MODE} SELFTEST_COUNT_PASS $SELFTEST_COUNT_PASS
    repro:set_persistent_var ${REPRO_NAME}_${REPRO_MODE} SELFTEST_COUNT_FAIL $SELFTEST_COUNT_FAIL
    repro:set_persistent_var ${REPRO_NAME}_${REPRO_MODE} SELFTEST_FAIL_LIST "$SELFTEST_FAIL_LIST"
}

function selftest:run_test() {
    repro:info "Running test: $*"
    declare -F "${REPRO_NAME}:test:$1" &>/dev/null && {
        # we expect exactly one particular failing test, to make sure the failing path works in the test suite
        "${REPRO_NAME}:test:$1" || [ "$1" = fail_by_design ] && {
            let SELFTEST_COUNT_PASS++
            repro:info "PASS: $1"
            return 0
        }
    }
    let SELFTEST_COUNT_FAIL++
    SELFTEST_FAIL_LIST+=",\"$1\""
    repro:error "FAIL: $1"
}


# tests start here; all tests except fail_by_design should return 0 on success ("works as intended") and non-zero otherwise
function selftest:test:fail_by_design() {
    false
}

function selftest:test:noop() {
    true
}

function selftest:test:logging() {
    repro:debug "debug" || return 1
    repro:info "info" || return 1
    echo "info from stdin" | repro:info || return 1
    repro:warn "warn" || return 1
    repro:error "error" || return 1
}

function selftest:test:run_cmd() {
    repro:cmd false && return 1
    repro:cmd true
}

function selftest:test:run_cmd_block() {
    echo false | repro:cmd && return 1
    echo true | repro:cmd
}

function selftest:test:persistent_vars() {
    repro:debug "set test_var"
    repro:set_persistent_var test_state test_var test_value || return 1
    [ -e "$(repro:get_persistent_file test_state)" ] || return 1
    [ "$(repro:get_persistent_var test_state test_var)" == test_value ] || return 1

    repro:debug "non existent state/var"
    [ "$(repro:get_persistent_var test_state_foo test_var default_val)" == default_val ] || return 1
    [ "$(repro:get_persistent_var test_state test_var_foo default_val)" == default_val ] || return 1

    repro:debug "unset test_var"
    repro:unset_persistent_var test_state test_var || return 1
    [ -e "$(repro:get_persistent_file test_state)" ] && return 1
    [ "$(repro:get_persistent_var test_state test_var default_val)" == default_val ] || return 1

    repro:debug "delete state"
    repro:set_persistent_var test_state test_var test_value || return 1
    repro:delete_persistent_state test_state || return 1
    [ -e "$(repro:get_persistent_file test_state)" ] && return 1
    [ "$(repro:get_persistent_var test_state test_var default_val)" == default_val ] || return 1
}

function selftest:test:state_changes() {
    repro:debug "set test_state"
    repro:state:set test_state test_value || return 1
    repro:state:set test_state2 test_value2 || return 1
    [ "$(repro:state:get test_state)" == test_value ] || return 1
    [ "$(repro:state:get test_state2)" == test_value2 ] || return 1

    repro:debug "unset test_state"
    repro:state:unset test_state || return 1
    cat $(repro:get_persistent_file REPRO_STATE)
    [ "$(repro:state:get test_state default_val)" == default_val ] || return 1
    repro:state:unset test_state2 || return 1
    [ "$(repro:state:get test_state2 default_val2)" == default_val2 ] || return 1

    repro:debug "set PID"
    repro:state:set_pid || return 1
    [ "$(repro:state:get PID)" == $$ ] || return 1
}

function selftest:test:get_state_all() {
        repro:state:get_all
}
