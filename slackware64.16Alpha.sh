#!/bin/bash
#
# slackware64.16Alpha.sh — Αυτόματη αναβάθμιση Slackware από το δέντρο εγκατάστασης
#
# Βασίζεται στο UPGRADE.TXT του Slackware και εκτελεί τα βήματα 0–8:
#   0. Μετάβαση σε single-user mode (προαιρετικό, με επιβεβαίωση)
#   1. Αφαίρεση πακέτων που δεν ανήκουν πλέον στη διανομή
#   2. Αναβάθμιση glibc (aaa_glibc-solibs)
#   3. Αναβάθμιση pkgtools/tar/xz/findutils/mkinitrd
#   4. Αναβάθμιση όλων των υπόλοιπων πακέτων (--install-new)
#   5. Εγκατάσταση των περισσότερων *.new αρχείων στο /etc (με .bak)
#   6. Ενημέρωση initrd και bootloader (GRUB / LILO / ELILO)
#   7. Επιστροφή σε multi-user mode
#   8. Επανεκκίνηση
#
# Χρήση:
#   sudo ./slackware_upgrade.sh              # διαδραστικά, με επιβεβαιώσεις
#   sudo ./slackware_upgrade.sh --yes        # χωρίς ερωτήσεις (προσοχή!)
#   sudo ./slackware_upgrade.sh --help
#
# Το script πρέπει να εκτελεστεί ΜΕΣΑ στο δέντρο εγκατάστασης, εκεί όπου
# υπάρχουν το ChangeLog.txt και ο κατάλογος slackware/ ή slackware64/.
# Συνιστάται να τρέξει από κονσόλα (όχι από τερματικό μέσα σε X), γιατί
# το βήμα 0 τερματίζει την γραφική συνεδρία.

set -u
shopt -s nullglob

INSTALL_TREE="$(pwd)"
ARCH_DIR=""
CHANGELOG="ChangeLog.txt"
YES=0
SINGLE_USER=0
LOG_FILE=""

# ---------------------------------------------------------------- βοηθητικές

usage() {
    cat <<EOF
Χρήση: sudo $0 [--yes] [--help]

  --yes, -y   Να μην γίνεται καμία ερώτηση επιβεβαίωσης.
  --help, -h  Εμφάνιση αυτού του μηνύματος.

Το script πρέπει να εκτελεστεί μέσα στο δέντρο εγκατάστασης του Slackware
(όπου υπάρχουν ChangeLog.txt και slackware/ ή slackware64/).
EOF
}

die() {
    echo "" >&2
    echo "ΣΦΑΛΜΑ: $*" >&2
    echo "Η αναβάθμιση σταμάτησε. Διόρθωσε το πρόβλημα και ξανατρέξε το script." >&2
    exit 1
}

warn() {
    echo "  ! $*"
}

section() {
    echo ""
    echo "=========================================================="
    echo " $*"
    echo "=========================================================="
}

confirm() {
    # Επιστρέφει 0 αν ο χρήστης συμφωνήσει, 1 αν αρνηθεί.
    local prompt="$1" answer

    if [ "$YES" -eq 1 ]; then
        return 0
    fi

    printf '%s [y/N] ' "$prompt"
    read -r answer || return 1
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Δεν βρέθηκε η εντολή '$1'."
}

# ------------------------------------------------------------ αρχικοί έλεγχοι

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)  YES=1 ;;
            -h|--help) usage; exit 0 ;;
            *)         usage; die "Άγνωστη παράμετρος: $1" ;;
        esac
        shift
    done
}

check_environment() {
    [ "$(id -u)" -eq 0 ] || die "Το script χρειάζεται root (sudo $0)."

    [ -f "$CHANGELOG" ] || die "Δεν βρίσκομαι σε δέντρο εγκατάστασης Slackware: λείπει το $CHANGELOG."

    if [ -d slackware64 ]; then
        ARCH_DIR="slackware64"
    elif [ -d slackware ]; then
        ARCH_DIR="slackware"
    else
        die "Δεν βρέθηκε κατάλογος slackware/ ή slackware64/ στον $(pwd)."
    fi

    [ -d "$ARCH_DIR/a" ] || die "Ο κατάλογος $ARCH_DIR/a δεν υπάρχει — ελλιπές δέντρο εγκατάστασης."

    require_cmd upgradepkg
    require_cmd removepkg
}

