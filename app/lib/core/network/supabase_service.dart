/// The single point of contact with Supabase.
///
/// This replaces `api_client.dart`. That file existed to speak the PHP §6
/// envelope — `{success, data, message, errors, meta}` — over Dio, attach a JWT
/// by hand, and turn a 401 into a logout. Postgrest returns rows directly and
/// GoTrue attaches the token itself, so almost all of that work disappears.
/// What is left, and what lives here, is the part the app still depends on:
///
///   1. Every failure arriving as [ApiException], so the 42 files that already
///      catch it keep compiling and keep showing the same messages.
///   2. Range-based pagination that yields the same `total` the old `meta` block
///      carried, so `Paged<T>` and every list screen are unchanged.
///   3. Storage path -> URL resolution, since the widget layer only ever sees a
///      finished URL (see AppConfig.resolveAsset).
library;

import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/app_config.dart';
import 'api_exception.dart';

/// Thin façade over [SupabaseClient].
///
/// Repositories hold one of these instead of an `ApiClient`. It is deliberately
/// not a wrapper around every Postgrest verb: the builder API is fluent and
/// hiding it would mean re-implementing it. Repositories use [db] directly and
/// wrap the awaited call in [guard].
class SupabaseService {
  SupabaseService(this._client);

  final SupabaseClient _client;

  /// Postgrest entry point: `svc.db.from('doctors').select()`.
  SupabaseQueryBuilder db(String table) => _client.from(table);

  /// `rpc()` for the schema's SECURITY DEFINER functions.
  Future<T> rpc<T>(String fn, {Map<String, dynamic>? params}) =>
      guard(() async => await _client.rpc<T>(fn, params: params));

  GoTrueClient get auth => _client.auth;
  SupabaseStorageClient get storage => _client.storage;

  /// Bucket-aware path -> URL helper. Every repository uses this to turn a
  /// storage column into something the widget layer can render.
  ///
  /// Built lazily and cached: it is stateless apart from the client reference,
  /// so one instance per service is enough and repositories need not construct
  /// their own.
  SupabaseStorage get storageHelper =>
      _storageHelper ??= SupabaseStorage(_client.storage);
  SupabaseStorage? _storageHelper;

  /// The signed-in user's uuid, or null. This is the replacement for "decode the
  /// JWT payload" — the id is a plain string now, matching `users.id`.
  String? get currentUserId => _client.auth.currentUser?.id;

  bool get hasSession => _client.auth.currentSession != null;

  /// Calls a Supabase Edge Function with the current user's auth token.
  Future<T> functionsInvoke<T>(
    String functionName, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    return guard(() async {
      final response = await _client.functions.invoke(
        functionName,
        body: body,
        headers: headers,
      );
      // Edge Functions throw on error, so if we get here it succeeded
      return response.data as T;
    });
  }

