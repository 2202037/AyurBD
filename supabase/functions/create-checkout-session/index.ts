import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.14.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
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
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const { appointment_id } = body;

    if (!appointment_id) {
      return new Response(JSON.stringify({ error: "appointment_id required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Fetch appointment with doctor info
    const { data: appointment, error: apptError } = await supabase
      .from("appointments")
      .select(
        "id, patient_id, doctor_id, fee, status, payment_status, doctor_name, appointment_date, appointment_time, doctors!left(user_id, consultation_fee)"
      )
      .eq("id", appointment_id)
      .eq("patient_id", user.id)
      .single();

    if (apptError || !appointment) {
      return new Response(JSON.stringify({ error: "Appointment not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Verify appointment is in pending_payment state
    if (appointment.status !== "pending_payment") {
      return new Response(
        JSON.stringify({ error: "Appointment is not awaiting payment" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Verify payment_status is pending
    if (appointment.payment_status !== "pending") {
      return new Response(
        JSON.stringify({ error: "Payment already processed" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const amount = appointment.fee;
    if (!amount || amount <= 0) {
      return new Response(JSON.stringify({ error: "Invalid amount" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

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

    // Check if user already has a Stripe customer ID (could store in users table or metadata)
    // For now, create a new customer each time or reuse from metadata
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
      success_url: `${Deno.env.get("APP_URL") || "http://localhost:3000"}/appointments/${appointment_id}?payment=success&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${Deno.env.get("APP_URL") || "http://localhost:3000"}/appointments/${appointment_id}?payment=cancelled`,
      metadata: {
        appointment_id: appointment_id.toString(),
        patient_id: user.id,
        provider_id: appointment.doctors?.user_id || "",
      },
      payment_intent_data: {
        metadata: {
          appointment_id: appointment_id.toString(),
          patient_id: user.id,
          provider_id: appointment.doctors?.user_id || "",
        },
      },
    });

    return new Response(
      JSON.stringify({
        checkout_url: session.url,
        session_id: session.id,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    console.error("Create checkout session error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});