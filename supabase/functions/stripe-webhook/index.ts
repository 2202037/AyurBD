// =====================================================================
// stripe-webhook
//
// The authoritative record of what Stripe actually charged.
//
// WHAT CHANGED AND WHY
//
//   1. Failures are no longer swallowed.
//      Every RPC error used to be logged and followed by a bare
//      `return`, after which the function still answered 200. Stripe
//      treats 2xx as "delivered, never mention it again", so a payment
//      that failed to record was lost silently: money taken, appointment
//      never confirmed, and no retry. Transient failures now answer 5xx
//      so Stripe redelivers on its own backoff schedule.
//
//   2. Permanent failures are told apart from transient ones.
//      Answering 5xx for something that can never succeed -- an
//      appointment that no longer exists, a payment belonging to a
//      different booking -- would have Stripe retry for days. Those are
//      acknowledged with 2xx and logged at NEEDS_RECONCILIATION so they
//      surface in a query rather than in a retry storm.
//
//   3. Duplicate deliveries are harmless by construction.
//      Stripe delivers at least once, and a retry after a timeout is
//      normal. record_payment_split() is idempotent on
//      stripe_session_id, provider_payouts has ON CONFLICT DO NOTHING on
//      payment_id, and confirm_appointment() is a no-op once the booking
//      is confirmed. So the second delivery of an event does exactly
//      nothing and reports success.
//
//   4. The appointment is settled by the database, not by this file.
//      payments_apply_verification() fires on the INSERT that
//      record_payment_split() performs and moves the appointment to
//      'confirmed', splits the commission and writes the payout ledger
//      inside the same transaction. confirm_appointment() below is kept
//      as an assertion and a notification hook, not as the thing that
//      makes the payment real.
// =====================================================================

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.14.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "stripe-signature, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type PostgrestErrorLike = {
  message?: string;
  details?: string;
  hint?: string;
  code?: string;
};

/**
 * SQLSTATEs that mean "this will never succeed, stop retrying".
 *
 * Everything else -- a dropped connection, a deadlock, a statement
 * timeout, an unexpected exception -- is assumed retryable, because the
 * cost of one extra delivery is nothing and the cost of dropping a
 * successful charge is a patient who paid for nothing.
 */
const TERMINAL_SQLSTATES = new Set([
  "PGRST116", // no such appointment
  "42501",    // payment does not belong to this appointment
  "P0001",    // an explicit business rule: cancelled, superseded, mismatched
  "22023",    // malformed arguments from us
  "22P02",    // bad input syntax
]);

function isTerminal(err: PostgrestErrorLike | null | undefined): boolean {
  return !!err?.code && TERMINAL_SQLSTATES.has(err.code);
}

/**
 * Structured logging helper for Edge Functions
 */
function logPayment(
  event: string,
  fields: Record<string, unknown>
): void {
  const logEntry = {
    timestamp: new Date().toISOString(),
    function: "stripe-webhook",
    event,
    ...fields,
  };
  console.log(JSON.stringify(logEntry));
}

function logError(
  event: string,
  fields: Record<string, unknown>,
  error: Error
): void {
  const logEntry = {
    timestamp: new Date().toISOString(),
    function: "stripe-webhook",
    event: `ERROR: ${event}`,
    ...fields,
    error: error.message,
    stack: error.stack,
  };
  console.error(JSON.stringify(logEntry));
}

/**
 * Money was taken but our records disagree. This is the line to alert on:
 * nobody is going to retry it for us.
 */
function logNeedsReconciliation(
  fields: Record<string, unknown>,
  error: Error
): void {
  console.error(JSON.stringify({
    timestamp: new Date().toISOString(),
    function: "stripe-webhook",
    event: "NEEDS_RECONCILIATION",
    severity: "critical",
    ...fields,
    error: error.message,
  }));
}

/** The outcome of handling one event. `retry` asks Stripe to redeliver. */
type HandlerResult = { ok: boolean; retry: boolean; reason?: string };

const OK: HandlerResult = { ok: true, retry: false };
const done = (reason: string): HandlerResult => ({ ok: true, retry: false, reason });
const retryLater = (reason: string): HandlerResult => ({ ok: false, retry: true, reason });

