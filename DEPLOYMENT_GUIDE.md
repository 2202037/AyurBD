# Stripe Payment Integration - Deployment Guide

## Overview
This guide covers deploying the Stripe payment integration to production.

## Prerequisites
- Supabase CLI installed and logged in
- Stripe account (Live mode)
- Domain configured for webhook URL
- SSL certificate for production

## Environment Variables

### Supabase Secrets (Required)
Set these using Supabase CLI or Dashboard:

```bash
# Stripe Live Keys
supabase secrets set STRIPE_SECRET_KEY=sk_live_xxxxx
supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_xxxxx

# Supabase (already set if linked)
supabase secrets set SUPABASE_URL=https://your-project.supabase.co
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=eyJhbGc...
supabase secrets set SUPABASE_ANON_KEY=eyJhbGc...

# App URL for redirects
# APP_URL is the ONLY switch that decides where Stripe returns the user after
# checkout. It must NEVER be the Supabase URL (the browser would request
# `https://project.supabase.co/appointments/...`, which returns
# `{"error":"requested path is invalid"}`).
#
#   Web (dev)      : APP_URL=http://localhost:62095   (use the port flutter run prints)
#   Web (production): APP_URL=https://ayurbd.me
#   Android / iOS   : APP_URL=ayurd://
#
# The Flutter web client builds on the original `/#/` hash router, so web
# redirects are `APP_URL/#/payment-success?...` and just work on a deep link to
# the checkout; mobile redirects are custom-scheme deep links the OS hands back
# to the app. Set the secret per environment with the value that matches where
# the app for THAT environment routes.
supabase secrets set APP_URL=https://ayurbd.me # production web
supabase secrets set APP_URL=http://localhost:62095 # local web dev
supabase secrets set APP_URL=ayurbd:// # Android / iOS builds
```

### Stripe Dashboard Configuration

#### Webhook Endpoint
1. Go to Stripe Dashboard → Developers → Webhooks
2. Click "Add endpoint"
3. URL: `https://your-project.supabase.co/functions/v1/stripe-webhook`
4. Events to subscribe:
   - `checkout.session.completed`
   - `checkout.session.expired`
   - `payment_intent.payment_failed`
5. Copy the "Signing secret" → set as `STRIPE_WEBHOOK_SECRET`

#### API Keys
1. Go to Stripe Dashboard → Developers → API keys
2. Copy "Secret key" → set as `STRIPE_SECRET_KEY`
3. Copy "Publishable key" → add to Flutter app config if needed

## Deployment Steps

### 1. Apply Database Migrations
```bash
# Link to production project
supabase link --project-ref YOUR_PROJECT_REF

# Push migrations
supabase db push
```

### 2. Deploy Edge Functions
```bash
# Deploy create-checkout-session (with JWT verification)
supabase functions deploy create-checkout-session

# Deploy stripe-webhook (WITHOUT JWT verification)
supabase functions deploy stripe-webhook --no-verify-jwt
```

### 3. Verify Function Deployment
```bash
# Check function status
supabase functions list

# Test create-checkout-session
curl -X POST https://your-project.supabase.co/functions/v1/create-checkout-session \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"appointment_id": 1}'
```

### 4. Update Flutter App Configuration
Update `lib/core/constants/app_config.dart` with production values:
```dart
static const String supabaseUrl = 'https://your-project.supabase.co';
static const String supabaseAnonKey = 'your-production-anon-key';
```

### 5. Build and Release Flutter App
```bash
# Android
flutter build appbundle --release

# iOS
flutter build ipa --release

# Web
flutter build web --release
```

### 5b. Deep-link back into the mobile app
Android is already configured: `android/app/src/main/AndroidManifest.xml` declares
a `VIEW` intent-filter for the `ayurbd` scheme, and `app_links`
(`lib/core/deep_links/deep_link_service.dart`) forwards it into GoRouter.

iOS needs the same scheme declared in `ios/Runner/Info.plist` (an `ios/` target
is not part of this repo yet, so add it when the target is created):

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>bd.ayur.app</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>ayurbd</string>
    </array>
  </dict>
</array>
```

## Post-Deployment Verification

### 1. Test Webhook Endpoint
```bash
# Use Stripe CLI to test webhook locally first
stripe listen --forward-to localhost:54321/functions/v1/stripe-webhook

# In production, verify webhook in Stripe Dashboard
# Go to Webhooks → Your endpoint → "Send test webhook"
```

### 2. Test Full Payment Flow
1. Book appointment in production app
2. Complete Stripe payment with live card (small amount)
3. Verify appointment confirmed
4. Check provider payout created
5. Check notifications sent

### 3. Monitor Logs
```bash
# Watch function logs
supabase functions logs stripe-webhook --follow

# Check for errors
supabase functions logs create-checkout-session
```

## Security Checklist

- [ ] `STRIPE_SECRET_KEY` is live key (sk_live_)
- [ ] `STRIPE_WEBHOOK_SECRET` matches Stripe Dashboard
- [ ] Webhook URL uses HTTPS
- [ ] `stripe-webhook` deployed with `--no-verify-jwt`
- [ ] `create-checkout-session` requires authentication
- [ ] RLS policies protect payment data
- [ ] Service role key only used in Edge Functions
- [ ] No secrets in Flutter app bundle
- [ ] Webhook signature verification implemented
- [ ] Idempotency keys prevent duplicate charges

## Rollback Plan

### Database
```bash
# Revert last migration if needed
supabase migration down
# Or manually run rollback SQL
```

### Edge Functions
```bash
# Redeploy previous version
supabase functions deploy create-checkout-session
supabase functions deploy stripe-webhook --no-verify-jwt
```

### Flutter App
- Revert to previous app store version
- Or push hotfix release

## Monitoring

### Key Metrics
- Payment success rate
- Webhook delivery success rate
- Average payment processing time
- Failed payment reasons

### Alerting
Set up alerts for:
- Webhook failure rate > 1%
- Payment success rate < 95%
- Edge Function errors > 0

## Stripe Live Mode Checklist

- [ ] Business verification complete
- [ ] Bank account configured
- [ ] Statement descriptor set
- [ ] Webhook endpoints registered
- [ ] Test mode disabled
- [ ] Radar rules configured (if needed)
- [ ] Payout schedule configured

## Support Contacts

- Supabase: https://supabase.com/support
- Stripe: https://support.stripe.com
- Flutter: https://flutter.dev/community