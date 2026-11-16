alter table public.projects
  add column release_checklist jsonb not null default '{"artwork":false,"tracklist":false,"credits":false,"metadata":false,"distribution":false,"announcement":false}'::jsonb
    check (jsonb_typeof(release_checklist) = 'object'),
  add column artwork_path text;

create policy "Band members can update release checklist and artwork" on public.projects
  for update using (public.is_project_member(id))
  with check (public.is_project_member(id));

grant update (release_checklist, artwork_path) on public.projects to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('release-artwork', 'release-artwork', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "Band members can view release artwork" on storage.objects
  for select to authenticated using (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(name))[1]
        and public.is_project_member(project.id)
    )
  );

create policy "Band members can upload release artwork" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(name))[1]
        and public.is_project_member(project.id)
    )
  );

create policy "Band members can replace release artwork" on storage.objects
  for update to authenticated using (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(name))[1]
        and public.is_project_member(project.id)
    )
  ) with check (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(name))[1]
        and public.is_project_member(project.id)
    )
  );

create policy "Band members can remove release artwork" on storage.objects
  for delete to authenticated using (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(name))[1]
        and public.is_project_member(project.id)
    )
  );
