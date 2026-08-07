<?php
/**
 * Blog / reviews / feedback — §6 (all marked NEW)
 * Reviews recompute the target's cached rating so directory listings stay honest.
 */

declare(strict_types=1);

/** GET /blog?search&category&page&limit */
function blog_list(): void
{
    [$page, $limit, $offset] = paging();

    $where  = ["b.status = 'published'"];
    $params = [];

    if ($search = q('search')) {
        $where[]  = '(b.title LIKE ? OR b.excerpt LIKE ?)';
        $like     = '%' . $search . '%';
        $params[] = $like;
        $params[] = $like;
    }
    if ($category = q('category')) {
        $where[]  = 'b.category = ?';
        $params[] = $category;
    }

    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $cs = db()->prepare("SELECT COUNT(*) FROM blogs b $whereSql");
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    // List view omits `content` — it can be large and is not rendered in a card.
    $stmt = db()->prepare(
        "SELECT b.id, b.title, b.slug, b.excerpt, b.cover_image, b.category,
                b.published_at, b.created_at, u.name AS author_name
           FROM blogs b LEFT JOIN users u ON u.id = b.author_id
         $whereSql
         ORDER BY b.published_at DESC, b.id DESC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows = array_map(static fn($r) => [
        'id'           => (int) $r['id'],
        'title'        => $r['title'],
        'slug'         => $r['slug'],
        'excerpt'      => $r['excerpt'],
        'image'        => $r['cover_image'],
        'category'     => $r['category'],
        'author_name'  => $r['author_name'],
        'published_at' => $r['published_at'] ?? $r['created_at'],
    ], $stmt->fetchAll());

    json_ok(['articles' => $rows], 'OK', meta_page($page, $limit, $total));
}

/** GET /blog/{slug} */
function blog_detail(string $slug): void
{
    $stmt = db()->prepare(
        "SELECT b.*, u.name AS author_name
           FROM blogs b LEFT JOIN users u ON u.id = b.author_id
          WHERE b.slug = ? AND b.status = 'published' LIMIT 1"
    );
    $stmt->execute([$slug]);
    $row = $stmt->fetch();

    if (!$row) {
        json_error('Article not found.', 404);
    }

    $rel = db()->prepare(
        'SELECT id, title, slug, excerpt, cover_image AS image, category, published_at
           FROM blogs
          WHERE status = \'published\' AND id <> ? AND (category = ? OR ? IS NULL)
          ORDER BY published_at DESC LIMIT 4'
    );
    $rel->execute([(int) $row['id'], $row['category'], $row['category']]);

    json_ok([
        'article' => [
            'id'           => (int) $row['id'],
            'title'        => $row['title'],
            'slug'         => $row['slug'],
            'excerpt'      => $row['excerpt'],
            'content'      => $row['content'],
            'image'        => $row['cover_image'],
            'category'     => $row['category'],
            'author_name'  => $row['author_name'],
            'published_at' => $row['published_at'] ?? $row['created_at'],
        ],
        'related' => $rel->fetchAll(),
    ]);
}

/**
 * Review targets — this list is the `reviews.reviewable_type` enum, exactly.
 *
 * 'product' is deliberately absent. The live enum is
 * enum('doctor','hospital','clinic','pharmacy'), so inserting 'product' would be
 * rejected by MySQL as truncated data (or silently stored as '' in a non-strict
 * install, which is worse). Product reviews would need that enum widened, which
 * means altering a column the website already reads — out of scope for an
 * additive migration. If they are wanted later, add 'product' to the enum in the
 * database first, then here.
 */
const REVIEW_TARGETS = ['doctor', 'clinic', 'hospital', 'pharmacy'];

/** GET /reviews?target_type&target_id */
function reviews_list(): void
{
    [$page, $limit, $offset] = paging();

    $type = q('target_type');
    $id   = q('target_id');

    if ($type === null || $id === null || !ctype_digit($id)) {
        json_error('target_type and target_id are required.', 400, [
            'target_type' => 'Required (' . implode('/', REVIEW_TARGETS) . ').',
            'target_id'   => 'Required numeric id.',
        ]);
    }
    if (!in_array($type, REVIEW_TARGETS, true)) {
        json_error('Invalid target_type.', 400, [
            'target_type' => 'Must be one of: ' . implode(', ', REVIEW_TARGETS),
        ]);
    }

    $params = [$type, (int) $id];

        $cs = db()->prepare(
                "SELECT COUNT(*) FROM reviews
                    WHERE reviewable_type = ? AND reviewable_id = ? AND status = 'approved'"
        );
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

        $ag = db()->prepare(
                "SELECT AVG(rating) AS avg_rating, COUNT(*) AS cnt FROM reviews
                    WHERE reviewable_type = ? AND reviewable_id = ? AND status = 'approved'"
        );
    $ag->execute($params);
    $agg = $ag->fetch();

    // LEFT JOIN: the COUNT and the AVG above do not join at all, so an inner
    // join here listed fewer reviews than it counted and averaged — the header
    // would read "12 reviews, 4.5" above a list of 11. It also keeps a review
    // visible after its author's account is removed, which is the honest
    // outcome given the rating it contributed is still in the average.
    $stmt = db()->prepare(
        "SELECT r.id, r.rating, r.comment, r.created_at,
                u.name AS reviewer_name, u.profile_image AS reviewer_image
           FROM reviews r LEFT JOIN users u ON u.id = r.user_id
          WHERE r.reviewable_type = ? AND r.reviewable_id = ? AND r.status = 'approved'
          ORDER BY r.created_at DESC
          LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok([
        'reviews'      => array_map(static fn($r) => [
            'id'             => (int) $r['id'],
            'rating'         => (int) $r['rating'],
            'comment'        => $r['comment'],
            'reviewer_name'  => $r['reviewer_name'],
            'reviewer_image' => $r['reviewer_image'],
            'created_at'     => $r['created_at'],
        ], $stmt->fetchAll()),
        'average_rating' => $agg['avg_rating'] === null ? 0.0 : round((float) $agg['avg_rating'], 2),
        'review_count'   => (int) $agg['cnt'],
    ], 'OK', meta_page($page, $limit, $total));
}

/** POST /reviews {target_type,target_id,rating,comment} */
function reviews_create(): void
{
    $user = require_auth();

    $in = validate(json_body(), [
        'target_type' => 'required|in:' . implode(',', REVIEW_TARGETS),
        'target_id'   => 'required|int',
        'rating'      => 'required|int|min:1|max:5',
        'comment'     => 'max:1000',
    ]);

    // Target must exist. Table chosen from a fixed map, never from input.
    $tableMap = [
        'doctor'   => 'doctors',
        'clinic'   => 'clinics',
        'hospital' => 'hospitals',
        'pharmacy' => 'pharmacies',
    ];
    $table = $tableMap[$in['target_type']];

    $ex = db()->prepare("SELECT id FROM $table WHERE id = ? LIMIT 1");
    $ex->execute([$in['target_id']]);
    if (!$ex->fetch()) {
        json_error('The item you are reviewing was not found.', 404);
    }

    // One review per user per target, checked with a query rather than caught as
    // a 1062. The live `reviews` table has no unique key on
    // (user_id, reviewable_type, reviewable_id) — only non-unique idx_reviewable
    // — so there is no constraint to violate and an earlier errno-23000 catch
    // here would never have fired.
    //
    // This is a check-then-insert, so two simultaneous submissions from the same
    // account could both pass. That is accepted: the cost is a duplicate review,
    // not a double booking or a double charge, and adding a unique index would
    // fail on any duplicates the website has already stored.
    $dup = db()->prepare(
        'SELECT id FROM reviews
          WHERE user_id = ? AND reviewable_type = ? AND reviewable_id = ? LIMIT 1'
    );
    $dup->execute([$user['id'], $in['target_type'], $in['target_id']]);
    if ($dup->fetch()) {
        json_error('You have already reviewed this.', 409);
    }

    // Reviews land as 'pending' (the column default) and appear publicly only
    // once an admin approves them — the same moderation flow the website uses.
    db()->prepare(
        'INSERT INTO reviews (user_id, reviewable_type, reviewable_id, rating, comment)
         VALUES (?, ?, ?, ?, ?)'
    )->execute([
        $user['id'],
        $in['target_type'],
        $in['target_id'],
        $in['rating'],
        $in['comment'] ?? null,
    ]);

    $reviewId = (int) db()->lastInsertId();

    // Cached rating/total_reviews are recomputed from APPROVED reviews only, so a
    // brand-new pending review does not move the average yet. Running it anyway
    // keeps the cache honest if an admin approved something since the last write.
    // COALESCE guards the case where no approved review exists: AVG() returns
    // NULL there, and rating is NOT NULL DEFAULT 0.00.
    $upd = db()->prepare(
        "UPDATE $table SET
            rating = COALESCE((
                SELECT ROUND(AVG(r.rating), 2) FROM reviews r
                 WHERE r.reviewable_type = ? AND r.reviewable_id = ?
                   AND r.status = 'approved'
            ), 0),
            total_reviews = (
                SELECT COUNT(*) FROM reviews r
                 WHERE r.reviewable_type = ? AND r.reviewable_id = ?
                   AND r.status = 'approved'
            )
          WHERE id = ?"
    );
    $upd->execute([
        $in['target_type'], $in['target_id'],
        $in['target_type'], $in['target_id'],
        $in['target_id'],
    ]);

    audit((int) $user['id'], 'create', 'reviews', $reviewId, [
        'target' => $in['target_type'] . '#' . $in['target_id'],
        'rating' => $in['rating'],
    ]);

    json_ok(null, 'Thank you for your review. It will appear once approved.', null, 201);
}

/** POST /feedback {subject,message,feedback_type?,phone?} — §6: guest-allowed. */
function feedback_create(): void
{
    $user = current_user();   // optional auth

    // `name`, `email`, `subject` and `message` are all NOT NULL in the live
    // table, so every one of them must end up with a real value. For a logged-in
    // user the first two fall back to the account; `subject` has no sensible
    // fallback and is therefore always required.
    $rules = [
        'message'       => 'required|min:5|max:2000',
        'subject'       => 'required|min:3|max:255',
        'phone'         => 'max:20',
        'feedback_type' => 'in:general,suggestion,complaint,bug_report,doctor_issue,'
                         . 'hospital_issue,appointment_issue,payment_issue,appreciation',
    ];
    if ($user === null) {
        // Guests should leave a way to reply.
        $rules['name']  = 'required|min:2|max:100';
        $rules['email'] = 'required|email|max:100';
    } else {
        $rules['name']  = 'max:100';
        $rules['email'] = 'email|max:100';
    }

    $in = validate(json_body(), $rules);

    rate_limit('feedback', 5, 600);   // §10: guest-writable endpoint

    $name  = $in['name']  ?? ($user['name']  ?? null);
    $email = $in['email'] ?? ($user['email'] ?? null);

    // A logged-in account with a blank name or email would otherwise trip the
    // NOT NULL constraint and surface as a 500.
    if ($name === null || trim((string) $name) === ''
        || $email === null || trim((string) $email) === '') {
        json_error('A name and email are required to send feedback.', 422, [
            'name'  => 'Required.',
            'email' => 'Required.',
        ]);
    }

    db()->prepare(
        'INSERT INTO feedback (user_id, name, email, phone, feedback_type, subject, message)
         VALUES (?, ?, ?, ?, ?, ?, ?)'
    )->execute([
        $user['id'] ?? null,
        $name,
        $email,
        $in['phone'] ?? null,
        $in['feedback_type'] ?? 'general',
        $in['subject'],
        $in['message'],
    ]);

    json_ok(null, 'Thank you for your feedback.', null, 201);
}
