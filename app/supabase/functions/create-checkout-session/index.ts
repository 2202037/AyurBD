// =====================================================================
// create-checkout-session
//
// Starts a Stripe Checkout for an appointment.
//
// WHAT CHANGED AND WHY
//   This function used to decide for itself whether an appointment could
//   be paid:
//
//       if (appointment.status !== "pending_payment") -> 400
//           "Appointment is not awaiting payment"
//
//   That is the exact error the user reported. It was wrong in two ways.
//   First, the comparison depended on a trigger side effect:
//   guard_appointments_insert re-stamped every new booking to 'pending',
//   so the state this function demanded could never be reached. Second,
//   payability is a rule about money and must be enforced where the money
//   lives. A check in an Edge Function is advisory -- it cannot stop the
//   PostgREST endpoints, and it drifts from the database the moment
//   either side changes.
//
//   Payability is now a database predicate. This function asks
//   public.gateway_payment_begin(), which:
//     * re-checks ownership (the patient may only pay their own booking),
//     * takes an advisory lock on the appointment,
//     * asserts payability through public.assert_appointment_payable(),
//     * and returns a live payment_sessions row -- reusing an existing
//       one when the patient taps twice.
//
//   So a double tap now returns the SAME Stripe page instead of minting a
//   second Customer and a second Session, and the failure messages the
//   patient sees are written once, in SQL, next to the rule they describe.
//
// The function keeps its response shape ({ success, data:{ checkout_url,
// session_id } } / { success:false, code, message, details }) because
// AppointmentRepository.createStripeCheckoutSession() reads exactly that.
// =====================================================================

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.14.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** How long a checkout attempt stays reusable and its Stripe page stays
 *  open. This is also the Stripe Checkout `expires_at`, which Stripe
 *  refuses when it is less than 30 minutes from creation — the previous
 *  value of 25 minutes was below that floor, so every checkout call was
 *  rejected with a StripeInvalidRequestError. Kept as one value so the
 *  payment_sessions row and the hosted page expire together. */
const REUSE_WINDOW_MINUTES = 45;

/**
 * Build the Stripe `success_url` for a specific client.
 *
 * `returnTarget` is what the Flutter client asked for and has already been
 * through `resolveReturnTarget()`, so it is one of the configured origins or
 * the mobile scheme — never raw user input.
 */
function buildSuccessUrl(returnTarget: string, appointmentId: string | number): string {
  return buildRedirectUrl(
    returnTarget,
    `payment-success?appointment_id=${appointmentId}&session_id={CHECKOUT_SESSION_ID}`
  );
}

function buildCancelUrl(returnTarget: string): string {
  return buildRedirectUrl(returnTarget, "payment-cancelled");
}

/**
 * Decide where Stripe returns this client to, and refuse anything unrecognised.
 *
 * A single global `APP_URL` cannot serve both platforms: set it to the web dev
 * origin and every Android user is redirected to `http://localhost:<port>`,
 * which on a phone is the phone; set it to `ayurbd` and no browser can follow
 * it. The client therefore states its own platform, and this function decides
 * whether to believe it.
 *
 * The allowlist is the point. `success_url` ends up in a redirect that carries
 * `session_id`, so accepting an arbitrary origin would let a caller aim that
 * redirect — and the id in it — at a host of their choosing. Only these are
 * accepted:
 *
 *   * the mobile custom scheme, `ayurbd`;
 *   * any origin listed in `APP_WEB_ORIGINS` (comma-separated);
 *   * `APP_URL`, kept so an existing single-secret deployment keeps working.
 *
 * Anything else falls back to `APP_URL` rather than failing the payment, which
 * is the same behaviour as before this parameter existed.
 */
function resolveReturnTarget(requested: unknown, appUrl: string): string {
  const fallback = appUrl.trim();
  if (typeof requested !== "string") return fallback;

  const want = requested.trim().replace(/\/+$/, "");
  if (!want) return fallback;

  // Mobile: a bare custom scheme, no host to validate.
  if (want === "ayurbd" || want === "ayurbd://") return "ayurbd";

  const allowed = new Set<string>();
  for (const raw of (Deno.env.get("APP_WEB_ORIGINS") || "").split(",")) {
    const o = raw.trim().replace(/\/+$/, "");
    if (o) allowed.add(o);
  }
  const configured = fallback.replace(/\/+$/, "");
  if (configured) allowed.add(configured);

  return allowed.has(want) ? want : fallback;
}

/**
 * Join a resolved return target with a relative redirect path.
 */
