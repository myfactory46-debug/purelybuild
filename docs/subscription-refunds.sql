-- Apply in Supabase SQL Editor. Call only after PayPal webhook signature verification succeeds.
-- Full refund is matched to a previously verified, processed subscription sale by resource.sale_id.
create or replace function public.record_verified_subscription_refund_event(
  p_provider text,
  p_environment text,
  p_event jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id text := p_event->>'id';
  v_resource jsonb := p_event->'resource';
  v_refund_id text := p_event #>> '{resource,id}';
  v_sale_id text := p_event #>> '{resource,sale_id}';
  v_amount_text text := p_event #>> '{resource,amount,total}';
  v_currency text := p_event #>> '{resource,amount,currency}';
  v_original public.payment_events%rowtype;
  v_existing public.payment_events%rowtype;
  v_subscription public.subscriptions%rowtype;
begin
  if p_provider is distinct from 'paypal'
     or p_environment is distinct from 'sandbox'
     or p_event->>'event_type' is distinct from 'PAYMENT.SALE.REFUNDED'
     or v_resource->>'state' is distinct from 'completed'
     or nullif(v_event_id, '') is null
     or nullif(v_refund_id, '') is null
     or nullif(v_sale_id, '') is null
     or v_amount_text is null
     or v_amount_text !~ '^[0-9]+(\\.[0-9]{1,2})?$'
     or nullif(v_currency, '') is null then
    raise exception 'Invalid PayPal refund event';
  end if;

  select * into v_original
  from public.payment_events
  where provider = p_provider
    and environment = p_environment
    and provider_payment_id = v_sale_id
    and event_type = 'PAYMENT.SALE.COMPLETED'
    and verification_status = 'verified'
    and processing_status = 'processed'
  for update;

  if not found
     or v_original.provider_subscription_id is null
     or v_original.amount is distinct from v_amount_text::numeric
     or v_original.currency is distinct from v_currency
     or v_resource->>'custom' is distinct from
        v_original.raw_payload #>> '{resource,custom}'
     or p_event #>> '{resource,total_refunded_amount,value}'
        is distinct from v_amount_text
     or p_event #>> '{resource,refund_to_payer,value}'
        is distinct from v_amount_text then
    raise exception 'Refund does not match a verified full subscription sale';
  end if;

  select * into v_subscription
  from public.subscriptions
  where provider = p_provider
    and environment = p_environment
    and provider_subscription_id = v_original.provider_subscription_id
  for update;

  if not found then
    raise exception 'Subscription for refunded sale was not found';
  end if;

  insert into public.payment_events (
    provider, environment, provider_event_id, event_type, raw_payload,
    verification_status, processing_status, provider_subscription_id
  ) values (
    p_provider, p_environment, v_event_id, 'PAYMENT.SALE.REFUNDED',
    p_event, 'verified', 'received', v_original.provider_subscription_id
  )
  on conflict do nothing;

  select * into v_existing
  from public.payment_events
  where provider = p_provider
    and environment = p_environment
    and provider_event_id = v_event_id
  for update;

  if not found
     or v_existing.event_type is distinct from 'PAYMENT.SALE.REFUNDED'
     or v_existing.verification_status is distinct from 'verified'
     or v_existing.provider_subscription_id is distinct from
        v_original.provider_subscription_id then
    raise exception 'Conflicting refund event';
  end if;

  if v_existing.processing_status = 'processed' then
    return jsonb_build_object('outcome', 'duplicate',
                              'event_id', v_existing.id);
  end if;

  update public.subscriptions
  set status = 'needs_review',
      current_period_end = least(coalesce(current_period_end, now()), now()),
      updated_at = now()
  where id = v_subscription.id;

  update public.payment_events
  set normalized_event_type = 'subscription_payment_refunded',
      provider_payment_id = v_refund_id,
      amount = v_amount_text::numeric,
      currency = v_currency,
      processing_status = 'processed',
      processed_at = now()
  where id = v_existing.id;

  return jsonb_build_object(
    'outcome', 'processed',
    'event_id', v_existing.id,
    'subscription_id', v_original.provider_subscription_id
  );
end;
$$;

revoke all on function
  public.record_verified_subscription_refund_event(text, text, jsonb)
  from public, anon, authenticated;

grant execute on function
  public.record_verified_subscription_refund_event(text, text, jsonb)
  to service_role;
