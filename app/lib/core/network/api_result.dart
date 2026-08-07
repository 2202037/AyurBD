/// Typed views over the §6 success envelope:
///   {"success": true, "message": "...", "data": {...},
///    "meta": {"page": 1, "limit": 20, "total": 137}}
library;

/// Pagination metadata. Absent on non-list endpoints.
class PageMeta {
  const PageMeta({required this.page, required this.limit, required this.total});

  final int page;
  final int limit;
  final int total;

  factory PageMeta.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const PageMeta(page: 1, limit: 0, total: 0);
    return PageMeta(
      page: _int(json['page'], 1),
      limit: _int(json['limit'], 0),
      total: _int(json['total'], 0),
    );
  }

  int get lastPage => limit <= 0 ? 1 : ((total + limit - 1) ~/ limit).clamp(1, 1 << 30);
  bool get hasMore => page < lastPage;

  static int _int(Object? v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }
}

/// A page of items plus the meta needed to fetch the next one.
class Paged<T> {
  const Paged({required this.items, required this.meta});

  final List<T> items;
  final PageMeta meta;

  bool get isEmpty => items.isEmpty;
  bool get hasMore => meta.hasMore;

  /// Appends the next page, carrying the newer meta forward.
  Paged<T> merge(Paged<T> next) =>
      Paged(items: [...items, ...next.items], meta: next.meta);

  static Paged<T> empty<T>() =>
      Paged(items: const [], meta: const PageMeta(page: 1, limit: 0, total: 0));
}
