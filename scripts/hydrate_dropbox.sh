#!/bin/bash
# Hydrate ALL checked Dropbox folders using Quick Look (parallel batches)
# Batches of 8 files, 6 seconds per batch ≈ ~2.5 hours for 18K files

LOG="/tmp/dropbox_hydrate_all.log"
BASE="/Users/scottwofford/Dropbox"

FOLDERS=(
    "0 Luthien"
    "1 Scott & Maria Shared Folder"
    "2 Recreation and Trips"
    "25 Scott's Home Movies"
    "26 Scott Songs"
    "3 GoGetEm"
    "4 Music-Guitar_Ableton"
    "5 Official Docs"
    "6 personal notes"
    "7 Books Lectures Lists"
    "9 Archives UT Misc"
    "Dad, Maria & Scott"
    "Family Room"
    "Pictures"
    "Public"
    "Scott, Maria & Linda Shared Folder"
    "Screenshots"
    "Sent files"
    "Wedding Pictures"
    "scott & maria shared folder"
)

echo "=== Dropbox Full Hydration ===" > "$LOG"
echo "Started: $(date)" >> "$LOG"
echo "" >> "$LOG"

HYDRATED=0
STILL_EMPTY=0
ALREADY_LOCAL=0
BATCH_SIZE=8
BATCH=()
TOTAL_PROCESSED=0

hydrate_batch() {
    if [[ ${#BATCH[@]} -eq 0 ]]; then return; fi

    PIDS=()
    for f in "${BATCH[@]}"; do
        qlmanage -p "$f" >/dev/null 2>&1 &
        PIDS+=($!)
    done

    sleep 6

    for p in "${PIDS[@]}"; do
        kill $p 2>/dev/null
    done
    wait 2>/dev/null

    for f in "${BATCH[@]}"; do
        NEW_SIZE=$(stat -f "%z" "$f" 2>/dev/null)
        if [[ "$NEW_SIZE" -gt 0 ]]; then
            HYDRATED=$((HYDRATED + 1))
        else
            STILL_EMPTY=$((STILL_EMPTY + 1))
        fi
    done

    BATCH=()
}

for folder in "${FOLDERS[@]}"; do
    FULL="$BASE/$folder"
    [[ ! -d "$FULL" ]] && continue

    echo "📁 Processing: $folder" >> "$LOG"
    FOLDER_COUNT=0

    while IFS= read -r -d '' file; do
        basename=$(basename "$file")
        [[ "$basename" == ~* ]] && continue
        [[ "$basename" == .DS_Store ]] && continue

        SIZE=$(stat -f "%z" "$file" 2>/dev/null)
        if [[ "$SIZE" -gt 0 ]]; then
            ALREADY_LOCAL=$((ALREADY_LOCAL + 1))
            continue
        fi

        BATCH+=("$file")
        FOLDER_COUNT=$((FOLDER_COUNT + 1))
        TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))

        if [[ ${#BATCH[@]} -ge $BATCH_SIZE ]]; then
            hydrate_batch
            # Progress update every 100 files
            if [[ $((TOTAL_PROCESSED % 100)) -lt $BATCH_SIZE ]]; then
                echo "  ... $TOTAL_PROCESSED files processed ($HYDRATED hydrated, $STILL_EMPTY empty) - $(date)" >> "$LOG"
            fi
        fi
    done < <(find "$FULL" -type f -print0 2>/dev/null)

    # Flush remaining batch for this folder
    hydrate_batch
    echo "  → $FOLDER_COUNT files in this folder" >> "$LOG"
done

echo "" >> "$LOG"
echo "=== FINAL SUMMARY ===" >> "$LOG"
echo "Finished: $(date)" >> "$LOG"
echo "Already local:  $ALREADY_LOCAL" >> "$LOG"
echo "Hydrated:       $HYDRATED" >> "$LOG"
echo "Genuinely empty: $STILL_EMPTY" >> "$LOG"
echo "Total processed: $TOTAL_PROCESSED" >> "$LOG"
echo "" >> "$LOG"
echo "DONE ✅" >> "$LOG"
