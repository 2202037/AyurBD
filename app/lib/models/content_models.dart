/// Notifications, blog posts and reviews.
library;

import '../core/utils/formatters.dart';

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.isRead,
    this.type,
    this.referenceId,
    this.createdAt,
  });

  final int id;
  final String title;

  /// `notifications.body` is nullable in the schema, but the shaper always emits
  /// the key. Empty string is the honest rendering of a null body.
  final String body;

  final bool isRead;

  /// [ASSUMED] appointment | payment | order | blood | system — decides the
  /// leading icon. Free-text VARCHAR(40) server-side, so treat unknown values as
  /// generic rather than asserting the set.
  final String? type;

  /// [ASSUMED] `notifications.ref_id` — the id of the appointment/order the
  /// notification points at, when the row carries one. Lets a tap deep-link into
  /// the right detail screen.
  ///
  /// The wire key is `ref_id`, not `reference_id`; reading the latter silently
  /// made every notification un-tappable.
  final int? referenceId;

  final String? createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: Fmt.toInt(json['id']),
        title: Fmt.str(json['title'], 'Notification'),
        body: Fmt.str(json['body']),
        isRead: Fmt.toBool(json['is_read']),
        type: _orNull(json['type']),
        referenceId: json['ref_id'] == null ? null : Fmt.toInt(json['ref_id']),
        createdAt: _orNull(json['created_at']),
      );

  /// True when a tap can go somewhere. [type] alone is not enough — a
  /// `system` notice has no target.
  bool get isActionable => referenceId != null && type != null;

  String get timeLabel => Fmt.relative(createdAt);

  AppNotification markRead() => AppNotification(
        id: id,
        title: title,
        body: body,
        isRead: true,
        type: type,
        referenceId: referenceId,
        createdAt: createdAt,
      );
}

/// Mirrors the two blog shapers in content.php.
///
/// The list and detail projections differ by exactly one field: `content`, which
/// the list omits because it is LONGTEXT and never rendered in a card. Everything
/// else is common to both, so one model serves both with [content] nullable.
///
/// There is no view counter — `blogs` has no such column and neither shaper
/// emits one. An earlier `viewCount` here was permanently 0.
class BlogPost {
  const BlogPost({
    required this.id,
    required this.slug,
    required this.title,
    this.excerpt,
    this.content,
    this.image,
    this.category,
    this.authorName,
    this.publishedAt,
  });

  final int id;
  final String slug;
  final String title;
  final String? excerpt;

  /// Only present on the detail response — the list endpoint omits it so the
  /// payload stays small. Null here means "not loaded", not "empty article".
  final String? content;

  final String? image;
  final String? category;

  /// Joined from `users.name` via `author_id`, which is `ON DELETE SET NULL` —
  /// so a real article can genuinely have no author.
  final String? authorName;

  /// The shaper coalesces `published_at ?? created_at`, so this is never null
  /// for a published article even though the column is nullable.
  final String? publishedAt;

  factory BlogPost.fromJson(Map<String, dynamic> json) => BlogPost(
        id: Fmt.toInt(json['id']),
        slug: Fmt.str(json['slug']),
        title: Fmt.str(json['title'], 'Untitled'),
        excerpt: _orNull(json['excerpt']),
        content: _orNull(json['content']),
        image: _orNull(json['image']),
        category: _orNull(json['category']),
        authorName: _orNull(json['author_name']),
        publishedAt: _orNull(json['published_at'] ?? json['created_at']),
      );

  /// True on list rows, where `content` is omitted by design. A detail screen
  /// handed one of these must fetch by [slug] before rendering the body.
  bool get isSummaryOnly => content == null;

  String get dateLabel => Fmt.dayMonth(publishedAt);
}

/// `/blog/{slug}` returns the article plus up to four same-category articles.
///
/// The `related` rows come straight from `$rel->fetchAll()` with no shaper, so
/// they are raw column names — which happen to match the list shaper's keys for
/// every field except that `published_at` is not coalesced. [BlogPost.fromJson]
/// already falls back to `created_at`, so it parses them safely.
class BlogArticle {
  const BlogArticle({required this.article, this.related = const []});

