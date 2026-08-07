/// §13 — about, terms, privacy and contact.
///
/// These four are client-side content. There is no `GET /pages/{slug}` in the
/// route table, so fetching them would mean inventing an endpoint; a const list
/// of sections renders instantly, works offline, and cannot 500.
///
/// They are also public routes. The person most likely to read the terms is the
/// one deciding whether to create an account, and gating them behind a login
/// would put the answer behind the question.
///
/// The copy below describes what this build *actually* does — including the parts
/// that do not work, like the SMS gateway and the payment flow. A privacy notice
/// that overstates the system is worse than none.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_config.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/widgets/state_views.dart';

/// One section of body copy. Kept as data rather than widgets so the four screens
/// share a single renderer.
class StaticSection {
  const StaticSection(this.heading, this.body, {this.bullets = const []});

  final String heading;
  final String body;
  final List<String> bullets;
}

/// Shared chrome: title, last-reviewed line, sections, and a footer that links
/// to the other three pages so a reader is never one dead end from the rest.
class StaticPageView extends StatelessWidget {
  const StaticPageView({
    super.key,
    required this.title,
    required this.intro,
    required this.sections,
    this.updated,
    this.footer,
  });

  final String title;
  final String intro;
  final List<StaticSection> sections;
  final String? updated;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(intro, style: theme.textTheme.bodyLarge),
                if (updated != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Last reviewed $updated',
                    style: theme.textTheme.labelMedium?.copyWith(color: muted),
                  ),
                ],
                const SizedBox(height: 8),
                for (final s in sections) _Section(section: s),
                if (footer != null) ...[
                  const SizedBox(height: 8),
                  footer!,
                ],
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                _PageLinks(current: title),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    '${AppConfig.appName} · v1.0.0',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
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

class _Section extends StatelessWidget {
  const _Section({required this.section});

  final StaticSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.heading,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            section.body,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          for (final b in section.bullets)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7, right: 10),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      b,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Cross-links between the four pages, minus the one being read.
class _PageLinks extends StatelessWidget {
  const _PageLinks({required this.current});

  final String current;

  static const _all = <(String, String)>[
    ('About', Routes.about),
    ('Terms of use', Routes.terms),
    ('Privacy', Routes.privacy),
    ('Contact', Routes.contact),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        for (final (label, route) in _all)
          if (label != current)
            TextButton(
              onPressed: () => context.push(route),
              child: Text(label),
            ),
      ],
    );
  }
}

/// A tappable contact row. Falls back to a toast rather than failing silently
/// when no handler app is installed — common on emulators with no dialer.
class ContactTile extends StatelessWidget {
  const ContactTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.uri,
  });

  final IconData icon;
  final String label;
  final String value;
  final Uri? uri;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(label),
        subtitle: Text(value),
        trailing: uri == null ? null : const Icon(Icons.open_in_new, size: 18),
        onTap: uri == null ? null : () => _open(context, uri!),
      ),
    );
  }

  static Future<void> _open(BuildContext context, Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      showToast(context, 'No app on this device can open ${uri.scheme}:', error: true);
    }
  }
}

/// Small helper so the pages can offer a route without importing go_router.
class StaticPageButton extends StatelessWidget {
  const StaticPageButton({super.key, required this.label, required this.route});

  final String label;
  final String route;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.gap),
      child: FilledButton.tonalIcon(
        onPressed: () => context.push(route),
        icon: const Icon(Icons.arrow_forward, size: 18),
        label: Text(label),
      ),
    );
  }
}
