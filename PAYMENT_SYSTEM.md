# AYUR Payment System — Complete Workflow Documentation

## Overview

The AYUR platform implements a **manual escrow payment flow** where patients pay the platform, admins verify payments, the platform retains a commission, providers receive the remainder, and only then can providers confirm bookings.

This design ensures:
- Platform revenue protection (commission collected upfront)
- Provider payment guarantee (money credited before confirmation)
- Fraud prevention (manual verification by admin)
- Audit trail (immutable payment & payout ledgers)

---

## Core Database Schema

### Key Tables

| Table | Purpose |
|-------|---------|
| `payments` | Patient submissions, verification state, money split |
| `provider_payouts` | Ledger of what platform owes each provider after commission |
| `appointments` | Links to payment via `payment_status`, `payment_verified_at/by` |
| `doctors/hospitals/clinics/pharmacies` | `commission_percentage` (default 2.00%) |

### Payment Status Enum
```sql
payment_status ENUM('pending', 'verified', 'rejected')
```

### Provider Payout Status
```sql
status ENUM('pending', 'paid')
```

---

## Workflow Steps

### 1. Patient Books Appointment & Initiates Payment

**Endpoint**: `POST /appointments/:id/pay`  
**Repository**: `AppointmentRepository.pay()`

**Patient provides**:
- `payment_method`: `bKash` | `Nagad` | `Rocket` | `Credit/Debit Card` | `Bank Transfer` | `Cash`
- `transaction_ref` (required for all except Cash)
- `sender_number` (optional, for mobile money)
- `notes` (optional)

**Server enforcement**:
```dart
// Amount is taken from appointment.fee — client CANNOT control it
final appointment = await _sb.db('appointments')
    .select('id, fee')
    .eq('id', appointmentId)
    .eq('patient_id', userId)
    .maybeSingle();

await _sb.db('payments').insert({
  'appointment_id': appointmentId,
  'user_id': userId,
  'amount': appointment['fee'],  // Server-enforced
  'payment_method': method.value,
  'transaction_id': transactionRef,
  'sender_number': senderNumber,
  'notes': notes,
});
```

**Result**: Payment row created with `payment_status = 'pending'`

---

### 2. Patient Views Payment History

**Screen**: `/appointments/payments` (`PaymentsScreen`)  
**Repository**: `AppointmentRepository.payments()`

Read-only ledger showing:
- All payments with status pills: `Pending` → `Verified` / `Rejected`
- Method icon (mobile money, card, bank, cash)
- Amount, transaction reference, appointment date
- Verification timestamp (when `verified_at` is set)

---

### 3. Admin Reviews & Verifies Payment

**Screen**: `/admin/payments` (`AdminPaymentsScreen`)  
**Repository**: `AdminRepository.verifyPayment()` + `AdminRepository.payments()`

**Admin sees**:
- Filterable queue: `All` | `Awaiting` | `Verified` | `Rejected`
- Patient name, amount, method, transaction reference, sender number
- Time waiting (relative timestamp)

**Actions**:

#### Verify
```dart
await adminRepository.verifyPayment(
  paymentId: p.id,
  approve: true,
  // rejectionReason not needed
);
```

#### Reject (requires reason)
```dart
final reason = await _askReason(p);  // Min 5 chars
await adminRepository.verifyPayment(
  paymentId: p.id,
  approve: false,
  rejectionReason: reason,
);
```

**Server validation**: Reject without reason → `422` error

---

### 4. Verification Trigger — Money Split (Auto-executes)

**Trigger**: `payments_apply_verification` (PostgreSQL, `SECURITY DEFINER`)

**Fires when**: `payment_status` changes `pending` → `verified`

