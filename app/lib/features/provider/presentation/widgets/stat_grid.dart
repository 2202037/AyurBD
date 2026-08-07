/// The stat tiles shared by the doctor, place and admin dashboards.
///
/// A tile is deliberately dumb — a label, a value and an optional tap. Every
/// dashboard in the app then reads the same, and a new stat is one list entry
/// rather than a fresh layout.
library;

import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_theme.dart';

/// One tile's worth of data. A record rather than positional args so adding a
/// field cannot silently reorder existing call sites.
typedef StatTile = ({
  String label,
  String value,
  IconData icon,
  Color? color,
  VoidCallback? onTap,
});

StatTile stat(
  String label,
  Object value, {
  IconData icon = Icons.insights_outlined,
  Color? color,
  VoidCallback? onTap,
}) =>
    (
      label: label,
      value: value.toString(),
      icon: icon,
      color: color,
      onTap: onTap
    );

class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.tiles, this.columns});

  final List<StatTile> tiles;

  /// Defaults to two on a phone and three once there is room. Fixed columns
  /// with long labels is what causes the overflow stripes on small screens.
  final int? columns;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = columns ?? (constraints.maxWidth >= 520 ? 3 : 2);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: tiles.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            // Wide and short: these hold a number and one line of label. A
            // squarer ratio just adds dead space.
            childAspectRatio: 1.55,
          ),
          itemBuilder: (context, i) => _Tile(tile: tiles[i]),
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile});

  final StatTile tile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The tile is handed a plain Color and paints it as a large number, so it
    // has to be the thing that swaps in the dark-mode variant — by this point
    // the caller's "warning"/"success" intent is long gone. resolve() leaves
    // anything it does not recognise alone, so a custom colour still works.
    final color = AppSemantic.of(context).resolve(tile.color ?? theme.colorScheme.primary);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tile.onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(tile.icon, size: 18, color: color),
                  if (tile.onTap != null) ...[
                    const Spacer(),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ],
              ),
              // FittedBox so a five-figure revenue number shrinks instead of
              // overflowing the tile.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  tile.value,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              Text(
                tile.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled block with consistent spacing, used down the dashboards.
class DashboardSection extends StatelessWidget {
  const DashboardSection({
    super.key,
    required this.title,
    required this.child,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final Widget child;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppTheme.gap),
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (actionLabel != null && onAction != null)
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}
