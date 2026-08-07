/// Slots, booking, cancellation and payment — from Supabase.
///
/// Public surface is unchanged: `slots()`, `book()`, `mine()`, `cancel()`,
/// `pay()`, `payments()` keep their signatures and return types, so the booking
/// flow, the appointment list and the payment sheet are not edited.
///
/// Three things the PHP did on the server now have to be arranged explicitly:
///
/// **Slots.** `/appointments/slots` returned the generated grid *and*
/// `works_on_day`. Postgres has `available_slots(p_doctor_id, p_date)`, but it
/// returns only the free times — it cannot say whether an empty result means
/// "off duty" or "fully booked", and those are different sentences in
/// [SlotsResult.emptyReason]. So the doctor's `available_days` is read alongside
/// and the weekday tested here, exactly as the PHP did.
///
/// **Money.** `fee` is copied from the doctor's `consultation_fee` at booking
/// time, as `appointments_book()` did. It is set on INSERT only: the
/// `aa_guard_appointments` trigger blocks any later change to it, along with
/// `payment_status` and the two verification columns.
///
/// **Payment.** [pay] writes a `payments` row and nothing else. It deliberately
/// does not touch `appointments.payment_status` — only the admin verification
/// path (`payments_apply_verification`) may, and the guard trigger refuses the
/// write anyway. The appointment is re-read afterwards so the caller still gets
/// the row back, which is what the old `{appointment}` response gave it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show CountOption;

import '../../../core/constants/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/appointment_models.dart';

/// Unchanged: `works_on_day` tells the screen whether the doctor practises at
/// all on that date, which is a very different message from "fully booked".
class SlotsResult {
  const SlotsResult({
    required this.slots,
    required this.worksOnDay,
    this.slotMinutes = 30,
  });

  final List<Slot> slots;
  final bool worksOnDay;
  final int slotMinutes;

  bool get hasFree => slots.any((s) => s.isFree);

  /// The empty-state line the picker should show. Kept here so the booking
  /// screen and the doctor detail sheet cannot disagree.
  String get emptyReason {
    if (!worksOnDay) return 'The doctor does not hold chamber on this day.';
    if (slots.isEmpty) return 'No slots published for this date.';
    return 'Every slot for this date is already booked.';
  }
}

class AppointmentRepository {
  AppointmentRepository(this._sb);

  final SupabaseService _sb;

  /// Columns of `appointments` the app reads, plus the doctor embed that
  /// supplies the name/specialty/chamber the list rows show.
  ///
  /// `doctors!left` and `users!left` are both deliberate. An inner join — which
  /// is Postgrest's default — would make the patient's own appointment vanish
  /// from their list if the doctor's row were ever invisible under RLS, which is
  /// a far worse failure than a missing name.
  static const _columns = 'id, patient_id, doctor_id, doctor_name, '
      'appointment_date, appointment_time, type, symptoms, notes, fee, status, '
      'payment_status, confirmation_code, created_at, '
      'doctors!left(specialization, hospital_clinic_name, chamber_address, '
      'users!left(name, profile_image)), '
      'payments!left(payment_status, created_at)';

  /// Free slots for one doctor on one date.
  ///
  /// The RPC returns only bookable times: it excludes taken slots and, for
  /// today, times that have already passed. So every row that comes back is
  /// available, and a slot that is free here can still lose the race — hence the
  /// 409 handling in [book].
  Future<SlotsResult> slots({required int doctorId, required DateTime date}) async {
    return SupabaseService.guard(() async {
      // Read the schedule first: it is what distinguishes "off duty" from
      // "fully booked" when the slot list comes back empty.
      final doctor = await _sb
          .db('doctors')
          .select('available_days, available_from, available_to, slot_minutes')
          .eq('id', doctorId)
          .maybeSingle();

      if (doctor == null) {
        throw ApiException(message: 'Doctor not found.', statusCode: 404);
      }

      final slotMinutes = Fmt.toInt(doctor['slot_minutes'], 30);
      final worksOnDay = _worksOn(doctor['available_days'], date) &&
          Fmt.str(doctor['available_from']).isNotEmpty &&
          Fmt.str(doctor['available_to']).isNotEmpty;

      // No point asking for slots on a day the doctor does not sit — the
      // function would return zero rows and the reason would be lost.
      if (!worksOnDay) {
        return SlotsResult(
          slots: const [],
          worksOnDay: false,
          slotMinutes: slotMinutes,
        );
      }

      final rows = await _sb.rpc<List<dynamic>>(
        'available_slots',
        params: {
          'p_doctor_id': doctorId,
          'p_date': Fmt.apiDate(date),
        },
      );

      // Each row is `{"slot_time": "10:00:00"}`. Slot.fromJson wants `time` and
      // `available`, and defaults `available` to false when the key is absent —
      // which would grey out the entire grid — so both are supplied.
      final slots = rows
          .whereType<Map>()
          .map((r) => Slot.fromJson({
                'time': Fmt.str(r['slot_time']),
                'available': true,
              }))
          .where((s) => s.time.isNotEmpty)
          .toList();

      return SlotsResult(
        slots: slots,
        worksOnDay: true,
        slotMinutes: slotMinutes,
      );
    });
  }

