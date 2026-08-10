/// One error type for the whole app, built from the §6 error envelope:
///   {"success": false, "message": "...", "errors": {"field": "..."}}
///
/// Screens show [message] and, on a form, feed [errors] back into the fields.
/// Nothing above this layer should ever need to touch DioException.
library;

class ApiException implements Exception {
  ApiException({
    required this.message,
    this.statusCode,
    this.errors = const {},
    this.kind = ApiErrorKind.server,
    this.code,
  });

  final String message;
  final int? statusCode;

  /// A stable machine code for the refusal, when the server sent one.
  ///
  /// The database raises its business rules with the user-facing sentence as
  /// the message and a code such as `ALREADY_PAID`, `OUT_OF_STOCK` or
  /// `DUPLICATE_ORDER` in the error's DETAIL field; Edge Functions send the
  /// same idea as `code` in their JSON envelope. Both land here.
  ///
  /// Screens should branch on this rather than on [message]: the wording is
  /// written for people and is expected to change, while the code is a
  /// contract. A payment already recorded, for instance, should quietly
  /// refresh the row rather than show an error, and that decision needs to
  /// survive an edit to the sentence.
  final String? code;

  /// Field name -> first message, flattened from the §6 `errors` object.
  final Map<String, String> errors;

  final ApiErrorKind kind;

  /// §10: a 401 is a normal logout, not a crash. The interceptor clears storage
  /// and the router bounces to /login; screens should not show a red dialog.
  bool get isUnauthorized => statusCode == 401;

  /// 403 role mismatch, 404 missing, 409 slot/stock conflict, 422 business rule.
  bool get isConflict => statusCode == 409;
  bool get isValidation => statusCode == 400 || statusCode == 422;
  bool get isNetwork => kind == ApiErrorKind.network;

  /// Message for a specific form field, if the server flagged it.
  String? fieldError(String field) => errors[field];

  /// True when the server refused with [wanted].
  bool hasCode(String wanted) => code == wanted;

  @override
  String toString() =>
      'ApiException($statusCode${code == null ? '' : ', $code'}): $message';
}

enum ApiErrorKind {
  /// No route to the server, DNS failure, timeout, connection refused.
  network,

  /// Server answered, but with a non-2xx status.
  server,

  /// Server answered 2xx with a body we could not parse as the §6 envelope.
  malformed,

  /// Request cancelled (screen disposed mid-flight).
  cancelled,
}
