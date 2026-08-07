/// Notifications, blog, reviews and feedback — from Supabase.
///
/// Public surface is unchanged: `notifications()`, `markRead()`,
/// `markAllRead()`, `registerFcmToken()`, `blog()`, `post()`, `reviews()`,
/// `submitReview()`, `sendFeedback()`.
///
/// Two things worth knowing.
///
/// **Notifications are read-only to the client.** `authenticated` has SELECT and
/// UPDATE on `notifications` and nothing more — no INSERT grant, no insert
/// policy, and `notify()` has EXECUTE revoked. Rows are created only by the
/// schema's triggers. So this file reads and marks read; it never writes one.
///
/// **The unread count is a separate query.** The old `notifications_my()`
/// returned `unread_count` as the *unfiltered* total alongside the page, which is
/// what keeps the badge correct when the list is paginated or filtered to
/// unread-only. Counting the rows on the current page would understate it, so a
/// `head: true` count query is issued for the badge.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show CountOption;

import '../../../core/constants/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/content_models.dart';

/// Notifications plus the unread badge count. The count is the unfiltered
/// total, so the badge stays correct even when the list is paginated or
/// filtered to unread-only.
class NotificationPage {
  const NotificationPage({required this.page, required this.unreadCount});

  final Paged<AppNotification> page;
  final int unreadCount;
}

class ContentRepository {
  ContentRepository(this._sb);

  final SupabaseService _sb;

  // -- notifications -------------------------------------------------------

  Future<NotificationPage> notifications({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    bool unreadOnly = false,
  }) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();
      final range = PageRange(page, limit);

      var query = _sb
          .db('notifications')
          .select('id, type, title, body, route, ref_id, is_read, created_at')
          .eq('user_id', userId);