  /// A 23505 from the booking RPC (or its `uq_appointments_doctor_slot`
  /// unique index) means someone else took the slot between the list load and
  /// the tap; [SupabaseService] already turns that into a 409 with "That time
  /// slot has just been taken", so callers keep the same reload-and-show
  /// behaviour they had.
  ///
  /// Booking goes through the `appointments_book` RPC, not a direct INSERT:
  /// the server validates the doctor, re-checks the slot, stamps the fee from
  /// `doctors.consultation_fee` and snapshots `doctor_name` — none of which the
  /// client is allowed to choose. The RPC returns the fresh row.
  ///
  /// [time] is passed through verbatim (`HH:MM:SS`) — reformatting it here is
  /// how slot lookups start missing the unique index.
  Future<Appointment> book({
    required int doctorId,
    required DateTime date,
    required String time,
    String? reason,
  }) async {
    return SupabaseService.guard(() async {
      _requireUser();

      final row = await _sb.rpc<Map<String, dynamic>>(
        'appointments_book',
        params: {
          'p_doctor_id': doctorId,
          'p_appointment_date': Fmt.apiDate(date),
          'p_appointment_time': time,
          if (reason != null && reason.trim().isNotEmpty) 'p_symptoms': reason.trim(),
        },
      );

      return Appointment.fromJson(_shape(row));
    });
  }

  Future<Paged<Appointment>> mine({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? status,
  }) async {
    return SupabaseService.guard(() async {
      final patientId = _requireUser();
      final range = PageRange(page, limit);

      var query =
          _sb.db('appointments').select(_columns).eq('patient_id', patientId);

      if (status != null && status.trim().isNotEmpty) {
        query = query.eq('status', status.trim());
      }

      // Soonest-first within the newest bookings, matching the PHP's
      // `ORDER BY appointment_date DESC, appointment_time DESC`.
      final res = await query
          .order('appointment_date', ascending: false)
          .order('appointment_time', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => Appointment.fromJson(_shape(r))).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Returns the updated row so the list can replace one item instead of
  /// refetching the whole page.
  ///
  /// The `patient_id` filter is not the security boundary — RLS is — but it
  /// makes a mis-passed id return "not found" rather than silently updating
  /// nothing and reporting success.
  ///
  /// Cancelling a paid appointment also flips `payment_status` to 'refunded',
  /// but that is done by the `appointments_refund_on_cancel` trigger; writing it
  /// here would be refused by the column guard.
  Future<Appointment> cancel({required int appointmentId}) async {
    return SupabaseService.guard(() async {
      final patientId = _requireUser();

      final row = await _sb
          .db('appointments')
          .update({'status': 'cancelled'})
          .eq('id', appointmentId)
          .eq('patient_id', patientId)
          .select(_columns)
          .maybeSingle();

      if (row == null) {
        throw ApiException(
          message: 'That appointment could not be cancelled.',
          statusCode: 404,
        );
      }

      return Appointment.fromJson(_shape(row));
    });
  }

  /// Submits payment details for admin verification.
  ///
  /// This does **not** mark the appointment paid: it writes a `payments` row
  /// with `payment_status = 'pending'` and leaves `appointments.payment_status`
  /// alone. Only an admin, after checking the reference against a statement, can
  /// move it — anything else would let a made-up transaction id book revenue
  /// that never arrived.
  ///
  /// [transactionRef] should be collected for every method except Cash.
  Future<Appointment> pay({
    required int appointmentId,
    required PaymentMethod method,
    String? transactionRef,
    String? senderNumber,
    String? notes,
  }) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();

      // `payments.amount` is NOT NULL and must be the appointment's own fee —
      // taking it from the caller would let the client decide what it owed.
      final appointment = await _sb
          .db('appointments')
          .select('id, fee')
          .eq('id', appointmentId)
          .eq('patient_id', userId)
          .maybeSingle();

      if (appointment == null) {
        throw ApiException(message: 'Appointment not found.', statusCode: 404);
      }

      await _sb.db('payments').insert({
        'appointment_id': appointmentId,
        'user_id': userId,
        'amount': Fmt.toDouble(appointment['fee']),
        'payment_method': method.value,
        if (transactionRef != null && transactionRef.trim().isNotEmpty)
          'transaction_id': transactionRef.trim(),
        if (senderNumber != null && senderNumber.trim().isNotEmpty)
          'sender_number': senderNumber.trim(),
        if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      });

      // Re-read so the caller gets the appointment back, as the old
      // `{appointment}` response did. `payment_review` now reads 'pending',
      // which is what drives the "Awaiting verification" pill.
      final row = await _sb
          .db('appointments')
          .select(_columns)
          .eq('id', appointmentId)
          .single();

      return Appointment.fromJson(_shape(row));
    });
  }

