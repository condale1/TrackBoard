create table public.bands (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.band_members (
  band_id uuid not null references public.bands(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (band_id, user_id)
);

create table public.band_invites (
  token uuid primary key default gen_random_uuid(),
  band_id uuid not null references public.bands(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days')
);

alter table public.projects add column band_id uuid references public.bands(id) on delete cascade;

do $$
declare
  project_row record;
  new_band uuid;
begin
  for project_row in
    select id, name, created_by from public.projects where band_id is null
  loop
    insert into public.bands (name, created_by)
    values (left(project_row.name || ' Band', 60), project_row.created_by)
    returning id into new_band;

    update public.projects set band_id = new_band where id = project_row.id;

    insert into public.band_members (band_id, user_id, role)
    select new_band, project_member.user_id, project_member.role
    from public.project_members as project_member
    where project_member.project_id = project_row.id;

    insert into public.band_members (band_id, user_id, role)
    values (new_band, project_row.created_by, 'owner')
    on conflict (band_id, user_id) do update set role = 'owner';
  end loop;
end;
$$;

alter table public.projects alter column band_id set not null;
create index projects_band_created_idx on public.projects(band_id, created_at);
create index band_members_user_idx on public.band_members(user_id, band_id);
create index band_invites_band_idx on public.band_invites(band_id);

create function public.is_band_member(target_band uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.band_members
    where band_id = target_band and user_id = auth.uid()
  );
$$;

create or replace function public.is_project_member(target_project uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.projects as project
    join public.band_members as membership on membership.band_id = project.band_id
    where project.id = target_project and membership.user_id = auth.uid()
  );
$$;

create or replace function public.is_project_owner(target_project uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.projects as project
    join public.band_members as membership on membership.band_id = project.band_id
    where project.id = target_project and membership.user_id = auth.uid() and membership.role = 'owner'
  );
$$;

create function public.create_band(band_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_band uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to create a band.';
  end if;
  if char_length(trim(band_name)) not between 1 and 60 then
    raise exception 'Band names must be between 1 and 60 characters.';
  end if;

  insert into public.bands (name, created_by)
  values (trim(band_name), auth.uid())
  returning id into new_band;

  insert into public.band_members (band_id, user_id, role)
  values (new_band, auth.uid(), 'owner');

  return new_band;
end;
$$;

create function public.create_project_in_band(target_band uuid, project_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_project uuid;
begin
  if not public.is_band_member(target_band) then
    raise exception 'You are not a member of this band.';
  end if;
  if char_length(trim(project_name)) not between 1 and 60 then
    raise exception 'Project names must be between 1 and 60 characters.';
  end if;

  insert into public.projects (name, created_by, band_id)
  values (trim(project_name), auth.uid(), target_band)
  returning id into new_project;

  insert into public.project_members (project_id, user_id, role)
  values (new_project, auth.uid(), 'owner');

  insert into public.instruments (project_id, name, position)
  values
    (new_project, 'Drums', 0),
    (new_project, 'Bass', 1),
    (new_project, 'Guitar', 2),
    (new_project, 'Keys', 3),
    (new_project, 'Lead vocal', 4),
    (new_project, 'Backing vocals', 5);

  return new_project;
end;
$$;

create or replace function public.create_project(project_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_band uuid;
begin
  new_band := public.create_band(trim(project_name) || ' Band');
  return public.create_project_in_band(new_band, project_name);
end;
$$;

create or replace function public.join_project_with_invite(invite_token uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  invited_band uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to join a band.';
  end if;

  select band_id into invited_band
  from public.band_invites
  where token = invite_token and expires_at > now();

  if invited_band is null then
    select project.band_id into invited_band
    from public.project_invites as invite
    join public.projects as project on project.id = invite.project_id
    where invite.token = invite_token and invite.expires_at > now();
  end if;

  if invited_band is null then
    raise exception 'This invite link is invalid or has expired.';
  end if;

  insert into public.band_members (band_id, user_id, role)
  values (invited_band, auth.uid(), 'member')
  on conflict (band_id, user_id) do nothing;

  return invited_band;
end;
$$;

create function public.create_band_invite(target_band uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_token uuid;
begin
  if not public.is_band_member(target_band) then
    raise exception 'You are not a member of this band.';
  end if;

  insert into public.band_invites (band_id, created_by)
  values (target_band, auth.uid())
  returning token into new_token;

  return new_token;
end;
$$;

alter table public.bands enable row level security;
alter table public.band_members enable row level security;
alter table public.band_invites enable row level security;

create policy "Band members can view their bands" on public.bands
  for select using (public.is_band_member(id));
create policy "Band owners can rename their bands" on public.bands
  for update using (
    exists (select 1 from public.band_members where band_id = id and user_id = auth.uid() and role = 'owner')
  )
  with check (
    exists (select 1 from public.band_members where band_id = id and user_id = auth.uid() and role = 'owner')
  );
create policy "Band members can view memberships" on public.band_members
  for select using (public.is_band_member(band_id));

revoke all on public.bands, public.band_members, public.band_invites from anon, authenticated;
grant select on public.bands, public.band_members to authenticated;
grant update (name) on public.bands to authenticated;

revoke all on function public.create_band(text) from public, anon;
revoke all on function public.create_project_in_band(uuid, text) from public, anon;
revoke all on function public.create_project(text) from public, anon;
revoke all on function public.create_band_invite(uuid) from public, anon;
revoke all on function public.join_project_with_invite(uuid) from public, anon;
revoke all on function public.is_band_member(uuid) from public, anon;
grant execute on function public.create_band(text) to authenticated;
grant execute on function public.create_project_in_band(uuid, text) to authenticated;
grant execute on function public.create_project(text) to authenticated;
grant execute on function public.create_band_invite(uuid) to authenticated;
grant execute on function public.join_project_with_invite(uuid) to authenticated;
grant execute on function public.is_band_member(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bands'
  ) then
    alter publication supabase_realtime add table public.bands;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'band_members'
  ) then
    alter publication supabase_realtime add table public.band_members;
  end if;
end;
$$;
