-- Phase 9 subscription preparation. Run once in Supabase SQL Editor.
-- This migration does not activate the offer or start any PayPal subscription.
create table if not exists public.subscription_requests (
  id uuid primary key default gen_random_uuid(),
  checkout_request_id uuid not null,
  customer_id uuid not null references public.customers(id) on delete restrict,
  project_id bigint not null references public.projects(id) on delete restrict,
  offer_id uuid not null references public.offers(id) on delete restrict,
  provider text not null check (provider in ('paypal', 'stripe')),
  environment text not null check (environment in ('sandbox', 'live')),
  expected_plan_id text not null,
  expected_merchant_id text not null,
  expected_amount numeric(12,2) not null check (expected_amount > 0),
  currency text not null,
  billing_interval text not null,
  status text not null default 'pending' check (status in ('pending', 'linked', 'cancelled', 'expired', 'needs_review')),
  provider_subscription_id text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 minutes'),
  unique (customer_id, checkout_request_id),
  unique (provider, environment, provider_subscription_id)
);

create index if not exists subscription_requests_project_idx
  on public.subscription_requests(project_id, created_at desc);

alter table public.subscription_requests enable row level security;
revoke all on public.subscription_requests from anon, authenticated;

create or replace function public.start_subscription_request(
  p_project_id bigint,
  p_offer_id uuid,
  p_provider text,
  p_environment text,
  p_checkout_request_id uuid
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_project public.projects%rowtype;
  v_offer public.offers%rowtype;
  v_config public.offer_provider_configs%rowtype;
  v_request public.subscription_requests%rowtype;
begin
  if v_user is null or p_checkout_request_id is null then
    raise exception 'Authentication and request ID are required';
  end if;
  if p_provider <> 'paypal' or p_environment <> 'sandbox' then
    raise exception 'This subscription checkout is unavailable';
  end if;

  select * into v_project from public.projects
    where id = p_project_id and user_id = v_user and customer_id is not null;
  if not found or not exists (
    select 1 from public.customers where id = v_project.customer_id and status = 'active'
  ) then
    raise exception 'Project or active customer not found';
  end if;

  select * into v_request from public.subscription_requests
    where customer_id = v_project.customer_id and checkout_request_id = p_checkout_request_id;
  if found then
    if v_request.project_id <> p_project_id or v_request.offer_id <> p_offer_id
       or v_request.provider <> p_provider or v_request.environment <> p_environment then
      raise exception 'Request ID belongs to another checkout';
    end if;
    if v_request.status <> 'pending' or v_request.expires_at <= now() then
      raise exception 'Subscription request is no longer pending';
    end if;
    return jsonb_build_object('subscription_request_id', v_request.id,
      'plan_id', v_request.expected_plan_id, 'merchant_id', v_request.expected_merchant_id);
  end if;

  select * into v_offer from public.offers
    where id = p_offer_id and is_active and offer_type = 'subscription'
      and billing_interval = 'month' and amount > 0;
  if not found then raise exception 'Active monthly offer not found'; end if;

  select * into v_config from public.offer_provider_configs
    where offer_id = p_offer_id and provider = p_provider and environment = p_environment
      and is_active and nullif(trim(provider_plan_id), '') is not null
      and nullif(trim(merchant_id), '') is not null;
  if not found then raise exception 'Active subscription plan not found'; end if;

  if exists (
    select 1 from public.subscriptions where project_id = p_project_id
      and provider = p_provider and environment = p_environment
      and status in ('pending', 'active', 'past_due', 'grace_period', 'suspended', 'needs_review')
  ) then raise exception 'Project already has a subscription'; end if;

  insert into public.subscription_requests (
    checkout_request_id, customer_id, project_id, offer_id, provider, environment,
    expected_plan_id, expected_merchant_id, expected_amount, currency, billing_interval
  ) values (
    p_checkout_request_id, v_project.customer_id, p_project_id, p_offer_id, p_provider, p_environment,
    trim(v_config.provider_plan_id), trim(v_config.merchant_id), v_offer.amount,
    v_offer.currency, v_offer.billing_interval
  ) returning * into v_request;

  return jsonb_build_object('subscription_request_id', v_request.id,
    'plan_id', v_request.expected_plan_id, 'merchant_id', v_request.expected_merchant_id);
end;
$$;

revoke all on function public.start_subscription_request(bigint,uuid,text,text,uuid) from public, anon;
grant execute on function public.start_subscription_request(bigint,uuid,text,text,uuid) to authenticated;

create or replace function public.bind_subscription_request(
  p_request_id uuid,
  p_subscription_id text,
  p_plan_id text
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_request public.subscription_requests%rowtype;
  v_subscription public.subscriptions%rowtype;
begin
  if p_subscription_id is null or p_subscription_id !~ '^I-[A-Z0-9]+$' then
    raise exception 'Invalid provider subscription ID';
  end if;
  select * into v_request from public.subscription_requests
    where id = p_request_id for update;
  if not found or v_request.expires_at <= now() or v_request.status not in ('pending', 'linked') then
    raise exception 'Subscription request is unavailable';
  end if;
  if v_request.provider <> 'paypal' or v_request.environment <> 'sandbox'
     or p_plan_id is distinct from v_request.expected_plan_id then
    raise exception 'Subscription plan does not match request';
  end if;
  if v_request.status = 'linked' then
    if v_request.provider_subscription_id <> p_subscription_id then
      raise exception 'Request was linked to another subscription';
    end if;
    return jsonb_build_object('outcome', 'linked', 'subscription_id', p_subscription_id);
  end if;
  if exists (
    select 1 from public.subscriptions where project_id = v_request.project_id
      and provider = v_request.provider and environment = v_request.environment
      and status in ('pending', 'active', 'past_due', 'grace_period', 'suspended', 'needs_review')
  ) then raise exception 'Project already has a subscription'; end if;

  insert into public.subscriptions (
    customer_id, project_id, offer_id, provider, environment, provider_subscription_id, status
  ) values (
    v_request.customer_id, v_request.project_id, v_request.offer_id,
    v_request.provider, v_request.environment, p_subscription_id, 'pending'
  ) returning * into v_subscription;
  update public.subscription_requests set status = 'linked', provider_subscription_id = p_subscription_id
    where id = v_request.id;
  return jsonb_build_object('outcome', 'linked', 'subscription_id', p_subscription_id,
    'subscription_row_id', v_subscription.id);
end;
$$;

revoke all on function public.bind_subscription_request(uuid,text,text) from public, anon, authenticated;
grant execute on function public.bind_subscription_request(uuid,text,text) to service_role;
