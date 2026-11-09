-- Allow an authenticated project owner to inspect only their project's attempts.
-- The payment workflows continue to write through their existing server credentials.
create policy "Project owners can read payment attempts"
on public.payment_attempts
for select
to authenticated
using (
  exists (
    select 1
    from public.projects as p
    where p.id = payment_attempts.project_id
      and p.user_id = (select auth.uid())
  )
);

grant select on public.payment_attempts to authenticated;
