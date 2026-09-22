#!/usr/bin/env bash
# Prints a full, human-readable status report for one mailbox: every queue
# job tied to it (with live progress if one is running), any local .pst/.zip
# chunks sitting in /data/backups not yet uploaded, and whatever's already in
# Dropbox for it. Read-only - never modifies anything.
#
# Usage:
#   ./mailbox-status.sh someone@example.com
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/queue/queue-lib.sh"

mailbox="${1:-}"
if [ -z "$mailbox" ]; then
    echo "Usage: $0 <mailbox>" >&2
    exit 1
fi

if ! validate_mailbox "$mailbox"; then
    exit 1
fi

human_size() {
    if command -v numfmt > /dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"
    else
        echo "${1}B"
    fi
}

describe_range() {
    local from="$1" to="$2"
    if [ -z "$from" ] && [ -z "$to" ]; then
        echo "full mailbox (no date range)"
    elif [ -n "$from" ] && [ -n "$to" ]; then
        echo "$from to $to"
    elif [ -n "$from" ]; then
        echo "since $from"
    else
        echo "before $to"
    fi
}

echo "Mailbox: $mailbox"
echo ""

# ---------------------------------------------------------------------------
# 1. Queue jobs
# ---------------------------------------------------------------------------
shopt -s nullglob
job_files=("$JOBS_DIR"/*.json)
shopt -u nullglob

matched_jobs=()
for jf in "${job_files[@]}"; do
    if [ "$(jq -r '.mailbox' "$jf")" = "$mailbox" ]; then
        matched_jobs+=("$jf")
    fi
done

echo "Queue jobs (${#matched_jobs[@]}):"
if [ "${#matched_jobs[@]}" -eq 0 ]; then
    echo "  none"
else
    # Sort by job id (filename), which is chronological submission order.
    IFS=$'\n' matched_jobs=($(printf '%s\n' "${matched_jobs[@]}" | sort))
    unset IFS

    for jf in "${matched_jobs[@]}"; do
        id=$(jq -r '.id' "$jf")
        type=$(jq -r '.type' "$jf")
        status=$(jq -r '.status' "$jf")
        from=$(jq -r '.from // empty' "$jf")
        to=$(jq -r '.to // empty' "$jf")
        submitted_at=$(jq -r '.submitted_at' "$jf")
        started_at=$(jq -r '.started_at // empty' "$jf")
        finished_at=$(jq -r '.finished_at // empty' "$jf")
        note=$(jq -r '.note // empty' "$jf")
        items_expected=$(jq -r '.items_expected // empty' "$jf")
        items_copied=$(jq -r '.items_copied // empty' "$jf")
        items_skipped=$(jq -r '.items_skipped // empty' "$jf")
        phase=$(jq -r '.phase // empty' "$jf")
        log_rel=$(jq -r '.log_file' "$jf")

        range_desc=""
        [ "$type" = "backup" ] && range_desc=" [$(describe_range "$from" "$to")]"

        printf "  [%-9s] %s  %s%s\n" "$status" "$id" "$type" "$range_desc"
        printf "      submitted %s" "$submitted_at"
        [ -n "$started_at" ] && printf ", started %s" "$started_at"
        [ -n "$finished_at" ] && printf ", finished %s" "$finished_at"
        echo ""

        if [ "$status" = "running" ]; then
            if [ "$phase" = "uploading" ]; then
                echo "      progress: backup done, now zipping/uploading to Dropbox - see log for live rclone output"
            else
                pf="$(progress_file "$id")"
                if [ -f "$pf" ]; then
                    percent=$(jq -r '.percent' "$pf")
                    copied=$(jq -r '.copied_items' "$pf")
                    total=$(jq -r '.total_items' "$pf")
                    current_folder=$(jq -r '.current_folder' "$pf")
                    echo "      progress: ${percent}% (${copied}/${total} items), currently on: ${current_folder:-<counting>}"
                else
                    echo "      progress: still computing total item count (this can take a couple of minutes for large mailboxes)"
                fi
            fi
        fi

        if [ -n "$items_skipped" ] && [ "$items_skipped" != "null" ] && [ "$items_skipped" -gt 0 ] 2>/dev/null; then
            echo "      items: ${items_copied:-?} copied, ${items_skipped} skipped (of ${items_expected:-?} expected)"
        fi

        if [ -n "$note" ] && [ "$note" != "null" ]; then
            echo "      note: $note"
        fi
        echo "      log: $log_rel"
    done
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Local files not yet uploaded
# ---------------------------------------------------------------------------
backup_dir="${M365_BACKUP_DIR:-/data/backups}"
shopt -s nullglob
local_files=("$backup_dir/$mailbox"*.pst)
shopt -u nullglob
zip_path="$backup_dir/$mailbox.zip"
[ -f "$zip_path" ] && local_files+=("$zip_path")

echo "Local files in $backup_dir (not yet uploaded): ${#local_files[@]}"
if [ "${#local_files[@]}" -eq 0 ]; then
    echo "  none"
else
    for f in "${local_files[@]}"; do
        size=$(stat --printf='%s' "$f" 2>/dev/null || echo 0)
        printf "  %s  (%s)\n" "$(basename "$f")" "$(human_size "$size")"
    done
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Dropbox
# ---------------------------------------------------------------------------
config_file="$script_dir/rclone-upload.env"
if [ -f "$config_file" ]; then
    # shellcheck disable=SC1090
    source "$config_file"
fi

if [ -n "${RCLONE_REMOTE:-}" ] && [ -n "${DROPBOX_FOLDER:-}" ]; then
    dropbox_listing="$(rclone lsjson "$RCLONE_REMOTE:$DROPBOX_FOLDER" 2>/dev/null || true)"
    dropbox_matches="$(echo "$dropbox_listing" | jq -r --arg mb "$mailbox" '.[]? | select(.Name | startswith($mb)) | "\(.Name)\t\(.Size)"' 2>/dev/null || true)"

    if [ -z "$dropbox_matches" ]; then
        echo "Dropbox ($DROPBOX_FOLDER): 0 file(s)"
        echo "  none"
    else
        count=$(echo "$dropbox_matches" | wc -l)
        echo "Dropbox ($DROPBOX_FOLDER): $count file(s)"
        while IFS=$'\t' read -r name size; do
            printf "  %s  (%s)\n" "$name" "$(human_size "$size")"
        done <<< "$dropbox_matches"
    fi
else
    echo "Dropbox: skipped - rclone-upload.env not found or incomplete"
fi
