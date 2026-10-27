#!/usr/bin/env bash
# Re-apply the migrations of origin/rc/ncw-v31-7 (ca0cfce, v31.0.8.1, NC 31) -> origin/rc/ncw-v33-2 (35fa7bc, v33.0.9.1, NC 33) by hand.
# From: https://github.com/IONOS-Productivity/ncw-server/commit/ca0cfceb70cea68baa307ac9f43201d753de9ba3
# To:   https://github.com/IONOS-Productivity/ncw-server/commit/35fa7bcbf61048148cc7001b01a41c2887cfd7cf
# Diff: https://github.com/IONOS-Productivity/ncw-server/compare/ca0cfceb70cea68baa307ac9f43201d753de9ba3...35fa7bcbf61048148cc7001b01a41c2887cfd7cf
# Generated 2026-10-27T06:44:55+00:00 by migration-notes.sh from the ref diff, not from a database.
# Generator: IONOS-Productivity/nc-docs-and-tools@e385bd90730
#            https://github.com/IONOS-Productivity/nc-docs-and-tools/commit/e385bd90730dfce803b8e489cec2c6c12217ca99
#
# Re-run with the same arguments (from the directory it was started in):
#   tools/release-notes.sh upgrade \
#     --from origin/rc/ncw-v31-7 \
#     --to origin/rc/ncw-v33-2 \
#     --output . \
#     --skip-migration 'tables:2200Date20260819000000:regenerates the UUID of every table' \
#     --skip-migration 'tables:2020Date20260513185340:regenerates the UUID of every column and view' \
#     --skip-migration 'files_sharing:33000Date20251030081948:does nothing, changeSchema returns null so auto increment is never dropped'
#
# Run by an admin or a job after a DB backup. Needs jq and occ. A replay runs the
# whole migration again, also for instances that already applied it. That normally
# works, but a migration whose guard is missing or incomplete fails (e.g. "index
# already exists"). Each migration runs on its own; failures are logged and listed
# at the end, the exit code is 1 then. There is no rollback.
#
# migrations:execute only works for enabled apps, so an app the customer has
# disabled is enabled for its migrations and disabled again right after, unless it
# was never installed on the instance (enabling would install it): that app is
# skipped. Apps that are already enabled are never touched. Whatever happens
# (failures, SIGTERM), the app states and the maintenance mode are put back as they
# were before the run.
# Only SIGKILL or a lost container can skip that; the log then says which apps
# were enabled by the script ("enabling disabled app").
#
# Log: one JSON object per line on stdout (run_id ties a run together), for
# Kibana. LOG_FORMAT=text prints plain lines. OCC overrides the occ command.
#
# DESTRUCTIVE and DATA-MUTATING migrations are marked above their line.
#
# Not in the list, new at origin/rc/ncw-v33-2: eurooffice
# Installing them runs their migrations.
#
# Left out on purpose (not safe to replay, or replaying changes nothing), review by hand:
#   files_sharing 33000Date20251030081948: does nothing, changeSchema returns null so auto increment is never dropped
#   tables 2020Date20260513185340: regenerates the UUID of every column and view
#   tables 2200Date20260819000000: regenerates the UUID of every table

OCC="${OCC:-./occ}"
STEP=origin/rc/ncw-v31-7\ \(ca0cfce\,\ v31.0.8.1\,\ NC\ 31\)\ -\>\ origin/rc/ncw-v33-2\ \(35fa7bc\,\ v33.0.9.1\,\ NC\ 33\)
TOTAL=71
LEFT_OUT=files_sharing:33000Date20251030081948\ tables:2020Date20260513185340\ tables:2200Date20260819000000
LOG_FORMAT="${LOG_FORMAT:-json}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ok=0
failed=""
enabled_by_us=""
maint_by_us=0

if ! command -v jq >/dev/null; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

