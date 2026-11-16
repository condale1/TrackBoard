alter table public.projects add column release_date date;

grant update (release_date) on public.projects to authenticated;
