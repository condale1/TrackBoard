alter table public.songs
  add column mix_status text not null default 'not_started'
    check (mix_status in ('not_started', 'in_progress', 'done')),
  add column master_status text not null default 'not_started'
    check (master_status in ('not_started', 'in_progress', 'done'));

create policy "Members can update song production status" on public.songs
  for update using (public.is_project_member(project_id))
  with check (public.is_project_member(project_id));

grant update (mix_status, master_status) on public.songs to authenticated;
