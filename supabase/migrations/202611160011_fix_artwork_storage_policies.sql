drop policy if exists "Band members can view release artwork" on storage.objects;
drop policy if exists "Band members can upload release artwork" on storage.objects;
drop policy if exists "Band members can replace release artwork" on storage.objects;
drop policy if exists "Band members can remove release artwork" on storage.objects;

create policy "Band members can view release artwork" on storage.objects
  for select to authenticated using (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(storage.objects.name))[1]
        and public.is_project_member(project.id)
    )
  );

create policy "Band members can upload release artwork" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(storage.objects.name))[1]
        and public.is_project_member(project.id)
    )
  );

create policy "Band members can replace release artwork" on storage.objects
  for update to authenticated using (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(storage.objects.name))[1]
        and public.is_project_member(project.id)
    )
  ) with check (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(storage.objects.name))[1]
        and public.is_project_member(project.id)
    )
  );

create policy "Band members can remove release artwork" on storage.objects
  for delete to authenticated using (
    bucket_id = 'release-artwork'
    and exists (
      select 1 from public.projects as project
      where project.id::text = (storage.foldername(storage.objects.name))[1]
        and public.is_project_member(project.id)
    )
  );
