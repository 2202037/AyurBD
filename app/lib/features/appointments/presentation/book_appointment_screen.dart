/// `/appointments/slots` + `/appointments/book` — pick a date, pick a slot, book.
///
/// The server is the only authority on availability. This screen renders what
/// `slots()` returns and never computes its own view of what is free: a slot can
/// still lose the race between the grid loading and the tap landing, which comes
/// back as a 409 and is handled by reloading rather than by guessing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/appointment_models.dart';
import '../../directory/presentation/doctor_detail_screen.dart' show doctorDetailProvider;
import '../data/appointment_repository.dart';

/// `(doctorId, date)` as a record so the family key has value equality — a plain
/// class would refetch on every rebuild, and a string key would need parsing
/// back out at the other end.
typedef SlotKey = ({int doctorId, DateTime date});

final slotsProvider =
    FutureProvider.autoDispose.family<SlotsResult, SlotKey>((ref, key) {
  return ref.watch(appointmentRepositoryProvider).slots(
        doctorId: key.doctorId,
        date: key.date,
      );
});

class BookAppointmentScreen extends ConsumerStatefulWidget {
  const BookAppointmentScreen({super.key, required this.doctorId});

  final int doctorId;

  @override
  ConsumerState<BookAppointmentScreen> createState() => _BookAppointmentScreenState();
}

class _BookAppointmentScreenState extends ConsumerState<BookAppointmentScreen> {
  /// Date-only, always. A DateTime carrying a time component would make two
  /// otherwise-identical days different family keys and refetch the grid every
  /// rebuild.
  late DateTime _day = _dateOnly(DateTime.now());
  late DateTime _focused = _day;

  String? _selectedTime;
  final _reason = TextEditingController();
  bool _busy = false;

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// §6 rejects past datetimes with a 422, so there is no point offering them.
  DateTime get _firstDay => _dateOnly(DateTime.now());
  DateTime get _lastDay => _firstDay.add(const Duration(days: 60));

  SlotKey get _key => (doctorId: widget.doctorId, date: _day);

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _onDaySelected(DateTime selected, DateTime focused) {
    final day = _dateOnly(selected);
    if (day == _day) return;
    setState(() {
      _day = day;
      _focused = focused;
      // A slot number means nothing on a different date — carrying the selection
      // across days is how you book 3pm on the wrong Tuesday.
      _selectedTime = null;
    });
  }

  Future<void> _book() async {
    final time = _selectedTime;
    if (time == null || _busy) return;

    setState(() => _busy = true);
    try {
      final appointment = await ref.read(appointmentRepositoryProvider).book(
            doctorId: widget.doctorId,
            date: _day,
            time: time,
            reason: _reason.text,
          );
      if (!mounted) return;
      // The list behind us is now stale in two ways: one fewer free slot, one
      // more appointment.
      ref.invalidate(slotsProvider(_key));
      await _showBooked(appointment);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);

      // 409: someone else took it in the meantime. The server's own wording is
      // better than anything invented here, and the grid must be refetched
      // before the user can pick again.
      if (e.isConflict) {
        setState(() => _selectedTime = null);
        ref.invalidate(slotsProvider(_key));
      }
      // A 401 is handled globally (§10) — the interceptor clears storage and the
      // router bounces to /login, so showing a red toast here would be noise.
      if (!e.isUnauthorized) showToast(context, e.message, error: true);
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, 'Could not complete the booking.', error: true);
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _showBooked(Appointment appointment) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline, size: 40),
        title: const Text('Appointment requested'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${appointment.doctorName} — ${appointment.whenLabel}'),
            const SizedBox(height: 10),
            // The API creates the row as `pending` with no payment yet;
            // saying "confirmed" here would be a lie the clinic has to walk
            // back. Payment comes first: the clinic confirms the slot only
            // once the admin verifies the payment.
            const Text(
              'Pay from My appointments to hold your slot. The clinic will '
              'confirm it once your payment is verified.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Book another'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              context.go(Routes.appointments);
            },
            child: const Text('View appointments'),
          ),
        ],
      ),
    );
    if (mounted) setState(() => _selectedTime = null);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(slotsProvider(_key));
    final doctor = ref.watch(doctorDetailProvider(widget.doctorId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Book appointment'),
        // Explicit type argument: `bottom` is `PreferredSizeWidget?`, and the two
        // branches return `PreferredSize` and `null`. Downward inference resolves
        // that, but spelling it out means the header never depends on it.
        bottom: doctor.maybeWhen<PreferredSizeWidget?>(
          data: (d) => PreferredSize(
            preferredSize: const Size.fromHeight(38),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppTheme.gap, 0, AppTheme.gap, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${d.doctor.name} · ${d.doctor.specialty}',
                      style: Theme.of(context).textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    d.doctor.feeLabel,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                ],
              ),
            ),
          ),
          orElse: () => null,
        ),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Confirming your slot…',
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppTheme.gap, 8, AppTheme.gap, 32),
          children: [
            _Calendar(
              day: _day,
              focused: _focused,
              firstDay: _firstDay,
              lastDay: _lastDay,
              onSelected: _onDaySelected,
              onPageChanged: (f) => _focused = f,
            ),
            const SizedBox(height: 18),
            SectionHeader(title: 'Slots for ${Fmt.dayFull(Fmt.apiDate(_day))}'),
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: LoadingView(message: 'Checking availability…'),
              ),
              error: (e, _) => ErrorView(
                error: e,
                onRetry: () => ref.invalidate(slotsProvider(_key)),
              ),
              data: (result) => _SlotGrid(
                result: result,
                selected: _selectedTime,
                onSelect: (t) => setState(() => _selectedTime = t),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _reason,
              maxLines: 3,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason for visit (optional)',
                alignLabelWithHint: true,
                hintText: 'Symptoms, how long you have had them, current medicines…',
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(AppTheme.gap, 8, AppTheme.gap, 12),
        child: FilledButton(
          onPressed: _selectedTime == null || _busy ? null : _book,
          child: Text(
            _selectedTime == null
                ? 'Select a time'
                : 'Confirm ${_labelFor(async, _selectedTime!)}',
          ),
        ),
      ),
    );
  }

  /// Prefer the server's own `g:i A` label so the button and the grid agree.
  String _labelFor(AsyncValue<SlotsResult> async, String time) {
    final slots = async.valueOrNull?.slots ?? const <Slot>[];
    for (final s in slots) {
      if (s.time == time) return s.label;
    }
    return Fmt.time(time);
  }
}