start_logging() {
    local candidate
    candidate="/var/log/slackware_upgrade_$(date +%Y%m%d-%H%M%S).log"

    # Αν δεν μπορούμε να γράψουμε στο /var/log, συνεχίζουμε χωρίς log.
    if ! { : >> "$candidate"; } 2>/dev/null; then
        warn "Δεν ήταν δυνατή η εγγραφή στο $candidate — συνεχίζω χωρίς log."
        return 0
    fi

    LOG_FILE="$candidate"

    # Όλη η έξοδος (και τα prompts) καταγράφεται και στην οθόνη και στο log.
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# ------------------------------------------------------------------- βήματα

step0_single_user() {
    section "Βήμα 0: Single-user mode"

    if confirm "Να γίνει τώρα μετάβαση σε single-user mode (telinit 1);"; then
        telinit 1 || die "Το telinit 1 απέτυχε."
        SINGLE_USER=1
    else
        warn "Συνεχίζω σε multi-user mode (περισσότερα πράγματα μπορούν να πάνε στραβά)."
    fi
}

step1_remove_obsolete() {
    section "Βήμα 1: Αφαίρεση παρωχημένων πακέτων"

    local failed
    failed="$(mktemp)" || die "Δεν μπόρεσα να δημιουργήσω προσωρινό αρχείο."

    echo "Αφαίρεση πακέτων που δεν ανήκουν πλέον στο Slackware:"

    # Το ChangeLog.txt γράφει "κάποιο/πακέτο.txz:  Removed." για κάθε αφαίρεση.
    # Αγνοούμε extra/, pasture/ και testing/ όπως ορίζει το UPGRADE.TXT.
    grep -v -e '^extra/' -e '^pasture/' -e '^testing/' "$CHANGELOG" \
        | grep -E 'txz:  Removed\.$' \
        | cut -f 1 -d ':' \
        | while IFS= read -r package; do
            [ -n "$package" ] || continue
            local name
            name="$(basename "$package" .txz)"

            # Μόνο αν το πακέτο είναι εγκατεστημένο.
            if [ -r "/var/lib/pkgtools/packages/$name" ]; then
                if removepkg --terse "$name"; then
                    echo "  - Αφαιρέθηκε: $name"
                else
                    echo "  ! Αποτυχία αφαίρεσης: $name"
                    echo "$name" >> "$failed"
                fi
            fi
        done

    if [ -s "$failed" ]; then
        warn "Κάποια πακέτα δεν αφαιρέθηκαν: $(tr '\n' ' ' < "$failed")"
        rm -f "$failed"
        die "Η αφαίρεση παρωχημένων πακέτων απέτυχε."
    fi

    rm -f "$failed"
}

step2_glibc() {
    section "Βήμα 2: Αναβάθμιση glibc"

    if ! compgen -G "$ARCH_DIR/a/aaa_glibc-solibs-*.txz" >/dev/null; then
        die "Δεν βρέθηκε πακέτο aaa_glibc-solibs-*.txz στον $ARCH_DIR/a/."
    fi

    # Απαραίτητο πριν από την αναβάθμιση των υπόλοιπων πακέτων.
    upgradepkg --install-new --terse "$ARCH_DIR"/a/aaa_glibc-solibs-*.txz \
        || die "Η αναβάθμιση της glibc απέτυχε."
}

step3_tools() {
    section "Βήμα 3: Αναβάθμιση pkgtools και εργαλείων"

    local tool pattern
    for tool in pkgtools tar xz findutils mkinitrd; do
        pattern="$ARCH_DIR/a/$tool-*.txz"
        if compgen -G "$pattern" >/dev/null; then
            echo "  - $tool"
            # Το pattern πρέπει να μείνει χωρίς quotes για να γίνει glob expansion.
            # shellcheck disable=SC2086
            upgradepkg --terse $pattern || die "Η αναβάθμιση του $tool απέτυχε."
        else
            warn "Δεν βρέθηκε πακέτο $tool — παράλειψη."
        fi
    done
}

step4_upgrade_all() {
    section "Βήμα 4: Αναβάθμιση όλων των πακέτων (--install-new)"

    local count
    count="$(find "$ARCH_DIR" -type f -name '*.txz' | wc -l)"
    [ "$count" -gt 0 ] || die "Δεν βρέθηκαν πακέτα .txz στον $ARCH_DIR/."

    echo "Βρέθηκαν $count πακέτα. Αυτό το βήμα μπορεί να πάρει αρκετή ώρα..."

    # Σε παρτίδες, ώστε να μην ξεπεραστεί το όριο ορισμάτων της γραμμής εντολών.
    find "$ARCH_DIR" -type f -name '*.txz' -print0 \
        | sort -z \
        | xargs -0 -r -n 100 upgradepkg --install-new --terse \
        || die "Η μαζική αναβάθμιση απέτυχε. Διόρθωσε το σφάλμα πριν συνεχίσεις."

    echo "Η αναβάθμιση των πακέτων ολοκληρώθηκε."
}

step5_configs() {
    section "Βήμα 5: Ενημέρωση αρχείων ρυθμίσεων στο /etc"

    echo "Τα αρχεία *.new θα εγκατασταθούν και τα παλιά θα κρατηθούν ως *.bak."
    echo "Εξαιρούνται: rc.inet1.conf, rc.local, group, passwd, shadow."

    if ! confirm "Να εγκατασταθούν τα *.new αρχεία στο /etc;"; then
        warn "Παραλείπω την αυτόματη εγκατάσταση — θα χρειαστεί να τα ελέγξεις με το χέρι."
        return 0
    fi

    (
        cd /etc || exit 1

        find . -type f -name '*.new' -print0 | while IFS= read -r -d '' configfile; do
            case "$configfile" in
                ./rc.d/rc.inet1.conf.new|./rc.d/rc.local.new|./group.new|./passwd.new|./shadow.new)
                    echo "  - Παράλειψη (ευαίσθητο): $configfile"
                    continue
                    ;;
            esac

            target="${configfile%.new}"

            # Κρατάμε αντίγραφο της παλιάς ρύθμισης πριν την αντικατάσταση.
            if [ -e "$target" ]; then
                cp -a "$target" "$target.bak" || echo "  ! Δεν έγινε backup: $target"
            fi

            mv --verbose "$configfile" "$target" || echo "  ! Αποτυχία μετακίνησης: $configfile"
        done
    )

    # Ξεχωριστή περίπτωση εκτός /etc, όπως αναφέρει το UPGRADE.TXT.
    if [ -f /usr/share/vim/vimrc.new ]; then
        if [ -f /usr/share/vim/vimrc ]; then
            cp -a /usr/share/vim/vimrc /usr/share/vim/vimrc.bak
        fi
        mv --verbose /usr/share/vim/vimrc.new /usr/share/vim/vimrc
    fi

    warn "Έλεγξε τα *.new/*.bak στο /etc και πρόσθεσε τις δικές σου αλλαγές."
}

