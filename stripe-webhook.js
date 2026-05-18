// Cloudflare Pages Function — Stripe webhook
// URL : https://bovicalc-app.com/api/stripe-webhook
// Variables d'environnement requises (Cloudflare dashboard > Settings > Variables) :
//   STRIPE_SECRET_KEY         sk_live_...
//   STRIPE_WEBHOOK_SECRET     whsec_...
//   SUPABASE_URL              https://xxx.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY eyJ...

export async function onRequestPost(context) {
  const { request, env } = context;

  const body      = await request.text();
  const sigHeader = request.headers.get('stripe-signature') || '';

  // ── 1. Vérifier la signature Stripe ──────────────────────────
  const valid = await verifyStripeSignature(body, sigHeader, env.STRIPE_WEBHOOK_SECRET);
  if (!valid) {
    return new Response('Signature invalide', { status: 400 });
  }

  let event;
  try { event = JSON.parse(body); }
  catch { return new Response('JSON invalide', { status: 400 }); }

  const { type, data } = event;
  console.log('Stripe event:', type);

  try {
    // ── 2. Checkout réussi (nouveau paiement) ─────────────────
    if (type === 'checkout.session.completed') {
      const session = data.object;
      if (session.mode === 'subscription') {
        const email = session.customer_email || session.customer_details?.email;
        const sub   = await stripeGet(`/v1/subscriptions/${session.subscription}`, env.STRIPE_SECRET_KEY);
        await setUserPlan(env, email, 'pro', session.customer, session.subscription,
          new Date(sub.current_period_end * 1000).toISOString());
      }
    }

    // ── 3. Abonnement mis à jour (renouvellement, etc.) ───────
    else if (type === 'customer.subscription.updated') {
      const sub      = data.object;
      const customer = await stripeGet(`/v1/customers/${sub.customer}`, env.STRIPE_SECRET_KEY);
      const active   = ['active', 'trialing'].includes(sub.status);
      await setUserPlan(env, customer.email, active ? 'pro' : 'free',
        sub.customer, sub.id, new Date(sub.current_period_end * 1000).toISOString());
    }

    // ── 4. Abonnement résilié ─────────────────────────────────
    else if (type === 'customer.subscription.deleted') {
      const sub      = data.object;
      const customer = await stripeGet(`/v1/customers/${sub.customer}`, env.STRIPE_SECRET_KEY);
      await setUserPlan(env, customer.email, 'free', sub.customer, null, null);
    }

  } catch (err) {
    console.error('Erreur traitement:', err);
    return new Response('Erreur interne', { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

// ── Vérification signature Stripe (sans SDK) ─────────────────────
async function verifyStripeSignature(payload, header, secret) {
  try {
    const parts = Object.fromEntries(header.split(',').map(p => p.split('=')));
    const timestamp  = parts['t'];
    const signature  = parts['v1'];
    if (!timestamp || !signature) return false;

    const signed = `${timestamp}.${payload}`;
    const key = await crypto.subtle.importKey(
      'raw', new TextEncoder().encode(secret),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
    );
    const sig  = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(signed));
    const expected = Array.from(new Uint8Array(sig))
      .map(b => b.toString(16).padStart(2, '0')).join('');

    // Tolérance 5 min
    if (Math.abs(Date.now() / 1000 - parseInt(timestamp)) > 300) return false;
    return expected === signature;
  } catch { return false; }
}

// ── Appel API Stripe ─────────────────────────────────────────────
async function stripeGet(path, secretKey) {
  const res = await fetch(`https://api.stripe.com${path}`, {
    headers: { 'Authorization': `Bearer ${secretKey}` },
  });
  if (!res.ok) throw new Error(`Stripe ${path} → ${res.status}`);
  return res.json();
}

// ── Mettre à jour le plan dans Supabase ──────────────────────────
async function setUserPlan(env, email, plan, customerId, subscriptionId, periodEnd) {
  // Trouver le user_id par email via l'API Admin Supabase
  const usersRes = await fetch(`${env.SUPABASE_URL}/auth/v1/admin/users?per_page=1000`, {
    headers: {
      'Authorization': `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'apikey': env.SUPABASE_SERVICE_ROLE_KEY,
    },
  });
  const usersData = await usersRes.json();
  const user = (usersData.users || []).find(u => u.email === email);
  if (!user) { console.log('User non trouvé pour:', email); return; }

  // Upsert dans user_plans
  const payload = {
    user_id:                user.id,
    plan,
    stripe_customer_id:     customerId    || null,
    stripe_subscription_id: subscriptionId || null,
    current_period_end:     periodEnd     || null,
    updated_at:             new Date().toISOString(),
  };
  const upsertRes = await fetch(`${env.SUPABASE_URL}/rest/v1/user_plans`, {
    method:  'POST',
    headers: {
      'Authorization':  `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'apikey':         env.SUPABASE_SERVICE_ROLE_KEY,
      'Content-Type':   'application/json',
      'Prefer':         'resolution=merge-duplicates',
    },
    body: JSON.stringify(payload),
  });
  if (!upsertRes.ok) {
    const err = await upsertRes.text();
    throw new Error(`Supabase upsert error: ${err}`);
  }
  console.log(`Plan "${plan}" défini pour ${email}`);
}
