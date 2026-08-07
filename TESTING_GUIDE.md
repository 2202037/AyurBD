# Stripe Payment Integration - Testing Guide

## Overview
This guide covers testing the Stripe payment integration in the AyurBD application.

## Prerequisites
1. Stripe Test Mode account
2. Supabase project with migrations applied
3. Edge Functions deployed
4. Flutter app running

## Test Card Numbers
- **Success**: `4242 4242 4242 4242` (any future expiry, any CVC)
- **Decline**: `4000 0000 0000 0002`
- **3D Secure**: `4000 0025 0000 3155`
- **Insufficient Funds**: `4000 0000 0000 9995`

## Test Flow

### 1. Book an Appointment
1. Navigate to Doctors screen
2. Select a doctor and book an appointment
3. Verify appointment status = `pending_payment`
4. Note the appointment ID

### 2. Initiate Stripe Payment
1. Go to My Appointments
2. Find the pending appointment
3. Tap "Pay now"
4. Select "Pay online (Card / bKash / Mobile Banking)"
5. Tap the Stripe payment button
6. Verify redirect to Stripe Checkout

### 3. Complete Payment on Stripe
1. On Stripe Checkout page, enter test card: `4242 4242 4242 4242`
2. Any future expiry date (e.g., `12/30`)
3. Any CVC (e.g., `123`)
4. Click Pay
5. Verify redirect back to app with `payment=success`

### 4. Verify Payment Processing
1. Check webhook received `checkout.session.completed`
2. Verify `record_payment_split` was called
3. Verify `confirm_appointment` was called
4. Check appointment status = `confirmed`
5. Check payment status = `paid`
6. Verify provider_payouts entry created

### 5. Verify Receipt Generation
1. Navigate to receipt screen: `/receipt/{appointmentId}`
2. Verify all details correct
3. Test PDF download
4. Test share functionality

### 6. Test Failed Payment
1. Use decline card: `4000 0000 0000 0002`
2. Verify webhook received `payment_intent.payment_failed`
3. Verify appointment stays in `pending_payment`
4. Verify failed payment record created
5. Verify patient can retry

### 7. Test Expired Session
1. Start checkout but don't complete
2. Wait for session to expire (24 hours)
3. Verify webhook received `checkout.session.expired`
4. Verify appointment stays in `pending_payment`

## Database Verification Queries

```sql
-- Check appointment status
SELECT id, status, payment_status, fee FROM appointments WHERE id = <appointment_id>;

-- Check payment record
SELECT id, payment_status, amount, stripe_session_id, admin_share, provider_share
FROM payments WHERE appointment_id = <appointment_id>;

-- Check provider payout
SELECT * FROM provider_payouts WHERE payment_id = (SELECT id FROM payments WHERE appointment_id = <appointment_id>);

-- Check notifications
SELECT * FROM notifications WHERE ref_id = <appointment_id> ORDER BY created_at DESC;
```

## Edge Function Logs
```bash
# View create-checkout-session logs
supabase functions logs create-checkout-session

# View stripe-webhook logs
supabase functions logs stripe-webhook
```

## Stripe Dashboard Verification
1. Go to Stripe Dashboard → Test Mode
2. Check Payments → Succeeded payments
3. Verify metadata contains `appointment_id`, `patient_id`, `provider_id`
4. Check Webhook delivery logs

## Flutter Integration Tests
Run the Flutter tests:
```bash
flutter test
```

## Manual Testing Checklist
- [ ] Book appointment with fee > 0
- [ ] Appointment status = pending_payment
- [ ] Stripe Checkout opens correctly
- [ ] Payment succeeds with test card
- [ ] Webhook processes payment
- [ ] Appointment status = confirmed
- [ ] Payment status = paid
- [ ] Provider payout created
- [ ] Notifications sent to patient, doctor, admin
- [ ] Receipt generated correctly
- [ ] PDF download works
- [ ] Failed payment handled correctly
- [ ] Expired session handled correctly
- [ ] Patient can retry failed payment

## Troubleshooting

### Webhook not receiving events
1. Check webhook URL in Stripe Dashboard
2. Verify `STRIPE_WEBHOOK_SECRET` is set correctly
3. Check Edge Function logs for errors

### Payment not confirmed
1. Check if `record_payment_split` succeeded
2. Check if `confirm_appointment` succeeded
3. Verify appointment payment_status = paid
4. Check for any trigger errors

### Amount mismatch
1. Verify appointment.fee matches Stripe amount
2. Check for currency conversion issues (BDT = 100 poisha)

### Idempotency issues
1. Verify unique indexes on stripe_session_id and stripe_payment_intent_id
2. Check for duplicate payment records