step6_bootloader() {
    section "Βήμα 6: Ενημέρωση initrd και bootloader"

    # --- initrd / grub.cfg μέσω geninitrd -----------------------------------
    if command -v geninitrd >/dev/null 2>&1; then
        geninitrd || die "Το geninitrd απέτυχε — μην κάνεις reboot."
    else
        warn "Το geninitrd δεν βρέθηκε. Αν χρησιμοποιείς initrd, ενημέρωσέ το με το χέρι."
    fi

    # --- bootloader ---------------------------------------------------------
    if [ -d /sys/firmware/efi ]; then
        echo "Ανιχνεύθηκε σύστημα UEFI."

        if [ -f /boot/grub/grub.cfg ] && command -v grub-install >/dev/null 2>&1; then
            if confirm "Εγκατάσταση του GRUB για UEFI (grub-install);"; then
                grub-install || die "Το grub-install απέτυχε — μην κάνεις reboot."
            else
                warn "Ο GRUB δεν εγκαταστάθηκε — μην κάνεις reboot πριν το ελέγξεις."
            fi
        elif command -v eliloconfig >/dev/null 2>&1; then
            if confirm "Εγκατάσταση του ELILO (eliloconfig);"; then
                eliloconfig || die "Το eliloconfig απέτυχε — μην κάνεις reboot."
            else
                warn "Το ELILO δεν εγκαταστάθηκε — μην κάνεις reboot πριν το ελέγξεις."
            fi
        else
            warn "Δεν βρέθηκε GRUB ή ELILO για UEFI. Ενημέρωσε τον bootloader με το χέρι."
        fi
    else
        echo "Ανιχνεύθηκε σύστημα legacy BIOS."

        if [ -f /etc/lilo.conf ] && command -v lilo >/dev/null 2>&1; then
            echo "Έλεγξε ότι τα paths του /etc/lilo.conf δείχνουν σε έγκυρο kernel."
            if confirm "Επανεγκατάσταση του LILO;"; then
                lilo || die "Το lilo απέτυχε — μην κάνεις reboot."
            else
                warn "Το LILO δεν ενημερώθηκε — μην κάνεις reboot πριν το ελέγξεις."
            fi
        elif [ -f /boot/grub/grub.cfg ] && command -v grub-install >/dev/null 2>&1; then
            local bootdev
            bootdev="/dev/sda"
            if [ "$YES" -eq 0 ]; then
                printf 'Συσκευή boot για GRUB (π.χ. /dev/sda) [%s]: ' "$bootdev"
                read -r answer && [ -n "$answer" ] && bootdev="$answer"
            fi
            [ -b "$bootdev" ] || die "Η συσκευή '$bootdev' δεν είναι έγκυρο block device."
            if confirm "Εγκατάσταση του GRUB στο $bootdev;"; then
                grub-install --target=i386-pc "$bootdev" \
                    || die "Το grub-install απέτυχε — μην κάνεις reboot."
            else
                warn "Ο GRUB δεν εγκαταστάθηκε — μην κάνεις reboot πριν το ελέγξεις."
            fi
        else
            warn "Δεν βρέθηκε LILO ή GRUB. Ενημέρωσε τον bootloader με το χέρι."
        fi
    fi
}

