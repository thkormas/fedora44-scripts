#!/bin/bash
# slackware_clean_old_kernels_JBs.sh v1.1.0
#
# Ενημέρωση συστήματος (slackpkg + flatpak) + καθαρισμός παλιών πυρήνων +
# αυτόματη ενημέρωση GRUB, σε Slackware (stable).
#
# Ροή εκτέλεσης:
#   1. slackpkg update          (ανανέωση mirror / βάσεων πακέτων)
#   2. slackpkg upgrade-all     (αναβάθμιση επίσημων πακέτων - μπορεί να φέρει
#                                καινούριο πυρήνα)
#   3. flatpak update -y (+ αφαίρεση αχρησιμοποίητων runtimes), αν υπάρχει flatpak
#   4. καθαρισμός παλιών πυρήνων: κρατάμε τον τρέχοντα (uname -r) + τους N πιο
#      πρόσφατους (default N=1), αφαιρούμε τους υπόλοιπους με removepkg και
#      καθαρίζουμε τα υπολείμματα στο /boot (vmlinuz-*, initrd-*.img,
#      System.map-*, config-*)
#   5. αναδημιουργία grub.cfg (grub2-mkconfig / grub-mkconfig) ή lilo, ώστε
#      το menu να δείχνει τον καινούριο πυρήνα και όχι σβησμένους παλιούς
#   6. επιβεβαίωση ότι οι παλιές εκδόσεις δεν υπάρχουν πια στο grub.cfg
#   7. ενημέρωση στην επιφάνεια εργασίας (notify-send), αν υπάρχει
#
# Τα βήματα 1-3 γίνονται ξανά σάρωση των πακέτων ώστε ο καθαρισμός να βλέπει
# τον καινούριο πυρήνα που μόλις μπήκε.
#
# Ασφάλεια:
#   * ΠΟΤΕ δεν αφαιρεί τον τρέχοντα πυρήνα, ούτε τον πιο πρόσφατο.
#   * Με -n / --dry-run δείχνει ακριβώς τι θα έγινε χωρίς να αλλάξει τίποτα.
#   * Χωρίς -y ρωτάει μία επιβεβαίωση στην αρχή πριν τρέξει οτιδήποτε.
#   * Σφάλματα δεν σταματούν το script (μετριώνται και αναφέρονται στο τέλος)
#     - αποτυχία ενημέρωσης δεν εμποδίζει τον καθαρισμό και το GRUB.
#
# Χρήση σε cron για εντελώς αυτόματο εκτέλεση (π.χ. κάθε Κυριακή):
#   0 3 * * 0 /usr/local/bin/slackware_clean_old_kernels_JBs.sh -y --keep 2
#
# Επιλογές:
#   -u, --update      Ενημέρωση με slackpkg + flatpak (default: ΝΑΙ)
#       --no-update   Χωρίς ενημέρωση - μόνο καθαρισμός πυρήνων + GRUB
#   -n, --dry-run     Δείχνει τι θα έγινε χωρίς να αλλάξει τίποτα
#   -y, --yes         Χωρίς ερώτηση επιβεβαίωσης
#   --keep N          Κρατά τους N πιο πρόσφατους πυρήνες (default: 1) +
#                     πάντα τον τρέχοντα
#   -h, --help        Βοήθεια
#
# (όλα τα paths/timeouts είναι παραμετροποιήσιμα μέσω env: PACKAGES_DIR,
#  BOOT_DIR, GRUB_CFG, UPDATE_TIMEOUT - χρήσιμο για δοκιμές)

set -uo pipefail

PROG=$(basename "$0")

PACKAGES_DIR=${PACKAGES_DIR:-/var/log/packages}
BOOT_DIR=${BOOT_DIR:-/boot}
GRUB_CFG=${GRUB_CFG:-/boot/grub2/grub.cfg}
UPDATE_TIMEOUT=${UPDATE_TIMEOUT:-1800}   # δευτ. ανά βήμα slackpkg/flatpak

DRY_RUN=0
ASSUME_YES=0
KEEP=1
DO_UPDATE=1

failures=0

info() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { warn "$*"; exit 1; }
fail() { warn "$*"; failures=$((failures + 1)); }

usage() {
	cat <<EOF
$PROG - ενημέρωση συστήματος + καθαρισμός παλιών πυρήνων + GRUB (Slackware)

Χρήση:
  $PROG [επιλογές]

Επιλογές:
  -u, --update      Ενημέρωση με slackpkg + flatpak (default: ΝΑΙ)
      --no-update   Χωρίς ενημέρωση - μόνο καθαρισμός πυρήνων + GRUB
  -n, --dry-run     Δείχνει τι θα έγινε χωρίς να αλλάξει τίποτα
  -y, --yes         Χωρίς ερώτηση επιβεβαίωσης
  --keep N          Κρατά τους N πιο πρόσφατους πυρήνες (default: 1)
  -h, --help        Αυτό το κείμενο

Παράδειγμα cron (κάθε Κυριακή, ενημέρωση + καθαρισμός, κρατάει 2 εκδόσεις):
  0 3 * * 0 $PROG -y --keep 2
EOF
}

notify() {
	# $1 = εικόνα, $2 = μήνυμα
	command -v notify-send >/dev/null 2>&1 || return 0
	notify-send -i "$1" "Ενημέρωση & καθαρισμός πυρήνων" "$2" 2>/dev/null || true
}

# Εκτέλεση εντολής με timeout (coreutils). 124 = τέλεσε timeout.
run_t() {
	local secs=$1
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout -k 5 "$secs" "$@"
	else
		"$@"
	fi
}

# "kernel-huge-smp-6.1.9-x86_64-1" -> "6.1.9"
# Επιστρέφει != 0 αν το όνομα δεν ταιριάζει στο format πυρήνα.
pkg_version() {
	local v=${1%-*}   # αφαίρεση build
	v=${v%-*}         # αφαίρεση arch
	case "$v" in
	kernel-generic-smp-*) v=${v#kernel-generic-smp-} ;;
	kernel-generic-*)     v=${v#kernel-generic-} ;;
	kernel-huge-smp-*)    v=${v#kernel-huge-smp-} ;;
	kernel-huge-*)        v=${v#kernel-huge-} ;;
	kernel-modules-smp-*) v=${v#kernel-modules-smp-} ;;
	kernel-modules-*)     v=${v#kernel-modules-} ;;
	kernel-headers-*)     v=${v#kernel-headers-} ;;
	kernel-source-*)      v=${v#kernel-source-} ;;
	*) return 1 ;;
	esac
	case "$v" in
	[0-9]*) printf '%s\n' "$v"; return 0 ;;
	*) return 1 ;;
	esac
}

# --- ανάλυση επιλογών ---------------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
	-u|--update)   DO_UPDATE=1 ;;
	--no-update)   DO_UPDATE=0 ;;
	-n|--dry-run)  DRY_RUN=1 ;;
	-y|--yes)      ASSUME_YES=1 ;;
	--keep)
		[ $# -ge 2 ] || die "η επιλογή --keep χρειάζεται αριθμό"
		KEEP=$2; shift ;;
	--keep=*)      KEEP=${1#--keep=} ;;
	-h|--help)     usage; exit 0 ;;
	-*)            die "άγνωστη επιλογή: $1 (δες '$PROG --help')" ;;
	*)             die "μη αναμενόμενο όνομα: $1 (δες '$PROG --help')" ;;
	esac
	shift
done

case "$KEEP" in ''|*[!0-9]*) die "--keep πρέπει να είναι αριθμός (π.χ. --keep 2)" ;; esac
[ "$KEEP" -ge 1 ] || die "--keep πρέπει να είναι >= 1"

# --- συλλογή εγκατεστημένων πυρήνων -------------------------------------------

running=$(uname -r)
running_ver=${running%-smp}   # το smp πακέτο έχει έκδοση χωρίς το -smp

