#!/bin/bash
# SPDX-FileCopyrightText: 2026 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

# Test the gate of post-upgrade/nsw1082-replay.sh with a stub occ and a stub
# replay script: when the replay runs, and when the marker is set.

set -u

ROOT="$( cd "$( dirname "${0}" )/.." && pwd )"
WRAPPER="${ROOT}/post-upgrade/nsw1082-replay.sh"

WORK="$( mktemp -d )"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/nc" "${WORK}/config"

# appconfig stub: one file per "app.key" in STUB_CONFIG
cat > "${WORK}/occ" <<'EOF'
#!/bin/sh
case "${1}" in
	config:app:get)
		[ -f "${STUB_CONFIG}/${2}.${3}" ] || exit 1
		cat "${STUB_CONFIG}/${2}.${3}"
		;;
	config:app:set)
		for _arg in "${@}"; do
			case "${_arg}" in
				--value=*) printf '%s' "${_arg#--value=}" > "${STUB_CONFIG}/${2}.${3}" ;;
			esac
		done
		;;
	config:app:delete)
		rm -f "${STUB_CONFIG}/${2}.${3}"
		;;
	config:system:get)
		[ "${2}" = version ] && [ -n "${STUB_INSTALLED:-}" ] && printf '%s' "${STUB_INSTALLED}"
		;;
esac
EOF
cat > "${WORK}/replay.sh" <<'EOF'
#!/bin/bash
touch "${STUB_RAN}"
printf '%s' "${COLUMNS:-unset}" > "${STUB_COLUMNS}"
finished() {
	printf '{"ts":"x","level":"INFO","msg":"finished","run_id":"stub-run","step":"stub step","migrations_ok":"%s","migrations_failed":"%s","migrations_skipped":"0"%s}\n' \
		"${1}" "${2}" "${3:-}"
}
if [ "${LOG_FORMAT:-json}" = text ]; then
	finished() { printf '2026-10-23T00:00:00Z INFO  finished migrations_ok=%s migrations_failed=%s\n' "${1}" "${2}"; }
fi
case "${STUB_MODE}" in
	ok) finished 74 0; exit 0 ;;
	fail)
		printf '%s\n' '{"level":"ERROR","msg":"migration failed","app":"core","version":"33000Date20251106131209","error":"Nextcloud is in maintenance mode, no apps are loaded.\nCommands provided by apps are unavailable.\nIn IndexAlreadyExists.php line 15:\n\n  An index with name \"x\" was already defined on table \"oc_y\".\n\n\nmigrations:execute <app> <version>"}'
		printf '%s\n' '{"level":"ERROR","msg":"migration failed","app":"tables","version":"2200Date20260707000000","error":"SQLSTATE[23000]: Integrity constraint violation: 1062 Duplicate entry for key y"}'
		finished 70 2 ',"failed":"core:33000Date20251106131209 tables:2200Date20260707000000"'; exit 1 ;;
	benign)
		printf '%s\n' '{"level":"ERROR","msg":"migration failed","app":"spreed","version":"22001Date20250927174738","error":"An index with name \"tta\" was already defined on table \"oc_talk\"."}'
		finished 73 1 ',"failed":"spreed:22001Date20250927174738"'; exit 1 ;;
	enablefail)
		printf '%s\n' '{"level":"ERROR","msg":"app:enable failed, its migrations are skipped","app":"calendar","output":"","error":"Table oc_x already exists"}'
		finished 70 0 ',"failed":"calendar:enable"'; exit 1 ;;
	slow)
		# like the real script: a TERM handler that cleans up, which takes a moment
		trap 'sleep 1; touch "${STUB_CLEANUP}"; exit 143' TERM
		touch "${STUB_STARTED}"
		while :; do sleep 0.2; done ;;
	skipapps)
		printf '%s\n' '{"level":"WARN","msg":"app was never installed on this instance, its migrations are skipped","app":"forms"}'
		printf '%s\n' '{"level":"WARN","msg":"app was never installed on this instance, its migrations are skipped","app":"collectives"}'
		printf '%s\n' '{"level":"WARN","msg":"app is not on this instance, its migrations are skipped","app":"eurooffice"}'
		printf '%s\n' '{"level":"WARN","msg":"migrations left out on purpose","left_out":"tables:x"}'
		finished 50 0; exit 0 ;;
	dupvalue)
		printf '%s\n' "{\"level\":\"ERROR\",\"msg\":\"migration failed\",\"app\":\"forms\",\"version\":\"050300Date20260303000000\",\"error\":\"SQLSTATE[23000]: Integrity constraint violation: 1062 Duplicate entry 'already exists' for key 'y'\"}"
		finished 73 1 ',"failed":"forms:050300Date20260303000000"'; exit 1 ;;
	restorefail)
		printf '%s\n' '{"level":"ERROR","msg":"could not disable the app, disable it by hand","app":"calendar","output":"","error":"Table oc_x already exists"}'
		printf '%s\n' '{"level":"ERROR","msg":"could not switch maintenance mode off, do it by hand","output":"","error":"Connection refused"}'
		finished 74 0; exit 0 ;;
	early) finished 0 0; exit 1 ;;
	killed) exit 143 ;;