# log LEVEL MESSAGE [key=value ...]
log() {
    local level=$1 msg=$2
    shift 2
    if [ "$LOG_FORMAT" = text ]; then
        printf '%s %-5s %s' "$(date -u +%FT%TZ)" "$level" "$msg"
        [ $# -gt 0 ] && printf ' %s' "$@"
        printf '\n'
    else
        jq -cn --arg ts "$(date -u +%FT%TZ)" --arg level "$level" --arg msg "$msg" --arg run_id "$RUN_ID" \
            '{ts: $ts, level: $level, msg: $msg, run_id: $run_id}
             + ([$ARGS.positional[] | index("=") as $i | {(.[:$i]): .[$i + 1:]}] | add // {})' \
            --args "$@"
    fi
}

# Run occ (no global warnings): stdout ends up in $OUT and stderr in $ERR (where
# occ prints errors, and banners such as "require upgrade"), the return value is
# occ's exit code. occ runs in the background and is waited for, so that a SIGTERM
# is handled at once instead of after a long migration, and can stop it.
# OCC_ENV may hold NAME=value pairs for this one call.
CHILD=""
occq() {
    local f rc
    f=$(mktemp)
    # shellcheck disable=SC2086  # OCC and OCC_ENV are split on purpose
    env $OCC_ENV $OCC "$@" --no-warnings >"$f" 2>"$f.err" &
    CHILD=$!
    wait "$CHILD"
    rc=$?
    CHILD=""
    OUT=$(cat "$f")
    ERR=$(cat "$f.err")
    rm -f "$f" "$f.err"
    return "$rc"
}

on_signal() {
    log WARN "signal received, stopping" signal="$1"
    if [ -n "$CHILD" ]; then
        kill "$CHILD" 2>/dev/null
        wait "$CHILD" 2>/dev/null
    fi
    exit "$2"
}

app_state() {
    jq -r --arg a "$1" \
        'if .enabled[$a] != null then "enabled" elif .disabled[$a] != null then "disabled" else "absent" end' \
        <<<"$apps_json"
}

unlist() {
    local a rest=""
    for a in $enabled_by_us; do
        [ "$a" = "$1" ] || rest="$rest $a"
    done
    enabled_by_us=$rest
}

# Make the app usable for migrations:execute. Fails (skipping its migrations) when
# the app is not on this instance or cannot be enabled.
app_begin() {
    local app=$1
    case "$(app_state "$app")" in
        enabled)
            log INFO "app already enabled, left as is" app="$app"
            return 0 ;;
        disabled)
            # app:list adds " (installed x.y.z)" once the app was enabled for the
            # first time. Without it the app was never installed here, and enabling
            # it would install it (tables and all migrations) instead of upgrading.
            if ! jq -e --arg a "$app" '.disabled[$a] | contains("(installed ")' >/dev/null <<<"$apps_json"; then
                log WARN "app was never installed on this instance, its migrations are skipped" app="$app"
                return 1
            fi
            log INFO "enabling disabled app" app="$app"
            # Listed before the call, and kept listed when it fails: app:enable
            # writes enabled=yes before it dispatches events and migrates config,
            # so it can exit nonzero with the app already enabled. app_end and the
            # cleanup disable it again, which is harmless when it never got enabled.
            enabled_by_us="$enabled_by_us $app"
            if occq app:enable "$app"; then
                log INFO "app enabled" app="$app" output="$OUT"
                return 0
            fi
            log ERROR "app:enable failed, its migrations are skipped" app="$app" output="$OUT" error="$ERR"
            failed="$failed $app:enable"
            return 1 ;;
        *)
            log WARN "app is not on this instance, its migrations are skipped" app="$app"
            return 1 ;;
    esac
}

# Disable the app again when app_begin enabled it.
app_end() {
    local app=$1
    case " $enabled_by_us " in *" $app "*) ;; *) return 0 ;; esac
    if occq app:disable "$app"; then
        log INFO "app disabled again" app="$app" output="$OUT"
        unlist "$app"
    else
        log ERROR "app:disable failed, the cleanup tries again" app="$app" output="$OUT" error="$ERR"
    fi
}

migrate() {
    local app=$1 ver=$2 rc OCC_ENV=NC_debug=true
    occq migrations:execute "$app" "$ver"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok=$((ok + 1))
        log INFO "migration ok" app="$app" version="$ver"
    else
        failed="$failed $app:$ver"
        log ERROR "migration failed" app="$app" version="$ver" exit_code="$rc" output="$OUT" error="$ERR"
    fi
}

