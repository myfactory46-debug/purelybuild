-- Read-only inspection. Run in Supabase SQL Editor and export the result as CSV.
-- It lists the columns, constraints, and relevant function signatures needed to
-- integrate subscriptions with the existing customer/project authorization model.
with columns_and_constraints as (
  select 'column' as kind, c.table_name as object_name,
         c.column_name as detail,
         c.data_type || ' / nullable=' || c.is_nullable as definition
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name in ('customers', 'projects', 'subscriptions',
                         'offers', 'offer_provider_configs',
                         'payment_attempts', 'payment_events')
  union all
  select 'constraint', t.relname, con.conname,
         pg_get_constraintdef(con.oid)
  from pg_constraint con
  join pg_class t on t.oid = con.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public'
    and t.relname in ('customers', 'projects', 'subscriptions',
                      'offers', 'offer_provider_configs',
                      'payment_attempts', 'payment_events')
  union all
  select 'function', p.proname,
         pg_get_function_identity_arguments(p.oid),
         pg_get_function_result(p.oid)
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('start_payment_attempt', 'record_verified_payment_event',
                      'save_paypal_capture', 'prepare_payment_capture')
)
select kind, object_name, detail, definition
from columns_and_constraints
order by kind, object_name, detail;