esac
EOF
chmod +x "${WORK}/occ" "${WORK}/replay.sh"

PRE_VERSION_FILE="${WORK}/config/ncw_tools.post_upgrade.nextcloud_version_before_upgrade"
MARKER_FILE="${WORK}/config/ncw_tools.post_upgrade.nsw1082_replay"

failures=0

CHECK_ENV=""

# check NAME PRE_VERSION CODE_VERSION MARKER MODE EXPECT_RAN EXPECT_MARKER [EXPECT_PRE_VERSION_KEPT]
# PRE_VERSION "-" means none recorded (fresh install), MARKER "-" means unset,
# EXPECT_PRE_VERSION_KEPT yes/no is only checked when given. CHECK_ENV is extra
# environment (NAME=value ...) for the wrapper.
check() {
	_name="${1}" _pre="${2}" _code="${3}" _marker="${4}" _mode="${5}" _exp_ran="${6}" _exp_marker="${7}" _exp_pre="${8:-}"

	rm -f "${WORK}/ran" "${PRE_VERSION_FILE}" "${MARKER_FILE}"
	if [ "${_pre}" != "-" ]; then
		printf '%s' "${_pre}" > "${PRE_VERSION_FILE}"
	fi
	if [ "${_marker}" != "-" ]; then
		printf '%s' "${_marker}" > "${MARKER_FILE}"
	fi
	printf '{"ncVersion": "%s"}\n' "${_code}" > "${WORK}/nc/version.json"

	# shellcheck disable=SC2086 # CHECK_ENV is a list of NAME=value words on purpose
	env ${CHECK_ENV} NEXTCLOUD_DIR="${WORK}/nc" OCC_CMD="${WORK}/occ" STUB_CONFIG="${WORK}/config" \
		REPLAY_SCRIPT="${WORK}/replay.sh" STUB_RAN="${WORK}/ran" \
		STUB_MODE="${_mode}" STUB_COLUMNS="${WORK}/columns" sh "${WRAPPER}" >/dev/null 2>&1
	_exit=$?

	_ran=no; [ -f "${WORK}/ran" ] && _ran=yes
	# a preset marker stays, so only compare the marker when it was unset before
	_has_marker=no
	if [ "${_marker}" = "-" ] && [ -f "${MARKER_FILE}" ]; then
		_has_marker=yes
	fi

	_pre_kept=no
	[ -f "${PRE_VERSION_FILE}" ] && _pre_kept=yes
	_pre_ok=1
	if [ -n "${_exp_pre}" ] && [ "${_pre_kept}" != "${_exp_pre}" ]; then
		_pre_ok=0
	fi

	if [ "${_exit}" -eq 0 ] && [ "${_ran}" = "${_exp_ran}" ] && [ "${_has_marker}" = "${_exp_marker}" ] && [ "${_pre_ok}" -eq 1 ]; then
		echo "  ok   ${_name}"
	else
		echo "  FAIL ${_name}: exit=${_exit} ran=${_ran} (want ${_exp_ran}) marker=${_has_marker} (want ${_exp_marker}) pre-version kept=${_pre_kept} (want ${_exp_pre:-any})"
		failures=$(( failures + 1 ))
	fi
}

# assert_marker NAME JQ_FILTER: the marker left by the last check is JSON and the filter is true for it
assert_marker() {
	if jq -e "${2}" "${MARKER_FILE}" >/dev/null 2>&1; then
		echo "  ok   ${1}"
	else
		echo "  FAIL ${1}: marker is '$( cat "${MARKER_FILE}" 2>/dev/null )'"
		failures=$(( failures + 1 ))
	fi
}

echo "Testing NSW-1082 replay gate..."
#     name                       pre          code             marker  mode    ran  marker pre-kept
check "fresh install"            -            33.0.9.1.1615    -       ok      no   no
check "below range"              31.0.8.0     33.0.9.1.1615    -       ok      no   no     no
check "lower bound"              31.0.8.1     33.0.9.1.1615    -       ok      yes  yes    no
check "build number is ignored"  31.0.8.1.99  33.0.9.1.1       -       ok      yes  yes    no
check "inside range"             32.0.14.1    33.0.9.1.1615    -       ok      yes  yes    no
assert_marker "clean run is recorded as done" \
	'.state == "done" and .ok == 74 and .failed == 0 and .failed_migrations == [] and .skipped_apps == [] and .exit == 0 and .run_id == "stub-run"
	and .nextcloud_version_before_upgrade == "32.0.14.1" and .nextcloud_version_deployed == "33.0.9.1.1615" and (.at | test("^20[0-9-]+T[0-9:]+Z$"))'