function buildRedirectUrl(appUrl: string, path: string): string {
  const base = appUrl.trim();
  if (base.startsWith("http://") || base.startsWith("https://")) {
    return `${base.replace(/\/+$/, "")}/#${path}`;
  }
  const scheme = base.split("://")[0];
  if (/^[a-z][a-z0-9+.-]*$/i.test(scheme)) {
    return `${scheme}://${path}`;
  }
  return `ayurbd://${path}`;
}

/**
 * Structured error response helper
 */
function errorResponse(
  code: string,
  message: string,
  status: number,
  details?: Record<string, unknown>
): Response {
  const body: Record<string, unknown> = {
    success: false,
    code,
    message,
  };
  if (details) body.details = details;
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/**
 * Success response helper
 */
function successResponse<T>(data: T): Response {
  return new Response(
    JSON.stringify({ success: true, data }),
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
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
    function: "create-checkout-session",
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
    function: "create-checkout-session",
    event: `ERROR: ${event}`,
    ...fields,
    error: error.message,
    stack: error.stack,
  };
  console.error(JSON.stringify(logEntry));
}

/**
 * Map a payability failure from the database onto an HTTP status and the
 * response `code` the Flutter client already understands.
 *
 * assert_appointment_payable() raises with the user-facing sentence as
 * the message and the machine code in DETAIL, which PostgREST surfaces as
 * `error.details`. We keep the database's wording: it is the single place
 * those sentences are written.
 */
function mapPayabilityError(
  err: { message?: string; details?: string; code?: string; hint?: string }
): { code: string; message: string; status: number } {
  const detail = (err.details || "").trim();
  const message = err.message || "This appointment cannot be paid right now.";

  switch (detail) {
    case "APPOINTMENT_NOT_FOUND":
      return { code: "APPOINTMENT_NOT_FOUND", message, status: 404 };
    case "ALREADY_PAID":
      return { code: "PAYMENT_ALREADY_PROCESSED", message, status: 409 };
    case "ALREADY_REFUNDED":
      return { code: "PAYMENT_ALREADY_PROCESSED", message, status: 409 };
    case "NO_FEE":
      return { code: "INVALID_AMOUNT", message, status: 400 };
    case "APPOINTMENT_NOT_PAYABLE":
      return { code: "INVALID_APPOINTMENT_STATUS", message, status: 409 };
  }

  // Not a payability verdict -- fall back on the SQLSTATE.
  if (err.code === "42501") {
    return { code: "FORBIDDEN", message, status: 403 };
  }
  if (err.code === "PGRST116") {
    return { code: "APPOINTMENT_NOT_FOUND", message, status: 404 };
  }
  return { code: "PAYMENT_START_FAILED", message, status: 400 };
}

serve(async (req) => {
  const requestId = crypto.randomUUID();
  const startTime = Date.now();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY")!;

    const authHeader = req.headers.get("Authorization")!;

    // The caller's own client. Every read and every RPC below runs as the
    // patient, so RLS stays the boundary rather than something this
    // function has to reimplement.
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();

    if (userError || !user) {
      logError("AUTH_FAILED", { requestId, userId: user?.id }, userError || new Error("No user"));
      return errorResponse("UNAUTHORIZED", "Unauthorized", 401);
    }

    const body = await req.json();
    const { appointment_id, return_target } = body;

    if (!appointment_id) {
      logError("VALIDATION_FAILED", { requestId, userId: user.id }, new Error("appointment_id required"));
      return errorResponse("VALIDATION_ERROR", "appointment_id required", 400, { field: "appointment_id" });
    }

    const appointmentId = typeof appointment_id === "number"
      ? appointment_id
      : parseInt(String(appointment_id), 10);

    if (!Number.isFinite(appointmentId)) {
      return errorResponse("VALIDATION_ERROR", "appointment_id must be a number", 400, {
        field: "appointment_id",
      });
    }

    logPayment("CREATE_CHECKOUT_REQUEST", {
      requestId,
      appointmentId,
      patientId: user.id,
    });

    // Configuration is checked before we touch the database so a
    // misconfigured deployment cannot leave a half-open session behind.
    if (!stripeSecretKey) {
      logError("STRIPE_NOT_CONFIGURED", { requestId, appointmentId, patientId: user.id },
        new Error("STRIPE_SECRET_KEY not set"));
      return errorResponse("STRIPE_NOT_CONFIGURED", "Online payment is temporarily unavailable.", 500);
    }

    const appUrl = Deno.env.get("APP_URL");
    if (!appUrl) {
      logError("APP_URL_NOT_CONFIGURED", { requestId, appointmentId, patientId: user.id },
        new Error("APP_URL not set"));
      return errorResponse("APP_URL_NOT_CONFIGURED", "Online payment is temporarily unavailable.", 500);
    }

    // Which frontend to return this caller to. Validated against the
    // allowlist, so a forged value cannot redirect the session id off-site.
    const returnTarget = resolveReturnTarget(return_target, appUrl);

    // -----------------------------------------------------------------
    // 1. Ask the database whether this payment may start, and claim the
    //    one live checkout slot for this appointment.
    //
    //    This single call replaces the old status / payment_status / fee
    //    checks. It is authoritative, it is the same rule the INSERT
    //    guard on `payments` applies, and it cannot be skipped by talking
    //    to PostgREST directly.
    // -----------------------------------------------------------------
    const { data: begun, error: beginError } = await supabase.rpc("gateway_payment_begin", {
      p_appointment_id: appointmentId,
      p_gateway: "stripe",
      p_reuse_window: `${REUSE_WINDOW_MINUTES} minutes`,
    });

    if (beginError) {
      const mapped = mapPayabilityError(beginError);
      logError("PAYMENT_BEGIN_REJECTED", {
        requestId,
        appointmentId,
        patientId: user.id,
        sqlstate: beginError.code,
        detail: beginError.details,
        mappedCode: mapped.code,
        httpStatus: mapped.status,
      }, new Error(beginError.message));
      return errorResponse(mapped.code, mapped.message, mapped.status, {
        reason: beginError.details || undefined,
      });
    }

    const session_row_id = begun?.session_row_id as string;
    const appointment = (begun?.appointment ?? {}) as Record<string, unknown>;
    const amount = Number(begun?.amount ?? appointment.amount ?? 0);

    logPayment("APPOINTMENT_STATE_CHECK", {
      requestId,
      appointmentId,
      patientId: user.id,
      status: appointment.status,
      fee: amount,
      paymentSessionId: session_row_id,
      reuse: begun?.reuse === true,
      stripeConfigured: true,
      appUrlConfigured: true,
    });

    // -----------------------------------------------------------------
    // 2. Idempotency: a live attempt is handed back, not duplicated.
    //
    //    Repeated taps, a return to the screen, or a retry after the
    //    response was lost all land here and get the same hosted page.
    // -----------------------------------------------------------------
    if (begun?.reuse === true && begun?.checkout_url) {
      logPayment("CHECKOUT_SESSION_REUSED", {
        requestId,
        appointmentId,
        patientId: user.id,
        paymentSessionId: session_row_id,
        stripeSessionId: begun?.gateway_ref,
        durationMs: Date.now() - startTime,
      });
      return successResponse({
        checkout_url: begun.checkout_url,
        session_id: begun.gateway_ref,
        reused: true,
      });
    }

    if (!amount || amount <= 0) {
      logError("INVALID_AMOUNT", { requestId, appointmentId, patientId: user.id, fee: amount },
        new Error(`Invalid fee: ${amount}`));
      return errorResponse("INVALID_AMOUNT", "This appointment has no fee to pay.", 400, { fee: amount });
    }

    // The provider's auth id rides along in Stripe metadata so the
    // webhook can attribute the payout without another lookup.
    let providerUserId = "";
    const doctorId = appointment.doctor_id;
    if (doctorId != null) {
      const { data: doctorRow } = await supabase
        .from("doctors")
        .select("user_id, consultation_fee")
        .eq("id", doctorId)
        .maybeSingle();
      providerUserId = (doctorRow?.user_id as string) || "";
    }

    // -----------------------------------------------------------------
    // 3. Create the hosted page.
    // -----------------------------------------------------------------
    const amountInPoisha = Math.round(amount * 100);
    const stripe = new Stripe(stripeSecretKey, { apiVersion: "2023-10-16" });

    const { data: patient } = await supabase
      .from("users")
      .select("email, name, phone")
      .eq("id", user.id)
      .single();

    // Reuse this patient's Stripe Customer if we have ever recorded one.
    // The old code created a fresh Customer on every single tap, which
    // littered the Stripe dashboard and lost the patient's saved details.
    let stripeCustomerId: string | undefined;
    const { data: priorPayment } = await supabase
      .from("payments")
      .select("stripe_customer_id")
      .eq("user_id", user.id)
      .not("stripe_customer_id", "is", null)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    stripeCustomerId = (priorPayment?.stripe_customer_id as string) || undefined;

    if (stripeCustomerId) {
      // A customer deleted in the Stripe dashboard would fail the session
      // call; fall back to creating a new one rather than erroring.
      try {
        const existing = await stripe.customers.retrieve(stripeCustomerId);
        if ((existing as { deleted?: boolean }).deleted) stripeCustomerId = undefined;
      } catch (_e) {
        stripeCustomerId = undefined;
      }
    }

    if (!stripeCustomerId) {
      const customer = await stripe.customers.create({
        email: patient?.email || user.email,
        name: patient?.name || user.user_metadata?.full_name,
        phone: patient?.phone,
        metadata: { supabase_user_id: user.id },
      });
      stripeCustomerId = customer.id;
    }

    const expiresAtSeconds = Math.floor(Date.now() / 1000) + REUSE_WINDOW_MINUTES * 60;

    const metadata = {
      appointment_id: String(appointmentId),
      patient_id: user.id,
      provider_id: providerUserId,
      payment_session_id: session_row_id ?? "",
    };

    const session = await stripe.checkout.sessions.create({
      customer: stripeCustomerId,
      payment_method_types: ["card"],
      client_reference_id: String(appointmentId),
      line_items: [
        {
          price_data: {
            currency: "bdt",
            product_data: {
              name: `Appointment with ${appointment.doctor_name ?? "your doctor"}`,
              description: `${appointment.appointment_date ?? ""} at ${appointment.appointment_time ?? ""}`.trim(),
            },
            unit_amount: amountInPoisha,
          },
          quantity: 1,
        },
      ],
      mode: "payment",
      // Stripe expires the page on the same clock as our payment_sessions
      // row, so the two cannot disagree about whether an attempt is live.
      expires_at: expiresAtSeconds,
      success_url: buildSuccessUrl(returnTarget, appointmentId),
      cancel_url: buildCancelUrl(returnTarget),
      metadata,
      payment_intent_data: { metadata },
    });

    logPayment("STRIPE_RESPONSE", {
      requestId,
      appointmentId,
      patientId: user.id,
      stripeSessionId: session.id,
      stripePaymentIntentId: session.payment_intent as string,
      checkoutUrl: session.url,
      amountInPoisha,
      currency: "bdt",
    });

    // -----------------------------------------------------------------
    // 4. Record the gateway identifiers against our session row.
    //
    //    Until this lands the row has no checkout_url, so
    //    gateway_payment_begin() treats it as an incomplete placeholder
    //    and a retry opens a clean attempt instead of getting stuck.
    // -----------------------------------------------------------------
    if (session_row_id && serviceRoleKey) {
      const admin = createClient(supabaseUrl, serviceRoleKey);
      const { error: attachError } = await admin.rpc("gateway_payment_attach", {
        p_session_row_id: session_row_id,
        p_gateway_ref: session.id,
        p_checkout_url: session.url,
        p_expires_at: new Date(expiresAtSeconds * 1000).toISOString(),
      });

      if (attachError) {
        // Not fatal: the patient can still pay, and the webhook keys off
        // Stripe's own identifiers. Logged loudly because it means a
        // retry will open a second Stripe page.
        logError("PAYMENT_SESSION_ATTACH_FAILED", {
          requestId,
          appointmentId,
          patientId: user.id,
          paymentSessionId: session_row_id,
          stripeSessionId: session.id,
          sqlstate: attachError.code,
          detail: attachError.details,
        }, new Error(attachError.message));
      }
    } else if (!serviceRoleKey) {
      logError("SERVICE_ROLE_KEY_MISSING", { requestId, appointmentId },
        new Error("SUPABASE_SERVICE_ROLE_KEY not set; payment session not linked"));
    }

    logPayment("FINAL_STATE", {
      requestId,
      appointmentId,
      patientId: user.id,
      status: appointment.status,
      paymentSessionId: session_row_id,
      stripeSessionId: session.id,
      stripePaymentIntentId: session.payment_intent as string,
      durationMs: Date.now() - startTime,
    });

    return successResponse({
      checkout_url: session.url,
      session_id: session.id,
      reused: false,
    });
  } catch (error) {
    const err = error as Error;
    logError("UNEXPECTED_ERROR", { requestId, durationMs: Date.now() - startTime }, err);
    // The detail stays in the log; the client gets a sentence it can act
    // on. Raw database and Stripe text is never echoed to a patient.
    return errorResponse(
      "UNEXPECTED_SERVER_ERROR",
      "We could not start the payment. Please try again.",
      500
    );
  }
});