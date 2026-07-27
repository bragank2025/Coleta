-- NK HUB Coleta - banco central, autenticação e políticas de acesso.
-- Execute este arquivo uma única vez no SQL Editor do projeto Supabase.

create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'nk_user_role') then
    create type public.nk_user_role as enum ('admin', 'operator', 'viewer');
  end if;
end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text,
  role public.nk_user_role not null default 'viewer',
  active boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles alter column role set default 'viewer';
alter table public.profiles alter column active set default false;
create unique index if not exists profiles_email_key on public.profiles(email);

create table if not exists public.collections (
  id uuid primary key default gen_random_uuid(),
  collection_code text not null unique,
  carrier text not null,
  plate text not null,
  driver text not null,
  helper text,
  operator_id uuid not null references public.profiles(id),
  operator_email text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'open' check (status in ('open', 'finished')),
  created_at timestamptz not null default now()
);

create table if not exists public.scans (
  id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references public.collections(id) on delete cascade,
  code_value text not null unique,
  code_type text not null check (code_type in ('Pedido', 'NF')),
  source text not null check (source in ('Câmera', 'Leitor externo', 'Digitação manual')),
  scanned_by uuid not null references public.profiles(id),
  scanned_by_email text not null,
  scanned_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint scans_code_format check (
    code_value ~ '^[0-9]{16}$' or code_value ~ '^[0-9]{44}$'
  )
);

create index if not exists collections_started_at_idx on public.collections(started_at desc);
create index if not exists collections_carrier_idx on public.collections(carrier);
create index if not exists collections_plate_idx on public.collections(plate);
create index if not exists collections_operator_id_idx on public.collections(operator_id);
create index if not exists scans_collection_id_idx on public.scans(collection_id);
create index if not exists scans_scanned_at_idx on public.scans(scanned_at desc);
create index if not exists scans_code_type_idx on public.scans(code_type);

create table if not exists public.sales_invoice_refs (
  id uuid primary key default gen_random_uuid(),
  marketplace text not null check (marketplace in ('SHOPEE', 'ML AUTOPARTS', 'ML AUTOPECAS')),
  venda text not null,
  nf text not null,
  sheet_name text not null,
  imported_by uuid references public.profiles(id),
  imported_by_email text,
  imported_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (marketplace, venda, nf)
);

