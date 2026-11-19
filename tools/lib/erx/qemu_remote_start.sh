# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# One remote QEMU boot (tools/lib/erx/qemu_remote.rb). QemuRemote::Run uploads
# this script into the boot's run directory and QemuRemote::Boot#start_argv
# runs it under nohup, detached from the ssh session, naming every file:
#
#   sh start.sh STARTED STATUS SIZES KEYBOARD TYPED SERIAL LOG TIMEOUT KILL_AFTER SECONDS QEMU...
#
# It runs once: a start repeated after a lost connection finds STARTED made and
# does nothing. QEMU and the keyboard feeder run under GNU timeout for SECONDS,
# killed KILL_AFTER seconds after its TERM.
# The feeder copies each byte the harness writes to TYPED into the KEYBOARD
# FIFO, which this script holds open both ways, so QEMU's open of it never
# blocks. A sampler appends "EPOCH SIZE" to SIZES once a second, the serial
# log's size at that time, so the harness can tell when each byte was written
# however late a poll fetches it. When QEMU ends, a last sample and then the
# exit status land in STATUS, renamed into place whole: 125 when the boot
# could not be set up, else GNU timeout's (124 at the deadline).

started=$1 status=$2 sizes=$3 keyboard=$4 typed=$5 serial=$6 log=$7 timeout=$8 kill_after=$9
seconds=${10}
shift 10

mkdir "$started" 2>/dev/null || exit 0

# A serial log not made yet, when setup failed, has no bytes.
sample() {
	echo "$(date +%s) $(wc -c < "$serial" 2>/dev/null || echo 0)" >> "$sizes"
}

finish() {
	kill "$feeder" "$sampler" 2>/dev/null
	sample
	echo "$1" > "$status.part" && mv -f "$status.part" "$status"
}

feeder= sampler=
trap 'finish $?' EXIT

mkfifo -m 600 "$keyboard" || exit 125
exec 3<>"$keyboard"
: > "$typed" && : > "$serial" || exit 125

"$timeout" -k "$kill_after" "$seconds" tail -c +1 -f "$typed" >&3 2>/dev/null &
feeder=$!
sample
# Bounded by a count, not by the timeout, so it ends even if this script is killed.
(
	tick=0
	while [ "$tick" -lt "$((seconds + kill_after + 10))" ] && sleep 1; do
		sample
		tick=$((tick + 1))
	done
) &
sampler=$!

"$timeout" -k "$kill_after" "$seconds" "$@" 3>&- > "$log" 2>&1 < /dev/null
