#!/usr/bin/env bash
# Runs weekly via a systemd timer, doing the one thing the daily
# queue-maintenance.sh cycle can't: apply a kernel (or any other
# reboot-required) upgrade, since restarting just the queue service never
# picks those up.
#
# Deliberately does NOT wait for the queue to drain the way
# queue-maintenance.sh does, and does NOT touch MAINTENANCE_PAUSE_FLAG - if
# the daily drain is still mid-wait for a long-running job (a single mailbox
# can run 24+ hours), clearing that flag here would let new jobs get claimed
# while the daily restart is still pending. So: check once, and if the queue
# isn't idle *right now*, skip this week entirely.
#
# The only residual risk is a job getting submitted in the brief window
# between the idle check and the reboot - acceptable because that's just an
# ordinary auto-recovering interruption (see Program.cs's ResumeState /
# queue-lib.sh's handle_interrupted_backup).
#
# Must run as root (apt, systemctl reboot).
#
# Usage: queue-weekly-reboot.sh [--dry-run]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/queue-lib.sh"

log() { echo "[$(now_iso)] $*"; }

dry_run=false
[ "${1:-}" = "--dry-run" ] && dry_run=true

if ! queue_is_idle; then
    log "Queue is not idle - skipping this week's reboot, will try again next Sunday."
    exit 0
fi

log "Queue is idle - running upgrades and rebooting to apply anything that needs it (e.g. a new kernel)."

if [ "$dry_run" = true ]; then
    log "[dry-run] would run: apt-get update && apt-get -y dist-upgrade, then systemctl reboot"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 -y dist-upgrade

log "Rebooting now."
systemctl reboot
