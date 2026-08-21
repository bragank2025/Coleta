-- NK HUB Coleta: data original da venda para Base Venda/NF.
-- Execute uma vez no SQL Editor do projeto Supabase antes de reimportar a planilha.

alter table public.sales_invoice_refs
  add column if not exists sale_date date;

create index if not exists sales_invoice_refs_sale_date_idx
  on public.sales_invoice_refs (sale_date desc);
