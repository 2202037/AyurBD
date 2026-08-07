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
  });

  final String message;
  final int? statusCode;

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

  @override
  String toString() => 'ApiException($statusCode): $message';
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
