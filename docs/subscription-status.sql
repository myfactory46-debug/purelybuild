-- Read-only status RPC for the signed-in project owner.
create or replace function public.subscription_request_status(p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_request public.subscription_requests%rowtype;
  v_sub public.subscriptions%rowtype;
begin
  if auth.uid() is null or p_request_id is null then
    raise exception 'Authentication and request ID are required';
  end if;
  select r.* into v_request from public.subscription_requests r
    join public.projects p on p.id = r.project_id
    where r.id = p_request_id and p.user_id = auth.uid()
      and p.customer_id = r.customer_id;
  if not found then raise exception 'Subscription request not found'; end if;

  if v_request.provider_subscription_id is not null then
    select * into v_sub from public.subscriptions
      where provider = v_request.provider and environment = v_request.environment
        and provider_subscription_id = v_request.provider_subscription_id;
  end if;
  return jsonb_build_object(
    'request_status', v_request.status,
    'subscription_status', v_sub.status,
    'paid_through', v_sub.current_period_end,
    'payment_confirmed', coalesce(
      v_sub.status = 'active' and v_sub.current_period_end > now(), false)
  );
end;
$$;

revoke all on function public.subscription_request_status(uuid) from public, anon;
grant execute on function public.subscription_request_status(uuid) to authenticated;
