#!/usr/bin/env php
<?php

declare(strict_types=1);

/**
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 STRATO GmbH
 *
 * Detect Nextcloud app migrations that are
 *   - never applied: present in the app's lib/Migration, no row in oc_migrations
 *   - applied but not in effect: row exists, but the schema changes of the
 *     migration (addColumn, createTable, addIndex, dropColumn, ...) are absent
 *     from the live schema
 *
 * Strictly read-only. The DB connection comes from the Nextcloud config; credentials are
 * never printed. Output contains migration versions and table/column/index
 * names, never row data.
 *
 * Exit codes: 0 all fine, 1 findings, 2 usage or input error.
 */

const EXIT_OK = 0;
const EXIT_FINDINGS = 1;
const EXIT_USAGE = 2;

function usage(): string {
	return <<<'TXT'
Usage:
  check-app-migrations.php [--app APP] [--app-path DIR] --db
  check-app-migrations.php --all --db
  check-app-migrations.php [--app APP] [--app-path DIR] \
                           --applied FILE --schema FILE
  check-app-migrations.php [--app APP] --db --dump-applied > applied.txt
  check-app-migrations.php --db --dump-schema > schema.txt

Options:
  --app APP        App id (default: spreed)
  --all            Check every app that has rows in the migrations table (with --db);
                   an overview table and details only for apps with findings
  --app-path DIR   App directory (default: found via apps_paths of the Nextcloud
                   config, else apps/, apps-external/, custom_apps/)
  --db             Read applied list and schema from the database
  --applied FILE   Applied versions, one per line (e.g. 23000Date20251030090219)
  --schema FILE    Schema dump as produced by --dump-schema
  --dump-applied   Print the applied versions of APP and exit
  --dump-schema    Print the live schema (table/column/index names) and exit
  --since-nc N     Only migrations written after Nextcloud N was branched (stable N cut from
                   master), i.e. what an upgrade from N to a later release should have run,
                   e.g. --since-nc 31 for the 31 -> 32 -> 33 path. Known: 28 to 33.
  --strict         Treat "not verifiable" migrations as findings too
  --verbose        Also list verified and superseded schema effects
  -h, --help       This help

Database connection: taken from the Nextcloud config (config/config.php and
config/*.config.php), nothing is passed on the command line or printed.
  --config DIR     Nextcloud config directory (default: $NEXTCLOUD_CONFIG_DIR, else the
                   config/ of the Nextcloud root this script lives in; not the current directory)
  --sqlite-file F  sqlite only: use this file instead of <datadirectory>/owncloud.db

Expected migrations: the Version*.php files in DIR/lib/Migration, i.e. what is
deployed in the app directory.

Schema dump format, whitespace separated, real (prefixed) table names:
  column <table> <column>
  index  <table> <index-name> <col1,col2,...>      (primary key: PRIMARY)

TXT;
}

function fail(string $message, int $code = EXIT_USAGE): never {
	fwrite(STDERR, "[ERROR] $message\n");
	exit($code);
}

// Never let PHP print exception messages: PDO messages can carry user/host.
set_exception_handler(static function (Throwable $e): void {
	fwrite(STDERR, '[ERROR] unexpected ' . get_class($e) . ' (code ' . (string)$e->getCode() . ') at '
		. basename($e->getFile()) . ':' . $e->getLine() . "\n");
	exit(EXIT_USAGE);
});
set_error_handler(static function (int $no, string $str, string $file, int $line): bool {
	fwrite(STDERR, "[ERROR] php error $no in " . basename($file) . ":$line\n");
	exit(EXIT_USAGE);
});

// ---------------------------------------------------------------------------
// Expected migrations
// ---------------------------------------------------------------------------

/** @return array<string,string> version => php source from the app directory */
function dirMigrations(string $dir): array {
	$result = [];
	foreach (glob("$dir/Version*.php") ?: [] as $path) {
		if (preg_match('/^Version(\d+Date\d+)\.php$/', basename($path), $m) === 1) {
			$result[$m[1]] = (string)file_get_contents($path);
		}
	}
	uksort($result, 'compareVersions');
	return $result;
}

function compareVersions(string $a, string $b): int {
	return [(int)$a, $a] <=> [(int)$b, $b];
}

// ---------------------------------------------------------------------------
// Live state: applied list and schema
// ---------------------------------------------------------------------------

/**
 * Schema model: ['columns' => [table => [col => true]], 'indexes' => [table => [name => [cols]]]]
 * Names are lower-cased and stripped of the table prefix.
 */
function newSchema(): array {
	return ['columns' => [], 'indexes' => []];
}

function stripPrefix(string $table, string $prefix): ?string {
	if ($prefix !== '' && strncmp($table, $prefix, strlen($prefix)) !== 0) {
		return null;
	}
	return strtolower(substr($table, strlen($prefix)));
}

function addColumnTo(array &$schema, string $table, string $column): void {
	$schema['columns'][$table][strtolower($column)] = true;
}

function addIndexTo(array &$schema, string $table, string $name, array $cols): void {
	$schema['indexes'][$table][strtolower($name) === 'primary' ? 'PRIMARY' : $name] = array_map('strtolower', $cols);
}

function readAppliedFile(string $file): array {
	if (!is_readable($file)) {
		fail("cannot read applied file $file");
	}
	$result = [];
	foreach (file($file, FILE_IGNORE_NEW_LINES) as $no => $line) {
		$line = trim($line);
		if ($line === '' || $line[0] === '#') {
			continue;
		}
		if (preg_match('/^\d+Date\d+$/', $line) !== 1) {
			fail('applied file: line ' . ($no + 1) . ' is not a migration version');
		}
		$result[$line] = true;
	}
	return $result;
}

function readSchemaFile(string $file, string $prefix): array {
	if (!is_readable($file)) {
		fail("cannot read schema file $file");
	}
	$schema = newSchema();
	foreach (file($file, FILE_IGNORE_NEW_LINES) as $no => $line) {
		$line = trim($line);
		if ($line === '' || $line[0] === '#') {
			continue;
		}
		$f = preg_split('/\s+/', $line);
		$table = isset($f[1]) ? stripPrefix($f[1], $prefix) : null;
		if ($f[0] === 'column' && count($f) === 3) {
			if ($table !== null) {
				addColumnTo($schema, $table, $f[2]);
			}
		} elseif ($f[0] === 'index' && count($f) === 4) {
			if ($table !== null) {
				addIndexTo($schema, $table, $f[2], explode(',', $f[3]));
			}
		} else {
			fail('schema file: line ' . ($no + 1) . ' is malformed');
		}
	}
	return $schema;
}

/** @return array<string,mixed> only the keys needed for the DB connection */
function loadNcConfig(string $dir, bool $required = true): array {
	$files = [];
	if (is_file("$dir/config.php")) {
		$files[] = "$dir/config.php";
	}
	$extra = glob("$dir/*.config.php") ?: [];
	sort($extra);
	$files = array_merge($files, $extra);
	if ($files === [] && !$required) {
		return [];
	}
	if ($files === []) {
		fail("no Nextcloud config found in $dir (use --config)");
	}
	// Some configs reference OC::$SERVERROOT; Nextcloud is not booted here, so provide just that.
	if (!class_exists('OC', false)) {
		eval('class OC { public static string $SERVERROOT = ' . var_export(dirname(__DIR__, 2), true) . '; }');
	}
	$load = static function (string $file): array {
		$CONFIG = [];
		include $file;
		return is_array($CONFIG) ? $CONFIG : [];
	};
	$config = [];
	foreach ($files as $file) {
		$config = array_replace($config, $load($file));
	}
	$keys = ['dbtype', 'dbhost', 'dbname', 'dbuser', 'dbpassword', 'dbtableprefix', 'datadirectory', 'apps_paths'];
	return array_intersect_key($config, array_flip($keys));
}

/** Directory of the app: apps_paths from the config (also mapped below the NC root), then the usual places. */
function findAppDir(string $app, string $ncRoot, array $config, bool $required = true): ?string {
	$roots = [];
	foreach ((array)($config['apps_paths'] ?? []) as $entry) {
		if (is_array($entry) && isset($entry['path'])) {
			$roots[] = (string)$entry['path'];
			$roots[] = $ncRoot . '/' . basename((string)$entry['path']);
		}
	}
	array_push($roots, "$ncRoot/apps", "$ncRoot/apps-external", "$ncRoot/custom_apps");
	foreach ($roots as $root) {
		if (is_file("$root/$app/appinfo/info.xml")) {
			return "$root/$app";
		}
	}
	if (!$required) {
		return null;
	}
	fail("app $app not found in apps_paths or $ncRoot/{apps,apps-external,custom_apps} (use --app-path)");
}

function connectDb(array $config, ?string $sqliteFile): PDO {
	$type = (string)($config['dbtype'] ?? '');
	if ($type === 'sqlite' || $type === 'sqlite3') {
		$file = $sqliteFile ?? rtrim((string)($config['datadirectory'] ?? ''), '/') . '/' . ($config['dbname'] ?? 'owncloud') . '.db';
		if (!is_file($file)) {
			fail('sqlite database file not found (use --sqlite-file)');
		}
		$pdo = new PDO('sqlite:' . $file);
		$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
		$pdo->exec('PRAGMA query_only = ON');
		return $pdo;
	}
	if ($type === 'mysql') {
		if (!extension_loaded('pdo_mysql')) {
			fail('PHP extension pdo_mysql is not available');
		}
		// dbhost is "host", "host:port", "/path/to.sock" or "host:/path/to.sock"
		$host = (string)($config['dbhost'] ?? 'localhost');
		$dsn = 'mysql:dbname=' . (string)($config['dbname'] ?? '') . ';charset=utf8mb4;';
		if (preg_match('#^(.*?):?(/.*)$#', $host, $m) === 1) {
			$dsn .= 'unix_socket=' . $m[2];
		} elseif (preg_match('/^(.+):(\d+)$/', $host, $m) === 1) {
			$dsn .= 'host=' . $m[1] . ';port=' . $m[2];
		} else {
			$dsn .= 'host=' . $host;
		}
		try {
			$pdo = new PDO($dsn, (string)($config['dbuser'] ?? ''), (string)($config['dbpassword'] ?? ''));
			$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
			$pdo->exec('SET SESSION TRANSACTION READ ONLY');
		} catch (PDOException $e) {
			fail('database connection failed (code ' . (string)$e->getCode() . ')');
		}
		return $pdo;
	}
	fail('unsupported dbtype in Nextcloud config (mysql and sqlite only)');
}

function dbApplied(PDO $pdo, string $app, string $prefix): array {
	$stmt = $pdo->prepare('SELECT version FROM ' . $prefix . 'migrations WHERE app = ?');
	$stmt->execute([$app]);
	$result = [];
	foreach ($stmt->fetchAll(PDO::FETCH_COLUMN) as $version) {
		$result[(string)$version] = true;
	}
	return $result;
}

/** @return array<string,array<string,true>> app => versions */
function dbAppliedAll(PDO $pdo, string $prefix): array {
	$result = [];
	foreach ($pdo->query('SELECT app, version FROM ' . $prefix . 'migrations')->fetchAll(PDO::FETCH_NUM) as [$app, $version]) {
		$result[(string)$app][(string)$version] = true;
	}
	ksort($result);
	return $result;
}

function dbSchema(PDO $pdo, string $prefix): array {
	$schema = newSchema();
	if ($pdo->getAttribute(PDO::ATTR_DRIVER_NAME) === 'sqlite') {
		$tables = $pdo->query("SELECT name FROM sqlite_master WHERE type = 'table'")->fetchAll(PDO::FETCH_COLUMN);
		foreach ($tables as $real) {
			$table = stripPrefix((string)$real, $prefix);
			if ($table === null) {
				continue;
			}
			$quoted = '"' . str_replace('"', '""', (string)$real) . '"';
			$pk = [];
			foreach ($pdo->query("PRAGMA table_info($quoted)")->fetchAll(PDO::FETCH_ASSOC) as $col) {
				addColumnTo($schema, $table, (string)$col['name']);
				if ((int)$col['pk'] > 0) {
					$pk[(int)$col['pk']] = (string)$col['name'];
				}
			}
			if ($pk !== []) {
				ksort($pk);
				addIndexTo($schema, $table, 'PRIMARY', array_values($pk));
			}
			foreach ($pdo->query("PRAGMA index_list($quoted)")->fetchAll(PDO::FETCH_ASSOC) as $idx) {
				if ($idx['origin'] === 'pk') {
					continue;
				}
				$iq = '"' . str_replace('"', '""', (string)$idx['name']) . '"';
				$cols = array_column($pdo->query("PRAGMA index_info($iq)")->fetchAll(PDO::FETCH_ASSOC), 'name');
				addIndexTo($schema, $table, (string)$idx['name'], array_map('strval', $cols));
			}
		}
		return $schema;
	}

	$rows = $pdo->query(
		'SELECT TABLE_NAME AS t, COLUMN_NAME AS c FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()'
	)->fetchAll(PDO::FETCH_NUM);
	foreach ($rows as [$real, $col]) {
		$table = stripPrefix((string)$real, $prefix);
		if ($table !== null) {
			addColumnTo($schema, $table, (string)$col);
		}
	}
	$rows = $pdo->query(
		'SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME FROM information_schema.STATISTICS '
		. 'WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX'
	)->fetchAll(PDO::FETCH_NUM);
	$grouped = [];
	foreach ($rows as [$real, $index, $col]) {
		$table = stripPrefix((string)$real, $prefix);
		if ($table !== null) {
			$grouped[$table][(string)$index][] = (string)$col;
		}
	}
	foreach ($grouped as $table => $indexes) {
		foreach ($indexes as $name => $cols) {
			addIndexTo($schema, $table, (string)$name, $cols);
		}
	}
	return $schema;
}

function dumpSchema(PDO $pdo, string $prefix): void {
	// Dump with the prefix kept so that the file is self-describing.
	$schema = dbSchema($pdo, $prefix);
	foreach ($schema['columns'] as $table => $cols) {
		foreach (array_keys($cols) as $col) {
			echo "column $prefix$table $col\n";
		}
	}
	foreach ($schema['indexes'] as $table => $indexes) {
		foreach ($indexes as $name => $cols) {
			echo "index $prefix$table $name " . implode(',', $cols) . "\n";
		}
	}
}

// ---------------------------------------------------------------------------
// Static extraction of schema effects from a migration
// ---------------------------------------------------------------------------

/**
 * Walks the token stream of changeSchema() and collects schema effects.
 * Anything it cannot interpret is recorded as a reason and never guessed.
 */
final class EffectExtractor {
	private const LOOPS = [T_FOREACH, T_FOR, T_WHILE, T_DO, T_SWITCH, T_TRY, T_MATCH];
	private const GUARD_CALLS = ['hasColumn', 'hasIndex', 'hasTable', 'hasPrimaryKey', 'hasUniqueConstraint'];
	private const IGNORED_TABLE_CALLS = [
		'hasColumn', 'hasIndex', 'hasPrimaryKey', 'hasUniqueConstraint', 'getName', 'addOption', 'setComment',
	];

	/** @var list<array{t:?int,s:string,l:int}> */
	private array $T = [];
	/** @var array<string,string> */
	private array $consts = [];
	/** @var array<string,array{k:string,name?:?string}> */
	private array $vars = [];
	/** @var list<array<string,mixed>> */
	public array $effects = [];
	/** @var array<string,true> */
	public array $reasons = [];
	private bool $conditional = false;
	/** True when changeSchema() ends with "return null;": Nextcloud then applies none of its changes. */
	private bool $returnsNull = false;
	/** @var array<string,true> tables that code we could not interpret may have changed */
	private array $touched = [];
	/** @var array<string,true> effect keys that an early-return has*() guard already speaks about */
	private array $guarded = [];

	/**
	 * @return array{effects:list<array<string,mixed>>,reasons:list<string>,touched:list<string>}
	 */
	public static function extract(string $source): array {
		$self = new self();
		$self->T = [];
		foreach (token_get_all($source) as $tok) {
			if (is_array($tok)) {
				if (in_array($tok[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) {
					continue;
				}
				$self->T[] = ['t' => $tok[0], 's' => $tok[1], 'l' => $tok[2]];
			} else {
				$last = $self->T === [] ? 1 : $self->T[count($self->T) - 1]['l'];
				$self->T[] = ['t' => null, 's' => $tok, 'l' => $last];
			}
		}
		$self->collectConsts();
		$methods = $self->findMethods();

		foreach (['preSchemaChange', 'postSchemaChange'] as $name) {
			if (isset($methods[$name]) && !$self->isTrivial(...$methods[$name])) {
				$self->reasons["data changes in $name() are not verifiable"] = true;
			}
		}
		if (isset($methods['changeSchema'])) {
			$self->vars = ['$schema' => ['k' => 'schema']];
			$self->walk($methods['changeSchema'][0], $methods['changeSchema'][1], true);
		}
		if ($self->returnsNull && $self->effects !== []) {
			// MigrationService::executeStep() only migrates when a schema wrapper is returned, so these
			// effects never happen and re-running the migration cannot create them.
			$self->effects = [];
			$self->reasons['changeSchema() ends with "return null;": Nextcloud discards its schema changes, they are never applied (defect in the app)'] = true;
		}
		return [
			'effects' => $self->effects,
			'reasons' => array_keys($self->reasons),
			'touched' => array_keys($self->touched),
		];
	}

	private function collectConsts(): void {
		$n = count($this->T);
		for ($i = 0; $i < $n; $i++) {
			if ($this->T[$i]['t'] !== T_CONST) {
				continue;
			}
			for ($j = $i + 1; $j < $n && $this->T[$j]['s'] !== ';'; $j++) {
				if ($this->T[$j]['t'] === T_STRING && ($this->T[$j + 1]['s'] ?? '') === '='
					&& ($this->T[$j + 2]['t'] ?? null) === T_CONSTANT_ENCAPSED_STRING
					&& ($this->T[$j + 3]['s'] ?? '') === ';') {
					$this->consts[$this->T[$j]['s']] = substr($this->T[$j + 2]['s'], 1, -1);
					break;
				}
			}
		}
	}

	/** @return array<string,array{0:int,1:int}> method => [first body token, end (exclusive)] */
	private function findMethods(): array {
		$methods = [];
		$n = count($this->T);
		for ($i = 0; $i < $n; $i++) {
			if ($this->T[$i]['t'] !== T_FUNCTION || ($this->T[$i + 1]['t'] ?? null) !== T_STRING) {
				continue;
			}
			$name = $this->T[$i + 1]['s'];
			$j = $i + 2;
			if (($this->T[$j]['s'] ?? '') !== '(') {
				continue;
			}
			$j = $this->close($j) + 1;
			while ($j < $n && $this->T[$j]['s'] !== '{' && $this->T[$j]['s'] !== ';') {
				$j++;
			}
			if ($j < $n && $this->T[$j]['s'] === '{') {
				$end = $this->close($j);
				$methods[$name] = [$j + 1, $end];
				$i = $end;
			}
		}
		return $methods;
	}

	private function isTrivial(int $from, int $to): bool {
		$s = '';
		for ($i = $from; $i < $to; $i++) {
			$s .= $this->T[$i]['s'];
		}
		return in_array($s, ['', 'return;'], true);
	}

	private function isOpen(int $i): bool {
		return in_array($this->T[$i]['s'], ['(', '[', '{'], true)
			|| in_array($this->T[$i]['t'], [T_CURLY_OPEN, T_DOLLAR_OPEN_CURLY_BRACES, T_ATTRIBUTE], true);
	}

	private function close(int $open): int {
		$depth = 0;
		$n = count($this->T);
		for ($i = $open; $i < $n; $i++) {
			if ($this->isOpen($i)) {
				$depth++;
			} elseif (in_array($this->T[$i]['s'], [')', ']', '}'], true)) {
				$depth--;
				if ($depth === 0) {
					return $i;
				}
			}
		}
		return $n - 1;
	}

	private function reason(string $text, int $tokenIndex): void {
		$this->reasons[$text . ' (line ' . ($this->T[min($tokenIndex, count($this->T) - 1)]['l']) . ')'] = true;
	}

	/** Remember which tables a range of uninterpreted code may touch: bound table variables and string literals. */
	private function touch(int $from, int $to): void {
		for ($i = $from; $i < $to && $i < count($this->T); $i++) {
			$t = $this->T[$i];
			if ($t['t'] === T_VARIABLE && ($this->vars[$t['s']]['k'] ?? '') === 'table' && isset($this->vars[$t['s']]['name'])) {
				$this->touched[$this->vars[$t['s']]['name']] = true;
			} elseif ($t['t'] === T_CONSTANT_ENCAPSED_STRING) {
				$this->touched[strtolower(substr($t['s'], 1, -1))] = true;
			}
		}
	}

	private function mentions(int $from, int $to): bool {
		for ($i = $from; $i < $to; $i++) {
			if ($this->T[$i]['t'] === T_VARIABLE && isset($this->vars[$this->T[$i]['s']])
				&& $this->vars[$this->T[$i]['s']]['k'] !== 'other') {
				return true;
			}
		}
		return false;
	}

	private function walk(int $i, int $end, bool $top): void {
		while ($i < $end) {
			$tok = $this->T[$i];
			if ($tok['t'] === T_IF) {
				$i = $this->handleIf($i);
			} elseif (in_array($tok['t'], self::LOOPS, true)) {
				$i = $this->skipConstruct($i, $end);
			} elseif ($tok['s'] === '{') {
				$close = $this->close($i);
				$this->walk($i + 1, $close, false);
				$i = $close + 1;
			} elseif ($tok['t'] === T_RETURN && $top) {
				$this->returnsNull = strtolower($this->T[$i + 1]['s'] ?? '') === 'null' && ($this->T[$i + 2]['s'] ?? '') === ';';
				return;
			} else {
				$stmtEnd = $this->statementEnd($i, $end);
				$this->statement($i, $stmtEnd);
				$i = $stmtEnd + 1;
			}
		}
	}

	private function statementEnd(int $i, int $end): int {
		for ($j = $i; $j < $end; $j++) {
			if ($this->isOpen($j)) {
				$j = $this->close($j);
			} elseif ($this->T[$j]['s'] === ';') {
				return $j;
			}
		}
		return $end;
	}

	private function skipConstruct(int $i, int $end): int {
		$start = $i;
		$j = $i + 1;
		if ($this->T[$i]['t'] === T_DO) {
			// do { } while (...);
			$j = $this->close($j) + 1;
			$j = $this->statementEnd($j, $end) + 1;
		} else {
			while ($j < $end && $this->T[$j]['s'] !== '{' && $this->T[$j]['s'] !== ';') {
				$j = $this->isOpen($j) ? $this->close($j) + 1 : $j + 1;
			}
			if ($j < $end && $this->T[$j]['s'] === '{') {
				$j = $this->close($j) + 1;
				while ($j < $end && in_array($this->T[$j]['t'], [T_CATCH, T_FINALLY], true)) {
					while ($j < $end && $this->T[$j]['s'] !== '{') {
						$j++;
					}
					$j = $this->close($j) + 1;
				}
			} else {
				$j++;
			}
		}
		if ($this->mentions($start, $j)) {
			$this->touch($start, $j);
			$this->reason('schema changes inside ' . strtolower(substr(token_name((int)$this->T[$start]['t']), 2)) . ' are not verifiable', $start);
		}
		return $j;
	}

	/** @return int index after the whole if/elseif/else chain */
	private function handleIf(int $i): int {
		$branches = [];
		$j = $i;
		$hasElse = false;
		while (true) {
			$isElse = $this->T[$j]['t'] === T_ELSE && ($this->T[$j + 1]['t'] ?? null) !== T_IF;
			if ($this->T[$j]['t'] === T_ELSE && !$isElse) {
				$j++; // "else if"
			}
			if ($isElse) {
				$hasElse = true;
				$condFrom = $condTo = $j;
				$j++;
			} else {
				$condFrom = $j + 2;
				$condClose = $this->close($j + 1);
				$condTo = $condClose;
				$j = $condClose + 1;
			}
			if (($this->T[$j]['s'] ?? '') === '{') {
				$bodyEnd = $this->close($j);
				$branches[] = [$condFrom, $condTo, $j + 1, $bodyEnd];
				$j = $bodyEnd + 1;
			} else {
				$bodyEnd = $this->statementEnd($j, count($this->T));
				$branches[] = [$condFrom, $condTo, $j, $bodyEnd];
				$j = $bodyEnd + 1;
			}
			$nextT = $this->T[$j]['t'] ?? null;
			if ($nextT !== T_ELSE && $nextT !== T_ELSEIF) {
				break;
			}
			if ($nextT === T_ELSEIF) {
				// "elseif (" behaves like "else if (": normalise by treating as branch start
				$this->T[$j]['t'] = T_IF;
			}
		}

		$single = count($branches) === 1;
		if ($single && $this->isGuard($branches[0][0], $branches[0][1])) {
			[, , $from, $to] = $branches[0];
			if ($this->conditional) {
				if ($this->mentions($from, $to)) {
					$this->touch($from, $to);
					$this->reasons['some schema changes follow a conditional early return and are not verifiable'] = true;
				}
				return $j;
			}
			$this->walk($from, $to, false);
			for ($k = $from; $k < $to; $k++) {
				if ($this->T[$k]['t'] === T_RETURN) {
					$this->conditional = true;
					$this->collectGuardedKeys($branches[0][0], $branches[0][1]);
					break;
				}
			}
			return $j;
		}
		foreach ($branches as [$cf, $ct, $bf, $bt]) {
			if ($this->mentions($cf, $ct) || $this->mentions($bf, $bt)) {
				foreach ($branches as [, , $tf, $tt]) {
					$this->touch($tf, $tt);
				}
				$this->reason('schema changes under a condition that is not a plain has*() guard are not verifiable', $i);
				break;
			}
		}
		return $j;
	}

	/**
	 * "if (hasTable('x')) return;" followed by createTable('x') leaves 'x' in place either way,
	 * so effects on exactly the guarded object stay verifiable; everything else does not.
	 */
	private function collectGuardedKeys(int $from, int $to): void {
		for ($i = $from; $i + 4 < $to; $i++) {
			if ($this->T[$i]['t'] !== T_VARIABLE || $this->T[$i + 1]['t'] !== T_OBJECT_OPERATOR
				|| ($this->T[$i + 3]['s'] ?? '') !== '(') {
				continue;
			}
			$recv = $this->vars[$this->T[$i]['s']] ?? ['k' => 'other'];
			$method = $this->T[$i + 2]['s'];
			$arg = $this->str([$i + 4, $i + 5]);
			if ($arg === null) {
				continue;
			}
			$arg = strtolower($arg);
			if ($recv['k'] === 'schema' && $method === 'hasTable') {
				$this->guarded["tbl:$arg"] = true;
			} elseif ($recv['k'] === 'table' && isset($recv['name'])) {
				if ($method === 'hasColumn') {
					$this->guarded["col:{$recv['name']}.$arg"] = true;
				} elseif ($method === 'hasIndex') {
					$this->guarded["idx:{$recv['name']}:$arg"] = true;
				}
			}
		}
	}

	private function isGuard(int $from, int $to): bool {
		for ($i = $from; $i < $to; $i++) {
			$t = $this->T[$i];
			if ($t['t'] === T_VARIABLE) {
				if (!isset($this->vars[$t['s']]) || $this->vars[$t['s']]['k'] === 'other') {
					return false;
				}
			} elseif ($t['t'] === T_STRING && ($this->T[$i + 1]['s'] ?? '') === '(') {
				$prev = $this->T[$i - 1]['t'] ?? null;
				if ($prev !== T_OBJECT_OPERATOR || !in_array($t['s'], self::GUARD_CALLS, true)) {
					return false;
				}
			}
		}
		return true;
	}

	/** @return list<array{0:int,1:int}> */
	private function splitArgs(int $open, int $close): array {
		$args = [];
		$start = $open + 1;
		for ($i = $open + 1; $i < $close; $i++) {
			if ($this->isOpen($i)) {
				$i = $this->close($i);
			} elseif ($this->T[$i]['s'] === ',') {
				$args[] = [$start, $i];
				$start = $i + 1;
			}
		}
		if ($start < $close) {
			$args[] = [$start, $close];
		}
		return $args;
	}

	private function str(array $range): ?string {
		[$a, $b] = $range;
		if ($b - $a === 1 && $this->T[$a]['t'] === T_CONSTANT_ENCAPSED_STRING) {
			$raw = $this->T[$a]['s'];
			if ($raw[0] === '"' && str_contains($raw, '$')) {
				return null;
			}
			return substr($raw, 1, -1);
		}
		if ($b - $a === 3 && $this->T[$a + 1]['t'] === T_DOUBLE_COLON && $this->T[$a + 2]['t'] === T_STRING
			&& in_array(strtolower($this->T[$a]['s']), ['self', 'static'], true)) {
			return $this->consts[$this->T[$a + 2]['s']] ?? null;
		}
		return null;
	}

	/** @return ?list<string> */
	private function strList(array $range): ?array {
		[$a, $b] = $range;
		if ($this->T[$a]['s'] === '[' && $this->close($a) === $b - 1) {
			$open = $a;
			$close = $b - 1;
		} elseif (strtolower($this->T[$a]['s']) === 'array' && ($this->T[$a + 1]['s'] ?? '') === '(' && $this->close($a + 1) === $b - 1) {
			$open = $a + 1;
			$close = $b - 1;
		} else {
			$single = $this->str($range);
			return $single === null ? null : [$single];
		}
		$out = [];
		foreach ($this->splitArgs($open, $close) as $arg) {
			$s = $this->str($arg);
			if ($s === null) {
				return null;
			}
			$out[] = $s;
		}
		return $out;
	}

	private function statement(int $from, int $to): void {
		if ($from >= $to) {
			return;
		}
		$first = $this->T[$from];
		$touches = $this->mentions($from, $to);

		if ($first['t'] === T_RETURN) {
			return;
		}
		$assignTo = null;
		$chainFrom = $from;
		if ($first['t'] === T_VARIABLE && ($this->T[$from + 1]['s'] ?? '') === '=') {
			$assignTo = $first['s'];
			$chainFrom = $from + 2;
		}
		$base = $this->T[$chainFrom] ?? null;
		if ($base === null || $base['t'] !== T_VARIABLE) {
			if ($touches) {
				$this->touch($from, $to);
				$this->reason('statement touching the schema is not understood', $from);
			}
			if ($assignTo !== null) {
				$this->vars[$assignTo] = ['k' => 'other'];
			}
			return;
		}
		if ($base['s'] === '$schemaClosure') {
			return;
		}
		if (!isset($this->vars[$base['s']]) || $this->vars[$base['s']]['k'] === 'other') {
			if ($touches) {
				$this->touch($from, $to);
				$this->reason('schema passed to code that is not parsed', $from);
			}
			if ($assignTo !== null) {
				$this->vars[$assignTo] = ['k' => 'other'];
			}
			return;
		}

		// Parse the call chain: $var->call(...)->call(...)
		$recv = $this->vars[$base['s']];
		$i = $chainFrom + 1;
		while ($i < $to) {
			if ($this->T[$i]['t'] !== T_OBJECT_OPERATOR || ($this->T[$i + 1]['t'] ?? null) !== T_STRING
				|| ($this->T[$i + 2]['s'] ?? '') !== '(') {
				$this->touch($from, $to);
				$this->reason('chain on the schema is not understood', $i);
				$recv = ['k' => 'other'];
				break;
			}
			$method = $this->T[$i + 1]['s'];
			$close = $this->close($i + 2);
			$args = $this->splitArgs($i + 2, $close);
			$recv = $this->call($recv, $method, $args, $i);
			$i = $close + 1;
		}
		if ($assignTo !== null) {
			$this->vars[$assignTo] = $recv;
		}
	}

	/**
	 * @param array{k:string,name?:?string} $recv
	 * @param list<array{0:int,1:int}> $args
	 * @return array{k:string,name?:?string}
	 */
	private function call(array $recv, string $method, array $args, int $at): array {
		$other = ['k' => 'other'];
		$name = isset($args[0]) ? $this->str($args[0]) : null;

		if ($recv['k'] === 'schema') {
			switch ($method) {
				case 'getTable':
				case 'createTable':
					if ($method === 'createTable') {
						$this->record(['op' => 'createTable', 'table' => $name], $at, [$name]);
					}
					return ['k' => 'table', 'name' => $name === null ? null : strtolower($name)];
				case 'dropTable':
					$this->record(['op' => 'dropTable', 'table' => $name], $at, [$name]);
					return $other;
				case 'hasTable':
					return $other;
				default:
					$this->touched[$name === null ? '*' : strtolower($name)] = true;
					$this->reason("schema->$method() is not verifiable", $at);
					return $other;
			}
		}

		if ($recv['k'] === 'column') {
			if (str_starts_with($method, 'set')) {
				$this->reason('column attribute change on ' . ($recv['name'] ?? '?') . ' is not verifiable', $at);
			}
			return $recv;
		}

		if ($recv['k'] !== 'table') {
			return $other;
		}
		$table = $recv['name'] ?? null;
		$t = $table === null ? null : $table;
		switch ($method) {
			case 'addColumn':
				$this->record(['op' => 'addColumn', 'table' => $t, 'column' => $name], $at, [$t, $name]);
				return ['k' => 'column', 'name' => $t . '.' . $name];
			case 'dropColumn':
				$this->record(['op' => 'dropColumn', 'table' => $t, 'column' => $name], $at, [$t, $name]);
				return $other;
			case 'renameColumn':
				$new = isset($args[1]) ? $this->str($args[1]) : null;
				$this->record(['op' => 'dropColumn', 'table' => $t, 'column' => $name], $at, [$t, $name]);
				$this->record(['op' => 'addColumn', 'table' => $t, 'column' => $new], $at, [$t, $new]);
				return $other;
			case 'getColumn':
				return ['k' => 'column', 'name' => $t . '.' . $name];
			case 'changeColumn':
			case 'modifyColumn':
				$this->reason("column attribute change on $t.$name is not verifiable", $at);
				return $other;
			case 'addIndex':
			case 'addUniqueIndex':
				$cols = isset($args[0]) ? $this->strList($args[0]) : null;
				$idx = isset($args[1]) ? $this->str($args[1]) : null;
				$this->record(['op' => 'addIndex', 'table' => $t, 'columns' => $cols, 'index' => $idx], $at, [$t, $cols]);
				return $other;
			case 'setPrimaryKey':
				$cols = isset($args[0]) ? $this->strList($args[0]) : null;
				$this->record(['op' => 'setPrimaryKey', 'table' => $t, 'columns' => $cols], $at, [$t, $cols]);
				return $other;
			case 'dropPrimaryKey':
				$this->record(['op' => 'dropPrimaryKey', 'table' => $t], $at, [$t]);
				return $other;
			case 'dropIndex':
			case 'removeUniqueConstraint':
				$this->record(['op' => 'dropIndex', 'table' => $t, 'index' => $name], $at, [$t, $name]);
				return $other;
			default:
				if (!in_array($method, self::IGNORED_TABLE_CALLS, true)) {
					$this->reason("table->$method() is not verifiable", $at);
				}
				return $other;
		}
	}

	/** @param array<string,mixed> $effect @param list<mixed> $required */
	private function record(array $effect, int $at, array $required): void {
		foreach ($required as $value) {
			if ($value === null) {
				$this->reason($effect['op'] . ' with a name that is computed at runtime is not verifiable', $at);
				return;
			}
		}
		foreach (['table', 'column', 'index'] as $key) {
			if (isset($effect[$key])) {
				$effect[$key] = strtolower((string)$effect[$key]);
			}
		}
		if (isset($effect['columns'])) {
			$effect['columns'] = array_map('strtolower', $effect['columns']);
		}
		if ($this->conditional && !isset($this->guarded[effectKey($effect)])) {
			$this->touched[$effect['table']] = true;
			$this->reasons['some schema changes follow a conditional early return and are not verifiable'] = true;
			return;
		}
		$effect['line'] = $this->T[$at]['l'];
		$this->effects[] = $effect;
	}
}

// ---------------------------------------------------------------------------
// Verification against the live schema
// ---------------------------------------------------------------------------

function effectKey(array $e): string {
	return match ($e['op']) {
		'addColumn', 'dropColumn' => "col:{$e['table']}.{$e['column']}",
		'createTable', 'dropTable' => "tbl:{$e['table']}",
		'setPrimaryKey', 'dropPrimaryKey' => "idx:{$e['table']}:PRIMARY",
		'addIndex', 'dropIndex' => isset($e['index'])
			? "idx:{$e['table']}:{$e['index']}"
			: "idxc:{$e['table']}:" . implode(',', $e['columns'] ?? []),
	};
}

function describeEffect(array $e): string {
	return match ($e['op']) {
		'addColumn', 'dropColumn' => "{$e['op']} {$e['table']}.{$e['column']}",
		'createTable', 'dropTable' => "{$e['op']} {$e['table']}",
		'setPrimaryKey' => "setPrimaryKey {$e['table']}(" . implode(',', $e['columns']) . ')',
		'dropPrimaryKey' => "dropPrimaryKey {$e['table']}",
		'addIndex' => "addIndex {$e['table']}." . ($e['index'] ?? '(' . implode(',', $e['columns']) . ')'),
		'dropIndex' => "dropIndex {$e['table']}.{$e['index']}",
	};
}

/** True if a later effect F makes the state asserted by earlier effect E irrelevant. */
function supersedes(array $later, array $earlier): bool {
	if (effectKey($later) === effectKey($earlier)) {
		return true;
	}
	return in_array($later['op'], ['createTable', 'dropTable'], true) && $later['table'] === $earlier['table'];
}

/** @return ?string problem description, null if the effect is in place */
function checkEffect(array $e, array $schema): ?string {
	$table = $e['table'];
	$tableExists = isset($schema['columns'][$table]);
	$indexes = $schema['indexes'][$table] ?? [];
	switch ($e['op']) {
		case 'createTable':
			return $tableExists ? null : 'table missing';
		case 'dropTable':
			return $tableExists ? 'table still present' : null;
		case 'addColumn':
			if (!$tableExists) {
				return 'table missing';
			}
			return isset($schema['columns'][$table][$e['column']]) ? null : 'column missing';
		case 'dropColumn':
			return $tableExists && isset($schema['columns'][$table][$e['column']]) ? 'column still present' : null;
		case 'setPrimaryKey':
			if (!$tableExists) {
				return 'table missing';
			}
			return ($indexes['PRIMARY'] ?? null) === $e['columns'] ? null : 'primary key missing or different';
		case 'dropPrimaryKey':
			return isset($indexes['PRIMARY']) ? 'primary key still present' : null;
		case 'addIndex':
			if (!$tableExists) {
				return 'table missing';
			}
			foreach ($indexes as $name => $cols) {
				if (isset($e['index']) && strtolower((string)$name) === $e['index']) {
					return null;
				}
				// Doctrine drops an index that a wider index starting with the same columns makes
				// redundant, so such a covering index counts as in effect.
				if (isset($e['columns']) && array_slice($cols, 0, count($e['columns'])) === $e['columns']) {
					return null;
				}
			}
			return 'index missing';
		case 'dropIndex':
			foreach ($indexes as $name => $cols) {
				if (strtolower((string)$name) === $e['index']) {
					return 'index still present';
				}
			}
			return null;
	}
	return null;
}

/**
 * Date (YYYYMMDD) on which stable<N> was cut from master in nextcloud/server
 * (merge-base of stable<N> and master). Migrations are stamped with the date they were written, so
 * one dated on or after this day is not part of Nextcloud N. This is an approximation: apps are
 * branched on their own schedule, so a migration written shortly before an app's own cut can be missed.
 */
const NC_BRANCH_DATES = [
	28 => '20231123',
	29 => '20240328',
	30 => '20240814',
	31 => '20250123',
	32 => '20250904',
	33 => '20260122',
];

/** Limit the report to migrations that an upgrade from the given Nextcloud major version should have run. */
function scopeFilter(array $opts): ?Closure {
	if (!isset($opts['since-nc'])) {
		return null;
	}
	$nc = (int)$opts['since-nc'];
	if (!isset(NC_BRANCH_DATES[$nc])) {
		fail('--since-nc must be one of ' . implode(', ', array_keys(NC_BRANCH_DATES)));
	}
	$since = NC_BRANCH_DATES[$nc];
	return static fn (string $version): bool => preg_match('/Date(\d{8})/', $version, $m) === 1 && $m[1] >= $since;
}

/**
 * Print the commands an admin has to run to repair the findings. Nothing is executed here.
 * @param array<string,list<string>> $fixes app => versions in execution order
 */
function printFix(array $fixes): void {
	if ($fixes === []) {
		return;
	}
	echo "== Suggested fix (run by an admin, this script changes nothing) ==\n";
	echo "# Before: take a DB backup/snapshot and enable maintenance mode:  occ maintenance:mode --on\n";
	echo "# migrations:execute is only available with debug on; NC_debug=true enables it for this one command only\n";
	echo "# Run in this order; only migrations that are missing or not in effect are listed:\n";
	foreach ($fixes as $app => $versions) {
		foreach ($versions as $v) {
			echo "NC_debug=true occ migrations:execute $app $v\n";
		}
	}
	echo "# After: occ maintenance:mode --off; then re-run this check\n\n";
}

/** Migration directory of an app; core keeps its migrations in core/Migrations. */
function migrationDir(string $app, string $ncRoot, ?string $appPath, array $config): ?string {
	if ($app === 'core') {
		return "$ncRoot/core/Migrations";
	}
	$dir = $appPath ?? findAppDir($app, $ncRoot, $config, false);
	return $dir === null ? null : "$dir/lib/Migration";
}

/**
 * Compare one app's migrations with the live state and print the report.
 * @param array<string,string> $expected version => php source
 * @param array<string,true> $applied
 * @return array{bad:bool,never:int,noeffect:int,unverifiable:int,verified:int,expected:int,text:string}
 *         text is the compact (--all) block for this app, empty when the app is clean
 */
function checkApp(string $app, array $expected, array $applied, array $schema, string $prefix, string $source, bool $verbose, bool $strict, bool $compact, ?Closure $inScope = null, array &$fixes = []): array {
	$neverApplied = [];
	$notInApp = [];
	foreach (array_keys($expected) as $v) {
		if (!isset($applied[$v]) && ($inScope === null || $inScope($v))) {
			$neverApplied[] = $v;
		}
	}
	foreach (array_keys($applied) as $v) {
		if (!isset($expected[$v])) {
			$notInApp[] = $v;
		}
	}
	usort($notInApp, 'compareVersions');

	// Extract effects of applied migrations, in execution order.
	$extracted = [];
	foreach ($expected as $v => $src) {
		if (isset($applied[$v])) {
			$extracted[$v] = EffectExtractor::extract($src);
		}
	}
	$flat = [];
	foreach ($extracted as $v => $x) {
		foreach ($x['effects'] as $e) {
			$flat[] = [$v, $e];
		}
	}

	$notInEffect = [];
	$verified = [];
	$superseded = [];
	foreach ($flat as $pos => [$v, $e]) {
		$isSuperseded = false;
		for ($later = $pos + 1; $later < count($flat); $later++) {
			if (supersedes($flat[$later][1], $e)) {
				$superseded[$v][] = describeEffect($e) . ' (by ' . $flat[$later][0] . ')';
				$isSuperseded = true;
				break;
			}
		}
		if ($isSuperseded) {
			continue;
		}
		// A later migration with code we cannot interpret may have changed this table again.
		foreach ($extracted as $laterVersion => $x) {
			if (compareVersions($laterVersion, $v) > 0
				&& (in_array($e['table'], $x['touched'], true) || in_array('*', $x['touched'], true))) {
				$superseded[$v][] = describeEffect($e) . " (table may be changed by $laterVersion, not verifiable)";
				continue 2;
			}
		}
		$problem = checkEffect($e, $schema);
		if ($problem !== null) {
			// One line per missing table instead of one per column/index of it.
			$line = $problem === 'table missing' ? "table {$e['table']} missing" : describeEffect($e) . ': ' . $problem;
			if (($inScope === null || $inScope($v)) && !in_array($line, $notInEffect[$v] ?? [], true)) {
				$notInEffect[$v][] = $line;
			}
		} else {
			$verified[$v][] = describeEffect($e);
		}
	}

	$unverifiable = [];
	foreach ($extracted as $v => $x) {
		if ($x['reasons'] !== [] && ($inScope === null || $inScope($v))) {
			$unverifiable[$v] = $x['reasons'];
		}
	}

	$bad = $neverApplied !== [] || $notInEffect !== [] || ($strict && $unverifiable !== []);
	$toRun = array_values(array_unique(array_merge($neverApplied, array_keys($notInEffect))));
	usort($toRun, 'compareVersions');
	if ($toRun !== []) {
		$fixes[$app] = $toRun;
	}
	$stats = [
		'bad' => $bad,
		'never' => count($neverApplied),
		'noeffect' => count($notInEffect),
		'unverifiable' => count($unverifiable),
		'verified' => array_sum(array_map('count', $verified)),
		'expected' => count($expected),
		'text' => '',
	];
	if ($compact) {
		if ($bad || $verbose) {
			$stats['text'] = compactBlock($app, $neverApplied, $notInEffect, $unverifiable, $notInApp, $verified, $superseded, $verbose);
		}
		return $stats;
	}
	echo "app=$app prefix=$prefix source=$source\n";
	echo 'expected=' . count($expected) . ' applied=' . count($applied) . "\n\n";

	echo '== Never applied (' . count($neverApplied) . ") ==\n";
	foreach ($neverApplied as $v) {
		echo "app='$app', version='$v'\n";
	}
	echo "\n== Applied but not in effect (" . count($notInEffect) . ") ==\n";
	foreach ($notInEffect as $v => $problems) {
		echo "app='$app', version='$v'\n";
		foreach ($problems as $p) {
			echo "    $p\n";
		}
	}
	echo "\n== Not verifiable (" . count($unverifiable) . ") ==\n";
	foreach ($unverifiable as $v => $reasons) {
		echo "app='$app', version='$v'" . (isset($verified[$v]) || isset($notInEffect[$v]) ? ' (partially verified)' : '') . "\n";
		foreach ($reasons as $r) {
			echo "    $r\n";
		}
	}
	if ($notInApp !== []) {
		echo "\n== Applied but not in the app directory (" . count($notInApp) . ", informational) ==\n";
		foreach ($notInApp as $v) {
			echo "app='$app', version='$v'\n";
		}
	}
	if ($verbose) {
		echo "\n== Verified in effect ==\n";
		foreach ($verified as $v => $list) {
			echo "$v\n";
			foreach ($list as $d) {
				echo "    $d\n";
			}
		}
		echo "\n== Not checked: superseded or possibly changed by a later migration ==\n";
		foreach ($superseded as $v => $list) {
			echo "$v\n";
			foreach ($list as $d) {
				echo "    $d\n";
			}
		}
	}
	$nVerified = array_sum(array_map('count', $verified));
	echo "\nsummary: never_applied=" . count($neverApplied) . ' not_in_effect=' . count($notInEffect)
		. ' not_verifiable=' . count($unverifiable) . " effects_verified=$nVerified\n";

	return $stats;
}

/**
 * Overview for --all: totals, a table of the apps with findings, their details, then the clean apps.
 * @param array<string,array<string,mixed>> $results
 */
function printOverview(array $results, string $prefix, string $source, array $opts): void {
	$bad = array_filter($results, static fn (array $r): bool => $r['bad']);
	$ok = array_diff_key($results, $bad);
	$scope = isset($opts['since-nc']) ? 'migrations after Nextcloud ' . $opts['since-nc'] . ' branched' : 'all migrations';
	echo "Migration check: source=$source prefix=$prefix scope=$scope\n";
	echo 'Apps checked: ' . count($results) . ', with findings: ' . count($bad) . ', clean: ' . count($ok) . "\n\n";

	if ($bad !== []) {
		$width = max(array_map('strlen', array_keys($bad)));
		echo "== Apps with findings ==\n";
		printf("  %-{$width}s  %12s  %13s  %14s\n", 'app', 'never applied', 'not in effect', 'not verifiable');
		foreach ($bad as $name => $r) {
			printf("  %-{$width}s  %12d  %13d  %14d\n", $name, $r['never'], $r['noeffect'], $r['unverifiable']);
		}
		echo "\n== Details ==\n";
		foreach ($bad as $r) {
			echo $r['text'] . "\n";
		}
	}
	$detailsOfClean = array_filter($ok, static fn (array $r): bool => $r['text'] !== '');
	foreach ($detailsOfClean as $r) {
		echo $r['text'] . "\n";
	}
	if ($ok !== []) {
		echo '== Clean apps (' . count($ok) . ") ==\n";
		echo wordwrap('  ' . implode(', ', array_keys($ok)), 100, "\n  ") . "\n\n";
	}
}

/** Per-app detail block for --all: only what is wrong, versions with their problems underneath. */
function compactBlock(string $app, array $never, array $notInEffect, array $unverifiable, array $notInApp, array $verified, array $superseded, bool $verbose): string {
	$out = "$app\n";
	if ($never !== []) {
		$out .= "  Never applied:\n";
		foreach ($never as $v) {
			$out .= "    $v\n";
		}
	}
	if ($notInEffect !== []) {
		$out .= "  Applied but not in effect:\n";
		foreach ($notInEffect as $v => $problems) {
			$out .= "    $v\n";
			foreach ($problems as $p) {
				$out .= "        - $p\n";
			}
		}
	}
	if ($unverifiable !== []) {
		if ($verbose) {
			$out .= "  Not verifiable:\n";
			foreach ($unverifiable as $v => $reasons) {
				$out .= "    $v" . (isset($verified[$v]) || isset($notInEffect[$v]) ? ' (partially verified)' : '') . "\n";
				foreach ($reasons as $r) {
					$out .= "        - $r\n";
				}
			}
		} else {
			$out .= '  Not verifiable: ' . count($unverifiable) . " (use --verbose to list)\n";
		}
	}
	if ($notInApp !== []) {
		$out .= '  Applied but not in the app directory (informational): ' . implode(', ', $notInApp) . "\n";
	}
	if ($verbose) {
		foreach (['Verified in effect' => $verified, 'Not checked (superseded or possibly changed later)' => $superseded] as $title => $groups) {
			$out .= "  $title:\n";
			foreach ($groups as $v => $list) {
				$out .= "    $v\n";
				foreach ($list as $d) {
					$out .= "        - $d\n";
				}
			}
		}
	}
	return $out;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main(array $argv): int {
	$opts = getopt('h', [
		'app:', 'app-path:', 'db', 'applied:', 'schema:', 'dump-applied', 'dump-schema',
		'strict', 'verbose', 'help', 'config:', 'sqlite-file:', 'all', 'since-nc:'
	], $rest);
	if (isset($opts['h']) || isset($opts['help'])) {
		echo usage();
		return EXIT_OK;
	}
	if ($rest < count($argv) - 1) {
		fail("unknown or malformed arguments\n\n" . usage());
	}
	$all = isset($opts['all']);
	if ($all && (isset($opts['app']) || isset($opts['app-path']) || !isset($opts['db']))) {
		fail('--all needs --db and cannot be combined with --app or --app-path');
	}
	$app = (string)($opts['app'] ?? 'spreed');
	if (preg_match('/^[a-z0-9_]+$/', $app) !== 1) {
		fail('invalid --app');
	}
	$useDb = isset($opts['db']);
	$ncRoot = dirname(__DIR__, 2);
	$config = [];
	$prefix = 'oc_';
	if ($useDb) {
		$config = loadNcConfig((string)(($opts['config'] ?? '') ?: getenv('NEXTCLOUD_CONFIG_DIR') ?: "$ncRoot/config"));
		$prefix = (string)($config['dbtableprefix'] ?? 'oc_');
	}
	$sqliteFile = isset($opts['sqlite-file']) ? (string)$opts['sqlite-file'] : null;

	if (isset($opts['dump-schema']) || isset($opts['dump-applied'])) {
		if (!$useDb) {
			fail('--dump-* requires --db');
		}
		$pdo = connectDb($config, $sqliteFile);
		if (isset($opts['dump-applied'])) {
			foreach (array_keys(dbApplied($pdo, $app, $prefix)) as $v) {
				echo $v . "\n";
			}
		} else {
			dumpSchema($pdo, $prefix);
		}
		return EXIT_OK;
	}

	if ($useDb === isset($opts['applied']) || $useDb === isset($opts['schema'])) {
		fail("use either --db or both --applied and --schema\n\n" . usage());
	}

	$verbose = isset($opts['verbose']);
	$strict = isset($opts['strict']);
	$appPath = isset($opts['app-path']) ? (string)$opts['app-path'] : null;
	if ($appPath !== null && !is_dir($appPath)) {
		fail('app directory not found: ' . $appPath);
	}
	$cfgForLookup = $config ?: loadNcConfig("$ncRoot/config", false);

	if ($useDb) {
		$pdo = connectDb($config, $sqliteFile);
		$schema = dbSchema($pdo, $prefix);
		$source = 'database';
		$appliedByApp = $all ? dbAppliedAll($pdo, $prefix) : [$app => dbApplied($pdo, $app, $prefix)];
	} else {
		$schema = readSchemaFile((string)$opts['schema'], $prefix);
		$source = 'files';
		$appliedByApp = [$app => readAppliedFile((string)$opts['applied'])];
	}

	$bad = false;
	$skipped = [];
	$fixes = [];
	$results = [];
	foreach ($appliedByApp as $name => $applied) {
		$dir = migrationDir($name, $ncRoot, $all ? null : $appPath, $cfgForLookup);
		if ($dir === null || !is_dir($dir)) {
			if (!$all) {
				fail("no migration directory for app $name (use --app-path)");
			}
			$skipped[] = $name;
			continue;
		}
		$expected = dirMigrations($dir);
		if ($expected === [] && !$all) {
			fail("no migrations found in $dir");
		}
		$result = checkApp($name, $expected, $applied, $schema, $prefix, $source, $verbose, $strict, $all, scopeFilter($opts), $fixes);
		$bad = $result['bad'] || $bad;
		if ($all) {
			$results[$name] = $result;
		}
	}
	if ($all) {
		printOverview($results, $prefix, $source, $opts);
	}
	printFix($fixes);
	if ($skipped !== []) {
		echo 'Skipped (not on disk, e.g. disabled or removed apps): ' . implode(', ', $skipped) . "\n";
	}
	return $bad ? EXIT_FINDINGS : EXIT_OK;
}

exit(main($argv));
