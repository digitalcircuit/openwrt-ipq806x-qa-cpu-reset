OpenWRT IPQ806x QA for CPU reset
===============

These shell scripts for OpenWRT assist with diagnosing unexpected CPU resets/reboots on the Qualcomm™ IPQ806x platform.

In particular, they have been used to recreate a crash on [the ZyXEL NBG6817 router](https://openwrt.org/toh/zyxel/nbg6817 ) featuring the IPQ8065 network processor.  [More details on the real-world workload below](README.md#what_real_workload_causes_this_).

## Usage via computer helper

*The computer helper script retries until a crash is detected, automatically organizes log files, etc.  Though not required, it may be more convenient.*

### Download scripts to computer

```
# Download
wget https://raw.githubusercontent.com/digitalcircuit/openwrt-ipq806x-qa-cpu-reset/main/debug-cpufreq-router.sh
wget https://raw.githubusercontent.com/digitalcircuit/openwrt-ipq806x-qa-cpu-reset/main/debug-cpufreq-ssh-loop.sh

# Mark launcher script as executable
chmod u+x debug-cpufreq-ssh-loop.sh
```

### Prepare for router hard reboot

When running this QA script, the router will likely **hard reboot without warning, as if unplugged from power supply.**  Save any changes on the router, finish up ongoing Internet transfers, voice chats, etc.

You can continue to use the router like normal during the test, just be prepared for a hard reboot, i.e. don't try to start a video conference with the CEO of Qualcomm™ :P

### Run QA script on computer

#### Basic test
```
./debug-cpufreq-ssh-loop.sh "default" "case1" "openwrt"
```

*Connects as user `root` on SSH port `22` to the OpenWRT router at hostname `openwrt`, then runs the QA test with `default` max CPU frequency (`1.75` GHz) while emulating the first set of crash conditions, `case1`.*

**NOTE:** It may take 8+ hours to trigger the crash!

#### Custom connection, KDE Connect support
```
./debug-cpufreq-ssh-loop.sh "default" "case1" "openwrt-router" "2222" "KDE Connect Pixel 4 XL"
```

*Connects as user `root` on SSH port `2222` to hostname `openwrt-router`, then runs the QA test with `default` max CPU frequency (`1.75` GHz) while emulating the first set of crash conditions, `case1`.*

*Also notifies the KDE Connect device `KDE Connect Pixel 4 XL` of test results if `kdeconnect-cli` is available and the device is paired and connected.*

*Note that if the router manages the local network, the KDE Connect device might not receive the message before the network is lost.*

**NOTE:** It may take 8+ hours to trigger the crash!

#### Verify temporary workaround crashes less often
```
./debug-cpufreq-ssh-loop.sh "1.4ghz" "case1" "openwrt"
```

*Connects as user `root` on SSH port `22` to the OpenWRT router at hostname `openwrt`, then runs the QA test with `1.4ghz` max CPU frequency (`1.4` GHz) while emulating the first set of crash conditions, `case1`.*

**Update 2021-8-24:** The crash may still happen, just less often.  [See CPU Frequencies below for more details](README.md#cpu-frequencies ).

## Usage on router directly

### Download to router

```
# Download
wget https://raw.githubusercontent.com/digitalcircuit/openwrt-ipq806x-qa-cpu-reset/main/debug-cpufreq-router.sh

# Mark script as executable
chmod u+x debug-cpufreq-router.sh
```

### Prepare for router hard reboot (again)

[See above for warnings](README.md#prepare_for_router_hard_reboot); in brief, the router will likely **hard reboot without warning, as if unplugged from power supply.**

### Run QA script on router

```
# Set router to default CPU frequency settings
./debug-cpufreq-router.sh "default"

# Run test
./debug-cpufreq-router.sh "test_cycle_freqs" "random" "case1"
```

*Sets the router to `default` max CPU frequency, then runs the QA test emulating the first set of crash conditions, `case1`, across both CPUs by randomly selecting CPU `0` and CPU `1` for each change.*

**NOTE:** It may take 8+ hours to trigger the crash!

## Options

### CPU frequencies

CPU frequency mode | Outcome
-------------------|---------
`default`          | Sets max CPU frequency to `1.75` GHz (default)
`1.4ghz`           | Sets max CPU frequency to `1.4` GHz (temporary workaround for issue)
`unchanged`        | No change, uses current per-CPU `[…]/policy*/scaling_max_freq` as upper limit

All options other than `unchanged` adjusts `scaling_max_freq` for all CPUs, e.g. `/sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq`.

**NOTE:** Setting a CPU frequency ceiling of `1.4` GHz is only a temporary workaround to use the router for workloads that cause crashes.  It is not a permanent solution due to reducing performance.

**Update 2021-8-24:** At `1.4ghz` (`1.4` GHz), the crash may still happen, just less often.  In one case, instead of rebooting after around 5 minutes to 2 hours (as with `1.75` GHz), it rebooted at 9 hours 19 minutes.  Any mitigation efforts will probably need to account for the `1.4` GHz speed as well.

Initial results suggest focusing on CPU frequency transitions that impact the L2 cache speed (`1.0` → `1.4` → `1.75` GHz).

### Test modes

Test mode | Outcome
----------|---------
`random`  | Randomizes CPU frequency from `600000 800000 1000000 1400000 1725000` limited by `scaling_max_freq`
`case1`   | Cycles CPU frequency between maximum (`scaling_max_freq`) and `800` MHz

### Advanced: CPU index

CPU index | Outcome
----------|---------
`all`     | Frequency of all CPUs are changed at once
`random`  | CPU `0` and `1` are randomly selected for each upcoming change
`<number>`| CPU `<number>` (`0` or `1`) is adjusted, other CPU remains at maximum (`scaling_max_freq`)

## Notes / FAQ

### Why guard against `date` segfaulting?

Occasionally, this QA script results in `date` itself segfaulting when getting current time since the Unix epoch in seconds.  If connected through Mosh, sometimes Mosh will segfault instead.

When running the real workload (Déjà Dup SFTP backup), OpenSSH instead will often exit unexpectedly, presumably from segfaulting as well.

It doesn't seem to be an issue with the programs; instead, something about the CPU frequency shifting seems to rarely result in corruption of some running programs.  This might be worse than a hard reboot since it's theoretically possible to silently corrupt persistent data.

### What real workload causes this?

Semi-reliable, "real" reproducer for this issue:

* Déjà Dup on a Linux computer
  * Set destination to SFTP on OpenWRT router
* OpenWRT router has OpenSSH installed, bound to second port
  * OpenSSH used so it can be locked down via `chroot` to secondary user, SFTP only
  * USB 3.0 HDD plugged into OpenWRT serving as Network Attached Storage

### What alternatives for the real workload have been tried?

* Isolating the USB 3.0 HDD via a fully powered USB 3.0 hub
  * USB current meter verifies at most `0.001` amps drawn from router port
  * Crash still happens
* Switching the USB 3.0 HDD to USB 3.0 SSD via USB 3.0 hub
  * Crash still happens
* Connecting USB 3.0 SSD via USB 2.0 port, bypassing USB SuperSpeed driver
  * Crash still happens
* Replacing the OEM 3.5 amp 12V DC power supply with 5 amp 12V DC power supply (12.3-ish V no load)
  * Crash still happens

### What has been tried to recreate this crash beyond CPU frequency?

* Measuring USB 3.0 HDD load (around 600 mA peak), recreating via digital USB test load
  * Leaving load on, setting load up to 900 mA, rapidly toggling load, etc
  * No crash even under full load
* Running `iperf3` via Gigabit Ethernet alongside `openssl benchmark`
  * No crash
* `stress-ng` in various permutations, including L2 cache tests
  * `nice -n 5 stress-ng --oomable -t 8h --times --cache 1 --cache-level 2`
  * `i=0 ; i_max=7200 ; while [ $i -lt $i_max ] ; do let i++; echo "[router] $(date -R): Iteration $i of $i_max" ; nice -n 5 stress-ng --oomable -t 3s --cache 1 --cache-level 2 || exit 1 ; sleep 1 ; done`
  * Above tests don't crash, other `stress-ng` tests result in near-instant crashes
  * Unable to determine if finding new bugs or recreating issue from real workload

### How should this be fixed?

Not sure yet!

Ansuel had [some initial suggestions on GitHub over here](https://github.com/openwrt/openwrt/pull/4464#issuecomment-903178662 ).

Result | Mitigation | Outcome
-------|------------|--------
?     | Add transition frequencies (e.g. `1.75` → `1.4` → `1.0` GHz) | *Not yet tested*
?     | Force both cores to same frequency (always, or at `1.4` & `1.75` GHz) | *Not yet tested*
?     | Increase clock latency (all, or just `1.4` & `1.75` GHz) | *Not yet tested*

## Links

* Bug reports
  * End of [FS#2053 - Regular crashes of ath10k-ct driver on ZyXEL NBG6817](https://bugs.openwrt.org/index.php?do=details&task_id=2053#comment9664 )
  * Part of the way into [FS#3099 - ipq806x: kernel 5.4 crash related to CPU frequency scaling](https://bugs.openwrt.org/index.php?do=details&task_id=3099#comment9674 )
* Mailing list entries
  * [Initial backport to 21.02 fix attempt in June](https://lists.openwrt.org/pipermail/openwrt-devel/2021-June/035544.html )
  * [Continuation of debugging into July](https://lists.openwrt.org/pipermail/openwrt-devel/2021-July/035729.html )
  * [Continuation of debugging into August](https://lists.openwrt.org/pipermail/openwrt-devel/2021-August/036026.html )
* GitHub conversations
  * [ipq806x: fix error with cache handling (#4192), by Ansuel](https://github.com/openwrt/openwrt/pull/4192 )
  * [ipq806x: fix min<>target opp volt mixup on ipq8065 (#4464), by digitalcircuit](https://github.com/openwrt/openwrt/pull/4464 )

## Acknowledgements

Loosely in order of appearance: `slh`, `plntyk2`, `zorun`, `mangix`, `PaulFertser`, `enyc`, and `Tusker` on the [OpenWRT IRC channel](https://openwrt.org/irc ) at [OFTC](https://www.oftc.net/ )/`#openwrt-devel`.

[`Ansuel`](https://github.com/Ansuel ) on the [OpenWRT mailing list](https://lists.openwrt.org/mailman/listinfo/openwrt-devel ) and [OpenWRT GitHub repository](https://github.com/openwrt/openwrt/ ).

*And everyone else who offered advice, encouragement, and humor!*
