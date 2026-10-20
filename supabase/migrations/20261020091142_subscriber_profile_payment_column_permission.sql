-- The editor always submits preferred_payment_method, including plate/spot-only edits.
-- Keep column-level privileges and the existing admin/manager RLS and guard trigger.
GRANT UPDATE (preferred_payment_method) ON public.monthly_subscribers TO authenticated;