serve(async (req) => {
  const requestId = crypto.randomUUID();
  const startTime = Date.now();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    logError("METHOD_NOT_ALLOWED", { requestId, method: req.method }, new Error("Method not allowed"));
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let eventType = "unknown";

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY")!;
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

    if (!webhookSecret) {
      // Without the secret we cannot tell a real Stripe call from a
      // forged one, and an unverified webhook is worse than no webhook.
      logError("WEBHOOK_SECRET_MISSING", { requestId },
        new Error("STRIPE_WEBHOOK_SECRET not set"));
      return new Response(JSON.stringify({ error: "Webhook not configured" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: "2023-10-16",
    });

    // Service role: the webhook is not acting for any signed-in user, and
    // the RPCs it calls are granted to service_role only.
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const signature = req.headers.get("stripe-signature");
    if (!signature) {
      logError("MISSING_SIGNATURE", { requestId }, new Error("Missing stripe-signature header"));
      return new Response(JSON.stringify({ error: "Missing signature" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.text();
    let event: Stripe.Event;

    try {
      // Authoritative verification: the payload is only trusted after the
      // signature checks out against our own secret. Nothing before this
      // line is allowed to influence the database.
      event = await stripe.webhooks.constructEventAsync(body, signature, webhookSecret);
    } catch (err) {
      const error = err as Error;
      logError("SIGNATURE_VERIFICATION_FAILED", { requestId, error: error.message }, error);
      return new Response(JSON.stringify({ error: "Invalid signature" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    eventType = event.type;
    const object = event.data.object as { id?: string; metadata?: Record<string, string> };

    logPayment("WEBHOOK_EVENT_RECEIVED", {
      requestId,
      eventId: event.id,
      eventType: event.type,
      signatureVerified: true,
      objectId: object?.id,
      appointmentId: object?.metadata?.appointment_id,
      patientId: object?.metadata?.patient_id,
      providerId: object?.metadata?.provider_id,
    });

    let result: HandlerResult = OK;

    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        result = await handleCheckoutSessionCompleted(supabase, session, requestId);
        break;
      }
      case "checkout.session.expired": {
        const session = event.data.object as Stripe.Checkout.Session;
        result = await handleCheckoutSessionExpired(supabase, session, requestId);
        break;
      }
      case "payment_intent.payment_failed": {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        result = await handlePaymentIntentFailed(supabase, paymentIntent, requestId);
        break;
      }
      default:
        logPayment("UNHANDLED_EVENT_TYPE", { requestId, eventId: event.id, eventType: event.type });
    }

    if (result.retry) {
      // 500 is deliberate: it is the only way to ask Stripe to deliver
      // this event again. The alternative is losing the charge.
      logError("WEBHOOK_RETRY_REQUESTED", {
        requestId,
        eventId: event.id,
        eventType: event.type,
        reason: result.reason,
        durationMs: Date.now() - startTime,
      }, new Error(result.reason || "handler asked for redelivery"));

      return new Response(
        JSON.stringify({ received: true, processed: false, retry: true, reason: result.reason }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    logPayment("WEBHOOK_PROCESSED", {
      requestId,
      eventId: event.id,
      eventType: event.type,
      outcome: result.reason ?? "ok",
      durationMs: Date.now() - startTime,
    });

    return new Response(JSON.stringify({ received: true, processed: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    const err = error as Error;
    logError("WEBHOOK_ERROR", { requestId, eventType, durationMs: Date.now() - startTime }, err);
    // Unknown failure: ask for redelivery rather than quietly dropping a
    // real payment. Duplicate deliveries are safe here by construction.
    return new Response(JSON.stringify({ received: true, processed: false, retry: true }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

async function handleCheckoutSessionCompleted(
  supabase: ReturnType<typeof createClient>,
  session: Stripe.Checkout.Session,
  requestId: string
): Promise<HandlerResult> {
  const appointmentIdRaw = session.metadata?.appointment_id;
  const patientId = session.metadata?.patient_id;
  const providerId = session.metadata?.provider_id;

  if (!appointmentIdRaw || !patientId) {
    // Nothing to retry against: the event carries no way to find the
    // booking. Acknowledge so Stripe stops, and shout in the log.
    logNeedsReconciliation({
      requestId,
      sessionId: session.id,
      paymentIntentId: session.payment_intent,
      amountTotal: session.amount_total,
      metadata: session.metadata,
    }, new Error("Checkout session completed with no appointment metadata"));
    return done("missing_metadata");
  }

  const appointmentId = parseInt(appointmentIdRaw, 10);

  // Only settle a session Stripe actually collected on. `complete` with
  // payment_status 'unpaid' happens for asynchronous methods and must not
  // confirm a booking.
  if (session.payment_status !== "paid" && session.payment_status !== "no_payment_required") {
    logPayment("CHECKOUT_COMPLETED_UNPAID", {
      requestId,
      appointmentId,
      patientId,
      sessionId: session.id,
      stripePaymentStatus: session.payment_status,
    });
    return done("session_not_paid");
  }

  const amount = session.amount_total ? session.amount_total / 100 : 0;

  if (!amount) {
    logNeedsReconciliation({
      requestId,
      appointmentId,
      patientId,
      sessionId: session.id,
      amountTotal: session.amount_total,
    }, new Error("Checkout session completed with no amount"));
    return done("invalid_amount");
  }

  logPayment("PROCESSING_SUCCESSFUL_PAYMENT", {
    requestId,
    appointmentId,
    patientId,
    providerId,
    stripeSessionId: session.id,
    stripePaymentIntentId: session.payment_intent as string,
    amount,
  });

  // record_payment_split() is the settlement. It is idempotent on
  // stripe_session_id, so a redelivered event returns the payment row
  // that already exists instead of charging the ledger twice.
  const { data: payment, error: splitError } = await supabase.rpc(
    "record_payment_split",
    {
      p_appointment_id: appointmentId,
      p_amount: amount,
      p_stripe_session_id: session.id,
      p_stripe_pi_id: session.payment_intent as string,
      p_stripe_customer_id: session.customer as string,
      p_patient_id: patientId,
    }
  );

  if (splitError) {
    const fields = {
      requestId,
      appointmentId,
      patientId,
      stripeSessionId: session.id,
      stripePaymentIntentId: session.payment_intent as string,
      amount,
      sqlstate: splitError.code,
      detail: splitError.details,
      hint: splitError.hint,
    };

    if (isTerminal(splitError)) {
      // The charge succeeded at Stripe but our rules refuse it -- for
      // example the appointment was cancelled while the patient was on
      // the hosted page. A human has to decide on a refund; retrying
      // cannot help.
      logNeedsReconciliation(fields, new Error(splitError.message));
      return done(`split_rejected:${splitError.code}`);
    }

    logError("RPC_RECORD_PAYMENT_SPLIT_FAILED", fields, new Error(splitError.message));
    return retryLater(`record_payment_split:${splitError.code ?? "unknown"}`);
  }

  logPayment("PAYMENT_SPLIT_RECORDED", {
    requestId,
    appointmentId,
    patientId,
    stripeSessionId: session.id,
    payment,
  });

  // The appointment is already confirmed by the trigger that fired on the
  // insert above. This call re-asserts that and drives the notifications;
  // it is a no-op when the booking is already confirmed.
  const { data: appointment, error: confirmError } = await supabase.rpc(
    "confirm_appointment",
    { p_appointment_id: appointmentId }
  );

  if (confirmError) {
    const fields = {
      requestId,
      appointmentId,
      patientId,
      stripeSessionId: session.id,
      sqlstate: confirmError.code,
      detail: confirmError.details,
      hint: confirmError.hint,
    };

    if (isTerminal(confirmError)) {
      // The money is recorded; only the confirmation step disagreed.
      // Flag it rather than making Stripe retry a settled payment.
      logNeedsReconciliation(fields, new Error(confirmError.message));
      return done(`confirm_rejected:${confirmError.code}`);
    }

    logError("RPC_CONFIRM_APPOINTMENT_FAILED", fields, new Error(confirmError.message));
    return retryLater(`confirm_appointment:${confirmError.code ?? "unknown"}`);
  }

  logPayment("APPOINTMENT_CONFIRMED", {
    requestId,
    appointmentId,
    patientId,
    providerId,
    appointment,
  });

  logPayment("FINAL_STATE", {
    requestId,
    appointmentId,
    patientId,
    status: (appointment as Record<string, unknown>)?.status,
    paymentStatus: (appointment as Record<string, unknown>)?.payment_status,
    stripeSessionId: session.id,
    stripePaymentIntentId: session.payment_intent as string,
    confirmationCode: (appointment as Record<string, unknown>)?.confirmation_code,
  });

  return OK;
}

async function handleCheckoutSessionExpired(
  supabase: ReturnType<typeof createClient>,
  session: Stripe.Checkout.Session,
  requestId: string
): Promise<HandlerResult> {
  const appointmentIdRaw = session.metadata?.appointment_id;
  const patientId = session.metadata?.patient_id;

  if (!appointmentIdRaw) {
    logError("MISSING_METADATA_EXPIRED", { requestId, sessionId: session.id, metadata: session.metadata },
      new Error("Missing metadata in expired session"));
    return done("missing_metadata");
  }

  const appointmentId = parseInt(appointmentIdRaw, 10);

  logPayment("CHECKOUT_SESSION_EXPIRED", {
    requestId,
    appointmentId,
    patientId,
    stripeSessionId: session.id,
  });

  return await closeFailedAttempt(
    supabase,
    appointmentId,
    session.id,
    "Checkout session expired",
    { requestId, patientId }
  );
}

async function handlePaymentIntentFailed(
  supabase: ReturnType<typeof createClient>,
  paymentIntent: Stripe.PaymentIntent,
  requestId: string
): Promise<HandlerResult> {
  const appointmentIdRaw = paymentIntent.metadata?.appointment_id;
  const patientId = paymentIntent.metadata?.patient_id;

  if (!appointmentIdRaw) {
    logError("MISSING_METADATA_FAILED", { requestId, paymentIntentId: paymentIntent.id, metadata: paymentIntent.metadata },
      new Error("Missing metadata in failed payment intent"));
    return done("missing_metadata");
  }

  const appointmentId = parseInt(appointmentIdRaw, 10);
  const reason = paymentIntent.last_payment_error?.message || "Payment failed";

  logPayment("PAYMENT_INTENT_FAILED", {
    requestId,
    appointmentId,
    patientId,
    stripePaymentIntentId: paymentIntent.id,
    failureReason: reason,
  });

  return await closeFailedAttempt(
    supabase,
    appointmentId,
    paymentIntent.id,
    reason,
    { requestId, patientId }
  );
}

/**
 * Retire the checkout attempt so the patient can start a clean one.
 *
 * handle_failed_payment() deliberately does NOT write a rejected payment
 * row and does NOT touch the appointment: a failed attempt leaves the
 * booking exactly where it was, awaiting payment, which is what makes
 * "try again" work.
 */
async function closeFailedAttempt(
  supabase: ReturnType<typeof createClient>,
  appointmentId: number,
  gatewayRef: string,
  reason: string,
  ctx: { requestId: string; patientId?: string }
): Promise<HandlerResult> {
  const { data, error } = await supabase.rpc("handle_failed_payment", {
    p_appointment_id: appointmentId,
    p_stripe_session_id: gatewayRef,
    p_failure_reason: reason,
  });

  if (error) {
    const fields = {
      requestId: ctx.requestId,
      appointmentId,
      patientId: ctx.patientId,
      gatewayRef,
      sqlstate: error.code,
      detail: error.details,
      hint: error.hint,
    };

    if (isTerminal(error)) {
      // Nothing was charged, so this is housekeeping rather than money.
      logError("RPC_HANDLE_FAILED_PAYMENT_REJECTED", fields, new Error(error.message));
      return done(`failed_payment_rejected:${error.code}`);
    }

    logError("RPC_HANDLE_FAILED_PAYMENT_FAILED", fields, new Error(error.message));
    return retryLater(`handle_failed_payment:${error.code ?? "unknown"}`);
  }

  logPayment("PAYMENT_ATTEMPT_CLOSED", {
    requestId: ctx.requestId,
    appointmentId,
    patientId: ctx.patientId,
    gatewayRef,
    result: data,
  });

  return OK;
}