  final BlogPost article;
  final List<BlogPost> related;

  /// Takes the whole `data` object — `{article: {...}, related: [...]}` — not the
  /// inner article, since it needs both siblings.
  factory BlogArticle.fromJson(Map<String, dynamic> json) {
    final raw = json['related'];
    final inner = json['article'];
    return BlogArticle(
      article: BlogPost.fromJson(
        inner is Map ? inner.map((k, v) => MapEntry(k.toString(), v)) : json,
      ),
      related: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => BlogPost.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
              .toList()
          : const [],
    );
  }
}

class Review {
  const Review({
    required this.id,
    required this.rating,
    this.comment,
    this.userName,
    this.userImage,
    this.createdAt,
  });

  final int id;
  final int rating;
  final String? comment;
  final String? userName;
  final String? userImage;
  final String? createdAt;

  factory Review.fromJson(Map<String, dynamic> json) => Review(
        id: Fmt.toInt(json['id']),
        rating: Fmt.toInt(json['rating']).clamp(1, 5),
        comment: _orNull(json['comment'] ?? json['review']),
        // The API joins the reviewer in as `reviewer_name` / `reviewer_image`
        // (content.php, and the embedded review lists in directory.php).
        userName: _orNull(json['reviewer_name'] ?? json['user_name'] ?? json['name']),
        userImage: _orNull(json['reviewer_image'] ?? json['user_image'] ?? json['image']),
        createdAt: _orNull(json['created_at']),
      );

  String get dateLabel => Fmt.dayMonth(createdAt);
}

/// `/reviews` also returns the aggregate for the target, which the detail
/// screens show above the list.
class ReviewSummary {
  const ReviewSummary({this.average = 0, this.count = 0, this.reviews = const []});

  final double average;
  final int count;
  final List<Review> reviews;

  factory ReviewSummary.fromJson(Map<String, dynamic> json) {
    final raw = json['reviews'] ?? json['items'];
    return ReviewSummary(
      average: Fmt.toDouble(json['average_rating'] ?? json['average']),
      count: Fmt.toInt(json['review_count'] ?? json['count']),
      reviews: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => Review.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
              .toList()
          : const [],
    );
  }

  String get averageLabel => count == 0 ? 'No reviews yet' : average.toStringAsFixed(1);
}

/// Valid `target_type` values, matching `const REVIEW_TARGETS` in content.php.
///
/// There is deliberately no `product`. The live `reviews.reviewable_type` column
/// is enum('doctor','hospital','clinic','pharmacy'), and `reviews_create()`
/// whitelists exactly those four — a product review is answered 400 before it
/// ever reaches MySQL. The value used to exist here, which made product reviews
/// look implemented at the call site and fail only at runtime. Widening the
/// database enum is the prerequisite for adding it back.
enum ReviewTarget {
  doctor,
  clinic,
  hospital,
  pharmacy;

  String get value => name;
}

/// The nine values `feedback_create()` accepts in its
/// `in:general,suggestion,complaint,bug_report,...` rule.
///
/// Spelled out rather than derived from `name` because four of them are
/// snake_case on the wire and Dart enum names cannot be — sending `bugReport`
/// would be a 400. [value] is what goes over the wire; [label] is what the form
/// shows.
enum FeedbackType {
  general('general', 'General'),
  suggestion('suggestion', 'Suggestion'),
  complaint('complaint', 'Complaint'),
  bugReport('bug_report', 'Bug report'),
  doctorIssue('doctor_issue', 'Problem with a doctor'),
  hospitalIssue('hospital_issue', 'Problem with a hospital'),
  appointmentIssue('appointment_issue', 'Problem with an appointment'),
  paymentIssue('payment_issue', 'Problem with a payment'),
  appreciation('appreciation', 'Appreciation');

  const FeedbackType(this.value, this.label);

  final String value;
  final String label;
}

String? _orNull(Object? v) {
  final s = Fmt.str(v);
  return s.isEmpty ? null : s;
}