check "upper bound"              33.0.9.1     33.0.9.1.1615    -       ok      yes  yes    no
check "newer code than target"   33.0.9.1     33.0.10.0.1700   -       ok      yes  yes    no
check "above range"              33.0.9.2     33.0.10.0.1700   -       ok      no   no     no
check "code older than target"   31.0.8.1     32.0.14.1.1563   -       ok      no   no     yes
check "marker already set"       31.0.8.1     33.0.9.1.1615    "done"  ok      no   no
check "failed migrations"        31.0.8.1     33.0.9.1.1615    -       fail    yes  yes    no
assert_marker "failed run names the migrations, tells benign from real" \
	'.state == "done_with_failures" and .ok == 70 and .failed == 2 and .failed_benign == 1 and .exit == 1
	and (.failed_migrations | map(.id)) == ["core:33000Date20251106131209", "tables:2200Date20260707000000"]
	and .failed_migrations[0].benign == true
	and .failed_migrations[0].error == "In IndexAlreadyExists.php line 15: An index with name \"x\" was already defined on table \"oc_y\"."
	and .failed_migrations[1].benign == false and (.failed_migrations[1].error | test("Duplicate entry"))'
columns="$( cat "${WORK}/columns" 2>/dev/null )"
if [ "${columns}" = "1000" ]; then
	echo "  ok   the replay gets a wide COLUMNS so occ does not wrap its errors"
else
	echo "  FAIL the replay gets COLUMNS=${columns:-nothing} (want 1000)"
	failures=$(( failures + 1 ))
fi
check "app that could not be enabled" 31.0.8.1   33.0.9.1.1615    -       enablefail yes yes  no
assert_marker "enable failure is never benign, even with 'already exists'" \
	'.state == "done_with_failures" and .failed == 1 and .failed_benign == 0
	and .failed_migrations[0].id == "calendar:enable" and .failed_migrations[0].benign == false
	and (.failed_migrations[0].error | test("already exists"))'
check "only benign failures"     31.0.8.1     33.0.9.1.1615    -       benign  yes  yes    no
assert_marker "benign failures only count as done" \
	'.state == "done" and .failed == 1 and .failed_benign == 1 and .failed_migrations[0].id == "spreed:22001Date20250927174738"'
check "duplicate entry with a value" 31.0.8.1    33.0.9.1.1615    -       dupvalue yes yes   no
assert_marker "a duplicate entry is never benign, even when its value says 'already exists'" \
	'.state == "done_with_failures" and .failed == 1 and .failed_benign == 0
	and .failed_migrations[0].id == "forms:050300Date20260303000000" and .failed_migrations[0].benign == false'
check "restore steps that failed" 31.0.8.1    33.0.9.1.1615    -       restorefail yes yes no
assert_marker "a failed restore is recorded as non-benign although the replay counted no failure" \
	'.state == "done_with_failures" and .ok == 74 and .failed == 2 and .failed_benign == 0
	and (.failed_migrations | map(.id)) == ["calendar:disable", "maintenance:off"]
	and (.failed_migrations | all(.benign == false)) and .failed_migrations[1].error == "Connection refused"'
check "apps that are not installed" 31.0.8.1    33.0.9.1.1615    -       skipapps yes yes   no
assert_marker "skipped apps are named, other warnings are not" \
	'.state == "done" and .ok == 50 and .skipped_apps == ["collectives", "eurooffice", "forms"]'
check "stopped before running"   31.0.8.1     33.0.9.1.1615    -       early   yes  no     yes
check "interrupted"              31.0.8.1     33.0.9.1.1615    -       killed  yes  no     yes
check "unreadable version"       garbage      33.0.9.1.1615    -       ok      no   no     no
CHECK_ENV="LOG_FORMAT=text"
check "inherited LOG_FORMAT=text" 31.0.8.1    33.0.9.1.1615    -       ok      yes  yes    no
CHECK_ENV=""

