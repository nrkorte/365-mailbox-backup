#!/usr/bin/env bash
# Shared helpers for the M365Backup job queue. Sourced by queue-submit.sh,
# queue-status.sh, queue-cancel.sh, and queue-worker.sh - not meant to be run
# directly.
set -euo pipefail

QUEUE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="$QUEUE_DIR/jobs"
PENDING_DIR="$QUEUE_DIR/pending"
RUNNING_DIR="$QUEUE_DIR/running"
PROGRESS_DIR="$QUEUE_DIR/progress"
LOGS_DIR="$QUEUE_DIR/logs"
SEQ_FILE="$QUEUE_DIR/seq"
SEQ_LOCK="$QUEUE_DIR/seq.lock"
WORKER_LOCK="$QUEUE_DIR/worker.lock"
# Touched by queue-maintenance.sh before a controlled restart (e.g. to pick
# up a library upgrade); the claim loop below refuses to start a NEW job
# while it exists, but never touches a job already running. Removed by
# queue-maintenance.sh once the restart it triggered has completed.
MAINTENANCE_PAUSE_FLAG="$QUEUE_DIR/.maintenance-pause"
BACKUP_DIR="${M365_BACKUP_DIR:-/data/backups}"
# Lives under BACKUP_DIR (on /data, not under the repo like PROGRESS_DIR) -
# these are per-run scratch files (skip counters/reasons for a backup job)
# that queue-worker.sh reads and folds into the job record, then deletes, so
# they never accumulate on disk (see run_job's manifest cleanup).
MANIFEST_DIR="$BACKUP_DIR/manifests"
MAILBOX_REGEX='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'