# Γεμίζει τα ver_pkgs / kernel_versions (globals). Καλείται δύο φορές: πριν και
# μετά την ενημέρωση, γιατί το upgrade-all μπορεί να φέρει καινούριο πυρήνα.
collect_kernels() {
	ver_pkgs=()
	kernel_versions=()
	local p base v kv seen

	for p in "$PACKAGES_DIR"/kernel-*; do
		[ -f "$p" ] || continue
		base=$(basename "$p")
		v=$(pkg_version "$base") || continue
		ver_pkgs[$v]="${ver_pkgs[$v]:+${ver_pkgs[$v]} }$base"
		case "$base" in
		kernel-generic*|kernel-huge*|kernel-modules*)
			seen=0
			for kv in ${kernel_versions[@]+"${kernel_versions[@]}"}; do
				[ "$kv" = "$v" ] && { seen=1; break; }
			done
			[ "$seen" -eq 1 ] || kernel_versions+=("$v")
			;;
		esac
	done

	[ "${#kernel_versions[@]}" -gt 0 ] || return 1
	mapfile -t kernel_versions < <(printf '%s\n' "${kernel_versions[@]}" | sort -V)
	return 0
}

# --- ενημέρωση συστήματος (slackpkg + flatpak) --------------------------------

run_update() {
	info "== 1/3 ενημέρωση συστήματος (slackpkg + flatpak) =="

	if ! command -v slackpkg >/dev/null 2>&1; then
		fail "δεν βρέθηκε slackpkg - παράλειψη ενημέρωσης πακέτων"
	else
		info "   slackpkg update (mirror / βάσεις πακέτων)..."
		if run_t "$UPDATE_TIMEOUT" slackpkg -batch=on update; then
			info "   ok: slackpkg update"
		else
			fail "το slackpkg update απέτυχε (rc=$?) - συνέχεια με τα υπόλοιπα"
		fi

		info "   slackpkg upgrade-all (αναβάθμιση πακέτων)..."
		if run_t "$UPDATE_TIMEOUT" slackpkg -batch=on upgrade-all; then
			info "   ok: slackpkg upgrade-all"
		else
			fail "το slackpkg upgrade-all απέτυχε (rc=$?) - συνέχεια με τα υπόλοιπα"
		fi
	fi

	if command -v flatpak >/dev/null 2>&1; then
		info "   flatpak update..."
		if run_t "$UPDATE_TIMEOUT" flatpak update -y; then
			info "   ok: flatpak update"
		else
			fail "το flatpak update απέτυχε (rc=$?) - συνέχεια με τα υπόλοιπα"
		fi
		# κενός χώρος: αχρησιμοποίητα flatpak runtimes
		if flatpak uninstall --unused -y; then
			info "   ok: flatpak uninstall --unused"
		else
			fail "το flatpak uninstall --unused απέτυχε (rc=$?)"
		fi
	else
		info "   δεν υπάρχει flatpak - παράλειψη"
	fi
}

# --- συλλογή + ποιους κρατάμε -------------------------------------------------

[ -d "$PACKAGES_DIR" ] || die "δεν βρέθηκε το φάκελος πακέτων: $PACKAGES_DIR"

declare -A ver_pkgs=()
declare -A keep=()
kernel_versions=()
dead=()
remove_list=()

collect_kernels ||
	{ info "δεν βρέθηκαν εγκατεστημένοι πυρήνες στο $PACKAGES_DIR - τίποτα να κάνει"; exit 0; }

