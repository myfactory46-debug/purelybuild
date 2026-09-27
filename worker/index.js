const SUPABASE_URL = 'https://zpxqetyrzpeleimnvzgq.supabase.co';
const SUPABASE_PUBLIC_KEY = 'sb_publishable_f8An8GUjq9__N2pzvfmsKg_nrPGnKKY';
const CHECKOUT_START_URL = 'https://purelybuild-agent.app.n8n.cloud/webhook/checkout-start';
const CHECKOUT_CAPTURE_URL = 'https://purelybuild-agent.app.n8n.cloud/webhook/checkout-capture';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}

async function supabaseGet(path, token) {
  const response = await fetch(`${SUPABASE_URL}${path}`, {
    headers: { apikey: SUPABASE_PUBLIC_KEY, authorization: `Bearer ${token}` },
  });
  if (!response.ok) throw new Error(`Supabase returned ${response.status}`);
  return response.json();
}

async function getUser(token) {
  try {
    const user = await supabaseGet('/auth/v1/user', token);
    return user?.id ? user : null;
  } catch {
    return null;
  }
}

function bearerToken(request) {
  return /^Bearer ([^\s]+)$/.exec(request.headers.get('authorization') || '')?.[1] || null;
}

async function startCheckout(request, env) {
  if (!env.N8N_CHECKOUT_INTERNAL_KEY) {
    return json({ error: 'Checkout is not configured' }, 503);
  }
  const token = bearerToken(request);
  if (!token) return json({ error: 'Sign in to continue' }, 401);

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'Invalid JSON' }, 400);
  }
  const { project_id: projectId, offer_id: offerId } = body || {};
  if ((!Number.isSafeInteger(projectId) || projectId <= 0) && !UUID.test(String(projectId))) {
    return json({ error: 'Invalid project ID' }, 400);
  }
  if (!UUID.test(String(offerId))) return json({ error: 'Invalid offer ID' }, 400);

  const user = await getUser(token);
  if (!user) return json({ error: 'Session expired. Sign in again' }, 401);

  const projectQuery = new URLSearchParams({ id: `eq.${projectId}`, user_id: `eq.${user.id}`, select: 'id', limit: '1' });
  const offerQuery = new URLSearchParams({ id: `eq.${offerId}`, is_active: 'eq.true', select: 'id,offer_type', limit: '1' });
  let projects, offers;
  try {
    [projects, offers] = await Promise.all([
      supabaseGet(`/rest/v1/projects?${projectQuery}`, token),
      supabaseGet(`/rest/v1/offers?${offerQuery}`, token),
    ]);
  } catch {
    return json({ error: 'Could not check project or offer' }, 502);
  }
  if (projects.length !== 1) return json({ error: 'Project not found' }, 404);
  if (offers.length !== 1 || offers[0].offer_type !== 'one_time') {
    return json({ error: 'Offer is unavailable for this checkout' }, 400);
  }

  let response;
  try {
    response = await fetch(CHECKOUT_START_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'X-Checkout-Internal-Key': env.N8N_CHECKOUT_INTERNAL_KEY },
      body: JSON.stringify({
        project_id: projectId,
        offer_id: offerId,
        provider: 'paypal',
        environment: 'sandbox',
        checkout_request_id: crypto.randomUUID(),
        checkout_return_origin: new URL(request.url).origin,
      }),
    });
  } catch {
    return json({ error: 'Checkout service is temporarily unavailable' }, 502);
  }
  if (!response.ok) return json({ error: 'Checkout could not start' }, 502);
  let result;
  try {
    result = await response.json();
  } catch {
    return json({ error: 'Invalid checkout response' }, 502);
  }
  const output = Array.isArray(result) ? result[0] : result;
  let approvalUrl;
  try {
    approvalUrl = new URL(output.approval_url);
  } catch {
    return json({ error: 'Invalid checkout response' }, 502);
  }
  if (approvalUrl.protocol !== 'https:' || !/(^|\.)paypal\.com$/.test(approvalUrl.hostname) || !output.attempt_id || !output.order_id) {
    return json({ error: 'Invalid checkout response' }, 502);
  }
  return json({ approval_url: approvalUrl.href, attempt_id: output.attempt_id, order_id: output.order_id });
}

