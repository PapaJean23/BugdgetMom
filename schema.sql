-- Exécuter une fois dans Supabase > SQL Editor.
-- NE PAS utiliser une clé service_role dans l'application.
create extension if not exists pgcrypto;

create table if not exists public.budget_households (
  id uuid primary key default gen_random_uuid(),
  invite_code text unique not null default encode(gen_random_bytes(24), 'hex'),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create table if not exists public.budget_members (
  household_id uuid not null references public.budget_households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key(household_id,user_id)
);
create table if not exists public.budget_state (
  household_id uuid primary key references public.budget_households(id) on delete cascade,
  revision bigint not null default 0,
  document jsonb not null default '{"categories":[],"accounts":[],"transactions":[],"overrides":{}}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.budget_households enable row level security;
alter table public.budget_members enable row level security;
alter table public.budget_state enable row level security;
-- Aucun accès direct aux données privées : uniquement via des RPC vérifiant auth.uid().
revoke all on public.budget_households, public.budget_members, public.budget_state from anon, authenticated;
grant usage on schema public to authenticated;

create or replace function public.budget_create_household()
returns table(household_id uuid, invite_code text)
language plpgsql security definer set search_path = '' as $$
declare h public.budget_households%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentification requise'; end if;
 if exists(select 1 from public.budget_members where user_id=auth.uid()) then
  raise exception 'Ce compte est déjà lié à un foyer';
 end if;
 insert into public.budget_households(created_by) values(auth.uid()) returning * into h;
 insert into public.budget_members(household_id,user_id) values(h.id,auth.uid());
 insert into public.budget_state(household_id) values(h.id);
 return query select h.id,h.invite_code;
end $$;

create or replace function public.budget_join_household(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare h uuid;
begin
 if auth.uid() is null then raise exception 'Authentification requise'; end if;
 if exists(select 1 from public.budget_members where user_id=auth.uid()) then
  raise exception 'Ce compte est déjà lié à un foyer';
 end if;
 select id into h from public.budget_households where invite_code=lower(trim(p_code));
 if h is null then raise exception 'Code de partage invalide'; end if;
 insert into public.budget_members(household_id,user_id) values(h,auth.uid());
 return h;
end $$;

create or replace function public.budget_my_household()
returns table(household_id uuid, invite_code text)
language sql security definer set search_path = '' as $$
 select h.id,h.invite_code from public.budget_households h
 join public.budget_members m on m.household_id=h.id
 where m.user_id=auth.uid() limit 1
$$;

create or replace function public.budget_get_state()
returns table(revision bigint, document jsonb)
language plpgsql security definer set search_path = '' as $$
declare h uuid;
begin
 select household_id into h from public.budget_members where user_id=auth.uid() limit 1;
 if h is null then raise exception 'Aucun foyer lié'; end if;
 return query select s.revision,s.document from public.budget_state s where s.household_id=h;
end $$;

create or replace function public.budget_save_state(p_expected_revision bigint,p_document jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare h uuid; n bigint;
begin
 select household_id into h from public.budget_members where user_id=auth.uid() limit 1;
 if h is null then raise exception 'Aucun foyer lié'; end if;
 if jsonb_typeof(p_document) <> 'object'
    or jsonb_typeof(p_document->'categories') <> 'array'
    or jsonb_typeof(p_document->'accounts') <> 'array'
    or jsonb_typeof(p_document->'transactions') <> 'array'
    or jsonb_typeof(p_document->'overrides') <> 'object'
    or length(p_document::text)>1500000 then
  raise exception 'Document invalide ou trop volumineux';
 end if;
 update public.budget_state set document=p_document, revision=revision+1, updated_at=now()
 where household_id=h and revision=p_expected_revision returning revision into n;
 if n is null then raise exception 'CONFLIT_REVISION'; end if;
 return n;
end $$;

revoke all on function public.budget_create_household(), public.budget_join_household(text), public.budget_my_household(), public.budget_get_state(), public.budget_save_state(bigint,jsonb) from public, anon;
grant execute on function public.budget_create_household(), public.budget_join_household(text), public.budget_my_household(), public.budget_get_state(), public.budget_save_state(bigint,jsonb) to authenticated;