compute_plan() {
	keep=()
	dead=()
	remove_list=()
	local n i v base

	n=${#kernel_versions[@]}
	local keep_from=$(( n > KEEP ? n - KEEP : 0 ))

	for (( i=keep_from; i<n; i++ )); do
		keep[${kernel_versions[$i]}]=1
	done
	keep[$running_ver]=1   # ο τρέχων πυρήνας ΑΠΟΤΟΜΑ κρατιέται πάντα

	for v in "${kernel_versions[@]}"; do
		[ -n "${keep[$v]:-}" ] || dead+=("$v")
	done

	for v in ${dead[@]+"${dead[@]}"}; do
		for base in ${ver_pkgs[$v]}; do
			remove_list+=("$base")
		done
	done
	return 0
}

print_plan() {
	info "τρέχων πυρήνας:   $running"
	info "εγκατεστημένοι:   ${kernel_versions[*]}"
	info "κρατάμε:          ${!keep[*]}"
	if [ "${#dead[@]}" -gt 0 ]; then
		info "προς αφαίρεση:    ${dead[*]}"
		local base
		for base in "${remove_list[@]}"; do
			info "  - $base"
		done
	else
		info "προς αφαίρεση:    (κανένας - τα πάντα ενημερωμένα)"
	fi
	return 0
}

compute_plan

# --- dry-run: δείχνει το plan και σταματά --------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
	info "== dry-run: τίποτα δεν εκτελέστηκε =="
	if [ "$DO_UPDATE" -eq 1 ]; then
		info "θα εκτελούντανε: slackpkg -batch=on update"
		info "θα εκτελούντανε: slackpkg -batch=on upgrade-all"
		command -v flatpak >/dev/null 2>&1 &&
			info "θα εκτελούντανε: flatpak update -y (+ uninstall --unused)"
	fi
	print_plan
	if [ "${#dead[@]}" -gt 0 ]; then
		for v in "${dead[@]}"; do
			for f in "$BOOT_DIR"/vmlinuz-*-"$v" "$BOOT_DIR"/initrd-*-"$v".img \
			         "$BOOT_DIR"/System.map-"$v" "$BOOT_DIR"/config-"$v"; do
				[ -e "$f" ] && info "θα σβηνότανε: $f"
			done
		done
	fi
	if [ "${#dead[@]}" -gt 0 ] || [ "$DO_UPDATE" -eq 1 ]; then
		info "θα εκτελούντανε: grub2-mkconfig -o $GRUB_CFG (ή lilo)"
	fi
	exit 0
fi

# --- εκτέλεση -----------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "πρέπει να τρέξει ως root: sudo $PROG"

need_work=0
{ [ "${#dead[@]}" -gt 0 ] || [ "$DO_UPDATE" -eq 1 ]; } && need_work=1

if [ "$need_work" -eq 0 ]; then
	info "τα πάντα είναι ενημερωμένα: ${kernel_versions[*]}"
	info "τρέχων πυρήνας: $running - τίποτα να κάνει (--no-update)"
	exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
	[ "$DO_UPDATE" -eq 1 ] &&
		info "θα γίνει: ενημέρωση slackpkg + flatpak, μετά καθαρισμός πυρήνων και GRUB"
	[ "${#dead[@]}" -gt 0 ] &&
		info "προς αφαίρεση: ${dead[*]} (${#remove_list[@]} πακέτα)"
	printf 'Συνέχεια; [y/N] '
	read -r ans
	case "$ans" in
	y|Y|yes|YES) ;;
	*) info "ακυρώθηκε"; exit 0 ;;
	esac
fi

if [ "$DO_UPDATE" -eq 1 ]; then
	run_update

	# Η ενημέρωση μπορεί να έφερε καινούριο πυρήνα - ξανασαρώνουμε τα πακέτα
	# ώστε ο καθαρισμός να δει την πραγματική κατάσταση.
	if collect_kernels; then
		compute_plan
		info ""
		info "== 2/3 καθαρισμός παλιών πυρήνων (μετά την ενημέρωση) =="
		print_plan
	else
		warn "δεν βρέθηκαν πυρήνες μετά την ενημέρωση - παράλειψη καθαρισμού"
		dead=()
		remove_list=()
	fi
else
	info "== 2/3 καθαρισμός παλιών πυρήνων =="
	print_plan
fi

removed=0