step7_multi_user() {
    section "Βήμα 7: Επιστροφή σε multi-user mode"

    if [ "$SINGLE_USER" -eq 1 ]; then
        telinit 3 || die "Το telinit 3 απέτυχε."
    else
        echo "Το σύστημα ήταν ήδη σε multi-user mode — δεν χρειάζεται ενέργεια."
    fi
}

step8_reboot() {
    section "Βήμα 8: Επανεκκίνηση"

    if confirm "Να γίνει επανεκκίνηση τώρα για το νέο kernel;"; then
        reboot
    else
        echo "Η αναβάθμιση ολοκληρώθηκε. Κάνε reboot όταν είσαι έτοιμος."
    fi
}

# --------------------------------------------------------------------- main

main() {
    parse_args "$@"
    check_environment
    start_logging

    section "Αναβάθμιση Slackware"
    echo "Δέντρο εγκατάστασης : $INSTALL_TREE"
    echo "Κατάλογος πακέτων   : $ARCH_DIR"
    echo "Αρχείο καταγραφής   : ${LOG_FILE:-(χωρίς log)}"

    if ! confirm "Να ξεκινήσει η αναβάθμιση;"; then
        echo "Ακυρώθηκε."
        exit 0
    fi

    step0_single_user
    step1_remove_obsolete
    step2_glibc
    step3_tools
    step4_upgrade_all
    step5_configs
    step6_bootloader
    step7_multi_user
    step8_reboot

    section "Τέλος"
    if [ -n "$LOG_FILE" ]; then
        echo "Το αρχείο καταγραφής βρίσκεται στο: $LOG_FILE"
    fi
}

main "$@"
