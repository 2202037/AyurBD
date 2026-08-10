/// The three states every data screen needs (§8), plus a couple of small things
/// used often enough that copy-pasting them would drift.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../constants/app_config.dart';
import '../constants/app_theme.dart';
import '../network/api_exception.dart';

/// Centred spinner. Used while a first page loads.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: AppTheme.gap),
            Text(message!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// "Nothing here yet" — not an error, so it stays calm and offers a way forward.
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.title,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final String? title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppTheme.gap),
            if (title != null)
              Text(
                title!,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
            if (title != null) const SizedBox(height: 6),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              SizedBox(
                width: 200,
                child: OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Failure state with Retry. Distinguishes "can't reach the server" from "the
/// server said no", because the fix is completely different — the first is
/// almost always the base URL or XAMPP being down.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final api = error is ApiException ? error as ApiException : null;
    final isNetwork = api?.isNetwork ?? false;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isNetwork ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
              size: 56,
              color: AppSemantic.of(context).danger,
            ),
            const SizedBox(height: AppTheme.gap),
            Text(
              isNetwork ? 'Cannot reach the server' : 'Something went wrong',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              api?.message ?? error.toString(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              SizedBox(
                width: 200,
                child: FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 20),
                  label: const Text('Try again'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Coloured status/urgency chip. The colour comes from [AppSemantic.forStatus]
/// so the same word is the same colour app-wide, resolved against the active
/// theme — the light-mode greens and reds are far too dark to read on the dark
/// surface, and vice versa.
///
/// The pill carries a **shape** as well as a colour. In light mode `success` and
/// `danger` are necessarily almost identical in lightness (both have to clear
/// 4.5:1 on a pale surface, which pins them into a narrow luminance band), so to
/// a red/green colour-blind reader they differ by hue alone — and hue is exactly
/// the channel they cannot use. The icon plus the label means the status is
/// always legible without perceiving colour at all.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.status,
    this.label,
    this.dense = false,
    this.showIcon = true,
  });

  final String status;
  final String? label;
  final bool dense;

  /// Only turn this off where the same information is already unmistakable from
  /// context, never just to save space.
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final sem = AppSemantic.of(context);
    final color = sem.forStatus(status);
    final fontSize = dense ? 11.0 : 12.0;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: sem.tintAlpha),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: sem.tintBorderAlpha)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(AppColors.statusIcon(status), size: fontSize + 2, color: color),
            SizedBox(width: dense ? 3 : 4),
          ],
          Text(
            label ?? _pretty(status),
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  String _pretty(String s) {
    if (s.isEmpty) return '—';
    final words = s.replaceAll(RegExp(r'[_\-]+'), ' ').split(' ');
    return words
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }
}

/// Network image with a placeholder and a graceful fallback.
///
/// Paths arrive here already absolute: each repository maps its storage columns
/// through [SupabaseStorage] before building a model, so this widget never
/// resolves a base URL itself. A non-absolute value is a leftover PHP-era path
/// and draws the placeholder — see [AppConfig.resolveAsset].
class RemoteImage extends StatelessWidget {
  const RemoteImage({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.radius = 8,
    this.fallbackIcon = Icons.image_outlined,
    this.fit = BoxFit.cover,
  });

  final String? path;
  final double? width;
  final double? height;
  final double radius;
  final IconData fallbackIcon;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final url = AppConfig.resolveAsset(path);
    final muted = Theme.of(context).colorScheme.surfaceContainerHighest;

    Widget fallback() => Container(
          width: width,
          height: height,
          color: muted,
          alignment: Alignment.center,
          child: Icon(
            fallbackIcon,
            size: ((width ?? height ?? 48) * 0.4).clamp(16, 40),
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url.isEmpty
          ? fallback()
          : CachedNetworkImage(
              imageUrl: url,
              width: width,
              height: height,
              fit: fit,
              placeholder: (_, __) => Container(width: width, height: height, color: muted),
              errorWidget: (_, __, ___) => fallback(),
            ),
    );
  }
}

/// Circular avatar that falls back to initials — most seeded users have no photo.
class AvatarCircle extends StatelessWidget {
  const AvatarCircle({super.key, this.imagePath, this.name, this.size = 48});

  final String? imagePath;
  final String? name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = AppConfig.resolveAsset(imagePath);
    if (url.isEmpty) {
      final letters = (name ?? '').trim().isEmpty
          ? '?'
          : (name!.trim().split(RegExp(r'\s+')).length == 1
              ? name!.trim()[0].toUpperCase()
              : (name!.trim().split(RegExp(r'\s+')).first[0] +
                      name!.trim().split(RegExp(r'\s+')).last[0])
                  .toUpperCase());
      final sem = AppSemantic.of(context);
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: sem.primary.withValues(alpha: sem.tintAlpha),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          letters,
          style: TextStyle(
            color: sem.primary,
            fontWeight: FontWeight.w700,
            fontSize: size * 0.36,
          ),
        ),
      );
    }
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          width: size,
          height: size,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        errorWidget: (_, __, ___) => AvatarCircle(name: name, size: size),
      ),
    );
  }
}

/// Section heading with an optional trailing action, used on the home screen.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// Full-screen translucent blocker shown while a booking or checkout is in
/// flight, so the user can't submit twice.
class BlockingOverlay extends StatelessWidget {
  const BlockingOverlay({super.key, required this.busy, required this.child, this.message});

  final bool busy;
  final Widget child;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (busy)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.35),
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                        const SizedBox(width: 14),
                        Text(message ?? 'Please wait…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// SnackBars, so success and failure look consistent everywhere.
///
/// The text colour is set explicitly rather than left to the SnackBar theme:
/// the fill is a semantic colour, so in light mode it is deep and wants white
/// on it, while in dark mode it is luminous and wants near-black. Both pairings
/// measure ≥4.5:1; the theme's default light-on-dark styling fails against the
/// dark theme's brighter fills.
void showToast(BuildContext context, String message, {bool error = false}) {
  final sem = AppSemantic.of(context);
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(color: sem.onFilled)),
        backgroundColor: error ? sem.danger : sem.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
}
