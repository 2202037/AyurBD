import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.14.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "stripe-signature, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
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
      console.error("Missing stripe-signature header");
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
      console.error("Webhook signature verification failed:", err.message);
      return new Response(JSON.stringify({ error: "Invalid signature" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    console.log(`Received Stripe event: ${event.type}`);

    // Handle supported events
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        await handleCheckoutSessionCompleted(supabase, session);
        break;
      }
      case "checkout.session.expired": {
        const session = event.data.object as Stripe.Checkout.Session;
        await handleCheckoutSessionExpired(supabase, session);
        break;
      }
      case "payment_intent.payment_failed": {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        await handlePaymentIntentFailed(supabase, paymentIntent);
        break;
      }
      default:
        console.log(`Unhandled event type: ${event.type}`);
    }

    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("Webhook error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

async function handleCheckoutSessionCompleted(
  supabase: ReturnType<typeof createClient>,
  session: Stripe.Checkout.Session
) {
  const appointmentId = session.metadata?.appointment_id;
  const patientId = session.metadata?.patient_id;
  const providerId = session.metadata?.provider_id;

  if (!appointmentId || !patientId) {
    console.error("Missing metadata in checkout session");
    return;
  }

  const amount = session.amount_total ? session.amount_total / 100 : 0;

  if (!amount) {
    console.error("Invalid amount in checkout session");
    return;
  }

  console.log(`Processing successful payment for appointment ${appointmentId}`);

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
    console.error("record_payment_split error:", splitError);
    // Don't throw - let Stripe know we received the event
    return;
  }

  console.log("Payment split recorded:", payment);

  // Call confirm_appointment RPC
  const { data: appointment, error: confirmError } = await supabase.rpc(
    "confirm_appointment",
    {
      p_appointment_id: parseInt(appointmentId),
    }
  );

  if (confirmError) {
    console.error("confirm_appointment error:", confirmError);
    return;
  }

  console.log("Appointment confirmed:", appointment);
}

async function handleCheckoutSessionExpired(
  supabase: ReturnType<typeof createClient>,
  session: Stripe.Checkout.Session
) {
  const appointmentId = session.metadata?.appointment_id;
  const patientId = session.metadata?.patient_id;

  if (!appointmentId || !patientId) {
    console.error("Missing metadata in expired session");
    return;
  }

  console.log(`Checkout session expired for appointment ${appointmentId}`);

  // Call handle_failed_payment RPC
  const { error } = await supabase.rpc("handle_failed_payment", {
    p_appointment_id: parseInt(appointmentId),
    p_stripe_session_id: session.id,
    p_failure_reason: "Checkout session expired",
  });

  if (error) {
    console.error("handle_failed_payment error:", error);
  }
}

async function handlePaymentIntentFailed(
  supabase: ReturnType<typeof createClient>,
  paymentIntent: Stripe.PaymentIntent
) {
  const appointmentId = paymentIntent.metadata?.appointment_id;
  const patientId = paymentIntent.metadata?.patient_id;

  if (!appointmentId || !patientId) {
    console.error("Missing metadata in failed payment intent");
    return;
  }

  console.log(`Payment failed for appointment ${appointmentId}`);

  // Call handle_failed_payment RPC
  const { error } = await supabase.rpc("handle_failed_payment", {
    p_appointment_id: parseInt(appointmentId),
    p_stripe_session_id: paymentIntent.id,
    p_failure_reason: paymentIntent.last_payment_error?.message || "Payment failed",
  });

  if (error) {
    console.error("handle_failed_payment error:", error);
  }
}