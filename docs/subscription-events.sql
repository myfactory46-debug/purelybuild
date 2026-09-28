-- Draft: apply only with the matching verified n8n workflow.
-- PayPal subscription details must be fetched server-side using the sandbox merchant OAuth token.
create unique index if not exists payment_events_subscription_sale_unique
  on public.payment_events(provider, environment, provider_payment_id)
  where normalized_event_type = 'subscription_payment_completed'
    and provider_payment_id is not null;

create or replace function public.record_verified_subscription_event(
  p_provider text, p_environment text, p_event jsonb, p_details jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_type text := p_event->>'event_type';
  v_event_id text := p_event->>'id';
  v_resource jsonb := p_event->'resource';
  v_sub_id text;
  v_sale_id text;
  v_amount_text text;
  v_currency text;
  v_request public.subscription_requests%rowtype;
  v_sub public.subscriptions%rowtype;
  v_existing public.payment_events%rowtype;
  v_record_id uuid;
  v_next timestamptz;
  v_paid_at timestamptz;
  v_outcome text := 'processed';
begin
  if p_provider <> 'paypal' or p_environment <> 'sandbox'
     or nullif(v_event_id, '') is null or v_resource is null
     or v_type not in (
       'PAYMENT.SALE.COMPLETED', 'PAYMENT.SALE.REFUNDED', 'PAYMENT.SALE.REVERSED',
       'BILLING.SUBSCRIPTION.ACTIVATED', 'BILLING.SUBSCRIPTION.CANCELLED',
       'BILLING.SUBSCRIPTION.SUSPENDED', 'BILLING.SUBSCRIPTION.EXPIRED',
       'BILLING.SUBSCRIPTION.PAYMENT.FAILED'
     ) then
    raise exception 'Invalid verified subscription event';
  end if;

  if v_type like 'PAYMENT.SALE.%' then
    v_sub_id := v_resource->>'billing_agreement_id';
    v_sale_id := v_resource->>'id';
  else
    v_sub_id := v_resource->>'id';
  end if;
  if v_sub_id is null or v_sub_id !~ '^I-[A-Z0-9]+$'
     or p_details->>'id' is distinct from v_sub_id then
    raise exception 'Subscription identity is missing or mismatched';
  end if;

  insert into public.payment_events (
    provider, environment, provider_event_id, event_type, raw_payload,
    verification_status, processing_status, provider_subscription_id
  ) values (
    p_provider, p_environment, v_event_id, v_type, p_event,
    'verified', 'received', v_sub_id
  ) on conflict do nothing;

  select * into v_existing from public.payment_events
    where provider = p_provider and environment = p_environment
      and provider_event_id = v_event_id for update;
  if not found then raise exception 'Could not record subscription event'; end if;
  if v_existing.verification_status <> 'verified'
     or v_existing.event_type <> v_type
     or (v_existing.provider_subscription_id is not null
         and v_existing.provider_subscription_id <> v_sub_id) then
    raise exception 'Conflicting event identity';
  end if;
  if v_existing.processing_status in ('processed', 'needs_review') then
    return jsonb_build_object('outcome', 'duplicate', 'event_id', v_existing.id);
  end if;
  v_record_id := v_existing.id;

  select * into v_sub from public.subscriptions
    where provider = p_provider and environment = p_environment
      and provider_subscription_id = v_sub_id for update;
  if not found then
    v_outcome := 'needs_review';
  else
    select * into v_request from public.subscription_requests
      where provider = p_provider and environment = p_environment
        and provider_subscription_id = v_sub_id and status = 'linked';
    if not found or p_details->>'plan_id' is distinct from v_request.expected_plan_id
       or p_details->>'custom_id' is distinct from v_request.id::text
       or v_sub.customer_id <> v_request.customer_id
       or v_sub.project_id <> v_request.project_id
       or v_sub.offer_id <> v_request.offer_id then
      v_outcome := 'needs_review';
    end if;
  end if;

  if v_outcome = 'processed' and v_type = 'PAYMENT.SALE.COMPLETED' then
    v_amount_text := coalesce(v_resource #>> '{amount,total}', v_resource #>> '{amount,value}');
    v_currency := coalesce(v_resource #>> '{amount,currency}', v_resource #>> '{amount,currency_code}');
    if v_sale_id is null or v_sale_id = ''
       or v_amount_text is null or v_amount_text !~ '^[0-9]+(\.[0-9]{1,2})?$'
       or v_amount_text::numeric <> v_request.expected_amount
       or v_currency is distinct from v_request.currency
       or p_details->>'status' <> 'ACTIVE'
       or coalesce(p_details #>> '{billing_info,last_payment,amount,value}', '')
          !~ '^[0-9]+(\.[0-9]{1,2})?$'
       or (case when coalesce(p_details #>> '{billing_info,last_payment,amount,value}', '')
                    ~ '^[0-9]+(\.[0-9]{1,2})?$'
                then (p_details #>> '{billing_info,last_payment,amount,value}')::numeric
                else null end) is distinct from v_request.expected_amount
       or p_details #>> '{billing_info,last_payment,amount,currency_code}' is distinct from v_currency
       or nullif(p_details #>> '{billing_info,next_billing_time}', '') is null
       or nullif(p_details #>> '{billing_info,last_payment,time}', '') is null
       or nullif(v_resource->>'create_time', '') is null
       or v_sub.status in ('cancelled', 'expired', 'needs_review') then
      v_outcome := 'needs_review';
    else
      v_next := (p_details #>> '{billing_info,next_billing_time}')::timestamptz;
      v_paid_at := (p_details #>> '{billing_info,last_payment,time}')::timestamptz;
      if v_next <= now() or v_paid_at > now() + interval '5 minutes'
         or abs(extract(epoch from (v_paid_at - (v_resource->>'create_time')::timestamptz))) > 600
         or exists (
           select 1 from public.payment_events
             where provider = p_provider and environment = p_environment
               and normalized_event_type = 'subscription_payment_completed'
               and provider_payment_id = v_sale_id and id <> v_record_id
         ) then
        v_outcome := 'needs_review';
      else
        update public.subscriptions set status = 'active',
          current_period_start = v_paid_at, current_period_end = v_next,
          grace_period_end = null, updated_at = now()
          where id = v_sub.id;
        update public.payment_events set
          normalized_event_type = 'subscription_payment_completed',
          provider_payment_id = v_sale_id, amount = v_amount_text::numeric,
          currency = v_currency where id = v_record_id;
      end if;
    end if;
  elsif v_outcome = 'processed' and v_type = 'BILLING.SUBSCRIPTION.ACTIVATED' then
    -- Approval alone does not prove a paid billing period.
    if v_sub.status = 'pending' then
      update public.subscriptions set updated_at = now() where id = v_sub.id;
    end if;
  elsif v_outcome = 'processed' and v_type = 'BILLING.SUBSCRIPTION.PAYMENT.FAILED' then
    if v_sub.status not in ('cancelled', 'expired', 'needs_review') then
      update public.subscriptions set status = 'past_due', updated_at = now()
        where id = v_sub.id;
    end if;
  elsif v_outcome = 'processed' and v_type in (
    'BILLING.SUBSCRIPTION.CANCELLED', 'BILLING.SUBSCRIPTION.SUSPENDED',
    'BILLING.SUBSCRIPTION.EXPIRED', 'PAYMENT.SALE.REFUNDED', 'PAYMENT.SALE.REVERSED'
  ) then
    update public.subscriptions set
      status = case v_type
        when 'BILLING.SUBSCRIPTION.CANCELLED' then 'cancelled'
        when 'BILLING.SUBSCRIPTION.SUSPENDED' then 'suspended'
        when 'BILLING.SUBSCRIPTION.EXPIRED' then 'expired'
        else 'needs_review' end,
      cancelled_at = case when v_type = 'BILLING.SUBSCRIPTION.CANCELLED'
        then now() else cancelled_at end,
      current_period_end = case when v_type in ('PAYMENT.SALE.REFUNDED', 'PAYMENT.SALE.REVERSED')
        then least(coalesce(current_period_end, now()), now()) else current_period_end end,
      updated_at = now() where id = v_sub.id;
  end if;

  update public.payment_events set processing_status = v_outcome,
    processed_at = now(), provider_subscription_id = v_sub_id,
    normalized_event_type = coalesce(normalized_event_type, lower(replace(v_type, '.', '_')))
    where id = v_record_id;
  return jsonb_build_object('outcome', v_outcome, 'event_id', v_record_id,
    'subscription_id', v_sub_id);
end;
$$;

revoke all on function public.record_verified_subscription_event(text,text,jsonb,jsonb)
  from public, anon, authenticated;
grant execute on function public.record_verified_subscription_event(text,text,jsonb,jsonb)
  to service_role;
