<?php
/**
 * Notifications — §6 /notifications/*
 * Token registration is kept even though Firebase is not wired into the Flutter
 * client in this build: the endpoint is harmless and means enabling FCM later
 * needs no API change.
 */

declare(strict_types=1);

/** GET /notifications/my?unread_only&page&limit */
function notifications_my(): void
{
    $user = require_auth();
    [$page, $limit, $offset] = paging();

    $where  = ['n.user_id = ?'];
    $params = [$user['id']];

    if (q('unread_only') === '1') {
        $where[] = 'n.is_read = 0';
    }

    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $cs = db()->prepare("SELECT COUNT(*) FROM notifications n $whereSql");
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    // Unread count is always the unfiltered total, so the badge stays correct
    // even when the list is filtered or paginated.
    $us = db()->prepare('SELECT COUNT(*) FROM notifications WHERE user_id = ? AND is_read = 0');
    $us->execute([$user['id']]);
    $unread = (int) $us->fetchColumn();

    $stmt = db()->prepare(
        "SELECT n.* FROM notifications n
         $whereSql ORDER BY n.created_at DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows = array_map(static fn($r) => [
        'id'         => (int) $r['id'],
        'title'      => $r['title'],
        'body'       => $r['body'],
        'type'       => $r['type'],
        'ref_id'     => isset($r['ref_id']) && $r['ref_id'] !== null ? (int) $r['ref_id'] : null,
        'is_read'    => (bool) $r['is_read'],
        'created_at' => $r['created_at'],
    ], $stmt->fetchAll());

    json_ok(
        ['notifications' => $rows, 'unread_count' => $unread],
        'OK',
        meta_page($page, $limit, $total)
    );
}

/** POST /notifications/{id}/read */
function notifications_mark_read(string $id): void
{
    $user = require_auth();

    // user_id in the WHERE prevents reading someone else's notification id.
    $stmt = db()->prepare('UPDATE notifications SET is_read = 1 WHERE id = ? AND user_id = ?');
    $stmt->execute([(int) $id, $user['id']]);

    if ($stmt->rowCount() === 0) {
        $check = db()->prepare('SELECT id FROM notifications WHERE id = ? AND user_id = ? LIMIT 1');
        $check->execute([(int) $id, $user['id']]);
        if (!$check->fetch()) {
            json_error('Notification not found.', 404);
        }
        // Row existed and was already read — idempotent success.
    }

    $us = db()->prepare('SELECT COUNT(*) FROM notifications WHERE user_id = ? AND is_read = 0');
    $us->execute([$user['id']]);

    json_ok(['unread_count' => (int) $us->fetchColumn()], 'Marked as read.');
}

/** POST /notifications/read-all */
function notifications_mark_all_read(): void
{
    $user = require_auth();

    db()->prepare('UPDATE notifications SET is_read = 1 WHERE user_id = ? AND is_read = 0')
        ->execute([$user['id']]);

    json_ok(['unread_count' => 0], 'All notifications marked as read.');
}

/** POST /notifications/fcm {fcm_token,platform} */
function notifications_register_token(): void
{
    $user = require_auth();

    $in = validate(json_body(), [
        'fcm_token' => 'required|max:255',
        'platform'  => 'in:android,ios,web',
    ]);

    // fcm_token is globally UNIQUE: if the device previously belonged to another
    // account, reassign it rather than failing.
    db()->prepare(
        'INSERT INTO device_tokens (user_id, fcm_token, platform) VALUES (?, ?, ?)
         ON DUPLICATE KEY UPDATE user_id = VALUES(user_id), platform = VALUES(platform)'
    )->execute([$user['id'], $in['fcm_token'], $in['platform'] ?? 'android']);

    json_ok(null, 'Device registered for notifications.');
}