      if (unreadOnly) query = query.eq('is_read', false);

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return NotificationPage(
        page: Paged(
          items: res.data.map(AppNotification.fromJson).toList(),
          meta: PageMeta(page: page, limit: limit, total: res.count),
        ),
        unreadCount: await _unreadCount(userId),
      );
    });
  }

  /// Returns the new unread total, recomputed after the update.
  ///
  /// Callers should use it rather than decrementing their own badge — the two
  /// drift if a notification arrives between the fetch and the tap.
  ///
  /// Marking an already-read notification is an idempotent success, not an
  /// error; only a genuinely missing (or someone else's) id is a 404.
  Future<int> markRead(int id) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();

      final row = await _sb
          .db('notifications')
          .update({'is_read': true})
          .eq('id', id)
          .eq('user_id', userId)
          .select('id')
          .maybeSingle();

      if (row == null) {
        throw ApiException(message: 'Notification not found.', statusCode: 404);
      }

      return _unreadCount(userId);
    });
  }

  /// Always resolves to 0, but the count is re-read rather than assumed: a
  /// notification created by a trigger between the update and the count would
  /// otherwise leave a badge the user cannot clear.
  Future<int> markAllRead() async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();

      await _sb
          .db('notifications')
          .update({'is_read': true})
          .eq('user_id', userId)
          .eq('is_read', false);

      return _unreadCount(userId);
    });
  }

  /// Push is out of scope for this slice (no Firebase dependency), so nothing
  /// calls this yet. Kept because the table exists and wiring a token later
  /// should not need a repository change.
  ///
  /// [platform] must be android/ios/web — it is a `device_platform` enum, so
  /// anything else is a 22P02. Upserts on `fcm_token` (`uq_device_token`), since
  /// the same handset re-registering must not accumulate rows.
  Future<void> registerFcmToken(String token, {String? platform}) async {
    await SupabaseService.guard(() async {
      final userId = _requireUser();

      await _sb.db('device_tokens').upsert(
        {
          'user_id': userId,
          'fcm_token': token.trim(),
          if (platform != null && platform.trim().isNotEmpty)
            'platform': platform.trim(),
        },
        onConflict: 'fcm_token',
      );
    });
  }

  Future<int> _unreadCount(String userId) async {
    final res = await _sb
        .db('notifications')
        .select('id')
        .eq('user_id', userId)
        .eq('is_read', false)
        .count(CountOption.exact);
    return res.count;
  }

  // -- blog ----------------------------------------------------------------

  /// Published articles only, newest first.
  ///
  /// `content` is deliberately not selected: it is the article body and never
  /// rendered in a card, so [BlogPost.isSummaryOnly] stays true for list rows
  /// and the detail screen knows it must fetch.
  Future<Paged<BlogPost>> blog({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? search,
    String? category,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb
          .db('blogs')
          .select('id, slug, title, excerpt, cover_image, category, tags, '
              'published_at, created_at, users!left(name)')
          .eq('status', 'published');

      if (_has(category)) query = query.eq('category', category!.trim());

      if (_has(search)) {
        final term = _escapeOr(search!.trim());
        query = query.or(
          'title.ilike.%$term%,'
          'excerpt.ilike.%$term%,'
          'tags.ilike.%$term%',
        );
      }

      final res = await query
          .order('published_at', ascending: false, nullsFirst: false)
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => BlogPost.fromJson(_shapePost(r))).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// The article plus up to four same-category articles.
  ///
  /// The view counter is not incremented. `blogs.views` exists, but a client has
  /// no UPDATE policy on `blogs` (admin only) and there is no RPC for it, so the
  /// attempt would be a 42501 on every article open. It was never wired to the
  /// UI — [BlogPost] models no view count — so nothing is lost on screen.
  Future<BlogArticle> post(String slug) async {
    return SupabaseService.guard(() async {
      const columns = 'id, slug, title, excerpt, content, cover_image, '
          'category, tags, published_at, created_at, users!left(name)';

      final row = await _sb
          .db('blogs')
          .select(columns)
          .eq('slug', slug)
          .eq('status', 'published')
          .maybeSingle();

      if (row == null) {
        throw ApiException(message: 'Article not found.', statusCode: 404);
      }

      final category = Fmt.str(row['category']);
      var related = const <Map<String, dynamic>>[];

      if (category.isNotEmpty) {
        final rows = await _sb
            .db('blogs')
            .select(columns)
            .eq('status', 'published')
            .eq('category', category)
            .neq('id', row['id'])
            .order('published_at', ascending: false, nullsFirst: false)
            .limit(4);
        related = rows;
      }

      return BlogArticle.fromJson({
        'article': _shapePost(row),
        'related': related.map(_shapePost).toList(),
      });
    });
  }

  // -- reviews -------------------------------------------------------------

  /// Approved reviews for one target, plus the aggregate the detail screens show
  /// above the list.
  ///
  /// The average and count come from the target's own cached `rating` /
  /// `total_reviews` columns, which the `recalc_reviewable_rating` trigger keeps
  /// in step with approved reviews. Averaging the current page client-side would
  /// give a different number on every page.
  Future<ReviewSummary> reviews({
    required ReviewTarget target,
    required int targetId,
    int page = 1,
    int limit = 10,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      final res = await _sb
          .db('reviews')
          .select('id, rating, comment, created_at, users!left(name, profile_image)')
          .eq('reviewable_type', target.value)
          .eq('reviewable_id', targetId)
          .eq('status', 'approved')
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      final aggregate = await _sb
          .db(_targetTable(target))
          .select('rating, total_reviews')
          .eq('id', targetId)
          .maybeSingle();

      return ReviewSummary.fromJson({
        'reviews': res.data.map(_shapeReview).toList(),
        'average_rating': aggregate?['rating'],
        // Falls back to the page total when the target row is not visible, so a
        // count is still shown rather than a bare 0.
        'review_count': aggregate?['total_reviews'] ?? res.count,
      });
    });
  }

  /// A 409 means this user already reviewed that target
  /// (`reviews_one_per_user`) or — for a doctor review without a valid
  /// appointment — that an appointment is missing or does not match.
  ///
  /// `status` is left to its `pending` default: it is an admin-only column, so
  /// sending even 'pending' explicitly risks the guard trigger, and a client
  /// must not be able to self-approve. The review therefore does not appear in
  /// the list until moderated — which is what the old backend did too.
  ///
  /// [appointmentId] is required for a doctor review and ignored for the other
  /// targets: the guard insists a doctor review reference an appointment the
  /// caller owns with the reviewed doctor, and the other reviewable types have
  /// no appointments. Leave it null (as the public directory screens do) and a
  /// doctor review is refused server-side.
  Future<void> submitReview({
    required ReviewTarget target,
    required int targetId,
    required int rating,
    String? comment,
    int? appointmentId,
  }) async {
    await SupabaseService.guard(() async {
      final userId = _requireUser();

      await _sb.db('reviews').insert({
        'user_id': userId,
        'reviewable_type': target.value,
        'reviewable_id': targetId,
        if (appointmentId != null) 'appointment_id': appointmentId,
        'rating': rating,
        if (comment != null && comment.trim().isNotEmpty)
          'comment': comment.trim(),
      });
    });
  }

  // -- feedback ------------------------------------------------------------

  /// Guests may submit, but then name and email are required — `feedback.name`
  /// and `feedback.email` are NOT NULL, and a signed-in user's own name/email
  /// are used as the fallback.
  ///
  /// [subject] is required for everyone: `feedback.subject` is NOT NULL and has
  /// no sensible fallback.
  ///
  /// Returns a thank-you message. The old server authored this text; there is no
  /// server to author it now, so the wording is here — it is the same sentence
  /// the PHP returned.
  ///
  /// `priority` and `status` are not sent: both are admin-only columns guarded by
  /// `aa_guard_feedback`, and both have defaults ('normal' / 'new').
  Future<String> sendFeedback({
    required String subject,
    required String message,
    String? name,
    String? email,
    String? phone,
    FeedbackType type = FeedbackType.general,
  }) async {
    return SupabaseService.guard(() async {
      final userId = _sb.currentUserId;

      var resolvedName = Fmt.str(name);
      var resolvedEmail = Fmt.str(email);

      if ((resolvedName.isEmpty || resolvedEmail.isEmpty) &&
          userId != null &&
          userId.isNotEmpty) {
        final profile = await _sb
            .db('users')
            .select('name, email')
            .eq('id', userId)
            .maybeSingle();

        if (resolvedName.isEmpty) resolvedName = Fmt.str(profile?['name']);
        if (resolvedEmail.isEmpty) resolvedEmail = Fmt.str(profile?['email']);
      }

      if (resolvedName.isEmpty || resolvedEmail.isEmpty) {
        throw ApiException(
          message: 'Please give your name and email address.',
          statusCode: 422,
          errors: {
            if (resolvedName.isEmpty) 'name': 'Please enter your name.',
            if (resolvedEmail.isEmpty) 'email': 'Please enter your email address.',
          },
        );
      }

      await _sb.db('feedback').insert({
        if (userId != null && userId.isNotEmpty) 'user_id': userId,
        'name': resolvedName,
        'email': resolvedEmail,
        'phone': _nullIfEmpty(phone),
        'feedback_type': type.value,
        'subject': subject.trim(),
        'message': message.trim(),
      });

      return 'Thank you for your feedback.';
    });
  }

  // -------------------------------------------------------------------------
  // Shaping
  // -------------------------------------------------------------------------

  /// Maps the blog columns onto the keys [BlogPost.fromJson] reads. The column
  /// is `cover_image`; the model reads `image`.
  Map<String, dynamic> _shapePost(Map<String, dynamic> r) {
    final author = r['users'] as Map<String, dynamic>?;
    return {
      ...r,
      'image': _sb.storageHelper.blogCover(r['cover_image'] as String?),
      'author_name': author?['name'],
    };
  }

  /// Flattens the author embed onto the aliases [Review.fromJson] reads.
  Map<String, dynamic> _shapeReview(Map<String, dynamic> r) {
    final author = r['users'] as Map<String, dynamic>?;
    return {
      ...r,
      'reviewer_name': author?['name'],
      'reviewer_image':
          _sb.storageHelper.avatar(author?['profile_image'] as String?),
    };
  }

  /// Which table holds the cached aggregate for a review target.
  static String _targetTable(ReviewTarget target) {
    switch (target) {
      case ReviewTarget.doctor:
        return 'doctors';
      case ReviewTarget.clinic:
        return 'clinics';
      case ReviewTarget.hospital:
        return 'hospitals';
      case ReviewTarget.pharmacy:
        return 'pharmacies';
    }
  }

  String _requireUser() {
    final id = _sb.currentUserId;
    if (id == null || id.isEmpty) {
      throw ApiException(
        message: 'Please sign in to continue.',
        statusCode: 401,
      );
    }
    return id;
  }

  static bool _has(String? v) => v != null && v.trim().isNotEmpty;

  static String? _nullIfEmpty(String? v) {
    final s = Fmt.str(v);
    return s.isEmpty ? null : s;
  }

  static String _escapeOr(String term) =>
      term.replaceAll(RegExp(r'[,()]'), ' ').replaceAll('*', '');
}

final contentRepositoryProvider = Provider<ContentRepository>(
  (ref) => ContentRepository(ref.watch(supabaseServiceProvider)),
);