  /// Runs [body] and converts anything it throws into [ApiException].
  ///
  /// Every repository call goes through this. Without it a Postgrest RLS refusal
  /// would surface as a raw `PostgrestException`, which no screen catches, and
  /// the user would see a red framework error instead of the message the old
  /// backend produced for the same situation.
  static Future<T> guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on ApiException {
      // Already translated (e.g. rethrown by a repository) — do not re-wrap.
      rethrow;
    } on AuthException catch (e) {
      throw _fromAuth(e);
    } on PostgrestException catch (e) {
      throw _fromPostgrest(e);
    } on StorageException catch (e) {
      throw _fromStorage(e);
    } on FunctionException catch (e) {
      throw _fromFunction(e);
    } on SocketException catch (e) {
      throw ApiException(
        message: 'No connection to the server.\n${e.message}',
        kind: ApiErrorKind.network,
      );
    } on TimeoutException {
      throw ApiException(
        message: 'The server took too long to respond. Please try again.',
        kind: ApiErrorKind.network,
      );
    } on FormatException catch (e) {
      throw ApiException(
        message: 'The server sent a response the app could not read.\n${e.message}',
        kind: ApiErrorKind.malformed,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Error translation
  //
  // The old client read HTTP status codes off a Dio response. Postgrest and
  // GoTrue report failures as SQLSTATE / provider codes, so these map each to
  // the status the app's own predicates already test for — `isValidation`,
  // `isConflict`, `isUnauthorized`. Getting the mapping wrong would not fail to
  // compile; it would quietly send a duplicate-booking error down the generic
  // path and lose the "that slot was just taken" message.
  // -------------------------------------------------------------------------

  static ApiException _fromAuth(AuthException e) {
    final raw = e.message;
    final lower = raw.toLowerCase();

    // GoTrue's own wording, mapped to what the PHP handlers used to say so the
    // login screen shows the same sentence for the same mistake.
    if (lower.contains('invalid login credentials')) {
      return ApiException(
        message: 'Incorrect email or password.',
        statusCode: 401,
        errors: const {'password': 'Incorrect email or password.'},
      );
    }
    if (lower.contains('email not confirmed')) {
      return ApiException(
        message: 'Please confirm your email address before signing in.',
        statusCode: 401,
        errors: const {'email': 'This address has not been confirmed yet.'},
      );
    }
    if (lower.contains('already registered') ||
        lower.contains('already been registered') ||
        lower.contains('user already exists')) {
      return ApiException(
        message: 'That email address is already registered.',
        statusCode: 409,
        errors: const {'email': 'That email address is already registered.'},
      );
    }
    if (lower.contains('password should be') || lower.contains('password is too')) {
      return ApiException(
        message: raw,
        statusCode: 400,
        errors: {'password': raw},
      );
    }
    if (lower.contains('rate limit') || lower.contains('too many')) {
      return ApiException(
        message: 'Too many attempts. Please wait a moment and try again.',
        statusCode: 429,
      );
    }

    // A stale or revoked refresh token is a normal signed-out condition, not a
    // crash: statusCode 401 makes `isUnauthorized` true, which is what the
    // router already keys off.
    final code = int.tryParse(e.statusCode ?? '') ?? 401;
    return ApiException(message: raw, statusCode: code);
  }

  static ApiException _fromPostgrest(PostgrestException e) {
    final code = e.code ?? '';
    final raw = (e.message).trim();
    // Functions that raise a business rule put a machine code in DETAIL, e.g.
    // `using errcode = 'P0001', detail = 'ALREADY_PAID'`. Carrying it through
    // lets a screen react to the *rule* without matching on English.
    final serverCode = _detailCode(e);

    switch (code) {
      // Row Level Security refused the row. This is the single most likely
      // failure in a fresh migration, so it says which table rather than
      // "permission denied for table users", which sends people to grants.
      case '42501':
        return ApiException(
          message: raw.isEmpty
              ? 'You do not have permission to do that.'
              : 'You do not have permission to do that.\n$raw',
          statusCode: 403,
          code: serverCode,
        );

      // Unique violation. Carries the constraint name so callers can tell a
      // double-booked slot from a duplicate email.
      case '23505':
        return ApiException(
          message: _uniqueMessage(e),
          statusCode: 409,
          errors: _uniqueField(e),
          code: serverCode,
        );

      // Foreign key violation — referencing a row that does not exist.
      case '23503':
        return ApiException(
          message: 'That item no longer exists.',
          statusCode: 409,
          code: serverCode,
        );

      // NOT NULL violation.
      case '23502':
        return ApiException(
          message: 'A required field was missing.',
          statusCode: 400,
          code: serverCode,
        );

      // CHECK constraint, and the enum-input failure below it. Both mean the
      // value the UI sent is outside what the column accepts.
      case '23514':
      case '22P02':
        return ApiException(
          message: raw.isEmpty ? 'That value is not allowed.' : raw,
          statusCode: 422,
          code: serverCode,
        );

      // raise exception in a trigger/function without an explicit errcode.
      // The schema's guards use this deliberately, e.g. the double-booking and
      // stock checks, so the text is the user-facing message and is passed
      // through verbatim.
      case 'P0001':
        return ApiException(
          message: raw.isEmpty ? 'That action was rejected.' : raw,
          statusCode: 422,
          code: serverCode,
        );

      // .single() matched no rows. The old API answered 404 here.
      //
      // The message is only passed through when a function raised this
      // deliberately (which is what a DETAIL code proves). PostgREST's own
      // text for the same status is "JSON object requested, multiple (or no)
      // rows returned", which is jargon no patient should be shown.
      case 'PGRST116':
        return ApiException(
          message: (serverCode != null && raw.isNotEmpty) ? raw : 'Not found.',
          statusCode: 404,
          code: serverCode,
        );

      // No/expired JWT.
      case 'PGRST301':
      case '401':
        return ApiException(message: 'Your session has expired.', statusCode: 401);
    }

    // Unmapped: keep the SQLSTATE in the message. A migration will surface a
    // handful of these, and the code is the only thing that makes them
    // diagnosable.
    return ApiException(
      message: raw.isEmpty ? 'Database error $code.' : raw,
      statusCode: 400,
      code: serverCode,
    );
  }

  /// The machine code a PL/pgSQL function put in DETAIL, if it looks like one.
  ///
  /// Functions raise with `detail = 'ALREADY_PAID'` and similar. DETAIL is also
  /// where Postgres itself writes prose for built-in violations ("Key (id)=(4)
  /// already exists."), so this only accepts SHOUTING_SNAKE_CASE and ignores
  /// anything else. That keeps a Postgres sentence from ever being mistaken
  /// for one of our codes.
  static String? _detailCode(PostgrestException e) {
    final detail = (e.details is String ? e.details as String : '').trim();
    if (detail.isEmpty || detail.length > 64) return null;
    return RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(detail) ? detail : null;
  }

  /// Translates a Supabase Edge Function failure into [ApiException].
  ///
  /// The SDK throws [FunctionException] for any non-2xx response, so an
  /// `errorResponse(..., status)` call on the function side reaches Dart as a
  /// `FunctionException` whose [FunctionException.details] carries the same
  /// `{code, message, ...}` envelope the 2xx path returns. Without this
  /// translator the exception bypasses the rest of the translation pipeline
  /// and bubbles up as an unhandled error, which is how a patient paying for
  /// an already-paid appointment used to see the generic "payment
  /// temporarily unavailable" message instead of the real reason.
  static ApiException _fromFunction(FunctionException e) {
    final status = e.status;
    final details = e.details;

    String? code;
    String? message;
    if (details is Map) {
      code = details['code']?.toString();
      message = details['message']?.toString();
      // Edge Functions are allowed to put the message under `error` (the SDK's
      // own helper convention) as well as under `message`.
      message ??= details['error']?.toString();
    }
    final safeMessage = (message == null || message.trim().isEmpty)
        ? 'The payment service did not respond correctly. Please try again.'
        : message.trim();

    return ApiException(
      message: safeMessage,
      statusCode: status,
      code: code,
    );
  }

  static ApiException _fromStorage(StorageException e) {
    final code = int.tryParse(e.statusCode ?? '');
    final raw = e.message.trim();
    final lower = raw.toLowerCase();

    if (code == 404 || lower.contains('not found')) {
      return ApiException(message: 'That file no longer exists.', statusCode: 404);
    }
    if (code == 403 || lower.contains('unauthorized') || lower.contains('violates')) {
      // Nearly always the path convention: storage_setup.sql requires the first
      // segment to be the owner's id, so an upload to the wrong folder is
      // refused by policy rather than by a missing grant.
      return ApiException(
        message: 'You do not have permission to upload that file.',
        statusCode: 403,
      );
    }
    if (code == 413 || lower.contains('too large') || lower.contains('exceeded')) {
      return ApiException(
        message: 'That file is too large.',
        statusCode: 413,
      );
    }
    if (lower.contains('mime') || lower.contains('content type')) {
      return ApiException(
        message: 'That file type is not allowed.',
        statusCode: 415,
      );
    }
    return ApiException(
      message: raw.isEmpty ? 'The upload failed.' : raw,
      statusCode: code ?? 400,
    );
  }

  /// Turns a unique-violation into the sentence the old backend used.
  ///
  /// Matched on the index names created in `schema.sql`; an unrecognised one
  /// falls back to generic wording rather than leaking the constraint name.
  static String _uniqueMessage(PostgrestException e) {
    final d = '${e.message} ${e.details ?? ''}'.toLowerCase();
    if (d.contains('users_email')) return 'That email address is already registered.';
    if (d.contains('appointments_no_double_booking') ||
        d.contains('uniq_doctor_slot')) {
      return 'That time slot has just been taken. Please pick another.';
    }
    if (d.contains('confirmation_code')) {
      return 'Could not allocate a confirmation code. Please try again.';
    }
    if (d.contains('reviews_one_per_user')) {
      return 'You have already reviewed this.';
    }
    if (d.contains('cart')) return 'That item is already in your cart.';
    if (d.contains('order_number')) {
      return 'Could not allocate an order number. Please try again.';
    }
    // The idempotency backstops behind place_order() and the payment
    // settlement path. Reaching them means two copies of the same request
    // raced past the advisory lock, so the honest answer is "the first one
    // won", not "that already exists".
    if (d.contains('uq_orders_idempotency')) {
      return 'Your previous order is already being processed.';
    }
    if (d.contains('uq_payments_verified_appointment') ||
        d.contains('uq_payments_stripe_session') ||
        d.contains('uq_payments_stripe_pi')) {
      return 'You have already paid for this appointment.';
    }
    if (d.contains('blood_donors_user')) {
      return 'You are already registered as a donor.';
    }
    return 'That already exists.';
  }

  static Map<String, String> _uniqueField(PostgrestException e) {
    final d = '${e.message} ${e.details ?? ''}'.toLowerCase();
    if (d.contains('users_email')) {
      return const {'email': 'That email address is already registered.'};
    }
    return const {};
  }
}

// ===========================================================================
// Pagination
// ===========================================================================

/// One page of rows plus the total, mirroring the old `meta` block.
///
/// The PHP endpoints ran a second `SELECT COUNT(*)` over the same WHERE clause.
/// Postgrest does it in one round trip: `count: CountOption.exact` asks for the
/// total in the `Content-Range` header alongside the rows, so this is strictly
/// fewer queries than before, not more.
class PageResult<T> {
  const PageResult({required this.rows, required this.total});

  final List<T> rows;
  final int total;
}

/// `page` is 1-based, matching every existing call site and the old `?page=`.
class PageRange {
  const PageRange(this.page, this.limit);

  final int page;
  final int limit;

  int get from => (page - 1) * limit;
  int get to => from + limit - 1;
}

// ===========================================================================
// Storage
// ===========================================================================

/// Bucket-aware path <-> URL helpers.
///
/// The widget layer receives finished URLs only (see AppConfig.resolveAsset), so
/// every repository runs its storage columns through [publicUrl] before building
/// a model. Columns store the object PATH, never a URL — that is what lets the
/// project ref change without a data migration.
class SupabaseStorage {
  SupabaseStorage(this._storage);

  final SupabaseStorageClient _storage;

  /// Path -> absolute CDN URL for the three public buckets.
  ///
  /// Returns '' for null/empty so callers can pass the column straight through.
  /// A value that is already absolute is returned untouched: rows written by the
  /// old PHP site may hold a full URL, and rewriting those is not this layer's
  /// job.
  String publicUrl(String bucket, String? path) {
    if (path == null) return '';
    final p = path.trim();
    if (p.isEmpty) return '';
    if (p.startsWith('http://') || p.startsWith('https://')) return p;

    // PHP-era relative paths ('uploads/avatars/12.jpg') name no object in any
    // bucket. Handing one to getPublicUrl would produce a URL that 404s on
    // every build of every list; '' makes the widget draw its placeholder
    // instead, which is what it already did when the PHP host 404'd.
    if (p.startsWith('uploads/')) return '';

    return _storage.from(bucket).getPublicUrl(p);
  }

  /// Time-limited URL for the PRIVATE provider-documents bucket.
  ///
  /// getPublicUrl on a non-public bucket returns a URL that 400s, so licence and
  /// certificate views must sign. Not cached: the result expires.
  Future<String> signedUrl(
    String bucket,
    String path, {
    int expiresInSeconds = 60,
  }) async {
    final p = path.trim();
    if (p.isEmpty) return '';
    return SupabaseService.guard(
      () => _storage.from(bucket).createSignedUrl(p, expiresInSeconds),
    );
  }

  /// Uploads bytes and returns the stored PATH — never a URL, because the path
  /// is what goes in the column.
  ///
  /// [ownerId] becomes the first path segment, which is what the storage
  /// policies check (`(storage.foldername(name))[1]`). Passing the wrong owner
  /// is refused by policy, not silently accepted.
  ///
  /// `upsert: true` matters: without it a second upload of the same filename
  /// fails with 409 instead of replacing the first, so changing an avatar twice
  /// would break.
  Future<String> uploadBytes({
    required String bucket,
    required String ownerId,
    required String filename,
    required Uint8List bytes,
    String? contentType,
  }) async {
    final safe = _sanitize(filename);
    final path = '$ownerId/$safe';
    await SupabaseService.guard(
      () => _storage.from(bucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
              upsert: true,
              contentType: contentType,
            ),
          ),
    );
    return path;
  }

  Future<void> remove(String bucket, String path) async {
    final p = path.trim();
    if (p.isEmpty) return;
    await SupabaseService.guard(() => _storage.from(bucket).remove([p]));
  }

  /// Strips anything that would change the path's shape.
  ///
  /// A '/' in a filename would add a path segment, which moves the object out of
  /// the owner's folder and past the policy check; '..' likewise. Both are
  /// rejected here rather than relying on the server to notice.
  static String _sanitize(String filename) {
    final base = filename.split(RegExp(r'[/\\]')).last.replaceAll('..', '');
    final cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (cleaned.isEmpty || cleaned == '.' ) {
      return 'file_${DateTime.now().millisecondsSinceEpoch}';
    }
    return cleaned;
  }

  // Convenience wrappers for the four buckets, so no repository repeats a
  // bucket-name string literal.
  String avatar(String? path) => publicUrl(AppConfig.bucketAvatars, path);
  String productImage(String? path) => publicUrl(AppConfig.bucketProductImages, path);
  String blogCover(String? path) => publicUrl(AppConfig.bucketBlogCovers, path);
  Future<String> providerDocument(String path) =>
      signedUrl(AppConfig.bucketProviderDocuments, path);
}
