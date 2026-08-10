/// Post-Stripe cancellation screen.
///
/// Stripe Checkout sends the user here when they hit "back" / close the
/// checkout page, via either a web URL (`APP_URL/#/payment-cancelled`) or a
/// deep link (`ayurbd://payment-cancelled`). No appointment work happens here —
/// Stripe did not charge anything, so there is nothing to refresh — it just
/// explains that the booking is still unpaid and points back at the list.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';

class PaymentCancelledScreen extends StatelessWidget {
  const PaymentCancelledScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Payment'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.gap),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.cancel_outlined,
                    size: 72, color: theme.colorScheme.error),
                const SizedBox(height: 16),
                Text('Payment Cancelled', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'No money has been taken. Your appointment is still saved as '
                  'unpaid — you can pay it again whenever you are ready.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => context.go(Routes.appointments),
                    child: const Text('My appointments'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
