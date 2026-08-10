/// §10.7 — read-only oversight of the appointment ledger.
///
/// There is no moderation call here: the admin reads but does not control the
/// lifecycle, which is the patient-and-doctor conversation. Mostly for support
/// — an admin seeing a complaint can look up the appointment and know what
/// actually happened.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/appointment_models.dart';
import 'admin_controllers.dart';
import 'widgets/admin_filter_bar.dart';

const _statusFilters = <FilterOption>[
  (value: null, label: 'All'),
  // Bookings holding a slot without payment. An admin verifying transfers
  // needs to find these directly — they are the queue the manual-payment
  // workflow actually works through.
  (value: 'pending_payment', label: 'Unpaid'),
  (value: 'pending', label: 'Pending'),
  (value: 'confirmed', label: 'Confirmed'),
  (value: 'completed', label: 'Completed'),
  (value: 'expired', label: 'Expired'),
  (value: 'cancelled', label: 'Cancelled'),
];

class AdminAppointmentsScreen extends ConsumerStatefulWidget {
  const AdminAppointmentsScreen({super.key});

  @override
  ConsumerState<AdminAppointmentsScreen> createState() =>
      _AdminAppointmentsScreenState();
}

class _AdminAppointmentsScreenState
    extends ConsumerState<AdminAppointmentsScreen> {
  final _dateController = TextEditingController();

  @override
  void dispose() {
    _dateController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked == null) return;
    final formatted = Fmt.apiDate(picked);
    _dateController.text = formatted;
    ref.read(adminApptDateProvider.notifier).state = formatted;
  }

  void _clearDate() {
    _dateController.clear();
    ref.read(adminApptDateProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(adminAppointmentsProvider);
    final controller = ref.read(adminAppointmentsProvider.notifier);
    final status = ref.watch(adminApptStatusProvider);

    final bar = AdminFilterBar(
      searchHint: 'Search patient or doctor name',
      onSearch: (v) => ref.read(adminApptSearchProvider.notifier).state = v,
      options: _statusFilters,
      selected: status,
      onSelected: (v) => ref.read(adminApptStatusProvider.notifier).state = v,
      trailing: TextField(
        controller: _dateController,
        readOnly: true,
        decoration: InputDecoration(
          labelText: 'Date',
          hintText: 'Any',
          isDense: true,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.calendar_today, size: 18),
          suffixIcon: _dateController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _clearDate,
                ),
        ),
        onTap: _pickDate,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appointments'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      body: PagedListView<Appointment>(
        state: state,
        onRefresh: controller.refresh,
        onLoadMore: controller.loadMore,
        onRetry: controller.reload,
        emptyTitle: 'No appointments',
        emptyIcon: Icons.event_note_outlined,
        emptyMessage: 'Nothing matches those filters.',
        itemBuilder: (context, a, _) => _AppointmentCard(appointment: a),
      ),
    );
  }
}

class _AppointmentCard extends StatelessWidget {
  const _AppointmentCard({required this.appointment});

  final Appointment appointment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = appointment;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.patientName ?? 'Patient',
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'with ${a.doctorName}',
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                StatusPill(status: a.status, dense: true),
              ],
            ),
            const SizedBox(height: 8),
            _Meta(icon: Icons.calendar_today, text: a.whenLabel),
            _Meta(icon: Icons.badge_outlined, text: 'ID ${a.id} · ${a.paymentLabel}'),
            if (a.confirmationCode != null)
              _Meta(
                icon: Icons.verified,
                text: 'Code ${a.confirmationCode}',
                color: AppColors.success,
              ),
            if (a.notes != null && a.notes!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  a.notes!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    // Painted as body text as well as an icon, so it needs the theme-matched
    // variant — see AppSemantic.resolve.
    final tone = AppSemantic.of(context).resolveOrNull(color);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: tone ?? muted),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tone,
                ),
          ),
        ],
      ),
    );
  }
}
