import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.14.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/**
 * Build the Stripe `success_url` from the `APP_URL` Supabase secret.
 */
function buildSuccessUrl(appointmentId: string | number): string {
  return buildRedirectUrl(
    Deno.env.get("APP_URL") || "",
    `payment-success?appointment_id=${appointmentId}&session_id={CHECKOUT_SESSION_ID}`
  );
}

function buildCancelUrl(): string {
  return buildRedirectUrl(Deno.env.get("APP_URL") || "", "payment-cancelled");
}

/**
 * Join an `APP_URL` secret with a relative redirect path.
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

serve(async (req) => {
  const requestId = crypto.randomUUID();
  const startTime = Date.now();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY")!;

    const authHeader = req.headers.get("Authorization")!;
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
    const { appointment_id } = body;

    if (!appointment_id) {
      logError("VALIDATION_FAILED", { requestId, userId: user.id }, new Error("appointment_id required"));
      return errorResponse("VALIDATION_ERROR", "appointment_id required", 400, { field: "appointment_id" });
    }

    logPayment("CREATE_CHECKOUT_REQUEST", {
      requestId,
      appointmentId: appointment_id,
      patientId: user.id,
    });

    // Fetch appointment with doctor info
    const { data: appointment, error: apptError } = await supabase
      .from("appointments")
      .select(
        "id, patient_id, doctor_id, fee, status, payment_status, doctor_name, appointment_date, appointment_time, doctors!left(user_id, consultation_fee, commission_percentage)"
      )
      .eq("id", appointment_id)
      .eq("patient_id", user.id)
      .single();

    if (apptError || !appointment) {
      logError("APPOINTMENT_NOT_FOUND", { requestId, appointmentId: appointment_id, patientId: user.id }, apptError || new Error("Appointment not found"));
      return errorResponse("APPOINTMENT_NOT_FOUND", "Appointment not found", 404);
    }

    // Verify appointment is in pending_payment state
    if (appointment.status !== "pending_payment") {
      logError("INVALID_STATUS", {
        requestId,
        appointmentId: appointment_id,
        patientId: user.id,
        status: appointment.status,
        paymentStatus: appointment.payment_status,
      }, new Error(`Appointment status is ${appointment.status}, expected pending_payment`));
      return errorResponse(
        "INVALID_APPOINTMENT_STATUS",
        "Appointment is not awaiting payment",
        400,
        { current_status: appointment.status, expected_status: "pending_payment" }
      );
    }

    // Verify payment_status is pending
    if (appointment.payment_status !== "pending") {
      logError("INVALID_PAYMENT_STATUS", {
        requestId,
        appointmentId: appointment_id,
        patientId: user.id,
        status: appointment.status,
        paymentStatus: appointment.payment_status,
      }, new Error(`Payment status is ${appointment.payment_status}, expected pending`));
      return errorResponse(
        "PAYMENT_ALREADY_PROCESSED",
        "Payment already completed",
        400,
        { current_payment_status: appointment.payment_status }
      );
    }

    const amount = appointment.fee;
    if (!amount || amount <= 0) {
      logError("INVALID_AMOUNT", {
        requestId,
        appointmentId: appointment_id,
        patientId: user.id,
        fee: amount,
      }, new Error(`Invalid fee: ${amount}`));
      return errorResponse("INVALID_AMOUNT", "Invalid appointment fee", 400, { fee: amount });
    }

    // Validate doctor exists and has fee
    const doctor = appointment.doctors;
    if (!doctor) {
      logError("DOCTOR_NOT_FOUND", {
        requestId,
        appointmentId: appointment_id,
        patientId: user.id,
        doctorId: appointment.doctor_id,
      }, new Error("Doctor not found"));
      return errorResponse("DOCTOR_NOT_FOUND", "Doctor not found", 404);
    }

    if (!doctor.consultation_fee || doctor.consultation_fee <= 0) {
      logError("DOCTOR_FEE_MISSING", {
        requestId,
        appointmentId: appointment_id,
        patientId: user.id,
        doctorId: appointment.doctor_id,
      }, new Error("Doctor consultation fee not set"));
      return errorResponse("DOCTOR_FEE_MISSING", "Doctor fee not configured", 400);
    }

    // Validate Stripe configuration
    if (!stripeSecretKey) {
      logError("STRIPE_NOT_CONFIGURED", {
        requestId,
        appointmentId: appointment_id,
        patientId: user.id,
      }, new Error("STRIPE_SECRET_KEY not set"));
      return errorResponse("STRIPE_NOT_CONFIGURED", "Stripe is not configured", 500);
    }

    // Validate APP_URL configuration
    const appUrl = Deno.env.get("APP_URL");
    if (!appUrl) {
      logError("APP_URL_NOT_CONFIGURED", {
        requestId,
        appointmentId: appointment_id,
        patientId: user.id,
      }, new Error("APP_URL not set"));
      return errorResponse("APP_URL_NOT_CONFIGURED", "Application URL not configured", 500);
    }

    logPayment("APPOINTMENT_STATE_CHECK", {
      requestId,
      appointmentId: appointment_id,
      patientId: user.id,
      status: appointment.status,
      paymentStatus: appointment.payment_status,
      fee: amount,
      doctorExists: !!doctor,
      doctorFeeExists: !!doctor.consultation_fee,
      stripeConfigured: !!stripeSecretKey,
      appUrlConfigured: !!appUrl,
    });

    // Convert to poisha (smallest currency unit for BDT)
    const amountInPoisha = Math.round(amount * 100);

    // Initialize Stripe
    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: "2023-10-16",
    });

    // Get or create Stripe customer
    let stripeCustomerId: string;
    const { data: patient } = await supabase
      .from("users")
      .select("email, name, phone")
      .eq("id", user.id)
      .single();

    const customer = await stripe.customers.create({
      email: patient?.email || user.email,
      name: patient?.name || user.user_metadata?.full_name,
      phone: patient?.phone,
      metadata: {
        supabase_user_id: user.id,
      },
    });
    stripeCustomerId = customer.id;

    // Create Checkout Session
    const session = await stripe.checkout.sessions.create({
      customer: stripeCustomerId,
      payment_method_types: ["card"],
      line_items: [
        {
          price_data: {
            currency: "bdt",
            product_data: {
              name: `Appointment with ${appointment.doctor_name}`,
              description: `${appointment.appointment_date} at ${appointment.appointment_time}`,
            },
            unit_amount: amountInPoisha,
          },
          quantity: 1,
        },
      ],
      mode: "payment",
      success_url: buildSuccessUrl(appointment_id),
      cancel_url: buildCancelUrl(),
      metadata: {
        appointment_id: appointment_id.toString(),
        patient_id: user.id,
        provider_id: doctor.user_id || "",
      },
      payment_intent_data: {
        metadata: {
          appointment_id: appointment_id.toString(),
          patient_id: user.id,
          provider_id: doctor.user_id || "",
        },
      },
    });

    logPayment("STRIPE_REQUEST", {
      requestId,
      appointmentId: appointment_id,
      patientId: user.id,
      stripeSessionId: session.id,
      amountInPoisha,
      currency: "bdt",
    });

    logPayment("STRIPE_RESPONSE", {
      requestId,
      appointmentId: appointment_id,
      patientId: user.id,
      stripeSessionId: session.id,
      stripePaymentIntentId: session.payment_intent as string,
      checkoutUrl: session.url,
    });

    logPayment("FINAL_STATE", {
      requestId,
      appointmentId: appointment_id,
      patientId: user.id,
      status: appointment.status,
      paymentStatus: appointment.payment_status,
      stripeSessionId: session.id,
      stripePaymentIntentId: session.payment_intent as string,
      durationMs: Date.now() - startTime,
    });

    return successResponse({
      checkout_url: session.url,
      session_id: session.id,
    });
  } catch (error) {
    const err = error as Error;
    logError("UNEXPECTED_ERROR", { requestId, durationMs: Date.now() - startTime }, err);
    return errorResponse(
      "UNEXPECTED_SERVER_ERROR",
      "An unexpected error occurred",
      500,
      { error: err.message }
    );
  }
});