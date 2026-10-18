-- Run once on the MonCommerce project. Existing catalogue/profile rows are preserved.
create table if not exists public.shop_snapshots (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default now()
);
alter table public.shop_snapshots enable row level security;
revoke all on public.shop_snapshots from anon;
grant select, insert, update on public.shop_snapshots to authenticated;
create policy shop_snapshot_read on public.shop_snapshots for select to authenticated using ((select auth.uid()) = owner_id);
create policy shop_snapshot_insert on public.shop_snapshots for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy shop_snapshot_update on public.shop_snapshots for update to authenticated using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);

create or replace function public.save_shop_snapshot(p_expected_revision bigint, p_payload jsonb)
returns bigint language plpgsql security invoker set search_path = '' as $$
declare next_revision bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if jsonb_typeof(p_payload) <> 'object' then raise exception 'Invalid payload'; end if;
  if p_expected_revision = 0 then
    insert into public.shop_snapshots(owner_id,payload,revision)
    values (auth.uid(),p_payload,1) on conflict (owner_id) do nothing returning revision into next_revision;
  else
    update public.shop_snapshots set payload = p_payload, revision = revision + 1, updated_at = now()
    where owner_id = auth.uid() and revision = p_expected_revision returning revision into next_revision;
  end if;
  if next_revision is null then raise exception 'Shop modified on another device' using errcode = '40001'; end if;
  return next_revision;
end;
$$;
revoke all on function public.save_shop_snapshot(bigint,jsonb) from public, anon;
grant execute on function public.save_shop_snapshot(bigint,jsonb) to authenticated;
