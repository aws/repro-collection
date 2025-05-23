# Repro Collection

A light framework for, and a loose collection of tests, workloads, and repro packages, to aid with community discussions around detecting regressions.

## 1. Introduction

### 1.1 Goals
1. Provide a way to easily run one or more repro scenarios (workloads, tests, etc) with no infrastructure dependencies and avoiding package requirements
1. Provide a framework to write repro cases easily (minimal code, abstracted from the hardware setup, aim to be cross-distro)
1. Provide a unified approach to processing/outputting results, to facilitate meaningful comparisons between setups

### 1.2 What The Repro Framework DOESN'T Do
* Manage infrastructure, security, or ACLs (create/delete instances, set up sudo and ssh, configure access and firewall, isolate the network, secure communication, etc)
* Act as a result repository (dashboard, result collection, persistent database, etc)
* Provide an automation framework (queuing, scheduling, etc)
* Pick the correct test approach for you (see https://github.com/aws/aws-graviton-getting-started/tree/main/perfrunbook to learn more about that)

A notable limitation is that the Repro Framework does not fully handle reboot workflow; for example, if a kernel update and subsequent reboot are required, this must be managed externally of the Repro Framework, as it does not include a mechanism to reboot and then automatically continue where it left off. It does, however, support continuing repro execution where it left off before a reboot (or other stopping conditions).

### 1.3 Assumptions

The Repro Framework aims to automate exactly what you would manually run given pre-configured SUT/LDG machines, and nothing more. 
In other words: all machines involved in running repros are assumed to be "throw-away" test grade. No effort is made to secure, conceal, verify, or otherwise harden data, communications, or APIs.

In particular, this means:
* data on the machines has no real world value and can/will be discarded and/or recreated at will;
* there is no other activity on the machines at test time (definitely no production activity!);
* the network used for communication is externally shielded from any accidental or intentional external disruptions (e.g. isolated via private networks or private cloud setups);
* the machines will not be reused for any purposes beyond this testing (e.g., they are virtual instances which will be terminated or reverted to a blank state when the testing is finished).

**Root access and Internet access**: The Repro Framework itself requires neither. However, as part of the install/configure steps, workloads are likely to attempt to download and install dependency packages, tweak system properties, edit system wide files, create test users, etc.
When this is performed, the only mechanism employed (and recommended) is `sudo`, which is assumed to be available and correctly preconfigured for the user running the repro or workload.

**Dependencies**: The Repro Framework is designed to be minimalistic as a framework in regards to dependencies. It runs on `bash v5` and only needs a few common commands such as `sed` or `cat`. The complete list of commands can be seen by running `REPROCFG_LOGLEVEL=DEBUG run.sh --help`.

### 1.4 Structure

The repository consists of workloads identified with a unique name (each placed in an eponymous directory under `workloads/`), repro scenarios (all placed under `repros/`), framework files (placed under `common/`), and standalone utilities (placed under `util/`).

### 1.5 Glossary

* `workload` - A distinct building block which tests and measures one or more metrics such as throughput performance. It can be run individually or as part of a repro scenario. The use of synthetic benchmarks as workloads is strongly discouraged, as they do not usually represent real life performance correctly.
* `repro` - Reproduction scenario. The application of one or more workloads for a particular use case. Repros are used to support claims like *"X workload has a regression under Y conditions"*.
* `SUT` - System Under Test. This is the machine/instance/VM which is measured (tested).
* `LDG` - Load Generator. The machine which generates workload data for the SUT. Some workloads only run locally, not requiring a load generator.
* `SUP` - Support. This is an additional machine class used by more complex workloads, e.g. for coordinating multiple LDGs.

## 2. How To Run

Running a simple SUT-only workload can be as simple as `run.sh workload_name SUT`.

Runtime parameters are configured via environment variables which can be modified before running `run.sh`. For convenience, a few parameters (`--dry-run`, `--sut=`, `--loadgen=`, `--support=`) are also available via command line arguments.

Available parameters and other helpful information are given when running `run.sh [<workload_name>] --help`.

For a more complete example, we will illustrate running a `mysql` test below.

### 2.1 Prepare

Set up an arbitrary `SUT` and a corresponding `LDG`, each running e.g. Ubuntu 22.04, with the default user having unrestricted `sudo` access.

Make sure the `LDG` can reach the `SUT`'s ports `3306` (`mysql`) and `31337` (the Repro Framework's communication channel; this is configurable by modifying `REPROCFG_PORT` before running).