create index if not exists sales_invoice_refs_venda_idx on public.sales_invoice_refs(venda);
create index if not exists sales_invoice_refs_nf_idx on public.sales_invoice_refs(nf);
create index if not exists sales_invoice_refs_marketplace_idx on public.sales_invoice_refs(marketplace);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(coalesce(new.email, ''), '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create or replace function public.current_user_role()
returns public.nk_user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles
  where id = (select auth.uid()) and active = true
  limit 1;
$$;

grant execute on function public.current_user_role() to authenticated;

create or replace function public.admin_update_profile(
  target_id uuid,
  new_role public.nk_user_role,
  new_active boolean,
  new_full_name text default null
)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_profile public.profiles;
begin
  if public.current_user_role() <> 'admin' then
    raise exception 'Apenas administradores podem alterar perfis.';
  end if;

  if target_id = (select auth.uid()) and (new_role <> 'admin' or new_active is not true) then
    raise exception 'Voce nao pode remover seu proprio acesso administrativo.';
  end if;

  update public.profiles
    set role = new_role,
        active = new_active,
        full_name = coalesce(new_full_name, full_name)
  where id = target_id
  returning * into updated_profile;

  if updated_profile.id is null then
    raise exception 'Perfil nao encontrado.';
  end if;

  return updated_profile;
end;
$$;

grant execute on function public.admin_update_profile(uuid, public.nk_user_role, boolean, text) to authenticated;

create or replace function public.admin_upsert_profile_by_email(
  target_email text,
  new_role public.nk_user_role,
  new_active boolean,
  new_full_name text default null
)
returns public.profiles
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  normalized_email text;
  target_user auth.users;
  updated_profile public.profiles;
begin
  if public.current_user_role() <> 'admin' then
    raise exception 'Apenas administradores podem liberar usuarios.';
  end if;

  normalized_email := lower(trim(target_email));

  select * into target_user
  from auth.users
  where lower(email) = normalized_email
  limit 1;

  if target_user.id is null then
    raise exception 'Usuario ainda nao existe no Auth. Crie com uma senha temporaria primeiro.';
  end if;

  if target_user.id = (select auth.uid()) and (new_role <> 'admin' or new_active is not true) then
    raise exception 'Voce nao pode remover seu proprio acesso administrativo.';
  end if;

  insert into public.profiles (id, email, full_name, role, active)
  values (
    target_user.id,
    coalesce(target_user.email, normalized_email),
    coalesce(new_full_name, target_user.raw_user_meta_data ->> 'full_name', split_part(coalesce(target_user.email, normalized_email), '@', 1)),
    new_role,
    new_active
  )
  on conflict (id) do update
    set email = excluded.email,
        full_name = coalesce(new_full_name, public.profiles.full_name),
        role = excluded.role,
        active = excluded.active
  returning * into updated_profile;

  return updated_profile;
end;
$$;

grant execute on function public.admin_upsert_profile_by_email(text, public.nk_user_role, boolean, text) to authenticated;

alter table public.profiles enable row level security;
alter table public.collections enable row level security;
alter table public.scans enable row level security;
alter table public.sales_invoice_refs enable row level security;

drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select"
on public.profiles for select to authenticated
using (id = (select auth.uid()) or public.current_user_role() = 'admin');

drop policy if exists "profiles_admin_update" on public.profiles;
drop policy if exists "profiles_no_direct_update" on public.profiles;
create policy "profiles_no_direct_update"
on public.profiles for update to authenticated
using (false)
with check (false);

drop policy if exists "collections_authenticated_select" on public.collections;
create policy "collections_authenticated_select"
on public.collections for select to authenticated
using (public.current_user_role() is not null);

drop policy if exists "collections_operator_insert" on public.collections;
create policy "collections_operator_insert"
on public.collections for insert to authenticated
with check (
  operator_id = (select auth.uid())
  and public.current_user_role() in ('admin', 'operator')
);

drop policy if exists "collections_owner_update" on public.collections;
create policy "collections_owner_update"
on public.collections for update to authenticated
using (
  operator_id = (select auth.uid())
  or public.current_user_role() = 'admin'
)
with check (
  operator_id = (select auth.uid())
  or public.current_user_role() = 'admin'
);

drop policy if exists "collections_admin_delete" on public.collections;
create policy "collections_admin_delete"
on public.collections for delete to authenticated
using (public.current_user_role() = 'admin');

drop policy if exists "scans_authenticated_select" on public.scans;
create policy "scans_authenticated_select"
on public.scans for select to authenticated
using (public.current_user_role() is not null);

drop policy if exists "scans_operator_insert" on public.scans;
create policy "scans_operator_insert"
on public.scans for insert to authenticated
with check (
  scanned_by = (select auth.uid())
  and public.current_user_role() in ('admin', 'operator')
);

drop policy if exists "scans_admin_delete" on public.scans;
create policy "scans_admin_delete"
on public.scans for delete to authenticated
using (public.current_user_role() = 'admin');

drop policy if exists "sales_invoice_refs_authenticated_select" on public.sales_invoice_refs;
create policy "sales_invoice_refs_authenticated_select"
on public.sales_invoice_refs for select to authenticated
using (public.current_user_role() is not null);

drop policy if exists "sales_invoice_refs_admin_insert" on public.sales_invoice_refs;
create policy "sales_invoice_refs_admin_insert"
on public.sales_invoice_refs for insert to authenticated
with check (
  public.current_user_role() = 'admin'
  and imported_by = (select auth.uid())
);

drop policy if exists "sales_invoice_refs_admin_update" on public.sales_invoice_refs;
create policy "sales_invoice_refs_admin_update"
on public.sales_invoice_refs for update to authenticated
using (public.current_user_role() = 'admin')
with check (public.current_user_role() = 'admin');

drop policy if exists "sales_invoice_refs_admin_delete" on public.sales_invoice_refs;
create policy "sales_invoice_refs_admin_delete"
on public.sales_invoice_refs for delete to authenticated
using (public.current_user_role() = 'admin');

grant usage on schema public to authenticated;
grant select on public.profiles, public.collections, public.scans, public.sales_invoice_refs to authenticated;
grant insert, update on public.collections to authenticated;
grant insert on public.scans to authenticated;
grant insert, update, delete on public.sales_invoice_refs to authenticated;
revoke update on public.profiles from authenticated;
grant delete on public.collections, public.scans to authenticated;

-- Depois de criar o primeiro usuário no painel Authentication > Users,
-- substitua o e-mail abaixo e execute para promovê-lo a administrador:
-- update public.profiles set role = 'admin' where email = 'seu-email@empresa.com';
