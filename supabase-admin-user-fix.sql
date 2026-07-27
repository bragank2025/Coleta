-- NK HUB Coleta - melhoria para liberar usuarios pelo painel Admin.
-- Execute no SQL Editor do Supabase.

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

-- Promove a Maria Gabriela a admin ativa.
insert into public.profiles (id, email, full_name, role, active)
select
  id,
  email,
  'Maria Gabriela',
  'admin',
  true
from auth.users
where lower(email) = lower('mariagabriela@autopecasnk.com.br')
on conflict (id) do update
set full_name = 'Maria Gabriela',
    role = 'admin',
    active = true;