The `LDG` should be sized appropriately to *not* be a bottleneck in any part of the workload (data generation, networking, processing, etc) - otherwise, the measured results will be invalid in the context of the `SUT`.

A RAID0 array is highly recommended for the `mysql` database; the workload will attempt to find available disks on the SUT, create a RAID0 array, and mount it for you. If an available (not mounted) RAID0 array already exists, it will be used instead.

Clone the `repro-collection` repository on both the `SUT` and `LDG`. In this example, we'll assume the path to the repository is `~/repro-collection` on both machines.

### 2.2 Run

*Note*: It is good practice to use a terminal abstraction layer such as `screen`, `tmux`, or `nohup`, so that the workload can continue running without interruption when your network connection to the `SUT`/`LDG` experiences disconnections.

* On the SUT, run: `~/repro-collection/run.sh mysql SUT --ldg=<ldg_address> 2>&1 | tee ~/sut.log` - this will install and start the `mysql` service, and wait for the LDG to signal when testing is finished.

* On the LDG, run: `~/repro-collection/run.sh mysql LDG --sut=<sut_address> 2>&1 | tee ~/ldg.log` - this will install and run the `HammerDB` load generator, produce and export the results when finished, and initiate cleanup both on itself and on the SUT.

Done!

*Notes*:
* Make sure you provide the `LDG` address the *same way* it will be visible on the `SUT`. For example, if the LDG has a private network IP address and a second IP address to access the Internet, specify the IP address that the `SUT` will receive when connected to. Otherwise, you will get `mysql` errors about unauthorized user connections. If in doubt, you can supply all addresses by using multiple `--ldg=` arguments.
* The machine order in which you run (`LDG` or `SUT` first) does not matter. The machines will wait for each other at the correct times to synchronize the workflow.
* Both the `--sut=` and the `--ldg=` parameters can be specified on the`SUT` and the `LDG`; while a longer command line, providing both parameters on both sides is harmless, more consistent and thus less prone to error.
* Some workloads support more than one `LDG`. These can be supplied by repeating the `--ldg=` argument as many times as needed.
* Each workload runs by going through a series of steps (operations). The default step sequence is `install`/`configure`/`run`/`results`/`cleanup`. Command line overrides are suported (see the output of `run.sh --help` for details).

### Results

The `mysql` workload will automatically parse the HammerDB output and create a `~/results.json` file on the `LDG`, containing the test conclusion (NOPM and TPM numbers, along with measured latency). It will also print a message like "Test score: NNNN".

An `mysql` results file might look like this:
```
{
    "score": [123456],
    "nopm": [123456],
    "tpm": [234567],
    "latency_min": [1.234,1.345,12.345,0.123,0.456],
    "latency_avg": [23.690,7.633,60.772,1.071,0.939],
    "latency_max": [45.123,45.456,56.123,34.123,23.123],
    "latency_p99": [45.456,45.123,56.012,34.345,23.345],
    "latency_p95": [34.321,12.345,67.890,1.234,1.123],
    "latency_p50": [23.456,7.890,6.789,1.123,0.123],
    "latency_ratios": [45.678,12.345,12.678,0.123,0.123],
}

The "Test score" message and the `score` entry in the results file are standardized outputs for all workloads.
```

## Repro Scenarios

Repros are an extension of the workload concept, and provide a way to express specific use cases by including sequencing, additional configurations, or even interactions between multiple workloads.

All repro scenarios are under the `repros/` directory. Any associated files must be placed in a subdirectory with the same name as the repro scenario.

## How To Extend

To find out how to contribute a workload or a repro scenario, please refer to the [Developer Guide](CONTRIBUTING.md).

## License

This project is licensed under the Apache-2.0 License. See [LICENSE](LICENSE) for more information.
