#!/bin/bash

# Αρχείο για την αποθήκευση της ημερομηνίας της τελευταίας ενημέρωσης
LAST_UPDATE_FILE="$HOME/.last_system_update"

# Ενημέρωση κάθε 2 ημέρες (2 * 24 * 3600)
UPDATE_INTERVAL_DAYS=2
UPDATE_INTERVAL_SECONDS=$((UPDATE_INTERVAL_DAYS * 24 * 3600))

CURRENT_TIME=$(date +%s)

if [ -f "$LAST_UPDATE_FILE" ]; then
    LAST_UPDATE=$(cat "$LAST_UPDATE_FILE")
else
    LAST_UPDATE=0
fi

# Αν το αρχείο δεν περιέχει καθαρό αριθμό (κενό, μισό κείμενο κ.λπ.),
# ο αριθμητικός υπολογισμός παρακάτω θα δώνει "arithmetic syntax error"
# και το script θα τερματιζόταν αμέσως χωρίς ενημέρωση.
# Θεωρούμε λοιπόν κάτι τέτοιο ως "καμία προηγούμενη ενημέρωση".
case "$LAST_UPDATE" in
    ''|*[!0-9]*) LAST_UPDATE=0 ;;
esac

# Έλεγχος αν έχουν περάσει 2 ημέρες από την τελευταία ενημέρωση
if [ $((CURRENT_TIME - LAST_UPDATE)) -ge $UPDATE_INTERVAL_SECONDS ]; then
    echo "=========================================="
    echo "   Έναρξη διήμερης ενημέρωσης Fedora       "
    echo "=========================================="
    echo ""

    # 1. Ενημέρωση αποθετηρίων και αναβάθμιση πακέτων RPM (με --refresh)
    # 2. Ενημέρωση Flatpaks
    # 3. Καθαρισμός: αφαίρεση ορφανών/περιττών πακέτων RPM και
    #    αχρησιμοποίητων Flatpak runtime (κενός χώρος στο δίσκο)
    sudo dnf upgrade --refresh -y && \
    sudo dnf autoremove -y && \
    flatpak update -y && \
    flatpak uninstall --unused -y

    # Αν όλες οι εντολές ολοκληρώθηκαν με επιτυχία ($? == 0)
    if [ $? -eq 0 ]; then
        # Αποθήκευση της σημερινής ημερομηνίας
        echo "$CURRENT_TIME" > "$LAST_UPDATE_FILE"
        
        # Αποστολή notification στο KDE Plasma
        notify-send -i system-software-update "Ενημέρωση Συστήματος" "Όλες οι αναβαθμίσεις (DNF & Flatpak) ολοκληρώθηκαν με επιτυχία!"
        
        echo ""
        echo "Η ενημέρωση ολοκληρώθηκε! Το παράθυρο θα κλείσει σε 5 δευτερόλεπτα..."
        sleep 5
    else
        notify-send -i dialog-error "Ενημέρωση Συστήματος" "Παρουσιάστηκε κάποιο σφάλμα κατά την ενημέρωση."
        echo ""
        echo "Παρουσιάστηκε σφάλμα. Πίεσε Enter για έξοδο..."
        read
    fi
fi
