/// §13 — Contact.
///
/// The tappable rows come before the wording, since someone on this screen wants
/// to reach somebody rather than read. The feedback form is offered as the route
/// that actually reaches an administrator: `POST /feedback` writes a row an admin
/// reads in their console, whereas the email address below is a placeholder for
/// whoever deploys this.
///
/// The emergency line is called out separately. Support email is the wrong
/// channel for an ambulance, and this screen is a plausible place to end up
/// looking for one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import 'static_page_screen.dart';

class ContactScreen extends ConsumerWidget {
  const ContactScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const StaticPageView(
      title: 'Contact',
      intro:
          'Questions about an appointment, an order, or your account. For anything '
          'that needs a reply from an administrator, the feedback form is the '
          'fastest route — it lands directly in the admin console.',
      sections: [
        StaticSection(
          'Response times',
          'Feedback is reviewed on working days. An account or payment question '
          'usually gets a reply within two working days; a provider verification '
          'request can take longer, since it involves checking your licence '
          'numbers against the issuing body.',
        ),
        StaticSection(
          'Before you write',
          'Including these saves a round trip:',
          bullets: [
            'For an appointment: the doctor’s name and the date you booked.',
            'For an order: the order number from the orders screen.',
            'For a provider account still pending: the licence or BMDC number '
                'you registered with.',
          ],
        ),
        StaticSection(
          'Reporting a review or a listing',
          'If a review about you is abusive or a directory listing is wrong, send '
          'it through the feedback form and pick the matching category. '
          'Administrators can hide a review or correct a listing; they cannot edit '
          'a review’s wording.',
        ),
      ],
      footer: _ContactBody(),
    );
  }
}

class _ContactBody extends StatelessWidget {
  const _ContactBody();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Text(
          'Reach us',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        ContactTile(
          icon: Icons.mail_outline,
          label: 'Email',
          value: 'support@ayur.example',
          uri: Uri(scheme: 'mailto', path: 'support@ayur.example'),
        ),
        ContactTile(
          icon: Icons.call_outlined,
          label: 'Phone',
          value: '+880 1700 000000',
          uri: Uri(scheme: 'tel', path: '+8801700000000'),
        ),
        const ContactTile(
          icon: Icons.place_outlined,
          label: 'Office',
          value: 'Dhanmondi, Dhaka 1205, Bangladesh',
        ),
        const ContactTile(
          icon: Icons.schedule_outlined,
          label: 'Hours',
          value: 'Sunday to Thursday, 10:00 – 18:00 (Dhaka time)',
        ),
        const SizedBox(height: AppTheme.gap),
        FilledButton.icon(
          onPressed: () => context.push(Routes.feedback),
          icon: const Icon(Icons.forum_outlined, size: 18),
          label: const Text('Send feedback'),
        ),
        const SizedBox(height: AppTheme.gap),
        // Support email is the wrong channel for an emergency, and this screen is
        // a plausible place to look for one.
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          color: AppSemantic.of(context).danger.withValues(alpha: AppSemantic.of(context).tintAlpha),
          child: InkWell(
            onTap: () => context.push(Routes.emergency),
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.gap),
              child: Row(
                children: [
                  Icon(Icons.emergency_outlined, color: AppSemantic.of(context).danger),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Medical emergency?',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppSemantic.of(context).danger,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Do not use this form. Open the hotline list and dial.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: AppSemantic.of(context).danger),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
