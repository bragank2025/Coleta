-- NK HUB Coleta - vinculo Venda/NF no bipe e comprovante assinado.
-- Execute no SQL Editor do Supabase.

alter table public.collections add column if not exists signature_name text;
alter table public.collections add column if not exists signature_data_url text;
alter table public.collections add column if not exists signature_at timestamptz;

alter table public.scans add column if not exists marketplace text;
alter table public.scans add column if not exists venda text;
alter table public.scans add column if not exists nf text;

create index if not exists scans_marketplace_idx on public.scans(marketplace);
create index if not exists scans_venda_idx on public.scans(venda);
create index if not exists scans_nf_idx on public.scans(nf);

notify pgrst, 'reload schema';
