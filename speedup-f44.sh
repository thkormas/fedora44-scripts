#!/usr/bin/env bash
# speedup-f44.sh - Fedora 44 speedups for ThinkPad T450s (i5-5300U)
# Run as root:  sudo bash speedup-f44.sh
#
# Changes:
#   1) /etc/default/grub : GRUB_TIMEOUT 5 -> 1  (+ regenerate grub.cfg)
#   2) tuned profile     : powersave -> desktop  (governor/boost/EPP per boot)
#
# Robustness rules (v2.0):
#   * commands that can block (tuned-adm, systemctl, grub2-mkconfig) always
#     run under `timeout`, so a wedged dbus/tuned can never freeze the script
#     (this was the "stops when switching to desktop" bug);
#   * steps never abort the script: errors are counted, reported, and the
#     final exit code is non-zero if anything failed - the AFTER summary and
#     the revert instructions are ALWAYS printed;
#   * the tuned daemon is restarted BEFORE the profile switch (a daemon stuck
#     mid-apply is the usual reason tuned-adm blocks), and if tuned-adm
#     fails or times out we write /etc/tuned/active_profile directly and
#     restart the daemon onto it;
#   * the profile switch is verified with retries (it is asynchronous).
#
# Backups are written next to every file that is modified.
#
# All paths/timeouts are overridable through the environment (used by the
# test harness); the defaults are the real system paths.

set -uo pipefail

GRUB_DEFAULT_FILE=${GRUB_DEFAULT_FILE:-/etc/default/grub}
TUNED_ACTIVE_FILE=${TUNED_ACTIVE_FILE:-/etc/tuned/active_profile}
CPU_SYSFS=${CPU_SYSFS:-/sys/devices/system/cpu}
EFI_DIR=${EFI_DIR:-/sys/firmware/efi}
BOOT_DIR=${BOOT_DIR:-/boot}
CMD_TIMEOUT=${CMD_TIMEOUT:-30}            # tuned-adm / systemctl
GRUB_MKCONFIG_TIMEOUT=${GRUB_MKCONFIG_TIMEOUT:-120}

ts=$(date +%Y%m%d-%H%M%S)
failures=0
GRUB_TARGET=""

fail() {
	echo "   ERROR: $*" >&2
	failures=$((failures + 1))
}

# Run a command under a timeout (coreutils timeout). 124 = timed out.
run_t() {
	local secs=$1
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout -k 5 "$secs" "$@"
	else
		"$@"
	fi
}

tuned_active_profile() {
	# expects the line "Current active profile: <name>"
	run_t "$CMD_TIMEOUT" tuned-adm active 2>/dev/null | tail -1
}

echo "== BEFORE =="
echo "GRUB_TIMEOUT:      $(grep -E '^GRUB_TIMEOUT=' "$GRUB_DEFAULT_FILE" 2>/dev/null || echo '(n/a)')"
echo "tuned profile:     $(tuned_active_profile)"
echo "cpu governor:      $(cat "$CPU_SYSFS"/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
echo "turbo (no_turbo):  $(cat "$CPU_SYSFS"/intel_pstate/no_turbo 2>/dev/null || echo n/a)"
echo "boot time:         $(systemd-analyze 2>/dev/null | head -1 || echo n/a)"
echo

# ---------------------------------------------------------------- 1) GRUB ----
echo "== 1/2 GRUB timeout 5 -> 1 =="

if [ -d "$EFI_DIR" ] && [ -f "$EFI_DIR/EFI/fedora/grub.cfg" ] &&
	grep -q 'configfile\|grub2/grub.cfg' "$EFI_DIR/EFI/fedora/grub.cfg"; then
	# On UEFI the ESP grub.cfg is usually a stub that configfiles into
	# /boot/grub2/grub.cfg - only the real config may be regenerated.
	GRUB_TARGET="$BOOT_DIR/grub2/grub.cfg"
elif [ -d "$EFI_DIR" ] && [ -f "$EFI_DIR/EFI/fedora/grub.cfg" ]; then
	GRUB_TARGET="$EFI_DIR/EFI/fedora/grub.cfg"
else
	GRUB_TARGET="$BOOT_DIR/grub2/grub.cfg"
fi
echo "   target: $GRUB_TARGET"

if [ ! -f "$GRUB_DEFAULT_FILE" ]; then
	fail "$GRUB_DEFAULT_FILE not found - skipping GRUB step"