  /// Creates a Stripe Checkout Session for the appointment.
  ///
  /// Calls the `create-checkout-session` Edge Function which:
  /// 1. Authenticates the user
  /// 2. Validates the appointment belongs to the patient and is in pending_payment state
  /// 3. Reads the fee from the database (never from client)
  /// 4. Creates a Stripe Checkout Session
  /// 5. Returns the checkout URL and session ID
  Future<StripeCheckoutSession> createStripeCheckoutSession({
    required int appointmentId,
  }) async {
    return SupabaseService.guard(() async {
      _requireUser();

      final result = await _sb.functionsInvoke<Map<String, dynamic>>(
        'create-checkout-session',
        body: {'appointment_id': appointmentId},
      );

      return StripeCheckoutSession.fromJson(result);
    });
  }

  Future<Paged<Payment>> payments({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
  }) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();
      final range = PageRange(page, limit);

      final res = await _sb
          .db('payments')
          .select('id, appointment_id, amount, payment_method, transaction_id, '
              'sender_number, payment_status, rejection_reason, verified_at, '
              'created_at, '
              'appointments!left(appointment_date, '
              'doctors!left(users!left(name)))')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => Payment.fromJson(_shapePayment(r))).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// Fetches the payment receipt for an appointment.
  ///
  /// Returns a [PaymentReceipt] with all details needed for display/PDF generation.
  /// Only works for verified/paid payments.
  Future<PaymentReceipt> getReceipt({
    required int appointmentId,
  }) async {
    return SupabaseService.guard(() async {
      _requireUser();

      final res = await _sb
          .db('payments')
          .select('''
            id,
            appointment_id,
            amount,
            payment_method,
            transaction_id,
            stripe_payment_intent_id,
            gateway_transaction_id,
            verified_at,
            admin_share,
            provider_share,
            appointments!inner(
              fee,
              appointment_date,
              appointment_time,
              doctor_name,
              patient_id,
              doctors!inner(
                hospital_clinic_name,
                chamber_address,
                users!inner(name)
              )
            ),
            users!inner(name)
          ''')
          .eq('appointment_id', appointmentId)
          .eq('payment_status', 'verified')
          .eq('gateway', 'stripe')
          .order('created_at', ascending: false)
          .limit(1)
          .single();

      return PaymentReceipt.fromJson(_shapeReceipt(res));
    });
  }

  // -------------------------------------------------------------------------
  // Shaping — reproduces appointment_public() / payment rows exactly
  // -------------------------------------------------------------------------

  /// Flattens the embeds onto the keys [Appointment.fromJson] already reads, so
  /// the model is untouched. The doctor's name prefers the snapshot column
  /// `doctor_name` (set by the booking RPC, immune to later renames and
  /// soft-deletes) and falls back to the embedded name for rows that predate it.
  Map<String, dynamic> _shape(Map<String, dynamic> r) {
    final doctor = r['doctors'] as Map<String, dynamic>?;
    final user = doctor?['users'] as Map<String, dynamic>?;

    return {
      ...r,
      'doctor_name': Fmt.str(r['doctor_name'], Fmt.str(user?['name'], 'Doctor')),
      'doctor_specialty': doctor?['specialization'],
      'doctor_image': _sb.storageHelper.avatar(user?['profile_image'] as String?),
      'clinic_name': doctor?['hospital_clinic_name'],
      'clinic_address': doctor?['chamber_address'],
      'payment_review': _latestPaymentStatus(r['payments']),
    };
  }

  /// The status of the most recent submission, which is what distinguishes
  /// "not paid yet" from "paid, awaiting verification" — the appointment's own
  /// `payment_status` reads 'pending' in both cases.
  ///
  /// Postgrest returns a to-many embed as a list with no ordering guarantee, so
  /// the newest is picked by `created_at` rather than by position.
  String? _latestPaymentStatus(Object? embed) {
    if (embed is! List || embed.isEmpty) return null;

    Map? newest;
    for (final e in embed) {
      if (e is! Map) continue;
      if (newest == null) {
        newest = e;
        continue;
      }
      final a = Fmt.str(e['created_at']);
      final b = Fmt.str(newest['created_at']);
      if (a.compareTo(b) > 0) newest = e;
    }

    final status = Fmt.str(newest?['payment_status']);
    return status.isEmpty ? null : status;
  }

  Map<String, dynamic> _shapePayment(Map<String, dynamic> r) {
    final appointment = r['appointments'] as Map<String, dynamic>?;
    final doctor = appointment?['doctors'] as Map<String, dynamic>?;
    final user = doctor?['users'] as Map<String, dynamic>?;

    return {
      ...r,
      // The model's `status` is the payment's own verification state.
      'status': r['payment_status'],
      'method': r['payment_method'],
      'transaction_ref': r['transaction_id'],
      'paid_at': r['verified_at'],
      'doctor_name': user?['name'],
      'appointment_date': appointment?['appointment_date'],
    };
  }

  Map<String, dynamic> _shapeReceipt(Map<String, dynamic> r) {
    final appointment = r['appointments'] as Map<String, dynamic>?;
    final doctor = appointment?['doctors'] as Map<String, dynamic>?;
    final doctorUser = doctor?['users'] as Map<String, dynamic>?;
    final patient = r['users'] as Map<String, dynamic>?;

    return {
      'id': r['id'],
      'appointment_id': r['appointment_id'],
      'amount': r['amount'],
      'payment_method': r['payment_method'],
      'transaction_id': r['transaction_id'],
      'stripe_payment_intent_id': r['stripe_payment_intent_id'],
      'gateway_transaction_id': r['gateway_transaction_id'],
      'paid_at': r['verified_at'],
      'admin_share': r['admin_share'],
      'provider_share': r['provider_share'],
      'patient_name': patient?['name'] ?? 'Patient',
      'doctor_name': appointment?['doctor_name'] ?? doctorUser?['name'] ?? 'Doctor',
      'appointment_date': appointment?['appointment_date'],
      'appointment_time': appointment?['appointment_time'],
      'clinic_name': doctor?['hospital_clinic_name'],
      'clinic_address': doctor?['chamber_address'],
      'fee': appointment?['fee'],
    };
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// The signed-in user's uuid.
  ///
  /// Every method here is patient-scoped. Without a session the queries would
  /// still run and simply return nothing under RLS, which reads to the user as
  /// "you have no appointments" rather than "you are signed out" — so this fails
  /// with a 401 that the router already handles.
  String _requireUser() {
    final id = _sb.currentUserId;
    if (id == null || id.isEmpty) {
      throw ApiException(
        message: 'Please sign in to continue.',
        statusCode: 401,
      );
    }
    return id;
  }

  /// Does the doctor sit on [date]?
  ///
  /// `available_days` is a lowercase CSV of Postgres' own three-letter day
  /// abbreviations — `sat,sun,mon,...` — because `available_slots()` matches it
  /// with `lower(to_char(p_date,'dy'))`. The same spelling is used here so the
  /// two cannot disagree about what day it is.
  static bool _worksOn(Object? availableDays, DateTime date) {
    final raw = Fmt.str(availableDays).toLowerCase();
    if (raw.isEmpty) return false;

    const names = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    // DateTime.weekday is 1 (Monday) .. 7 (Sunday).
    final today = names[date.weekday - 1];

    return raw
        .split(',')
        .map((d) => d.trim())
        .any((d) => d == today);
  }
}

final appointmentRepositoryProvider = Provider<AppointmentRepository>(
  (ref) => AppointmentRepository(ref.watch(supabaseServiceProvider)),
);