cleanup() {
    local rc=$? app n
    trap - EXIT
    # shellcheck disable=SC2086  # split the list on purpose
    for app in $enabled_by_us; do
        if occq app:disable "$app"; then
            log INFO "app disabled again (cleanup)" app="$app" output="$OUT"
        else
            log ERROR "could not disable the app, disable it by hand" app="$app" output="$OUT" error="$ERR"
        fi
    done
    if [ "$maint_by_us" = 1 ]; then
        if occq maintenance:mode --off; then
            log INFO "maintenance mode off" output="$OUT"
        else
            log ERROR "could not switch maintenance mode off, do it by hand" output="$OUT" error="$ERR"
        fi
    fi
    # shellcheck disable=SC2086  # split the list on purpose
    set -- $failed
    n=$#
    if [ "$n" -gt 0 ]; then
        log ERROR "finished with failures" step="$STEP" migrations_ok="$ok" migrations_failed="$n" migrations_skipped="$((TOTAL - ok - n))" failed="${failed# }" exit_code="$rc"
    else
        log INFO "finished" step="$STEP" migrations_ok="$ok" migrations_failed="0" migrations_skipped="$((TOTAL - ok))" exit_code="$rc"
    fi
}

apps_json=$($OCC app:list --output=json_pretty --no-warnings 2>/dev/null)
if ! jq -e . >/dev/null 2>&1 <<<"$apps_json"; then
    log ERROR "cannot read the app list, nothing was changed"
    exit 1
fi
if $OCC maintenance:mode --no-warnings 2>/dev/null | grep -q 'currently enabled'; then
    maint_was_on=1
else
    maint_was_on=0
fi

log INFO "start" step="$STEP" occ="$OCC" host="$(hostname)" migrations="$TOTAL" maintenance_was_on="$maint_was_on"
[ -z "$LEFT_OUT" ] || log WARN "migrations left out on purpose (not safe to replay, or replaying changes nothing), review by hand" left_out="$LEFT_OUT"
trap cleanup EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

if [ "$maint_was_on" = 0 ]; then
    # Claimed before the call: a SIGTERM after occ saved maintenance=true but
    # before occq returns would otherwise leave the tenant in maintenance mode.
    maint_by_us=1
    if occq maintenance:mode --on; then
        log INFO "maintenance mode on" output="$OUT"
    else
        maint_by_us=0
        log ERROR "cannot switch maintenance mode on, nothing was changed" output="$OUT" error="$ERR"
        exit 1
    fi
else
    log INFO "maintenance mode was already on, left as is"
fi

# core
# DESTRUCTIVE: $result = $qb->executeQuery();
migrate core 32000Date20250731062008
migrate core 32000Date20250806110519
migrate core 33000Date20250819110529
migrate core 33000Date20251013110519
migrate core 33000Date20251023110529
# DATA-MUTATING: $result = $qb->executeQuery();
migrate core 33000Date20251023120529
# DESTRUCTIVE: $qb->executeStatement();
migrate core 33000Date20251106131209
migrate core 33000Date20251124110529
migrate core 33000Date20251126152410
# DESTRUCTIVE: $table->dropIndex('mounts_user_root_path_index');
migrate core 33000Date20251209123503
# DESTRUCTIVE: $schema->dropTable('whats_new');
migrate core 33000Date20260126120000
migrate core 34000Date20260318095645

# activity
if app_begin activity; then
    # DESTRUCTIVE: $table->dropIndex('amp_user');
    migrate activity 8000Date20260603120000
fi
app_end activity

# calendar
if app_begin calendar; then
    migrate calendar 5050Date20250701000001
    migrate calendar 5050Date20250701000002
    migrate calendar 5050Date20250701000003
    migrate calendar 5050Date20250701000004
    migrate calendar 6060Date20260801000000
fi
app_end calendar

# circles
if app_begin circles; then
    migrate circles 0032Date20250623120204
fi
app_end circles

# cloud_federation_api
if app_begin cloud_federation_api; then
    migrate cloud_federation_api 1016Date202502262004
fi
app_end cloud_federation_api

# collectives
if app_begin collectives; then
    migrate collectives 030300Date20251009000000
    migrate collectives 030301Date20251029000000
    migrate collectives 030400Date20251103000000
    # DESTRUCTIVE: $table->dropColumn('circle_unique_id');
    migrate collectives 040301Date20260427000000
