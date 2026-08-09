import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.14.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "stripe-signature, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

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

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY")!;
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: "2023-10-16",
    });

    // Create Supabase client with service role (bypasses RLS)
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
      event = stripe.webhooks.constructEvent(body, signature, webhookSecret);
    } catch (err) {
      const error = err as Error;
      logError("SIGNATURE_VERIFICATION_FAILED", { requestId, error: error.message }, error);
      return new Response(JSON.stringify({ error: "Invalid signature" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const appointmentId = event.data.object.metadata?.appointment_id;
    const patientId = event.data.object.metadata?.patient_id;
    const providerId = event.data.object.metadata?.provider_id;
    const stripeSessionId = (event.data.object as Stripe.Checkout.Session).id;
    const stripePaymentIntentId = (event.data.object as Stripe.Checkout.Session).payment_intent as string;

    logPayment("WEBHOOK_EVENT_RECEIVED", {
      requestId,
      eventType: event.type,
      signatureVerified: true,
      appointmentId: appointmentId ? parseInt(appointmentId) : undefined,
      patientId,
      providerId,
      stripeSessionId,
      stripePaymentIntentId,
      metadata: event.data.object.metadata,
    });

    // Handle supported events
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        await handleCheckoutSessionCompleted(supabase, session, requestId);
        break;
      }
      case "checkout.session.expired": {
        const session = event.data.object as Stripe.Checkout.Session;
        await handleCheckoutSessionExpired(supabase, session, requestId);
        break;
      }
      case "payment_intent.payment_failed": {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        await handlePaymentIntentFailed(supabase, paymentIntent, requestId);
        break;
      }
      default:
        logPayment("UNHANDLED_EVENT_TYPE", {
          requestId,
          eventType: event.type,
        });
    }

    logPayment("WEBHOOK_PROCESSED", {
      requestId,
      eventType: event.type,
      appointmentId: appointmentId ? parseInt(appointmentId) : undefined,
      durationMs: Date.now() - startTime,
    });

    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    const err = error as Error;
    logError("WEBHOOK_ERROR", { requestId, durationMs: Date.now() - startTime }, err);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

async function handleCheckoutSessionCompleted(
  supabase: ReturnType<typeof createClient>,
  session: Stripe.Checkout.Session,
  requestId: string
) {
  const appointmentId = session.metadata?.appointment_id;
  const patientId = session.metadata?.patient_id;
  const providerId = session.metadata?.provider_id;

  if (!appointmentId || !patientId) {
    logError("MISSING_METADATA", {
      requestId,
      sessionId: session.id,
      metadata: session.metadata,
    }, new Error("Missing metadata in checkout session"));
    return;
  }

  const amount = session.amount_total ? session.amount_total / 100 : 0;

  if (!amount) {
    logError("INVALID_AMOUNT", {
      requestId,
      sessionId: session.id,
      amountTotal: session.amount_total,
    }, new Error("Invalid amount in checkout session"));
    return;
  }

  logPayment("PROCESSING_SUCCESSFUL_PAYMENT", {
    requestId,
    appointmentId: parseInt(appointmentId),
    patientId,
    providerId,
    stripeSessionId: session.id,
    stripePaymentIntentId: session.payment_intent as string,
    amount,
  });

  // Call record_payment_split RPC
  const { data: payment, error: splitError } = await supabase.rpc(
    "record_payment_split",
    {
      p_appointment_id: parseInt(appointmentId),
      p_amount: amount,
      p_stripe_session_id: session.id,
      p_stripe_pi_id: session.payment_intent as string,
      p_stripe_customer_id: session.customer as string,
      p_patient_id: patientId,
    }
  );

  if (splitError) {
    logError("RPC_RECORD_PAYMENT_SPLIT_FAILED", {
      requestId,
      appointmentId: parseInt(appointmentId),
      patientId,
      stripeSessionId: session.id,
      error: splitError.message,
      details: splitError.details,
      hint: splitError.hint,
      code: splitError.code,
    }, new Error(splitError.message));

    logPayment("RPC_RESULT", {
      requestId,
      rpcName: "record_payment_split",
      appointmentId: parseInt(appointmentId),
      patientId,
      success: false,
      error: splitError.message,
    });
    // Don't throw - let Stripe know we received the event
    return;
  }

  logPayment("RPC_RESULT", {
    requestId,
    rpcName: "record_payment_split",
    appointmentId: parseInt(appointmentId),
    patientId,
    success: true,
    result: payment,
  });

  logPayment("PAYMENT_SPLIT_RECORDED", {
    requestId,
    appointmentId: parseInt(appointmentId),
    patientId,
    payment,
  });

  // Call confirm_appointment RPC
  const { data: appointment, error: confirmError } = await supabase.rpc(
    "confirm_appointment",
    {
      p_appointment_id: parseInt(appointmentId),
    }
  );

  if (confirmError) {
    logError("RPC_CONFIRM_APPOINTMENT_FAILED", {
      requestId,
      appointmentId: parseInt(appointmentId),
      patientId,
      error: confirmError.message,
      details: confirmError.details,
      hint: confirmError.hint,
      code: confirmError.code,
    }, new Error(confirmError.message));

    logPayment("RPC_RESULT", {
      requestId,
      rpcName: "confirm_appointment",
      appointmentId: parseInt(appointmentId),
      patientId,
      success: false,
      error: confirmError.message,
    });
    return;
  }

  logPayment("RPC_RESULT", {
    requestId,
    rpcName: "confirm_appointment",
    appointmentId: parseInt(appointmentId),
    patientId,
    success: true,
    result: appointment,
  });

  logPayment("APPOINTMENT_CONFIRMED", {
    requestId,
    appointmentId: parseInt(appointmentId),
    patientId,
    appointment,
  });

  // Log notifications (these are handled inside confirm_appointment RPC)
  logPayment("NOTIFICATION_SENT", {
    requestId,
    appointmentId: parseInt(appointmentId),
    patientId,
    type: "patient_confirmation",
    success: true,
  });
  logPayment("NOTIFICATION_SENT", {
    requestId,
    appointmentId: parseInt(appointmentId),
    patientId: providerId || "unknown",
    type: "doctor_confirmation",
    success: true,
  });
  logPayment("NOTIFICATION_SENT", {
    requestId,
    appointmentId: parseInt(appointmentId),
    patientId: "admin",
    type: "admin_payment_recorded",
    success: true,
  });

  logPayment("FINAL_STATE", {
    requestId,
    appointmentId: parseInt(appointmentId),
    patientId,
    status: appointment?.status,
    paymentStatus: appointment?.payment_status,
    stripeSessionId: session.id,
    stripePaymentIntentId: session.payment_intent as string,
    confirmationCode: appointment?.confirmation_code,
  });
}

async function handleCheckoutSessionExpired(
  supabase: ReturnType<typeof createClient>,
  session: Stripe.Checkout.Session,
  requestId: string
) {
  const appointmentId = session.metadata?.appointment_id;
  const patientId = session.metadata?.patient_id;

  if (!appointmentId || !patientId) {
    logError("MISSING_METADATA_EXPIRED", {
      requestId,
      sessionId: session.id,
      metadata: session.metadata,
    }, new Error("Missing metadata in expired session"));
    return;
  }

  logPayment("CHECKOUT_SESSION_EXPIRED", {
    requestId,
    appointmentId: parseInt(appointmentId),
    patientId,
    stripeSessionId: session.id,
  });

  // Call handle_failed_payment RPC
  const { error } = await supabase.rpc("handle_failed_payment", {
    p_appointment_id: parseInt(appointmentId),
    p_stripe_session_id: session.id,
    p_failure_reason: "Checkout session expired",
  });

  if (error) {
    logError("RPC_HANDLE_FAILED_PAYMENT_FAILED", {
      requestId,
      appointmentId: parseInt(appointmentId),
      patientId,
      error: error.message,
      details: error.details,
      hint: error.hint,
      code: error.code,
    }, new Error(error.message));

    logPayment("RPC_RESULT", {
      requestId,
      rpcName: "handle_failed_payment",
      appointmentId: parseInt(appointmentId),
      patientId,
      success: false,
      error: error.message,
    });
  } else {
    logPayment("RPC_RESULT", {
      requestId,
      rpcName: "handle_failed_payment",
      appointmentId: parseInt(appointmentId),
      patientId,
      success: true,
    });

    logPayment("NOTIFICATION_SENT", {
      requestId,
      appointmentId: parseInt(appointmentId),
      patientId,
      type: "payment_failed",
      success: true,
    });
  }
}

async function handlePaymentIntentFailed(
  supabase: ReturnType<typeof createClient>,
  paymentIntent: Stripe.PaymentIntent,
  requestId: string
) {
  const appointmentId = paymentIntent.metadata?.appointment_id;
  const patientId = paymentIntent.metadata?.patient_id;

  if (!appointmentId || !patientId) {
    logError("MISSING_METADATA_FAILED", {
      requestId,
      paymentIntentId: paymentIntent.id,
      metadata: paymentIntent.metadata,
    }, new Error("Missing metadata in failed payment intent"));
    return;
  }

  logPayment("PAYMENT_INTENT_FAILED", {
    requestId,
    appointmentId: parseInt(appointmentId),
    patientId,
    stripePaymentIntentId: paymentIntent.id,
    failureReason: paymentIntent.last_payment_error?.message || "Payment failed",
  });

  // Call handle_failed_payment RPC
  const { error } = await supabase.rpc("handle_failed_payment", {
    p_appointment_id: parseInt(appointmentId),
    p_stripe_session_id: paymentIntent.id,
    p_failure_reason: paymentIntent.last_payment_error?.message || "Payment failed",
  });

  if (error) {
    logError("RPC_HANDLE_FAILED_PAYMENT_FAILED", {
      requestId,
      appointmentId: parseInt(appointmentId),
      patientId,
      error: error.message,
      details: error.details,
      hint: error.hint,
      code: error.code,
    }, new Error(error.message));

    logPayment("RPC_RESULT", {
      requestId,
      rpcName: "handle_failed_payment",
      appointmentId: parseInt(appointmentId),
      patientId,
      success: false,
      error: error.message,
    });
  } else {
    logPayment("RPC_RESULT", {
      requestId,
      rpcName: "handle_failed_payment",
      appointmentId: parseInt(appointmentId),
      patientId,
      success: true,
    });

    logPayment("NOTIFICATION_SENT", {
      requestId,
      appointmentId: parseInt(appointmentId),
      patientId,
      type: "payment_failed",
      success: true,
    });
  }
}