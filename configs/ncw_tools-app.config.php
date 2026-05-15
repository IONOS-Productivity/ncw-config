<?php

/**
 * SPDX-FileCopyrightText: 2026 STRATO GmbH
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

$CONFIG = [
	'ncw_tools.pss.base_url' => (string)getenv('IONOS_MAILCONFIG_API_URL'),
	'ncw_tools.pss.username' => (string)getenv('IONOS_MAILCONFIG_API_USER'),
	'ncw_tools.pss.password' => (string)getenv('IONOS_MAILCONFIG_API_PASS'),
	'ncw_tools.pss.brand' => (string)getenv('BRAND'),
	'ncw_tools.pss.ext_ref' => (string)getenv('EXT_REF'),
];
