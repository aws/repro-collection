#!/usr/bin/tclsh
proc runtimer { seconds } {
	set x 0
	set timerstop 0
	while {!$timerstop} {
		incr x
		after 1000
		if { ![ expr {$x % 60} ] } {
			set y [ expr $x / 60 ]
			puts "Timer: $y minutes elapsed"
		}
		update
		if { [ vucomplete ] || $x eq $seconds } { set timerstop 1 }
	}
	return
}
puts "SETTING CONFIGURATION"
dbset db mysql
dbset bm TPC-C
diset connection mysql_host {{ REPROMARK_SUT }}
diset tpcc mysql_count_ware {{ PARAM_WH }}
# start with VU = WH, see https://www.hammerdb.com/docs/ch04s03.html
diset tpcc mysql_num_vu {{ PARAM_WH }}
diset tpcc mysql_user {{ MYSQL_USERNAME }}
diset tpcc mysql_pass {{ MYSQL_PASSWORD }}
diset tpcc mysql_dbase hammerdbtest
diset tpcc mysql_partition true
diset tpcc mysql_storage_engine innodb
diset tpcc mysql_prepared true
diset tpcc mysql_total_iterations 1000000000000
diset tpcc mysql_raiseerror true
diset tpcc mysql_keyandthink false
diset tpcc mysql_driver timed
diset tpcc mysql_rampup {{ PARAM_RAMPUP_MIN }}
diset tpcc mysql_duration {{ PARAM_DURATION_MIN }}
diset tpcc mysql_allwarehouse true
diset tpcc mysql_timeprofile true
diset tpcc mysql_async_scale false
diset tpcc mysql_async_client 1
diset tpcc mysql_async_delay 500
vuset logtotemp 1
loadscript

puts "STARTING BUILD"
buildschema
runtimer 43200
vudestroy
after 5000
puts "BUILD COMPLETE"

puts "STARTING TEST"
puts "{{ PARAM_VUSERS }} VU"
vuset vu {{ PARAM_VUSERS }}
vucreate
vurun
runtimer {{ PARAM_DURATION_TOTAL_SEC }}
vudestroy
after {{ PARAM_RAMPDOWN_MSEC }}
puts "TEST COMPLETE"
