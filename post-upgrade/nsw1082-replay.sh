#!/bin/sh

# SPDX-FileCopyrightText: 2026 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

# NSW-1082: one-off replay of migrations that are recorded in oc_migrations but
# were not in effect after the v31 -> v33 upgrade. Remove together with
# upgrade-31.0.8.1-ca0cfce-to-33.0.9.1-35fa7bc.sh once all tenants are done.
#
# Usage: nsw1082-replay.sh [run|record]
#   run      (default) replay if this tenant needs it. Started with exec by post-upgrade.sh,
#            so it is PID 1 of the Job and gets the stop signal (see run_forwarding).
#   record   remember the installed version before an upgrade. Called from apps-enable.sh.
#
# Neither mode fails the caller: problems are logged, and a replay that did not run
# to the end is tried again next time (the marker stays unset).
#
# The replay only runs when all of these hold:
#   - a version before the upgrade is recorded (appconfig ncw_tools,
#     post_upgrade.nextcloud_version_before_upgrade; a fresh install has none)
#   - that version is within FROM_VERSION..TO_VERSION (inclusive, build number ignored)
#   - the code now deployed is at least TO_VERSION (the migrations exist in it)
#   - the marker ncw_tools/post_upgrade.nsw1082_replay is not set
#
# That marker is a JSON object once the replay ran: state (done when every failure,
# if any, only says that the thing already exists, else done_with_failures), at,
# run_id, step, the Nextcloud versions before the upgrade and deployed, the
# ok/failed/failed_benign/skipped counts, and failed_migrations with the first error
# text of each and whether it is benign (never: an app that could not be enabled or
# disabled again, maintenance mode that stayed on, a duplicate entry).
#
# Environment (for tests): NEXTCLOUD_DIR, OCC_CMD, REPLAY_SCRIPT

set -u

# Range the generated script was made for (see its header, STEP=)
readonly FROM_VERSION="31.0.8.1"
readonly TO_VERSION="33.0.9.1"

readonly MARKER_APP="ncw_tools"
readonly MARKER_KEY="post_upgrade.nsw1082_replay"
readonly PRE_VERSION_KEY="post_upgrade.nextcloud_version_before_upgrade"

# A failed migration whose error says this only found the schema already in place,
# which is expected when a migration without a guard is replayed. "Duplicate entry"
# is a data error: it is checked first, because MySQL puts the conflicting value into
# the text and that value can contain "already exists".
readonly BENIGN_ERROR_RE='already (defined|exists)|duplicate (key|column) name'
readonly DATA_ERROR_RE='duplicate entry'

EXIT_CODE=0
BDIR="$( dirname "${0}" )"
NEXTCLOUD_DIR="${NEXTCLOUD_DIR:-${BDIR}/../..}"
OCC_CMD="${OCC_CMD:-php ${NEXTCLOUD_DIR}/occ}"
REPLAY_SCRIPT="${REPLAY_SCRIPT:-${BDIR}/upgrade-31.0.8.1-ca0cfce-to-33.0.9.1-35fa7bc.sh}"

log_info() {
	printf '[i] NSW-1082 replay: %s\n' "${*}"
}

log_warn() {
	printf '[!] NSW-1082 replay: %s\n' "${*}"
}

occ() {
	# shellcheck disable=SC2086 # OCC_CMD is a command with arguments on purpose
	${OCC_CMD} "${@}"
}

