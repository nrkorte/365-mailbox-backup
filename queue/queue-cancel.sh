#!/usr/bin/env bash
# Cancels a mailbox's backup effort - not just one job. If a mailbox has
# multiple date-range chunk jobs queued/running, this kills the running one
# (if any), drops every other queued job for that same mailbox, and deletes
# every .pst/.zip already produced for it. No partial backups are kept.
#
# Usage:
#   queue-cancel.sh <mailbox>
#   queue-cancel.sh --job <job_id>   (resolved to its mailbox first)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/queue-lib.sh"

arg="${1:-}"

if [ "$arg" = "--job" ]; then
    job_id="${2:-}"
    if [ -z "$job_id" ]; then
        echo '{"error": "missing job_id after --job"}' >&2
        exit 1
    fi
    mailbox="$(mailbox_for_job "$job_id")" || exit 1
elif [ -n "$arg" ]; then
    mailbox="$arg"
else
    echo '{"error": "usage: queue-cancel.sh <mailbox> | --job <job_id>"}' >&2
    exit 1
fi

cascade_cancel_mailbox "$mailbox" "cancelled by user request"