else
	cp -a "$GRUB_DEFAULT_FILE" "$GRUB_DEFAULT_FILE.bak.$ts"
	echo "   backup: $GRUB_DEFAULT_FILE.bak.$ts"

	if grep -qE '^GRUB_TIMEOUT=[0-9]+$' "$GRUB_DEFAULT_FILE"; then
		sed -i 's/^GRUB_TIMEOUT=[0-9]\+$/GRUB_TIMEOUT=1/' "$GRUB_DEFAULT_FILE"
		if grep -q '^GRUB_TIMEOUT=1$' "$GRUB_DEFAULT_FILE"; then
			echo "   GRUB_TIMEOUT=1 written to $GRUB_DEFAULT_FILE"
		else
			fail "GRUB_TIMEOUT could not be updated, restoring backup"
			cp -a "$GRUB_DEFAULT_FILE.bak.$ts" "$GRUB_DEFAULT_FILE"
		fi
	else
		# nothing was modified yet, so there is nothing to restore here
		# (and reporting the same problem twice would inflate the count)
		fail "no plain 'GRUB_TIMEOUT=<number>' line in $GRUB_DEFAULT_FILE - GRUB step skipped, file left unchanged"
	fi

	if [ -f "$GRUB_TARGET" ]; then
		cp -a "$GRUB_TARGET" "$GRUB_TARGET.bak.$ts"
		echo "   backup: $GRUB_TARGET.bak.$ts"
	else
		echo "   (no existing $GRUB_TARGET yet - nothing to back up)"
	fi

	# GRUB_CMDLINE_LINUX / GRUB_TIMEOUT are baked into this file, so it must
	# be regenerated for the new timeout to take effect.
	run_t "$GRUB_MKCONFIG_TIMEOUT" grub2-mkconfig -o "$GRUB_TARGET" >/dev/null
	mkrc=$?
	if [ "$mkrc" -eq 0 ]; then
		echo "   regenerated $GRUB_TARGET"
		# Tolerate leading whitespace / trailing content that grub's template
		# may add, but still require the value to actually be 1.
		if grep -qE '^[[:space:]]*set timeout=1[[:space:]]*$' "$GRUB_TARGET"; then
			echo "   OK: 'set timeout=1' found in generated config"
		else
			echo "   WARNING: generated config does not contain 'set timeout=1':" >&2
			grep -nE 'set timeout' "$GRUB_TARGET" >&2 || true
		fi
	else
		fail "grub2-mkconfig failed/timed out (rc=$mkrc) - $GRUB_DEFAULT_FILE says 1 but $GRUB_TARGET was NOT regenerated (run grub2-mkconfig manually, or restore the .bak file)"
	fi
fi

# ---------------------------------------------------------------- 2) tuned ----
echo
echo "== 2/2 tuned: powersave -> desktop =="

if ! command -v tuned-adm >/dev/null 2>&1; then
	fail "tuned-adm not found - skipping tuned step"
elif ! command -v systemctl >/dev/null 2>&1; then
	fail "systemctl not found - skipping tuned step"
else
	# A daemon that is stuck mid-apply makes `tuned-adm profile` block on
	# dbus forever, so bring it back to a fresh state FIRST.
	echo "   restarting tuned.service (timeout ${CMD_TIMEOUT}s)"
	run_t "$CMD_TIMEOUT" systemctl restart tuned.service
	rc=$?
	[ "$rc" -eq 0 ] || fail "systemctl restart tuned.service failed/timed out (rc=$rc)"
	sleep 1

	if run_t "$CMD_TIMEOUT" tuned-adm profile desktop; then
		echo "   profile set via tuned-adm"
	else
		# tuned-adm can fail or hang when dbus is wedged (or when another
		# power manager like TLP owns the policy); the active profile is
		# plain state, so set it directly and restart the daemon onto it.
		echo "   tuned-adm failed/timed out, writing $TUNED_ACTIVE_FILE directly"
		if printf 'desktop\n' >"$TUNED_ACTIVE_FILE"; then
			run_t "$CMD_TIMEOUT" systemctl restart tuned.service
			rc=$?
			[ "$rc" -eq 0 ] || fail "restarting tuned onto fallback profile failed (rc=$rc)"
		else
			fail "cannot write $TUNED_ACTIVE_FILE"
		fi
	fi

	# The switch is asynchronous: verify with a few short retries.
	ok=0
	for _ in 1 2 3 4 5; do
		if [ "$(tuned_active_profile)" = "Current active profile: desktop" ]; then
			ok=1
			break
		fi
		sleep 1
	done
	if [ "$ok" -eq 1 ]; then
		echo "   active:  Current active profile: desktop"
	else
		fail "tuned profile is not 'desktop' (got: $(tuned_active_profile))"
	fi

	verify_out=$(run_t "$CMD_TIMEOUT" tuned-adm verify 2>&1)
	verify_rc=$?
	echo "   verify (rc=$verify_rc): $(printf '%s\n' "$verify_out" | tail -1)"
fi

# ---------------------------------------------------------------- summary ----
echo
echo "== AFTER =="
echo "GRUB_TIMEOUT:      $(grep -E '^GRUB_TIMEOUT=' "$GRUB_DEFAULT_FILE" 2>/dev/null || echo '(n/a)')"
echo "tuned profile:     $(tuned_active_profile)"
sleep 2
echo "cpu governor:      $(cat "$CPU_SYSFS"/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
echo "energy perf pref:  $(cat "$CPU_SYSFS"/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo n/a)"
echo "turbo (no_turbo):  $(cat "$CPU_SYSFS"/intel_pstate/no_turbo 2>/dev/null || echo n/a)"
echo "   (no_turbo=0 means turbo boost ENABLED; powersave had it disabled)"
echo
echo "Backups: *.bak.$ts next to each changed file. To revert:"
echo "  sudo cp $GRUB_DEFAULT_FILE.bak.$ts $GRUB_DEFAULT_FILE && sudo grub2-mkconfig -o $GRUB_TARGET"
echo "  sudo tuned-adm profile powersave"

if [ "$failures" -gt 0 ]; then
	echo
	echo "Finished with $failures error(s) - see ERROR lines above."
	exit 1
fi

echo
echo "Done. Restart to see the faster boot; log out/in (or reboot) for Plasma"
echo "to pick up the tuned changes everywhere."
