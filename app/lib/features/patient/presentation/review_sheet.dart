/// §5.6 — writing a review, for any of the four entity types plus products.
///
/// One sheet rather than four screens: the only thing that varies by target is
/// the title, and `POST /reviews` takes `target_type` + `target_id` for all of
/// them. Callers get [showReviewSheet] and never construct the widget directly.
///
/// A 409 means this user already reviewed this target (`uq_review_once`). That is
/// worth its own wording — "you have already reviewed this" is actionable, while
/// the generic failure toast would just look like a bug.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/content_models.dart';
import '../../content/data/content_repository.dart';

/// Opens the sheet and returns true when a review was actually submitted, so the
/// caller can refresh its list. Null or false means the user backed out.
///
/// [appointmentId] is the appointment a doctor review is being left against
/// (the server requires it); pass null for hospital/clinic/pharmacy reviews,
/// which have no appointments.
Future<bool?> showReviewSheet(
  BuildContext context, {
  required ReviewTarget target,
  required int targetId,
  String? targetName,
  int? appointmentId,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ReviewSheet(
      target: target,
      targetId: targetId,
      targetName: targetName,
      appointmentId: appointmentId,
    ),
  );
}

class ReviewSheet extends ConsumerStatefulWidget {
  const ReviewSheet({
    super.key,
    required this.target,
    required this.targetId,
    this.targetName,
    this.appointmentId,
  });

  final ReviewTarget target;
  final int targetId;
  final String? targetName;

  /// The appointment a doctor review is anchored to; null for non-doctor
  /// targets, where the server does not want one.
  final int? appointmentId;

  @override
  ConsumerState<ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends ConsumerState<ReviewSheet> {
  final _comment = TextEditingController();

  /// Starts at 0 so the user has to make a choice — a pre-filled 5 stars would
  /// let an accidental submit publish praise nobody meant to give.
  int _rating = 0;
  bool _busy = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating < 1) {
      showToast(context, 'Tap a star to rate first.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(contentRepositoryProvider).submitReview(
            target: widget.target,
            targetId: widget.targetId,
            rating: _rating,
            comment: _comment.text,
            appointmentId: widget.appointmentId,
          );
      if (!mounted) return;
      Navigator.pop(context, true);
      showToast(
        context,
        'Thanks. Your review goes live once an admin approves it.',
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      // 409 is the one-review-per-target constraint, not a failure to explain.
      final message = e.statusCode == 409
          ? 'You have already reviewed this.'
          : e.message;
      if (!e.isUnauthorized) showToast(context, message, error: true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, 'Something went wrong.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppTheme.gap,
        AppTheme.gap,
        AppTheme.gap,
        AppTheme.gap + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Write a review', style: theme.textTheme.titleMedium),
            if (widget.targetName != null) ...[
              const SizedBox(height: 2),
              Text(
                widget.targetName!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            _StarPicker(
              rating: _rating,
              onChanged: (v) => setState(() => _rating = v),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _comment,
              maxLines: 4,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Comment (optional)',
                hintText: 'What was your experience like?',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Reviews are checked by an admin before they appear publicly.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Submit review'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Five tappable stars with a word for the current value, so the rating is not
/// left to be inferred from the count alone.
class _StarPicker extends StatelessWidget {
  const _StarPicker({required this.rating, required this.onChanged});

  final int rating;
  final ValueChanged<int> onChanged;

  static const _words = [
    'Tap to rate',
    'Poor',
    'Fair',
    'Good',
    'Very good',
    'Excellent',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                onPressed: () => onChanged(i),
                tooltip: '$i star${i == 1 ? '' : 's'}',
                icon: Icon(
                  i <= rating ? Icons.star_rounded : Icons.star_border_rounded,
                  size: 36,
                  color: AppSemantic.of(context).warning,
                ),
              ),
          ],
        ),
        Text(
          _words[rating.clamp(0, 5)],
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: rating == 0 ? theme.colorScheme.onSurfaceVariant : null,
          ),
        ),
      ],
    );
  }
}
