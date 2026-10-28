#!/bin/sh

# SPDX-FileCopyrightText: 2026 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

# Entry point of the post-upgrade Job of the Helm chart: the steps that run after an
# upgrade. They are not part of configure.sh so that they do not count against the
# deadline of the upgrade job.
#
# The step is started with exec, so it is PID 1 of the Job and receives the stop
# signal itself. That is why its signal handling (nsw1082-replay.sh) is enough.
#
# This script assumes to be located in /IONOS as submodule within the Nextcloud
# server repository.

BDIR="$( dirname "${0}" )"

# NSW-1082: replay migrations that were not in effect after the v31 -> v33 upgrade.
# The wrapper decides by itself whether the tenant needs it and never fails the job.
_replay_wrapper="${BDIR}/post-upgrade/nsw1082-replay.sh"
if [ -f "${_replay_wrapper}" ]; then
	exec /bin/sh "${_replay_wrapper}"
fi

printf '[i] No post-upgrade steps in this image, nothing to do.\n'