fi
app_end collectives

# contacts
if app_begin contacts; then
    migrate contacts 8004Date20260130131217
    # DATA-MUTATING: $qb->executeStatement();
    migrate contacts 8005Date20260418120000
fi
app_end contacts

# dav
if app_begin dav; then
    migrate dav 1034Date20250605132605
    # DESTRUCTIVE: $qb->delete('properties')
    migrate dav 1034Date20250813093701
    migrate dav 1036Date20251202000000
    # DATA-MUTATING: $qb->executeStatement();
    migrate dav 1040Date20260805000000
fi
app_end dav

# files_external
if app_begin files_external; then
    migrate files_external 1025Date20250228162604
fi
app_end files_external

# files_sharing
if app_begin files_sharing; then
    migrate files_sharing 32000Date20251017081948
fi
app_end files_sharing

# forms
if app_begin forms; then
    # DATA-MUTATING: ->executeStatement();
    migrate forms 050300Date20250914000000
    migrate forms 050300Date20260303000000
    migrate forms 050300Date20260413233000
    migrate forms 050300Date20260511121033
    migrate forms 050300Date20260713180000
    # DATA-MUTATING: ->executeStatement();
    migrate forms 050300Date20260716000000
fi
app_end forms

# groupfolders
if app_begin groupfolders; then
    migrate groupfolders 2000002Date20250927142943
    migrate groupfolders 20002Date20250612140256
    migrate groupfolders 2100000Date20251104151854
    migrate groupfolders 21000Date20250925152053
    migrate groupfolders 2300000Date20260722115802
fi
app_end groupfolders

# integration_openai
if app_begin integration_openai; then
    migrate integration_openai 030800Date20250812122830
    migrate integration_openai 030900Date20251006152735
fi
app_end integration_openai

# spreed
if app_begin spreed; then
    # DESTRUCTIVE: $table->dropColumn('active_guests');
    migrate spreed 22000Date20250526102909
    migrate spreed 22000Date20250623142327
    # DESTRUCTIVE: $table->dropColumn('last_read_message');
    migrate spreed 22000Date20250710124258
    # DATA-MUTATING: $result = $query->executeQuery();
    migrate spreed 22000Date20250803160923
    migrate spreed 22000Date20250813122342
    migrate spreed 22001Date20250927174738
    migrate spreed 23000Date20251030090219
    migrate spreed 23000Date20251105125333
    migrate spreed 23000Date20251114105144
    # DESTRUCTIVE: $table->dropColumn('has_scheduled_messages');
    migrate spreed 23000Date20251215204457
    migrate spreed 23000Date20251218142903
    # DESTRUCTIVE: $table->dropColumn('created_at');
    migrate spreed 23000Date20260107162758
fi
app_end spreed

# tables
if app_begin tables; then
    migrate tables 000920Date20250422000000
    migrate tables 001000Date20250720000000
    migrate tables 002001Date20260109000000
    migrate tables 1000Date20251208192653
    # DATA-MUTATING: $affected = $qb->executeStatement();
    migrate tables 1000Date20260324000000
    migrate tables 2010Date20260414000000
    # DATA-MUTATING: $result = $selectQb->executeQuery();
    migrate tables 2200Date20260707000000
    # DATA-MUTATING: $updatedCount = $qb->executeStatement();
    migrate tables 2200Date20260723000000
    # DATA-MUTATING: $select = $qbSelect->executeQuery();
    migrate tables 2202Date20260825184226
    migrate tables 2203Date20260821000000
    migrate tables 2210Date20260709000000
fi
app_end tables

# text
if app_begin text; then
    migrate text 080000Date20260331132113
fi
app_end text

# twofactor_totp
if app_begin twofactor_totp; then
    # DATA-MUTATING: $qb->delete('twofactor_totp_secrets')
    migrate twofactor_totp 140000Date202503027114917
fi
app_end twofactor_totp

# webhook_listeners
if app_begin webhook_listeners; then
    migrate webhook_listeners 1500Date20251007130000
fi
app_end webhook_listeners

[ -z "$failed" ] || exit 1