# run_forwarding CMD [ARGS...]
# Runs CMD in the background, passes TERM, INT and QUIT on to it as TERM, waits until
# it has finished (also after a signal, so its cleanup completes) and leaves its exit
# code in RUN_RC. RUN_INTERRUPTED is 1 when a signal was received.
#
# The replay script puts app states and maintenance mode back in its own TERM
# handler, so the signal has to reach it, and this shell must not exit before the
# handler is done. A shell that is PID 1 ignores a signal it has no handler for, and a
# shell that dies leaves its children running until the container is killed. The stop
# signal is not always TERM: the php-fpm image, and the manager image built on it, set
# STOPSIGNAL SIGQUIT, which docker stop and a containerd based kubelet send. The child
# always gets TERM (shells ignore INT and QUIT in background jobs anyway).
run_forwarding() {
	RUN_INTERRUPTED=0
	"${@}" &
	_run_pid=$!
	trap 'RUN_INTERRUPTED=1; kill -TERM "${_run_pid}" 2>/dev/null' TERM INT QUIT
	wait "${_run_pid}"
	RUN_RC=$?
	# A trapped signal ends the first wait early while the child is still cleaning up
	while kill -0 "${_run_pid}" 2>/dev/null; do
		wait "${_run_pid}"
		RUN_RC=$?
	done
	trap - TERM INT QUIT
}

is_version() {
	printf '%s' "${1}" | grep -Eq '^[0-9]+(\.[0-9]+){3}'
}

# version_ge A B: true if A >= B, comparing the first four numbers only
version_ge() {
	_i=1
	while [ "${_i}" -le 4 ]; do
		_a="$( printf '%s' "${1}" | cut -d. -f"${_i}" )"
		_b="$( printf '%s' "${2}" | cut -d. -f"${_i}" )"
		if [ "${_a}" -gt "${_b}" ]; then
			return 0
		fi
		if [ "${_a}" -lt "${_b}" ]; then
			return 1
		fi
		_i=$(( _i + 1 ))
	done
	return 0
}

# version_in_range V: FROM_VERSION <= V <= TO_VERSION
version_in_range() {
	version_ge "${1}" "${FROM_VERSION}" && version_ge "${TO_VERSION}" "${1}"
}

# The recorded version belongs to the upgrade that is waiting for its replay. It is
# dropped once it is used up or can never make the tenant eligible.
forget_pre_version() {
	occ config:app:delete "${MARKER_APP}" "${PRE_VERSION_KEY}" >/dev/null 2>&1 || true
}

# Remember the installed version, before upgrade.sh changes it. An existing value
# is kept only while it can still qualify (in range: an earlier upgrade could not
# run the replay yet, or this is a retry). Anything else is replaced, so a value
# left by an upgrade that did not qualify, or by one where this script did not run,
# can never hide a tenant that qualifies now.
record_pre_upgrade_version() {
	_marker="$( occ config:app:get "${MARKER_APP}" "${MARKER_KEY}" 2>/dev/null || true )"
	if [ -n "${_marker}" ]; then
		return 0
	fi

	_existing="$( occ config:app:get "${MARKER_APP}" "${PRE_VERSION_KEY}" 2>/dev/null || true )"
	if is_version "${_existing}" && version_in_range "${_existing}"; then
		log_info "keeping the recorded version before the upgrade (${_existing})"
		return 0
	fi

	_installed="$( occ config:system:get version 2>/dev/null || true )"
	if ! is_version "${_installed}"; then
		log_warn "cannot read the installed version ('${_installed}'), nothing recorded"
		return 0
	fi
	if ! occ config:app:set "${MARKER_APP}" "${PRE_VERSION_KEY}" --value="${_installed}" >/dev/null; then
		log_warn "could not record the version before the upgrade"
		return 0
	fi
	log_info "version before the upgrade: ${_installed}"
}

