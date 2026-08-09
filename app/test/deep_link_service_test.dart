// Proves the deep-link → go_router translation stays correct across the URL
// shapes the Stripe redirect can produce. Pure static logic, so no platform
// channels or Supabase are involved.

import 'package:flutter_test/flutter_test.dart';

import 'package:ayur/core/deep_links/deep_link_service.dart';

void main() {
  group('DeepLinkService.toRouterLocation', () {
    test('Android/iOS deep link with query', () {
      expect(
        DeepLinkService.toRouterLocation(
          'ayurd://payment-success?appointment_id=42&session_id=cs_test_123',
        ),
        '/payment-success?appointment_id=42&session_id=cs_test_123',
      );
    });

    test('deep link without query (cancel)', () {
      expect(
        DeepLinkService.toRouterLocation('ayurd://payment-cancelled'),
        '/payment-cancelled',
      );
    });

    test('scheme secret stored with trailing slashes', () {
      expect(
        DeepLinkService.toRouterLocation(
          'ayurd:///payment-success?appointment_id=7',
        ),
        '/payment-success?appointment_id=7',
      );
    });

    test('web hash-route URL is tolerated as a safety net', () {
      expect(
        DeepLinkService.toRouterLocation(
          'http://localhost:62095/#/payment-success?appointment_id=3',
        ),
        '/payment-success?appointment_id=3',
      );
    });
  });
}