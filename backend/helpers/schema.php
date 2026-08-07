<?php
/**
 * Schema introspection — the defence against the drift feature.md §14 warns
 * about ("different SQL dumps, especially around users.role and the password
 * column name").
 *
 * The registration and profile-edit forms collect a wide set of fields. Which
 * of those actually exist as columns varies between dumps of this database. An
 * INSERT naming a column that isn't there is a hard 1054 and takes the whole
 * request down; silently dropping the column keeps the account creation
 * working and loses one optional field. The second failure mode is much better
 * than the first, so every write built from a wide field map goes through
 * table_columns() first.
 *
 * This is NOT a way to let user input choose column names. Callers pass a
 * literal map written in PHP; this only filters that map down to what the
 * live table can accept.
 */

declare(strict_types=1);

require_once __DIR__ . '/../config/database.php';

/**
 * Column names of $table, lower-cased, as a set for O(1) lookup.
 *
 * Cached per-request: a registration touches this twice and an admin list
 * once per row otherwise.
 *
 * @return array<string,true>
 */
function table_columns(string $table): array
{
    static $cache = [];

    if (isset($cache[$table])) {
        return $cache[$table];
    }

    // $table is always a literal from our own code. Guard anyway so a future
    // caller cannot turn this into an injection point.
    if (!preg_match('/^[A-Za-z0-9_]+$/', $table)) {
        throw new InvalidArgumentException("Unsafe table name: $table");
    }

    $cols = [];
    try {
        $stmt = db()->query("SHOW COLUMNS FROM `$table`");
        foreach ($stmt->fetchAll() as $row) {
            // SHOW COLUMNS keys its rows 'Field'; PDO::FETCH_ASSOC keeps the case.
            $name = $row['Field'] ?? $row['field'] ?? null;
            if ($name !== null) {
                $cols[strtolower((string) $name)] = true;
            }
        }
    } catch (Throwable $e) {
        error_log("[ayur][schema] cannot read columns of $table: " . $e->getMessage());
    }

    return $cache[$table] = $cols;
}

/** True when $table really has $column in this database. */
function table_has_column(string $table, string $column): bool
{
    return isset(table_columns($table)[strtolower($column)]);
}

/**
 * Drop entries whose key is not a real column of $table, and drop nulls.
 *
 * Nulls go too so the column's own DEFAULT applies rather than an explicit
 * NULL — which is what makes this safe against NOT NULL columns the form
 * never asked about.
 *
 * @param array<string,mixed> $data
 * @return array<string,mixed>
 */
function filter_to_columns(string $table, array $data): array
{
    $cols = table_columns($table);

    // An empty set means SHOW COLUMNS failed. Passing the data through
    // unfiltered would surface the real error from the INSERT itself, which is
    // more informative than a silent no-op write.
    if (empty($cols)) {
        return array_filter($data, static fn($v) => $v !== null);
    }

    $out = [];
    foreach ($data as $col => $value) {
        if ($value !== null && isset($cols[strtolower($col)])) {
            $out[$col] = $value;
        }
    }

    return $out;
}

/**
 * INSERT $data into $table, keeping only real columns.
 *
 * @param array<string,mixed> $data  column => value, keys written as literals
 * @return int  the new row id, or 0 when nothing was insertable
 */
function insert_row(PDO $pdo, string $table, array $data): int
{
    $data = filter_to_columns($table, $data);
    if (empty($data)) {
        return 0;
    }

    $cols         = array_keys($data);
    $placeholders = implode(', ', array_fill(0, count($cols), '?'));
    $colSql       = '`' . implode('`, `', $cols) . '`';

    $pdo->prepare("INSERT INTO `$table` ($colSql) VALUES ($placeholders)")
        ->execute(array_values($data));

    return (int) $pdo->lastInsertId();
}

/**
 * UPDATE $table SET ... WHERE $idColumn = $id, keeping only real columns.
 *
 * @param array<string,mixed> $data
 * @return bool  false when there was nothing to write
 */
function update_row(PDO $pdo, string $table, array $data, string $idColumn, int $id): bool
{
    $data = filter_to_columns($table, $data);
    if (empty($data)) {
        return false;
    }

    if (!preg_match('/^[A-Za-z0-9_]+$/', $idColumn)) {
        throw new InvalidArgumentException("Unsafe column name: $idColumn");
    }

    $sets = implode(', ', array_map(static fn($c) => "`$c` = ?", array_keys($data)));

    $params   = array_values($data);
    $params[] = $id;

    $pdo->prepare("UPDATE `$table` SET $sets WHERE `$idColumn` = ?")->execute($params);

    return true;
}
