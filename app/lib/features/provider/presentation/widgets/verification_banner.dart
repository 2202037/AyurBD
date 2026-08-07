/// The verification notice every provider workspace leads with (§6.1, §7–9).
///
/// Three states, never two. A provider whose documents were *rejected* must not
/// be shown the same "we're reviewing it" message as one who is still in the
/// queue — that is how someone waits a fortnight for a decision that already
/// came back negative.
library;

import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_theme.dart';
import '../../../../models/provider_models.dart';

class VerificationBanner extends StatelessWidget {
  const VerificationBanner({
    super.key,
    required this.status,
    this.accountStatus,
    this.onEditProfile,
  });

  final VerificationStatus status;

  /// `status` from the provider row: active | inactive | pending. Distinct from
  /// [status] — an admin can deactivate an already-verified provider, and that
  /// also hides them from the directory.
  final String? accountStatus;

  final VoidCallback? onEditProfile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deactivated = accountStatus == 'inactive';

    // A verified but deactivated account still needs a banner: the provider is
    // invisible to patients and nothing on the dashboard would otherwise say so.
    if (status.isVerified && !deactivated) return const SizedBox.shrink();

    // `_content` is a pure mapping from status to presentation and has no
    // BuildContext, so it returns the light-mode constant and the resolve()
    // happens here where the brightness is known. Passing an already-resolved
    // colour through resolve() is a no-op, so this stays safe either way.
    final (rawColor, icon, title, body) = _content(deactivated);
    final color = AppSemantic.of(context).resolve(rawColor);

    return Card(
      color: color.withValues(alpha: AppSemantic.of(context).tintAlpha),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(color: color.withValues(alpha: AppSemantic.of(context).tintBorderAlpha)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: theme.textTheme.bodySmall),
            // Only offered where it helps. A pending provider re-editing their
            // profile does not speed anything up; a rejected one has to.
            if (onEditProfile != null && status == VerificationStatus.rejected) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onEditProfile,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Update my details'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  (Color, IconData, String, String) _content(bool deactivated) {
    if (deactivated && status.isVerified) {
      return (
        AppColors.danger,
        Icons.visibility_off_outlined,
        'Account deactivated',
        'Your account is verified but has been deactivated by an administrator, '
            'so patients cannot find or book you. Contact support to restore it.',
      );
    }

    return switch (status) {
      VerificationStatus.pending => (
          AppColors.warning,
          Icons.hourglass_top_outlined,
          status.label,
          status.note!,
        ),
      VerificationStatus.rejected => (
          AppColors.danger,
          Icons.report_gmailerrorred_outlined,
          status.label,
          status.note!,
        ),
      // Reached only when deactivated is false, which returned above.
      VerificationStatus.verified => (
          AppColors.success,
          Icons.verified_outlined,
          status.label,
          'Your profile is live in the directory.',
        ),
    };
  }
}