class _Calendar extends StatelessWidget {
  const _Calendar({
    required this.day,
    required this.focused,
    required this.firstDay,
    required this.lastDay,
    required this.onSelected,
    required this.onPageChanged,
  });

  final DateTime day;
  final DateTime focused;
  final DateTime firstDay;
  final DateTime lastDay;
  final void Function(DateTime, DateTime) onSelected;
  final void Function(DateTime) onPageChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TableCalendar<void>(
          firstDay: firstDay,
          lastDay: lastDay,
          focusedDay: focused.isBefore(firstDay)
              ? firstDay
              : (focused.isAfter(lastDay) ? lastDay : focused),
          currentDay: DateTime.now(),
          calendarFormat: CalendarFormat.twoWeeks,
          availableGestures: AvailableGestures.horizontalSwipe,
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: theme.textTheme.titleMedium ?? const TextStyle(),
          ),
          selectedDayPredicate: (d) => isSameDay(d, day),
          onDaySelected: onSelected,
          onPageChanged: onPageChanged,
          calendarStyle: CalendarStyle(
            outsideDaysVisible: false,
            // Same-family primary tint, matched to AppSemantic.tintAlpha so the
            // calendar's "today" reads the same as every other primary wash in
            // the app. The onSurface day number keeps ≥4.5:1 over it in both
            // themes (8.5:1 light / 8.8:1 dark, measured).
            todayDecoration: BoxDecoration(
              color: theme.colorScheme.primary
                  .withValues(alpha: AppSemantic.of(context).tintAlpha),
              shape: BoxShape.circle,
            ),
            todayTextStyle: TextStyle(color: theme.colorScheme.onSurface),
            selectedDecoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// The slot grid, plus the three different reasons it can be empty.
///
/// `SlotsResult.emptyReason` distinguishes "the doctor does not sit that day"
/// from "fully booked" — collapsing them into one "no slots" message is the
/// difference between a user trying tomorrow and a user giving up.
class _SlotGrid extends StatelessWidget {
  const _SlotGrid({
    required this.result,
    required this.selected,
    required this.onSelect,
  });

  final SlotsResult result;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (!result.hasFree) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: EmptyView(
          message: result.emptyReason,
          icon: result.worksOnDay
              ? Icons.event_busy_outlined
              : Icons.event_available_outlined,
          title: 'Nothing free',
        ),
      );
    }

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final slot in result.slots)
              ChoiceChip(
                label: Text(slot.label),
                selected: slot.time == selected,
                // Disabled rather than hidden: seeing that 10:00 exists but is
                // taken tells the user more than an unexplained gap.
                onSelected: slot.isFree ? (_) => onSelect(slot.time) : null,
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '${result.slotMinutes}-minute consultations. '
          'Greyed times are already booked or have passed.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
