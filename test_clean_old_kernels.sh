#!/bin/bash
# Τεστ harness για το slackware_clean_old_kernels_JBs.sh (v1.1) με mock περιβάλλον.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/slackware_clean_old_kernels_JBs.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PKGDIR="$TMP/packages"
BOOT="$TMP/boot"
BIN="$TMP/bin"
STUB_LOG="$TMP/stub.log"
mkdir -p "$PKGDIR" "$BOOT" "$BIN" "$BOOT/grub2"

pass=0; fail=0
check() { # $1=περιγραφή, $2=κωδικός (0=ok)
	if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
	else fail=$((fail+1)); echo "FAIL - $1"; fi
}

# stubs
cat >"$BIN/removepkg" <<'EOF'
#!/bin/bash
echo "removepkg $*" >>"$STUB_LOG"
exit 0
EOF
cat >"$BIN/grub2-mkconfig" <<'EOF'
#!/bin/bash
echo "grub2-mkconfig $*" >>"$STUB_LOG"
out=""
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { out=$2; shift; }; shift; done
: >"$out"
for v in $STUB_KEEP; do echo "menuentry \"Slackware ($v)\" { linux /vmlinuz-$v }" >>"$out"; done
exit 0
EOF
cat >"$BIN/slackpkg" <<'EOF'
#!/bin/bash
echo "slackpkg $*" >>"$STUB_LOG"
exit "${STUB_SLPKG_RC:-0}"
EOF
cat >"$BIN/flatpak" <<'EOF'
#!/bin/bash
echo "flatpak $*" >>"$STUB_LOG"
exit 0
EOF
cat >"$BIN/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
cat >"$BIN/uname" <<'EOF'
#!/bin/bash
[ "$1" = "-r" ] && { echo "${STUB_UNAME_R:-6.6.10}"; exit 0; }
exec /usr/bin/uname "$@"
EOF
cat >"$BIN/notify-send" <<'EOF'
#!/bin/bash
echo "notify-send $*" >>"$STUB_LOG"
EOF
chmod +x "$BIN"/*

mkpkg() { : >"$PKGDIR/$1"; }

setup_pkgs() {
	rm -f "$PKGDIR"/* 2>/dev/null
	# 6.1.9 (παλιός), 6.1.10 (παλιός), 6.6.10 (νεότερος)
	for v in 6.1.9 6.1.10 6.6.10; do
		mkpkg "kernel-generic-$v-x86_64-1"
		mkpkg "kernel-huge-$v-x86_64-1"
		mkpkg "kernel-modules-$v-x86_64-1"
		mkpkg "kernel-headers-$v-x86_64-1"
	done
	mkpkg "kernel-source-6.1.9-x86_64-1"
	mkpkg "kernel-source-6.6.10-x86_64-1"
	mkpkg "aaa_base-15.0-x86_64-3"             # μη-πυρήνα: πρέπει να μείνει ανέπαφο
	mkpkg "kernel-firmware-20230101-noarch-1"  # άλλο μη-πυρήνα πακέτο
}

setup_boot() {
	rm -f "$BOOT"/* "$BOOT/grub2/grub.cfg" 2>/dev/null
	for v in 6.1.9 6.1.10 6.6.10; do
		: >"$BOOT/vmlinuz-huge-$v"
		: >"$BOOT/vmlinuz-generic-$v"
		: >"$BOOT/System.map-$v"
		: >"$BOOT/config-$v"
		: >"$BOOT/initrd-huge-$v.img"
	done
}

run() { # $@ = επιλογές
	: >"$STUB_LOG"
	PACKAGES_DIR="$PKGDIR" BOOT_DIR="$BOOT" GRUB_CFG="$BOOT/grub2/grub.cfg" \
	PATH="$BIN:$PATH" STUB_LOG="$STUB_LOG" STUB_KEEP="$STUB_KEEP" \
	STUB_UNAME_R="${STUB_UNAME_R:-6.6.10}" STUB_SLPKG_RC="${STUB_SLPKG_RC:-0}" \
	bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------- TEST 1 -----
echo "== TEST 1: dry-run δείχνει plan χωρίς αλλαγές =="
setup_pkgs; setup_boot
STUB_KEEP="6.6.10"
out=$(run -n 2>&1); rc=$?
check "dry-run exit 0" "$rc"
echo "$out" | grep -q "6.1.9"
check "dry-run αναφέρει dead εκδόσεις" $?
echo "$out" | grep -q "slackpkg -batch=on update"
check "dry-run αναφέρει slackpkg update" $?
grep -q "removepkg\|slackpkg \|flatpak \|grub2-mkconfig " "$STUB_LOG"
[ $? -ne 0 ]; check "dry-run ΔΕΝ εκτελεί καμία εντολή" $?
[ -e "$BOOT/vmlinuz-huge-6.1.9" ]; check "dry-run ΔΕΝ σβήνει /boot files" $?

# ---------------------------------------------------------------- TEST 2 -----
echo "== TEST 2: --no-update πλήρης εκτέλεση αφαιρεί παλιούς + ενημερώνει GRUB =="
setup_pkgs; setup_boot
STUB_KEEP="6.6.10"
run -y --no-update >/dev/null 2>&1; rc=$?
check "εκτέλεση exit 0" "$rc"
grep -q "removepkg kernel-huge-6.1.9" "$STUB_LOG"
check "removepkg για kernel-huge-6.1.9" $?
grep -q "removepkg kernel-headers-6.1.10" "$STUB_LOG"
check "removepkg για kernel-headers-6.1.10" $?
grep -q "removepkg kernel-source-6.1.9" "$STUB_LOG"
check "removepkg για kernel-source-6.1.9 (παλιός source)" $?
grep -q "removepkg.*6.6.10" "$STUB_LOG"
[ $? -ne 0 ]; check "ΔΕΝ αφαιρεί τον νεότερο πυρήνα 6.6.10" $?
grep -q "removepkg aaa_base\|removepkg kernel-firmware" "$STUB_LOG"
[ $? -ne 0 ]; check "ΔΕΝ αφαιρεί μη-πυρήνα πακέτα" $?
[ ! -e "$BOOT/vmlinuz-huge-6.1.9" ] && [ ! -e "$BOOT/initrd-huge-6.1.10.img" ] && [ ! -e "$BOOT/System.map-6.1.9" ]
check "καθαρίστηκαν τα /boot υπολείμματα των παλιών" $?
[ -e "$BOOT/vmlinuz-huge-6.6.10" ]; check "κρατήθηκαν τα /boot files του νεότερου" $?
grep -q "grub2-mkconfig -o $BOOT/grub2/grub.cfg" "$STUB_LOG"
check "τράπηκε grub2-mkconfig -o grub.cfg" $?
grep -q "6.1.9" "$BOOT/grub2/grub.cfg"
[ $? -ne 0 ]; check "το νέο grub.cfg ΔΕΝ αναφέρει παλιές εκδόσεις" $?
grep -q "6.6.10" "$BOOT/grub2/grub.cfg"
check "το νέο grub.cfg περιέχει τον νεότερο πυρήνα" $?
grep -q "slackpkg\|flatpak" "$STUB_LOG"
[ $? -ne 0 ]; check "με --no-update ΔΕΝ τρέχει slackpkg/flatpak" $?

# ---------------------------------------------------------------- TEST 3 -----
echo "== TEST 3: ο τρέχωντας (παλιός) πυρήνας προστατεύεται =="
setup_pkgs; setup_boot
STUB_UNAME_R="6.1.9-smp"   # τρέχει ο πιο παλιός → πρέπει να κρατηθεί
STUB_KEEP="6.6.10"
run -y --no-update >/dev/null 2>&1; rc=$?
check "εκτέλεση exit 0" "$rc"
grep -q "removepkg.*6\.1\.9" "$STUB_LOG"
[ $? -ne 0 ]; check "ΔΕΝ αφαιρεί τον τρέχοντα πυρήνα 6.1.9 (smp)" $?
grep -q "removepkg.*6\.1\.10" "$STUB_LOG"
check "αφαιρεί τον μεσαίο 6.1.10" $?
STUB_UNAME_R="6.6.10"

# ---------------------------------------------------------------- TEST 4 -----
echo "== TEST 4: --no-update + τα πάντα ενημερωμένα → τίποτα να κάνει =="
setup_pkgs; setup_boot
STUB_UNAME_R="6.6.10-smp"
rm -f "$PKGDIR"/kernel-*-6.1.9-* "$PKGDIR"/kernel-*-6.1.10-*
STUB_KEEP="6.6.10"
out=$(run -y --no-update 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "τα πάντα είναι ενημερωμένα"
check "μήνυμα 'τα πάντα ενημερωμένα'" $?
grep -q "removepkg\|grub2-mkconfig\|slackpkg\|flatpak" "$STUB_LOG"
[ $? -ne 0 ]; check "δεν τρέχει καμία εντολή στην καθαρή περίπτωση" $?

# ---------------------------------------------------------------- TEST 5 -----
echo "== TEST 5: --keep 2 κρατάει 2 πιο πρόσφατους =="
setup_pkgs; setup_boot
STUB_UNAME_R="6.6.10"
STUB_KEEP="6.1.10 6.6.10"
run -y --no-update --keep 2 >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "removepkg.*6\.1\.10" "$STUB_LOG"
[ $? -ne 0 ]; check "με --keep 2 κρατάει τον 6.1.10" $?
grep -q "removepkg.*6\.1\.9" "$STUB_LOG"
check "με --keep 2 αφαιρεί τον 6.1.9" $?

# ---------------------------------------------------------------- TEST 6 -----
echo "== TEST 6: αποτυχία grub2-mkconfig → non-zero exit =="
setup_pkgs; setup_boot
STUB_KEEP="6.6.10"
cat >"$BIN/grub2-mkconfig" <<'EOF'
#!/bin/bash
echo "grub2-mkconfig FAIL $*" >>"$STUB_LOG"
exit 1
EOF
chmod +x "$BIN/grub2-mkconfig"
run -y --no-update >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 όταν αποτυχάνει το grub2-mkconfig" $?
# επαναφορά του καλού stub
cat >"$BIN/grub2-mkconfig" <<'EOF'
#!/bin/bash
echo "grub2-mkconfig $*" >>"$STUB_LOG"
out=""
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { out=$2; shift; }; shift; done
: >"$out"
for v in $STUB_KEEP; do echo "menuentry \"Slackware ($v)\" { linux /vmlinuz-$v }" >>"$out"; done
exit 0
EOF
chmod +x "$BIN/grub2-mkconfig"

# ---------------------------------------------------------------- TEST 7 -----
echo "== TEST 7: default (με update) τρέχει slackpkg+flatpak και μετά καθαρισμό =="
setup_pkgs; setup_boot
STUB_KEEP="6.6.10"
run -y >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^slackpkg -batch=on update$" "$STUB_LOG"
check "τράπηκε slackpkg -batch=on update" $?
grep -q "^slackpkg -batch=on upgrade-all$" "$STUB_LOG"
check "τράπηκε slackpkg -batch=on upgrade-all" $?
grep -q "^flatpak update -y$" "$STUB_LOG"
check "τράπηκε flatpak update -y" $?
grep -q "^flatpak uninstall --unused -y$" "$STUB_LOG"
check "τράπηκε flatpak uninstall --unused -y" $?
grep -q "removepkg kernel-huge-6.1.9" "$STUB_LOG"
check "ο καθαρισμός ακολούθησε την ενημέρωση" $?
grep -q "grub2-mkconfig" "$STUB_LOG"
check "τράπηκε grub2-mkconfig μετά την ενημέρωση" $?

# ---------------------------------------------------------------- TEST 8 -----
echo "== TEST 8: αποτυχία slackpkg → συνέχεια καθαρισμού + exit 1 =="
setup_pkgs; setup_boot
STUB_KEEP="6.6.10"
STUB_SLPKG_RC=1
run -y >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 όταν αποτυχάνει το slackpkg" $?
grep -q "removepkg kernel-huge-6.1.9" "$STUB_LOG"
check "ο καθαρισμός συνεχίζει παρόλη την αποτυχία ενημέρωσης" $?
grep -q "grub2-mkconfig" "$STUB_LOG"
check "το grub ενημερώνεται παρόλη την αποτυχία ενημέρωσης" $?
STUB_SLPKG_RC=0

# ---------------------------------------------------------------- TEST 9 -----
echo "== TEST 9: ενημέρωση χωρίς παλιούς πυρήνες → GRUB ενημερώνεται (νέος πυρήνας από upgrade) =="
setup_pkgs; setup_boot
rm -f "$PKGDIR"/kernel-*-6.1.9-* "$PKGDIR"/kernel-*-6.1.10-*
STUB_UNAME_R="6.6.10"
STUB_KEEP="6.6.10"
run -y >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^slackpkg -batch=on upgrade-all$" "$STUB_LOG"
check "τράπηκε slackpkg upgrade-all" $?
grep -q "removepkg" "$STUB_LOG"
[ $? -ne 0 ]; check "κανένα removepkg όταν δεν υπάρχουν παλιοί" $?
grep -q "grub2-mkconfig" "$STUB_LOG"
check "grub2-mkconfig τρέχει μετά update ακόμα και χωρίς καθαρισμό" $?
STUB_UNAME_R="6.6.10"

# ---------------------------------------------------------------- TEST 10 ----
echo "== TEST 10: --keep 2 με update =="
setup_pkgs; setup_boot
STUB_UNAME_R="6.6.10"
STUB_KEEP="6.1.10 6.6.10"
run -y --keep 2 >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "removepkg.*6\.1\.10" "$STUB_LOG"
[ $? -ne 0 ]; check "με --keep 2 κρατάει τον 6.1.10" $?
grep -q "removepkg.*6\.1\.9" "$STUB_LOG"
check "με --keep 2 αφαιρεί τον 6.1.9" $?

echo
echo "== ΣΥΝΟΛΟ: $pass ok, $fail FAIL =="
[ "$fail" -eq 0 ]
