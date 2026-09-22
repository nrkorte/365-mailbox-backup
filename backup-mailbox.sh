#!/usr/bin/env bash
# Backs up a single M365 mailbox to a .pst file via the M365Backup console app.
#
# Usage:
#   ./backup-mailbox.sh
#   ./backup-mailbox.sh someone@example.com
#   ./backup-mailbox.sh someone@example.com --from 2023-01-01 --to 2024-01-01
set -euo pipefail

mailbox=""
from=""
to=""

while [ $# -gt 0 ]; do
    case "$1" in
        --from)
            from="$2"
            shift 2
            ;;
        --to)
            to="$2"
            shift 2
            ;;
        *)
            if [ -n "$mailbox" ]; then
                echo "Unexpected argument: $1" >&2
                exit 1
            fi
            mailbox="$1"
            shift
            ;;
    esac
done

if [ -z "$mailbox" ]; then
    read -r -p "Enter the mailbox email address to back up: " mailbox
fi

if ! [[ "$mailbox" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    echo "'$mailbox' doesn't look like a valid email address." >&2
    exit 1
fi

# PST directory and filename (including the [MONYYYY-MONYYYY] chunk label, if
# --from/--to are given) are computed by Program.cs itself - see
# DefaultBackupDirectory()/DefaultPstFileName() - so there's one source of
# truth for that naming instead of two copies drifting apart.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

dotnet_args=("$mailbox")
[ -n "$from" ] && dotnet_args+=(--from "$from")
[ -n "$to" ] && dotnet_args+=(--to "$to")

dotnet run -- "${dotnet_args[@]}"
