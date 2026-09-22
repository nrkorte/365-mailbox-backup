#!/usr/bin/env bash
# Read-only status polling for the job queue - safe to call as often as
# needed, never blocks. Prints JSON.
#
# Usage:
#   queue-status.sh <job_id>              one job, merged with live progress
#   queue-status.sh --mailbox <mailbox>   array of all jobs for that mailbox
#   queue-status.sh --all                 array of every job
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/queue-lib.sh"

merge_progress() {
    local jf="$1"
    local id pf
    id=$(jq -r '.id' "$jf")
    pf=$(progress_file "$id")
    if [ -f "$pf" ]; then
        jq -s '.[0] + {progress: .[1]}' "$jf" "$pf"
    else
        jq '. + {progress: null}' "$jf"
    fi
}

arg="${1:-}"

if [ "$arg" = "--all" ]; then
    shopt -s nullglob
    files=("$JOBS_DIR"/*.json)
    shopt -u nullglob
    if [ "${#files[@]}" -eq 0 ]; then
        echo "[]"
        exit 0
    fi
    for f in "${files[@]}"; do merge_progress "$f"; done | jq -s 'sort_by(.id)'
    exit 0
fi

if [ "$arg" = "--mailbox" ]; then
    mailbox="${2:-}"
    if [ -z "$mailbox" ]; then
        echo '{"error": "missing mailbox argument"}' >&2
        exit 1
    fi
    shopt -s nullglob
    files=("$JOBS_DIR"/*.json)
    shopt -u nullglob
    matched=()
    for f in "${files[@]}"; do
        if [ "$(jq -r '.mailbox' "$f")" = "$mailbox" ]; then
            matched+=("$f")
        fi
    done
    if [ "${#matched[@]}" -eq 0 ]; then
        echo "[]"
        exit 0
    fi
    for f in "${matched[@]}"; do merge_progress "$f"; done | jq -s 'sort_by(.id)'
    exit 0
fi

if [ -z "$arg" ]; then
    echo '{"error": "usage: queue-status.sh <job_id> | --mailbox <mailbox> | --all"}' >&2
    exit 1
fi

jf="$(job_file "$arg")"
if [ ! -f "$jf" ]; then
    echo "{\"error\": \"no such job: $arg\"}" >&2
    exit 1
fi

merge_progress "$jf"
