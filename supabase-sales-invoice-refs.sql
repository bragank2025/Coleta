-- NK HUB Coleta - base de referencia Venda/NF importada da planilha.
-- Execute no SQL Editor do Supabase uma vez antes de importar a planilha pelo painel admin.

create extension if not exists pgcrypto;

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

alter table public.sales_invoice_refs enable row level security;

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

grant select on public.sales_invoice_refs to authenticated;
grant insert, update, delete on public.sales_invoice_refs to authenticated;