job_file() { echo "$JOBS_DIR/$1.json"; }
pending_marker() { echo "$PENDING_DIR/$1"; }
running_marker() { echo "$RUNNING_DIR/$1"; }
progress_file() { echo "$PROGRESS_DIR/$1.json"; }
manifest_file() { echo "$MANIFEST_DIR/$1.json"; }
log_file() { echo "$LOGS_DIR/$1.log"; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

validate_mailbox() {
    if ! [[ "$1" =~ $MAILBOX_REGEX ]]; then
        echo "'$1' doesn't look like a valid email address." >&2
        return 1
    fi
}

# Allocates the next FIFO sequence number under flock, so concurrent submits
# (e.g. Node firing one queue-submit.sh per year-chunk back to back) never
# collide even if they land within the same clock tick.
next_seq() {
    local seq
    exec 9>"$SEQ_LOCK"
    flock 9
    seq=$(( $(cat "$SEQ_FILE" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$seq" > "$SEQ_FILE"
    flock -u 9
    exec 9>&-
    printf '%010d' "$seq"
}

new_job_id() {
    printf '%s-%s' "$(next_seq)" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# Atomically updates a JSON file: file, jq filter, then any extra jq flags
# (e.g. --arg k v) to splice into the filter. NEVER do `jq '...' f > f` -
# the redirect truncates f before jq even reads it. Write-to-temp-then-mv
# (same directory - a rename syscall) is what makes concurrent reads
# (queue-status.sh polling mid-write) always see a fully-old or fully-new
# file, never a torn one.
atomic_jq_update() {
    local file="$1"; shift
    local filter="$1"; shift
    local tmp="${file}.tmp.$$"
    if jq "$@" "$filter" "$file" > "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

atomic_write() {
    local file="$1"
    local content="$2"
    local tmp="${file}.tmp.$$"
    printf '%s' "$content" > "$tmp"
    mv "$tmp" "$file"
}

# Cancels EVERY job for a mailbox (queued or running), then deletes every
# .pst/.zip file already produced for that mailbox - intentionally
# mailbox-scoped, not job-scoped, so sibling date-range chunks queued behind
# the running one are cancelled too. Prints one JSON summary to stdout.
cascade_cancel_mailbox() {
    local mailbox="$1"
    local note="${2:-}"
    local killed_pid=""
    local cancelled_ids=()

    # Loop until nothing's left for this mailbox in pending/ or running/. A
    # single linear pass has a race: killing a running job takes real time,
    # and the worker's claim loop can claim the NEXT pending chunk for this
    # mailbox before a one-shot pending scan gets to it. Looping catches that
    # rare remainder (a sibling claimed mid-kill).
    local marker id jf job_mailbox pid waited did_something running_id
    while :; do
        did_something=false

        for marker in "$PENDING_DIR"/*; do
            [ -e "$marker" ] || continue
            id=$(basename "$marker")
            jf=$(job_file "$id")
            [ -f "$jf" ] || continue
            job_mailbox=$(jq -r '.mailbox' "$jf")
            [ "$job_mailbox" = "$mailbox" ] || continue

            rm -f "$marker"
            atomic_jq_update "$jf" '.status = "cancelled" | .finished_at = $now | .note = ($note // .note) | .will_retry = false | .next_job_id = null' \
                --arg now "$(now_iso)" --arg note "$note"
            cancelled_ids+=("$id")
            did_something=true
        done

        running_id=""
        for marker in "$RUNNING_DIR"/*; do
            [ -e "$marker" ] || continue
            id=$(basename "$marker")
            jf=$(job_file "$id")
            [ -f "$jf" ] || continue
            job_mailbox=$(jq -r '.mailbox' "$jf")
            [ "$job_mailbox" = "$mailbox" ] || continue
            running_id="$id"
            break
        done

        if [ -n "$running_id" ]; then
            jf=$(job_file "$running_id")

            # Set cancel_requested BEFORE signaling - this is how the
            # worker's wait loop later tells "killed on purpose" apart from
            # "crashed."
            atomic_jq_update "$jf" '.cancel_requested = true'

            pid=$(jq -r '.pid // empty' "$jf")
            waited=0
            while [ -z "$pid" ] && [ "$waited" -lt 10 ]; do
                sleep 0.5
                pid=$(jq -r '.pid // empty' "$jf")
                waited=$((waited + 1))
            done

            if is_job_pid_alive "$pid"; then
                kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
                waited=0
                while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 15 ]; do
                    sleep 1
                    waited=$((waited + 1))
                done
                if kill -0 "$pid" 2>/dev/null; then
                    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
                    sleep 1
                fi
                [ -z "$killed_pid" ] && killed_pid="$pid"
            fi

            rm -f "$(running_marker "$running_id")"
            atomic_jq_update "$jf" '.status = "cancelled" | .finished_at = $now | .note = ($note // .note) | .will_retry = false | .next_job_id = null' \
                --arg now "$(now_iso)" --arg note "$note"
            cancelled_ids+=("$running_id")
            did_something=true
        fi

        [ "$did_something" = true ] || break
    done

    # nullglob only removes UNMATCHED patterns that contain a wildcard - a
    # literal "$mailbox.zip" has no `*`, so it would always appear in the
    # array whether or not the file exists. Test it explicitly instead.
    shopt -s nullglob
    local files=("$BACKUP_DIR/$mailbox"*.pst)
    local resume_dirs=("$BACKUP_DIR/.resume-$mailbox"*)
    shopt -u nullglob
    local zip_path="$BACKUP_DIR/$mailbox.zip"
    [ -f "$zip_path" ] && files+=("$zip_path")
    local deleted_json="[]"
    if [ "${#files[@]}" -gt 0 ]; then
        deleted_json=$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)
        rm -f "${files[@]}"
    fi
    # An intentional cancel means "clean slate" - a resume-state directory
    # left behind would otherwise make a later resubmission silently resume
    # instead of starting over. This is the only place that deletes it; a
    # plain failure/interrupted-restart must NOT reach this function (see
    # handle_interrupted_backup below) - that's what makes resume possible.
    [ "${#resume_dirs[@]}" -gt 0 ] && rm -rf "${resume_dirs[@]}"

    local cancelled_json="[]"
    if [ "${#cancelled_ids[@]}" -gt 0 ]; then
        cancelled_json=$(printf '%s\n' "${cancelled_ids[@]}" | jq -R . | jq -s .)
    fi

    local killed_pid_json="null"
    [ -n "$killed_pid" ] && killed_pid_json="$killed_pid"

    jq -n --arg mailbox "$mailbox" --argjson killed_pid "$killed_pid_json" \
        --argjson cancelled_jobs "$cancelled_json" --argjson deleted_files "$deleted_json" \
        '{mailbox: $mailbox, killed_pid: $killed_pid, cancelled_jobs: $cancelled_jobs, deleted_files: $deleted_files}'
}

# Handles a backup job that ended WITHOUT an explicit user cancel - either a
# plain nonzero exit from run_job's own wait, or a job left status=running by
# an unclean worker restart. Never deletes the job's PST/resume-state -
# Program.cs's ResumeState keeps a durable record of what's already copied,
# so a later attempt can pick back up near where this one left off. Marks
# the job failed, then auto-requeues the same mailbox/range so it resumes on
# its own - unless it's already failed M365_MAX_AUTO_RETRIES times in a row,
# to avoid a tight crash-loop against a genuinely unfixable problem.
#
# $5 (reason) is the factual "what happened" fragment; this function appends
# whether that means an automatic retry or a give-up, so .note never goes
# stale. Also sets max_retries/will_retry/next_job_id so other tools (e.g. a
# status dashboard) can read the outcome without parsing .note text.
handle_interrupted_backup() {
    local id="$1" mailbox="$2" from="$3" to="$4" reason="$5"
    local jf max_retries retry_count next_retry submit_args new_job new_job_id note

    jf="$(job_file "$id")"
    max_retries="${M365_MAX_AUTO_RETRIES:-5}"
    retry_count=$(jq -r '.retry_count // 0' "$jf")
    next_retry=$((retry_count + 1))

    rm -f "$(running_marker "$id")"

    if [ "$next_retry" -gt "$max_retries" ]; then
        note="$reason - gave up after $retry_count consecutive failure(s), PST/resume-state kept for manual resubmission"
        atomic_jq_update "$jf" '
            .status = "failed" | .finished_at = $now | .note = $note
            | .max_retries = $max_retries | .will_retry = false | .next_job_id = null' \
            --arg now "$(now_iso)" --arg note "$note" --argjson max_retries "$max_retries"
        echo "[$(now_iso)] Job $id ($mailbox) - giving up after $retry_count consecutive failure(s); PST/resume-state kept, resubmit manually once fixed." >&2
        return
    fi

    submit_args=(backup "$mailbox" --retry-count "$next_retry")
    [ -n "$from" ] && submit_args+=(--from "$from")
    [ -n "$to" ] && submit_args+=(--to "$to")
    new_job=$("$QUEUE_DIR/queue-submit.sh" "${submit_args[@]}")
    new_job_id=$(jq -r '.job_id' <<< "$new_job")

    note="$reason - resuming automatically as job $new_job_id"
    atomic_jq_update "$jf" '
        .status = "failed" | .finished_at = $now | .note = $note
        | .max_retries = $max_retries | .will_retry = true | .next_job_id = $next_job_id' \
        --arg now "$(now_iso)" --arg note "$note" --argjson max_retries "$max_retries" --arg next_job_id "$new_job_id"
    echo "[$(now_iso)] Job $id ($mailbox) - auto-requeued as $new_job_id (retry $next_retry of $max_retries)." >&2
}

# Handles a backup job durably known to have finished successfully before an
# unclean worker restart interrupted it - either .phase already reached
# "uploading", or the manifest file shows completed:true even though .phase
# never advanced past "backup". Either way, resuming the backup itself would
# redo the ENTIRE mailbox from scratch (ResumeState.Complete() already
# deleted the resume-state directory), so only the upload half gets retried.
#
# $4/$5/$6 (items_expected/copied/skipped) are optional - pass them only
# when read from a still-present manifest. Omit them for the
# phase=="uploading" case, where run_job already folded those in correctly.
handle_backup_already_complete() {
    local id="$1" mailbox="$2" jf="$3"
    local items_expected="${4:-}" items_copied="${5:-}" items_skipped="${6:-}"
    local new_upload_job new_upload_job_id

    rm -f "$(running_marker "$id")"
    new_upload_job=$("$QUEUE_DIR/queue-submit.sh" upload "$mailbox")
    new_upload_job_id=$(jq -r '.job_id' <<< "$new_upload_job")

    atomic_jq_update "$jf" '.status = "failed" | .finished_at = $now
        | .note = "worker restarted after the backup finished - backup was already complete, retrying upload only as job \($next_id)"
        | .will_retry = true | .next_job_id = $next_id' \
        --arg now "$(now_iso)" --arg next_id "$new_upload_job_id"

    if [ -n "$items_expected" ]; then
        atomic_jq_update "$jf" \
            '.items_expected = $expected | .items_copied = $copied | .items_skipped = $skipped' \
            --argjson expected "$items_expected" --argjson copied "$items_copied" --argjson skipped "$items_skipped"
    fi

    echo "[$(now_iso)] Job $id ($mailbox) - backup already complete, auto-requeued upload-only as $new_upload_job_id." >&2
}

# True only if $pid is alive AND its cmdline looks like one of our job
# processes. A bare `kill -0 $pid` isn't enough: after a reboot, PIDs restart
# from low numbers, so a stale pid can coincidentally match an unrelated
# process that's alive right now.
is_job_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    [[ "$cmdline" == *"M365Backup.dll"* ]] || [[ "$cmdline" == *"upload-mailbox-backup.sh"* ]]
}

mailbox_for_job() {
    local jf
    jf=$(job_file "$1")
    [ -f "$jf" ] || { echo "No such job: $1" >&2; return 1; }
    jq -r '.mailbox' "$jf"
}

# True (exit 0) if $1 contains at least one real job marker, ignoring the
# .gitkeep placeholder kept so the (normally empty) pending/running dirs
# survive in git. A plain `ls -A` check isn't enough on its own - .gitkeep
# always makes the directory look non-empty.
_has_job_markers() {
    [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -not -name '.gitkeep' 2>/dev/null)" ]
}

any_running_jobs() { _has_job_markers "$RUNNING_DIR"; }
any_pending_jobs() { _has_job_markers "$PENDING_DIR"; }

# "Idle" means nothing running AND nothing waiting to run - used by the
# weekly reboot window (queue-weekly-reboot.sh), which unlike the daily
# drain (queue-maintenance.sh) never waits around for the queue to clear;
# it just checks once and skips entirely if there's anything to lose.
queue_is_idle() {
    ! any_running_jobs && ! any_pending_jobs
}