async function ownedAttempt(token, userId, attemptId, orderId) {
  const attemptQuery = new URLSearchParams({
    id: `eq.${attemptId}`, provider_order_id: `eq.${orderId}`,
    provider: 'eq.paypal', environment: 'eq.sandbox',
    select: 'id,project_id,status,provider_order_id', limit: '1',
  });
  const attempts = await supabaseGet(`/rest/v1/payment_attempts?${attemptQuery}`, token);
  if (attempts.length !== 1) return null;
  const projectQuery = new URLSearchParams({
    id: `eq.${attempts[0].project_id}`, user_id: `eq.${userId}`, select: 'id', limit: '1',
  });
  const projects = await supabaseGet(`/rest/v1/projects?${projectQuery}`, token);
  return projects.length === 1 ? attempts[0] : null;
}

async function captureCheckout(request, env) {
  if (!env.N8N_CHECKOUT_INTERNAL_KEY) return json({ error: 'Checkout is not configured' }, 503);
  const token = bearerToken(request);
  if (!token) return json({ error: 'Sign in to continue' }, 401);
  let body;
  try { body = await request.json(); } catch { return json({ error: 'Invalid JSON' }, 400); }
  const attemptId = body?.attempt_id;
  const orderId = body?.order_id;
  if (!UUID.test(String(attemptId)) || !/^[A-Za-z0-9-]{10,40}$/.test(String(orderId))) {
    return json({ error: 'Invalid payment reference' }, 400);
  }
  const user = await getUser(token);
  if (!user) return json({ error: 'Session expired. Sign in again' }, 401);
  let attempt;
  try { attempt = await ownedAttempt(token, user.id, attemptId, orderId); }
  catch { return json({ error: 'Could not check payment attempt' }, 502); }
  if (!attempt) return json({ error: 'Payment attempt not found' }, 404);
  if (attempt.status === 'completed') return json({ outcome: 'completed' });
  if (attempt.status !== 'pending') return json({ outcome: attempt.status }, 409);

  let response;
  try {
    response = await fetch(CHECKOUT_CAPTURE_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'X-Checkout-Internal-Key': env.N8N_CHECKOUT_INTERNAL_KEY },
      body: JSON.stringify({ attempt_id: attemptId, order_id: orderId }),
    });
  } catch {
    return json({ error: 'Capture service is temporarily unavailable' }, 502);
  }
  if (!response.ok) return json({ error: 'Payment could not be confirmed' }, 502);
  return json({ outcome: 'processing' });
}

async function checkoutStatus(request) {
  const token = bearerToken(request);
  if (!token) return json({ error: 'Sign in to continue' }, 401);
  const { searchParams } = new URL(request.url);
  const attemptId = searchParams.get('attempt_id');
  const orderId = searchParams.get('order_id');
  if (!UUID.test(String(attemptId)) || !/^[A-Za-z0-9-]{10,40}$/.test(String(orderId))) {
    return json({ error: 'Invalid payment reference' }, 400);
  }
  const user = await getUser(token);
  if (!user) return json({ error: 'Session expired. Sign in again' }, 401);
  try {
    const attempt = await ownedAttempt(token, user.id, attemptId, orderId);
    return attempt ? json({ outcome: attempt.status }) : json({ error: 'Payment attempt not found' }, 404);
  } catch {
    return json({ error: 'Could not check payment status' }, 502);
  }
}

export default {
  async fetch(request, env) {
    const pathname = new URL(request.url).pathname;
    if (pathname === '/api/checkout/start') {
      if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
      return startCheckout(request, env);
    }
    if (pathname === '/api/checkout/capture') {
      if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
      return captureCheckout(request, env);
    }
    if (pathname === '/api/checkout/status') {
      if (request.method !== 'GET') return json({ error: 'Method not allowed' }, 405);
      return checkoutStatus(request);
    }
    if (pathname.startsWith('/api/')) return json({ error: 'Not found' }, 404);
    return env.ASSETS.fetch(request);
  },
};