```sql
-- 1. Read provider's commission_percentage at verification time
SELECT d.commission_percentage, u.id
  INTO v_commission, v_doctor_user
  FROM appointments a
  JOIN doctors d ON d.id = a.doctor_id
  JOIN users u ON u.id = d.user_id
 WHERE a.id = NEW.appointment_id;

-- 2. Calculate split (commission defaults to 2.00%)
v_admin    := round(NEW.amount * COALESCE(v_commission, 0) / 100.0, 2);
v_provider := NEW.amount - v_admin;

-- 3. Write split to payment row
NEW.admin_share    := v_admin;
NEW.provider_share := v_provider;

-- 4. Create provider payout ledger entry
INSERT INTO provider_payouts
  (provider_user_id, payment_id, amount, commission_percentage, status)
VALUES (v_doctor_user, NEW.id, v_provider, COALESCE(v_commission, 0), 'pending')
ON CONFLICT (payment_id) WHERE payment_id IS NOT NULL DO NOTHING;

-- 5. Mark appointment PAID (but NOT confirmed)
UPDATE appointments
   SET payment_status      = 'paid',
       payment_verified_at = NOW(),
       payment_verified_by = COALESCE(NEW.verified_by, auth.uid())
 WHERE id = NEW.appointment_id;
```

**Critical**: Appointment status remains `pending` — provider must confirm separately.

---

### 5. Provider Confirms Booking

**Trigger**: `appointments_guard_confirm` (BEFORE UPDATE on `appointments`)

**Rules enforced**:
1. **Only owning doctor** (or admin) can confirm
2. **Free consultations** (`fee = 0`) → can confirm immediately
3. **Paid consultations** (`fee > 0`) → **blocked unless** `payment_status = 'paid'`

```sql
IF NEW.status = 'confirmed' AND OLD.status IS DISTINCT FROM 'confirmed'
   AND NEW.fee > 0
   AND NEW.payment_status IS DISTINCT FROM 'paid' THEN
  RAISE EXCEPTION
    'This booking can be confirmed only after the patient payment is verified.'
    USING ERRCODE = 'P0001';
END IF;
```

**Result**: Escrow enforced — provider confirms only after their 98% is credited.

---

### 6. Admin Settles Provider Payout

**Screen**: `/admin/payouts`  
**Repository**: `AdminRepository.payouts()` + `AdminRepository.settlePayout()`

**Admin workflow**:
1. Views pending payouts (provider name, amount, source appointment/order)
2. Transfers money offline (bKash/Nagad/Rocket/Bank)
3. Marks payout `paid`:

```dart
await adminRepository.settlePayout(
  payoutId: payout.id,
  note: 'Sent via bKash to 017XXXXXXXX',  // Optional
);
```

**Server update**:
```sql
UPDATE provider_payouts
   SET status = 'paid',
       paid_at = NOW(),
       paid_by = auth.uid(),
       payout_note = '...'
 WHERE id = :payoutId AND status = 'pending';
```

---

### 7. Rejection Flow

**Trigger**: `payments_apply_verification` (on `pending` → `rejected`)

```sql
IF NEW.payment_status = 'rejected' AND OLD.payment_status IS DISTINCT FROM 'rejected' THEN
  NEW.rejection_reason := NEW.rejection_reason;  -- Preserved from admin input
  NEW.verified_at      := NOW();
  NEW.verified_by      := COALESCE(NEW.verified_by, auth.uid());
  -- No money split, no payout, appointment stays payment_status = 'pending'
END IF;
```

**Patient experience**: Sees rejection reason in payment history, can resubmit.

---

## Business Rules Summary

| Rule | Enforced By |
|------|-------------|
| Payment amount = appointment fee | `AppointmentRepository.pay()` (server) |
| Only admin can verify | RLS policy `payments_update_admin` |
| Commission split at verification time | `payments_apply_verification` trigger |
| Split immutable after verification | Trigger writes once; unique index on `provider_payouts(payment_id)` |
| Appointment not auto-confirmed | Trigger explicitly omits status change |
| Provider confirms only after paid | `appointments_guard_confirm` trigger |
| Rejection requires reason | `AdminRepository.verifyPayment()` + trigger |
| Cash payments don't need transaction ref | Client validation + server allows NULL |
| Provider payouts never edited/deleted | Only `settlePayout` (pending → paid); reversal = refund appointment |