# The first error text of every failed migration, from the replay's own log lines,
# as {"<app>:<version>": "<text>"}. An app that could not be enabled is "<app>:enable".
# Two restore steps that failed at the end are listed the same way. They are not in the
# replay's "failed" list and need a manual fix: maintenance mode that stayed on is
# "maintenance:off", an app that stayed enabled is "<app>:disable".
failure_details() {
	grep '"level":"ERROR"' "${1}" | jq -cs '
		reduce (.[] | select(.msg == "migration failed" or (.msg | startswith("app:enable failed"))
				or (.msg | startswith("could not switch maintenance mode off")) or (.msg | startswith("could not disable the app")))) as $l ({};
			. + {(if $l.msg == "migration failed" then $l.app + ":" + $l.version
					elif ($l.msg | startswith("app:enable failed")) then $l.app + ":enable"
					elif ($l.msg | startswith("could not disable the app")) then $l.app + ":disable"
					else "maintenance:off" end):
				((($l.error // "") + " " + ($l.output // "")) | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
					# occ prints this while maintenance mode is on, and the usage line after an error: not the message
					| sub("^Nextcloud is in maintenance mode, no apps are loaded\\. Commands provided by apps are unavailable\\. "; "")
					| sub(" migrations:execute <app> <version>$"; "")
					| .[0:300])})
	' 2>/dev/null || true
}

# The apps whose migrations were skipped because the app is not installed on the
# tenant, from the replay's own WARN lines, as a JSON array of app names.
skipped_apps() {
	grep '"level":"WARN"' "${1}" | jq -cs '
		[.[] | select(.msg | test("^app (was never installed on|is not on) this instance")) | .app] | unique
	' 2>/dev/null || true
}

run_replay() {
	_pre_version="$( occ config:app:get "${MARKER_APP}" "${PRE_VERSION_KEY}" 2>/dev/null || true )"
	if [ -z "${_pre_version}" ]; then
		log_info "no pre-upgrade version recorded (fresh install), skipping"
		return 0
	fi

	_code_version=""
	if [ -f "${NEXTCLOUD_DIR}/version.json" ]; then
		_code_version="$( jq -r '.ncVersion // empty' "${NEXTCLOUD_DIR}/version.json" 2>/dev/null || true )"
	fi

	if ! is_version "${_pre_version}"; then
		log_warn "version before upgrade '${_pre_version}' is not a version, dropping it and skipping"
		forget_pre_version
		return 0
	fi
	if ! is_version "${_code_version}"; then
		log_warn "cannot read the deployed version ('${_code_version}'), skipping"
		return 0
	fi

	if ! version_in_range "${_pre_version}"; then
		log_info "version before upgrade ${_pre_version} is outside ${FROM_VERSION}..${TO_VERSION}, dropping it and skipping"
		forget_pre_version
		return 0
	fi
	# Not dropped: the replay is due once the deployed code reaches TO_VERSION
	if ! version_ge "${_code_version}" "${TO_VERSION}"; then
		log_info "deployed version ${_code_version} is older than ${TO_VERSION}, skipping"
		return 0
	fi

	if [ ! -f "${REPLAY_SCRIPT}" ] || ! command -v bash >/dev/null 2>&1 || ! command -v mkfifo >/dev/null 2>&1; then
		log_warn "replay script, bash or mkfifo not available, skipping"
		return 0
	fi

	log_info "running replay (before upgrade ${_pre_version}, deployed ${_code_version})"
	# The script logs while it runs (so the log is there if the job is killed), tee
	# keeps a copy to read afterwards. It reads from a fifo instead of a pipe so that
	# the script is a direct child of this shell: TERM, INT and QUIT are passed on to it
	# and waited for (run_forwarding), so its cleanup restores apps and maintenance mode.
	# This shell is PID 1 of the Job (post-upgrade.sh execs it), so it gets them itself.
	# JSON is forced, an inherited LOG_FORMAT=text would leave no "finished" line.
	# COLUMNS is wide so that occ does not wrap its error text in the middle of a word.
	_tmp="$( mktemp -d )"
	_log="${_tmp}/log"
	mkfifo "${_tmp}/out"
	tee "${_log}" < "${_tmp}/out" &
	_tee_pid=$!
	run_forwarding env LOG_FORMAT=json COLUMNS=1000 OCC="${OCC_CMD}" bash "${REPLAY_SCRIPT}" > "${_tmp}/out"
	_rc="${RUN_RC}"
	wait "${_tee_pid}"

	# Its exit code is 1 both for failed migrations and when it stopped before
	# running any (no app list, maintenance mode not switched on). Only its final
	# "finished" line tells how many migrations were really attempted.
	_finished="$( grep '"msg":"finished' "${_log}" | tail -n 1 )"
	_details="$( failure_details "${_log}" )"
	_skipped_apps="$( skipped_apps "${_log}" )"
	rm -f "${_tmp}/out" "${_log}"
	rmdir "${_tmp}" 2>/dev/null || true
	if [ -z "${_details}" ]; then
		_details='{}'
	fi
	if [ -z "${_skipped_apps}" ]; then
		_skipped_apps='[]'
	fi
	_attempted="$( printf '%s' "${_finished}" \
		| jq -r '(.migrations_ok | tonumber) + (.migrations_failed | tonumber)' 2>/dev/null || true )"

	if [ "${_rc}" -ge 128 ] || [ -z "${_attempted}" ] || [ "${_attempted}" -eq 0 ]; then
		log_warn "replay did not run to the end (exit ${_rc}), marker not set, it runs again next time"
		if [ "${RUN_INTERRUPTED}" -eq 1 ]; then
			EXIT_CODE=143
		fi
		return 0
	fi

	# What was done, in one value: state, run, versions, counts and the failed
	# migrations with their error. Failed migrations are not retried on every
	# upgrade, an admin follows up on the ones that are not benign.
	_now="$( date -u +%Y-%m-%dT%H:%M:%SZ )"
	_result="$( printf '%s' "${_finished}" | jq -c \
		--arg at "${_now}" --arg before "${_pre_version}" --arg deployed "${_code_version}" \
		--argjson exit "${_rc}" --argjson details "${_details}" --argjson skipped_apps "${_skipped_apps}" --arg benign "${BENIGN_ERROR_RE}" --arg data "${DATA_ERROR_RE}" '
		(((.failed // "") | split(" ") | map(select(. != "")))
			# restore steps that failed are not in "failed", they come from the details
			+ ($details | keys | map(select(endswith(":disable") or . == "maintenance:off")))
			| unique
			| map({id: ., error: ($details[.] // "")}
				# whatever the text says: an app that could not be enabled had all its other migrations
				# skipped, a restore step that failed left the tenant changed, a duplicate entry is a data error
				| .benign = ((.id | (endswith(":enable") or endswith(":disable") or . == "maintenance:off") | not)
					and (.error | test($data; "i") | not) and (.error | test($benign; "i"))))) as $list
		| ($list | map(select(.benign | not)) | length) as $other
		| {
			state: (if $other > 0 then "done_with_failures" else "done" end),
			at: $at,
			run_id: .run_id,
			step: .step,
			nextcloud_version_before_upgrade: $before,
			nextcloud_version_deployed: $deployed,
			ok: (.migrations_ok | tonumber),
			failed: ($list | length),
			failed_benign: (($list | length) - $other),
			skipped: (.migrations_skipped | tonumber),
			skipped_apps: $skipped_apps,
			failed_migrations: $list,
			exit: $exit
		}' 2>/dev/null || true )"
	if [ -z "${_result}" ]; then
		_result="done ${_now} exit=${_rc}"
	fi

	if ! occ config:app:set "${MARKER_APP}" "${MARKER_KEY}" --value="${_result}" >/dev/null; then
		log_warn "could not set the marker, the replay runs again next time"
		return 0
	fi
	forget_pre_version
	log_info "replay finished with exit ${_rc}, marker set"
}

main() {
	_marker="$( occ config:app:get "${MARKER_APP}" "${MARKER_KEY}" 2>/dev/null || true )"
	if [ -n "${_marker}" ]; then
		log_info "already done (${_marker}), skipping"
		return 0
	fi
	run_replay
}

case "${1:-run}" in
	run) main ;;
	record) record_pre_upgrade_version ;;
	*) log_warn "unknown mode '${1}', nothing done" ;;
esac
exit "${EXIT_CODE}"