# check_record NAME EXISTING INSTALLED MARKER EXPECTED
# "record" mode: EXISTING/MARKER "-" means unset, EXPECTED is the version left under the
# key ("-" for none)
check_record() {
	_name="${1}" _existing="${2}" _installed="${3}" _marker="${4}" _expect="${5}"

	rm -f "${PRE_VERSION_FILE}" "${MARKER_FILE}"
	if [ "${_existing}" != "-" ]; then
		printf '%s' "${_existing}" > "${PRE_VERSION_FILE}"
	fi
	if [ "${_marker}" != "-" ]; then
		printf '%s' "${_marker}" > "${MARKER_FILE}"
	fi

	NEXTCLOUD_DIR="${WORK}/nc" OCC_CMD="${WORK}/occ" STUB_CONFIG="${WORK}/config" \
		STUB_INSTALLED="${_installed}" sh "${WRAPPER}" record >/dev/null 2>&1
	_exit=$?

	_got="-"
	[ -f "${PRE_VERSION_FILE}" ] && _got="$( cat "${PRE_VERSION_FILE}" )"
	if [ "${_exit}" -eq 0 ] && [ "${_got}" = "${_expect}" ]; then
		echo "  ok   ${_name}"
	else
		echo "  FAIL ${_name}: exit=${_exit} recorded=${_got} (want ${_expect})"
		failures=$(( failures + 1 ))
	fi
}

echo "Testing recording of the version before an upgrade..."
#            name                                      existing   installed   marker  expected
check_record "first upgrade records the version"        -          32.0.14.1   -       32.0.14.1
check_record "in range value is kept (earlier upgrade)" 32.0.14.1  33.0.9.1.1841 -      32.0.14.1
check_record "out of range value is replaced"           31.0.8.0   32.0.14.1   -       32.0.14.1
check_record "garbage value is replaced"                garbage    32.0.14.1   -       32.0.14.1
check_record "nothing is recorded once replayed"        -          32.0.14.1   "done"  -
check_record "unreadable installed version"             -          ""          -       -

# check_signal NAME SIGNAL: the signal sent to post-upgrade.sh (which execs the wrapper) must reach the replay
# (as TERM), and post-upgrade.sh must not exit before the replay's cleanup is done
check_signal() {
	_name="${1}" _signal="${2}"
	rm -f "${WORK}/started" "${WORK}/cleanup" "${MARKER_FILE}"
	printf '%s' 31.0.8.1 > "${PRE_VERSION_FILE}"
	printf '{"ncVersion": "33.0.9.1.1615"}\n' > "${WORK}/nc/version.json"

	# A background job of this script would have INT and QUIT ignored, which a shell
	# cannot undo. The container runtime does not start PID 1 that way, so reset them.
	env --default-signal=INT,QUIT \
		NEXTCLOUD_DIR="${WORK}/nc" OCC_CMD="${WORK}/occ" STUB_CONFIG="${WORK}/config" \
		REPLAY_SCRIPT="${WORK}/replay.sh" STUB_MODE=slow \
		STUB_STARTED="${WORK}/started" STUB_CLEANUP="${WORK}/cleanup" \
		sh "${ROOT}/post-upgrade.sh" > "${WORK}/signal.out" 2>&1 &
	_pid=$!
	_waited=0
	while [ ! -f "${WORK}/started" ] && [ "${_waited}" -lt 50 ]; do
		sleep 0.1
		_waited=$(( _waited + 1 ))
	done
	kill -s "${_signal}" "${_pid}"
	# a regression must fail the test, not hang it
	_waited=0
	while kill -0 "${_pid}" 2>/dev/null && [ "${_waited}" -lt 100 ]; do
		sleep 0.1
		_waited=$(( _waited + 1 ))
	done
	if kill -0 "${_pid}" 2>/dev/null; then
		kill -KILL "${_pid}" 2>/dev/null
	fi
	wait "${_pid}" 2>/dev/null
	_exit=$?
	# whatever is left of the stub (the launcher may have died without forwarding)
	pkill -KILL -f "${WORK}/replay.sh" 2>/dev/null

	_cleaned=no; [ -f "${WORK}/cleanup" ] && _cleaned=yes
	_marked=no; [ -f "${MARKER_FILE}" ] && _marked=yes
	_kept=no; [ -f "${PRE_VERSION_FILE}" ] && _kept=yes
	if [ "${_cleaned}" = yes ] && [ "${_marked}" = no ] && [ "${_kept}" = yes ] && [ "${_exit}" -eq 143 ]; then
		echo "  ok   ${_name}"
	else
		echo "  FAIL ${_name}: cleanup ran=${_cleaned} (want yes) marker=${_marked} (want no) version kept=${_kept} (want yes) exit=${_exit} (want 143)"
		failures=$(( failures + 1 ))
	fi
}

echo "Testing termination..."
check_signal "TERM reaches the replay and its cleanup finishes first" TERM
check_signal "QUIT (the image's STOPSIGNAL) is handled the same way" QUIT
check_signal "INT is handled the same way" INT

if [ "${failures}" -gt 0 ]; then
	echo "${failures} check(s) failed"
	exit 1
fi
echo "All checks passed"