---

## Commission Configuration

| Provider Type | Commission Column | Default |
|---------------|-------------------|---------|
| Doctors | `doctors.commission_percentage` | 2.00% |
| Hospitals | `hospitals.commission_percentage` | 2.00% |
| Clinics | `clinics.commission_percentage` | 2.00% |
| Pharmacies | `pharmacies.commission_percentage` | 2.00% |
| Blood Banks | **None** (no fee, no commission) | N/A |

**Admin can update**: `AdminRepository.updateCommission(type, id, percent)`

**Split calculation**: Done at verification time using **current** commission — later changes only affect future payments.

---

## UI Screens Reference

| Role | Screen | Route | Purpose |
|------|--------|-------|---------|
| Patient | Payments History | `/appointments/payments` | View all payments + status |
| Patient | Booking Flow | `/appointments/:id/pay` | Submit payment for appointment |
| Admin | Payment Verification | `/admin/payments` | Verify/reject pending payments |
| Admin | Payout Settlement | `/admin/payouts` | Mark provider payouts as paid |
| Provider | Payout Ledger | `/provider/payouts` | View pending/paid payouts (read-only) |

---

## API / Repository Methods

### Patient Side (`AppointmentRepository`)
```dart
Future<Appointment> pay({
  required int appointmentId,
  required PaymentMethod method,
  String? transactionRef,
  String? senderNumber,
  String? notes,
});

Future<Paged<Payment>> payments({int page, int limit});
```

### Admin Side (`AdminRepository`)
```dart
Future<void> verifyPayment({
  required int paymentId,
  required bool approve,
  String? rejectionReason,
});

Future<Paged<ProviderPayment>> payments({int page, int limit, String? status});

Future<Paged<Payout>> payouts({int page, int limit, String? status});

Future<void> settlePayout({required int payoutId, String? note});

Future<void> updateCommission({required String type, required int id, required double percent});
```

---

## Error Codes & Handling

| Scenario | HTTP | Error Code | Message |
|----------|------|------------|---------|
| Appointment not found | 404 | - | "Appointment not found." |
| Payment not found | 404 | - | "Payment not found." |
| Reject without reason | 422 | - | "Please give a reason for rejecting this payment." |
| Confirm before payment | 400 | P0001 | "This booking can be confirmed only after the patient payment is verified." |
| Non-doctor confirms | 403 | 42501 | "Only the doctor for this appointment can confirm it." |
| Settle non-pending payout | 409 | - | "Payout is no longer pending." |
| Non-admin access | 403 | 42501 | RLS policy denial |

All errors surfaced via `SupabaseService.guard()` → `ApiException`.

---

## Migration History

| Migration | Purpose |
|-----------|---------|
| `20260806000006_escrow_payment_flow.sql` | Core escrow: commission defaults, split trigger, confirm guard |
| `20260806000009_payments_guard_dead_appointment.sql` | Prevent payment on cancelled appointments |
| `20260806000015_payments_transaction_ref_check.sql` | Validate transaction ref format |
| `20260806000016_payments_notify_wording.sql` | Notification text for verification/rejection |
| `20260806000018_payments_verified_immutable.sql` | Prevent modification of verified payments |
| `20260806000003_payment_commission_reviews.sql` | Commission review workflow |

---

## Key Design Decisions

1. **Manual verification only** — No payment gateway integration; admin checks platform statement
2. **Escrow, not pass-through** — Platform holds money, splits, then pays provider
3. **Split at verification time** — Commission % captured at verification; later changes don't affect past payments
4. **Confirmation decoupled from payment** — Provider confirms booking as separate step after payout credited
5. **Immutable ledger** — Verified payments & payouts never edited; reversals via refund flow
6. **Cash supported** — No transaction ref required; sender number optional
7. **Blood banks excluded** — No fees, no commission, no payment flow