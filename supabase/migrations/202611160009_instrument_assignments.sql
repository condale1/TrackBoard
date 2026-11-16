alter table public.instruments add column assigned_to text;

update public.instruments as instrument
set assigned_to = assignments.assigned_to
from (
  select instrument_id, min(assigned_to) as assigned_to
  from public.song_parts
  where assigned_to is not null
  group by instrument_id
  having count(distinct assigned_to) = 1
) as assignments
where instrument.id = assignments.instrument_id;

alter table public.song_parts drop column assigned_to;

create policy "Members can assign project instruments" on public.instruments
  for update using (public.is_project_member(project_id))
  with check (public.is_project_member(project_id));

grant update (assigned_to) on public.instruments to authenticated;
