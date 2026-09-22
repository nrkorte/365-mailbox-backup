#!/usr/bin/env bash
# Enqueues one backup or upload job - a fast, one-shot command (writes a job
# record and returns) so a remote caller (e.g. over SSH) never has to hold a
# connection open for the job's actual (potentially multi-hour) run.
#
# A "backup" job runs its own upload automatically once it (and every
# sibling date-range chunk queued for the same mailbox, if any) reaches a
# terminal state - see queue-worker.sh's run_job for the chained
# backup -> zip -> upload flow. Callers should NOT poll for backup
# completion and then submit an "upload" job themselves - just submit
# "backup" and wait for that one job to reach done/failed.
#
# "upload" remains submittable directly only for manual recovery - e.g.
# retrying the upload step on its own after a previous verify failure left
# local files in place, without re-running the backup.
#
# Usage:
#   queue-submit.sh backup <mailbox> [--from yyyy-MM-dd] [--to yyyy-MM-dd]
#   queue-submit.sh upload <mailbox>   (manual recovery only - see above)
#
# Prints {"job_id": "...", "status": "queued", "mailbox": "...", "type": "..."}
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/queue-lib.sh"

type="${1:-}"
mailbox="${2:-}"
shift 2 || true

if [ "$type" != "backup" ] && [ "$type" != "upload" ]; then
    echo '{"error": "first argument must be \"backup\" or \"upload\""}' >&2
    exit 1
fi

if [ -z "$mailbox" ]; then
    echo '{"error": "missing mailbox argument"}' >&2
    exit 1
fi

if ! validate_mailbox "$mailbox"; then
    echo "{\"error\": \"'$mailbox' doesn't look like a valid email address\"}" >&2
    exit 1
fi

from=""
to=""
retry_count=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from) from="$2"; shift 2 ;;
        --to) to="$2"; shift 2 ;;
        # Internal only - not documented above. Only queue-lib.sh's own
        # auto-requeue helper ever passes this, to carry a resumed backup's
        # attempt count forward onto its replacement job record so the
        # retry cap (M365_MAX_AUTO_RETRIES) can be enforced across attempts.
        --retry-count) retry_count="$2"; shift 2 ;;
        *) echo "{\"error\": \"unknown argument: $1\"}" >&2; exit 1 ;;
    esac
done

if [ "$type" = "upload" ] && { [ -n "$from" ] || [ -n "$to" ]; }; then
    echo '{"error": "--from/--to are not valid for upload jobs"}' >&2
    exit 1
fi

date_regex='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
for d in "$from" "$to"; do
    if [ -n "$d" ] && ! [[ "$d" =~ $date_regex ]]; then
        echo "{\"error\": \"'$d' isn't a valid date - use yyyy-MM-dd\"}" >&2
        exit 1
    fi
done

id="$(new_job_id)"
jf="$(job_file "$id")"

from_json="null"; [ -n "$from" ] && from_json="\"$from\""
to_json="null"; [ -n "$to" ] && to_json="\"$to\""

# manifest_file only ever gets a real (absolute) path for backup jobs - it's
# where queue-worker.sh points Program.cs's --manifest-file at, then reads,
# folds into items_expected/items_copied/items_skipped below, and deletes
# once the job finishes. Upload jobs never produce one.
manifest_file_json="null"
[ "$type" = "backup" ] && manifest_file_json="\"$(manifest_file "$id")\""

jq -n \
    --arg id "$id" --arg type "$type" --arg mailbox "$mailbox" \
    --argjson from "$from_json" --argjson to "$to_json" \
    --arg submitted_at "$(now_iso)" \
    --arg log_file "queue/logs/$id.log" \
    --arg progress_file "queue/progress/$id.json" \
    --argjson manifest_file "$manifest_file_json" \
    --argjson retry_count "$retry_count" \
    --argjson max_retries "${M365_MAX_AUTO_RETRIES:-5}" \
    '{
        id: $id, type: $type, mailbox: $mailbox, from: $from, to: $to,
        status: "queued", cancel_requested: false, pid: null, exit_code: null,
        submitted_at: $submitted_at, started_at: null, finished_at: null,
        log_file: $log_file, progress_file: $progress_file,
        manifest_file: $manifest_file,
        items_expected: null, items_copied: null, items_skipped: null,
        note: null,
        phase: null,
        retry_count: $retry_count,
        max_retries: $max_retries,
        will_retry: null,
        next_job_id: null
    }' > "$jf"

: > "$(pending_marker "$id")"

jq -c '{job_id: .id, status: .status, mailbox: .mailbox, type: .type}' "$jf"
