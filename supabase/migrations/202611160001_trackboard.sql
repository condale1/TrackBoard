create extension if not exists pgcrypto;

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.project_members (
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (project_id, user_id)
);

create table public.instruments (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 24),
  position integer not null check (position >= 0),
  unique (project_id, name),
  unique (project_id, position)
);

create table public.songs (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  position integer not null check (position >= 0),
  created_at timestamptz not null default now(),
  unique (project_id, position)
);

create table public.song_parts (
  song_id uuid not null references public.songs(id) on delete cascade,
  instrument_id uuid not null references public.instruments(id) on delete cascade,
  done boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (song_id, instrument_id)
);

create table public.project_invites (
  token uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days')
);

create index songs_project_position_idx on public.songs(project_id, position);
create index instruments_project_position_idx on public.instruments(project_id, position);
create index project_members_user_idx on public.project_members(user_id, project_id);
create index project_invites_project_idx on public.project_invites(project_id);

create function public.is_project_member(target_project uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.project_members
    where project_id = target_project and user_id = auth.uid()
  );
$$;

create function public.is_project_owner(target_project uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.project_members
    where project_id = target_project and user_id = auth.uid() and role = 'owner'
  );
$$;

create function public.create_project(project_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_project uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to create a project.';
  end if;
  if char_length(trim(project_name)) not between 1 and 60 then
    raise exception 'Project names must be between 1 and 60 characters.';
  end if;

  insert into public.projects (name, created_by)
  values (trim(project_name), auth.uid())
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

create function public.import_legacy_board(board_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  imported_project uuid;
  imported_song uuid;
  instrument_row record;
  song_row record;
  instrument_name text;
  song_name text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to import a board.';
  end if;
  if jsonb_typeof(board_data) is distinct from 'object'
    or jsonb_typeof(board_data->'instruments') is distinct from 'array'
    or jsonb_typeof(board_data->'songs') is distinct from 'array' then
    raise exception 'The saved board is not in a supported format.';
  end if;
  if jsonb_array_length(board_data->'instruments') > 30
    or jsonb_array_length(board_data->'songs') > 200 then
    raise exception 'The saved board is too large to import.';
  end if;
  if char_length(trim(board_data->>'project')) not between 1 and 60 then
    raise exception 'The saved project needs a name between 1 and 60 characters.';
  end if;

  imported_project := public.create_project(trim(board_data->>'project'));
  delete from public.instruments where project_id = imported_project;

  for instrument_row in
    select value, ordinality
    from jsonb_array_elements_text(board_data->'instruments') with ordinality
  loop
    instrument_name := trim(instrument_row.value);
    if char_length(instrument_name) not between 1 and 24 then
      raise exception 'Instrument names must be between 1 and 24 characters.';
    end if;
    insert into public.instruments (project_id, name, position)
    values (imported_project, instrument_name, instrument_row.ordinality - 1);
  end loop;

  for song_row in
    select value, ordinality
    from jsonb_array_elements(board_data->'songs') with ordinality
  loop
    if jsonb_typeof(song_row.value) <> 'object'
      or jsonb_typeof(song_row.value->'checks') <> 'array' then
      raise exception 'A saved song has an unsupported format.';
    end if;
    song_name := trim(song_row.value->>'name');
    if char_length(song_name) not between 1 and 60 then
      raise exception 'Song names must be between 1 and 60 characters.';
    end if;

    insert into public.songs (project_id, name, position)
    values (imported_project, song_name, song_row.ordinality - 1)
    returning id into imported_song;

    insert into public.song_parts (song_id, instrument_id, done)
    select imported_song, instrument.id,
      case
        when jsonb_typeof(song_row.value->'checks'->instrument.position) = 'boolean'
          then (song_row.value->'checks'->>instrument.position)::boolean
        else false
      end
    from public.instruments as instrument
    where instrument.project_id = imported_project;
  end loop;

  return imported_project;
end;
$$;

create function public.add_song(target_project uuid, song_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_song uuid;
  next_position integer;
begin
  if not public.is_project_member(target_project) then
    raise exception 'You are not a member of this project.';
  end if;
  if char_length(trim(song_name)) not between 1 and 60 then
    raise exception 'Song names must be between 1 and 60 characters.';
  end if;

  perform 1 from public.projects where id = target_project for update;
  select coalesce(max(position) + 1, 0) into next_position
  from public.songs where project_id = target_project;

  insert into public.songs (project_id, name, position)
  values (target_project, trim(song_name), next_position)
  returning id into new_song;

  insert into public.song_parts (song_id, instrument_id)
  select new_song, id from public.instruments where project_id = target_project;

  return new_song;
end;
$$;

create function public.add_instrument(target_project uuid, instrument_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_instrument uuid;
  next_position integer;
begin
  if not public.is_project_member(target_project) then
    raise exception 'You are not a member of this project.';
  end if;
  if char_length(trim(instrument_name)) not between 1 and 24 then
    raise exception 'Instrument names must be between 1 and 24 characters.';
  end if;

  perform 1 from public.projects where id = target_project for update;
  select coalesce(max(position) + 1, 0) into next_position
  from public.instruments where project_id = target_project;

  insert into public.instruments (project_id, name, position)
  values (target_project, trim(instrument_name), next_position)
  returning id into new_instrument;

  insert into public.song_parts (song_id, instrument_id)
  select id, new_instrument from public.songs where project_id = target_project;

  return new_instrument;
end;
$$;

create function public.create_project_invite(target_project uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_token uuid;
begin
  if not public.is_project_member(target_project) then
    raise exception 'You are not a member of this project.';
  end if;

  insert into public.project_invites (project_id, created_by)
  values (target_project, auth.uid())
  returning token into new_token;

  return new_token;
end;
$$;

create function public.join_project_with_invite(invite_token uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  invited_project uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to join a project.';
  end if;

  select project_id into invited_project
  from public.project_invites
  where token = invite_token and expires_at > now();

  if invited_project is null then
    raise exception 'This invite link is invalid or has expired.';
  end if;

  insert into public.project_members (project_id, user_id, role)
  values (invited_project, auth.uid(), 'member')
  on conflict (project_id, user_id) do nothing;

  return invited_project;
end;
$$;

alter table public.projects enable row level security;
alter table public.project_members enable row level security;
alter table public.instruments enable row level security;
alter table public.songs enable row level security;
alter table public.song_parts enable row level security;
alter table public.project_invites enable row level security;

create policy "Members can view their projects" on public.projects
  for select using (public.is_project_member(id));
create policy "Owners can rename projects" on public.projects
  for update using (public.is_project_owner(id)) with check (public.is_project_owner(id));
create policy "Owners can delete projects" on public.projects
  for delete using (public.is_project_owner(id));

create policy "Members can view project members" on public.project_members
  for select using (public.is_project_member(project_id));

create policy "Members can view project instruments" on public.instruments
  for select using (public.is_project_member(project_id));
create policy "Owners can remove project instruments" on public.instruments
  for delete using (public.is_project_owner(project_id));

create policy "Members can view project songs" on public.songs
  for select using (public.is_project_member(project_id));
create policy "Owners can remove project songs" on public.songs
  for delete using (public.is_project_owner(project_id));

create policy "Members can view song parts" on public.song_parts
  for select using (
    exists (select 1 from public.songs where songs.id = song_id and public.is_project_member(songs.project_id))
  );
create policy "Members can update song parts" on public.song_parts
  for update using (
    exists (select 1 from public.songs where songs.id = song_id and public.is_project_member(songs.project_id))
  )
  with check (
    updated_by = auth.uid()
    and exists (select 1 from public.songs where songs.id = song_id and public.is_project_member(songs.project_id))
  );

revoke all on public.projects, public.project_members, public.instruments, public.songs, public.song_parts, public.project_invites from anon, authenticated;
grant select on public.projects, public.project_members, public.instruments, public.songs, public.song_parts to authenticated;
grant update (name) on public.projects to authenticated;
grant delete on public.projects to authenticated;
grant delete on public.instruments, public.songs to authenticated;
grant update on public.song_parts to authenticated;

revoke all on function public.create_project(text) from public, anon;
revoke all on function public.import_legacy_board(jsonb) from public, anon;
revoke all on function public.add_song(uuid, text) from public, anon;
revoke all on function public.add_instrument(uuid, text) from public, anon;
revoke all on function public.create_project_invite(uuid) from public, anon;
revoke all on function public.join_project_with_invite(uuid) from public, anon;
revoke all on function public.is_project_member(uuid) from public, anon;
revoke all on function public.is_project_owner(uuid) from public, anon;

grant execute on function public.create_project(text) to authenticated;
grant execute on function public.import_legacy_board(jsonb) to authenticated;
grant execute on function public.add_song(uuid, text) to authenticated;
grant execute on function public.add_instrument(uuid, text) to authenticated;
grant execute on function public.create_project_invite(uuid) to authenticated;
grant execute on function public.join_project_with_invite(uuid) to authenticated;
grant execute on function public.is_project_member(uuid) to authenticated;
grant execute on function public.is_project_owner(uuid) to authenticated;

do $$
declare
  table_name text;
begin
  foreach table_name in array array['projects', 'project_members', 'instruments', 'songs', 'song_parts']
  loop
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = table_name
    ) then
      execute format('alter publication supabase_realtime add table public.%I', table_name);
    end if;
  end loop;
end;
$$;
