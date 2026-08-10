/// Post-Stripe cancellation screen.
///
/// Stripe Checkout sends the user here when they hit "back" / close the
/// checkout page, via either a web URL (`APP_URL/#/payment-cancelled`) or a
/// deep link (`ayurbd://payment-cancelled`). No appointment work happens here —
/// Stripe did not charge anything, so there is nothing to refresh — it just
/// explains that the booking is still unpaid and sends the patient back to the
/// appointments list they started from.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';

class PaymentCancelledScreen extends StatefulWidget {
  const PaymentCancelledScreen({super.key, this.returnTo});

  /// The internal route to hand the patient back to. Comes from the
  /// `return_to` query value and is validated against the route allowlist —
  /// a forged value is replaced by the appointments list.
  final String? returnTo;

  @override
  State<PaymentCancelledScreen> createState() => _PaymentCancelledScreenState();
}

class _PaymentCancelledScreenState extends State<PaymentCancelledScreen> {
  /// How long the cancellation message stays on screen before returning the
  /// patient to the appointments list.
  static const _dismissDelay = Duration(seconds: 2);

  Timer? _returnTimer;

  @override
  void initState() {
    super.initState();
    _returnTimer = Timer(_dismissDelay, () {
      if (mounted) {
        context.go(resolvePaymentReturn(widget.returnTo));
      }
    });
  }

  @override
  void dispose() {
    _returnTimer?.cancel();
    super.dispose();
  }

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
                    onPressed: () =>
                        context.go(resolvePaymentReturn(widget.returnTo)),
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