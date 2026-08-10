/// OS deep-link → go_router bridge.
///
/// Stripe Checkout redirects mobile users back to the app with a custom-scheme
/// URL: `ayurbd://payment-success?appointment_id=123&session_id=cs_...`. The OS
/// delivers that as an intent (Android `/VERView` i or iOS URL) rather than a
/// navigation, so Flutter has to read it and translate it into a go_router
/// location (`/payment-success?appointment_id=...`), which is what this service
/// does.
///
/// Web needs none of this. The Edge Function builds web redirects as real
/// hash-route URLs (`APP_URL/#/payment-success...`), the browser does a full
/// load, and GoRouter picks the hash up as its initial location — no plugin, no
/// listener. [start] returns early on [kIsWeb] for exactly that reason.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

class DeepLinkService {
  DeepLinkService._();

  static final DeepLinkService instance = DeepLinkService._();

  final AppLinks _links = AppLinks();
  StreamSubscription<Uri>? _sub;

  /// Reads the link that cold-started the app (if any) and subscribes to
  /// everything after it. [onLink] receives each incoming URI as a string; the
  /// caller is responsible for routing it.
  void start(void Function(String uri) onLink) {
    if (kIsWeb) return;

    unawaited(_initial(onLink));
    _sub = _links.uriLinkStream.listen(
      (uri) => onLink(uri.toString()),
      onError: (_) {},
    );
  }

  Future<void> _initial(void Function(String uri) onLink) async {
    try {
      final initial = await _links.getInitialLink();
      if (initial != null) onLink(initial.toString());
    } catch (_) {
      // No link on cold start (the normal launch path).
    }
  }

  /// Converts a raw deep-link URI string into the equivalent go_router
  /// location, e.g. `aayurbd://payment-success?appointment_id=5&...` →
  /// `/payment-success?appointment_id=5&...`.
  ///
  /// The scheme prefix is peeled off and a leading slash enforced so the rest
  /// is a clean relative path. Hash-route web URLs are also tolerated
  /// (`http://x/#/payment-success?...` → `/payment-success?...`) as a safety
  /// net, though web never hands those to this service.
  static String toRouterLocation(String raw) {
    var location = raw.trim();

    final hash = location.indexOf('#');
    if (hash >= 0) {
      location = location.substring(hash + 1);
    }

    // `ayurd://payment-success` parses as scheme=ayurd, path=/payment-success,
    // and `ayurd://payment-success` parses payment-success into the authority,
    // so the only safe way to strip the scheme is textually.
    location = location.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');

    if (!location.startsWith('/')) location = '/$location';
    return location;
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}

final deepLinkService = DeepLinkService.instance;
