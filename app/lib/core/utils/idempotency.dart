/// A stable key for one user-visible attempt at a write that must not happen
/// twice.
///
/// ## Why this exists
///
/// Before this, the only thing standing between a customer and two identical
/// orders was a `bool _busy` in a screen's state. That guard disappears the
/// moment the process does: a dropped Wi-Fi connection mid-request, an app
/// resumed from the background, a tap on "retry" — each starts a brand new
/// request that the server has no way of recognising as the same attempt.
///
/// The fix is an idempotency key, generated on the client and sent with the
/// write. The server stores it (`orders.idempotency_key`, unique per user) and
/// answers a repeat with the row it already created. The distinction that makes
/// this work is between an *attempt* and a *request*:
///
///   * One attempt = one thing the user meant to do. It keeps one key.
///   * One request = one network round trip. An attempt may need several.
///
/// So a retry after a timeout deliberately reuses the key — that is precisely
/// the case we are protecting against. The key is only [renew]ed once the
/// attempt has genuinely finished, successfully or terminally, and the next tap
/// means something new.
///
/// ## Usage
///
/// ```dart
/// final _attempt = IdempotencyToken();          // in initState
/// ...
/// await repo.checkout(idempotencyKey: _attempt.value);
/// _attempt.renew();                              // only after it settled
/// ```
///
/// The value is short enough for the `varchar(64)` column and carries a
/// millisecond timestamp first so keys sort chronologically when read in the
/// database during support work.
library;

import 'dart:math';

class IdempotencyToken {
  IdempotencyToken([this.scope = 'op']) : _value = _mint(scope);

  /// A short label that shows up in the key, so a row in the database says
  /// what it belonged to. Not used for uniqueness.
  final String scope;

  String _value;

  /// The key to send with the current attempt. Stable across retries.
  String get value => _value;

  /// Starts a new attempt. Call this only when the previous one has settled —
  /// after a success, or after a failure the user cannot simply retry into
  /// (a validation error, an empty cart, a rule refusal). Calling it after a
  /// network timeout would defeat the entire mechanism.
  void renew() => _value = _mint(scope);

  static final Random _rng = Random.secure();

  static String _mint(String scope) {
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch
        .toRadixString(36);
    // 80 bits of randomness: far more than enough to make a collision between
    // two of one person's own attempts impossible in practice, and the column
    // is unique per user rather than globally.
    final noise = List<String>.generate(
      5,
      (_) => _rng.nextInt(1 << 16).toRadixString(36).padLeft(4, '0'),
    ).join();

    final safeScope = scope.replaceAll(RegExp(r'[^a-z0-9_]'), '');
    final key = '$safeScope-$stamp-$noise';
    return key.length <= 64 ? key : key.substring(0, 64);
  }
}