if [ "${#dead[@]}" -gt 0 ]; then
	for base in "${remove_list[@]}"; do
		if command -v removepkg >/dev/null 2>&1 && removepkg "$base"; then
			removed=$((removed + 1))
			info "  αφαιρέθηκε: $base"
		else
			fail "αποτυχία αφαίρεσης: $base"
		fi
	done

	# Τα initrd κ.λπ. που δημιουργούνται τοπικά δεν ανήκουν σε πακέτο, οπότε τα
	# καθαρίζουμε μόνοι μας (απομένουν μετά το removepkg).
	for v in "${dead[@]}"; do
		for f in "$BOOT_DIR"/vmlinuz-*-"$v" "$BOOT_DIR"/initrd-*-"$v".img \
		         "$BOOT_DIR"/System.map-"$v" "$BOOT_DIR"/config-"$v"; do
			[ -e "$f" ] || continue
			if rm -f -- "$f"; then
				info "  καθαρίστηκε: $f"
			else
				fail "αποτυχία διαγραφής: $f"
			fi
		done
	done
else
	info "κανένας παλιός πυρήνας προς αφαίρεση"
fi

# --- ενημέρωση bootloader ------------------------------------------------------
# Το grub.cfg του Slackware είναι στατικό: χωρίς ανανέωση, ο καινούριος πυρήνας
# δεν εμφανίζεται στο menu και οι σβησμένοι παλιοί μένουν. Ανανεώνει λοιπόν
# ΠΑΝΤΑ όταν έγινε ενημέρωση ή αφαιρέθηκαν πυρήνες.

grub_updated=0

if [ "${#dead[@]}" -gt 0 ] || [ "$DO_UPDATE" -eq 1 ]; then
	info ""
	info "== 3/3 ενημέρωση bootloader =="

	if command -v grub2-mkconfig >/dev/null 2>&1; then
		# Slackware 15.0: το grub2-mkconfig βρίσκεται στο /usr/sbin
		if run_t "$UPDATE_TIMEOUT" grub2-mkconfig -o "$GRUB_CFG" >/dev/null 2>&1; then
			info "  grub2-mkconfig -> $GRUB_CFG"
			grub_updated=1
		else
			fail "το grub2-mkconfig απέτυχε - ενημέρωσε το bootloader χειροκίνητα"
		fi
	elif command -v grub-mkconfig >/dev/null 2>&1; then
		if run_t "$UPDATE_TIMEOUT" grub-mkconfig -o "$GRUB_CFG" >/dev/null 2>&1; then
			info "  grub-mkconfig -> $GRUB_CFG"
			grub_updated=1
		else
			fail "το grub-mkconfig απέτυχε - ενημέρωσε το bootloader χειροκίνητα"
		fi
	elif command -v lilo >/dev/null 2>&1 && [ -f /etc/lilo.conf ]; then
		if run_t "$UPDATE_TIMEOUT" lilo >/dev/null 2>&1; then
			info "  lilo εκτελέστηκε"
			grub_updated=1
		else
			fail "το lilo απέτυχε - ενημέρωσε το bootloader χειροκίνητα"
		fi
	else
		fail "δεν βρέθηκε grub2-mkconfig/grub-mkconfig ούτε lilo - ενημέρωσε το bootloader χειροκίνητα"
	fi

	# Επιβεβαίωση: οι παλιές εκδόσεις δεν πρέπει να υπάρχουν πια στο menu.
	if [ "$grub_updated" -eq 1 ] && [ -f "$GRUB_CFG" ] && [ "${#dead[@]}" -gt 0 ]; then
		for v in "${dead[@]}"; do
			if grep -q -- "$v" "$GRUB_CFG"; then
				fail "το $GRUB_CFG ακόμα αναφέρει την έκδοση $v - έλεγξε το bootloader"
			fi
		done
	fi
fi

# --- σύνοψη -------------------------------------------------------------------

info ""
if [ "$failures" -eq 0 ]; then
	info "ολοκληρώθηκε: αφαιρέθηκαν $removed παλιά πακέτα πυρήνων, bootloader ενημερώθηκε"
	notify dialog-information \
		"Ολοκληρώθηκε: $removed παλιά πακέτα πυρήνων αφαιρέθηκαν και το bootloader ενημερώθηκε."
	exit 0
fi

warn "τελείωσε με $failures σφάλμα(τα) - δες τις γραμμές ERROR παραπάνω"
notify dialog-error \
	"Ο ενημέρωση/καθαρισμός τελείωσε με $failures σφάλμα(τα) - δες το τερματικό."
exit 1
