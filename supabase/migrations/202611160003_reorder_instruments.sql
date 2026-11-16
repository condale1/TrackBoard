create function public.reorder_project_instruments(
  target_project uuid,
  ordered_instrument_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  instrument_count integer;
  distinct_count integer;
  position_offset integer;
begin
  if not public.is_project_member(target_project) then
    raise exception 'You are not a member of this project.';
  end if;

  perform 1 from public.projects where id = target_project for update;

  select count(*) into instrument_count
  from public.instruments where project_id = target_project;

  select count(distinct instrument_id) into distinct_count
  from unnest(coalesce(ordered_instrument_ids, '{}'::uuid[])) as submitted(instrument_id);

  if cardinality(coalesce(ordered_instrument_ids, '{}'::uuid[])) <> instrument_count
    or distinct_count <> instrument_count
    or exists (
      select 1
      from unnest(coalesce(ordered_instrument_ids, '{}'::uuid[])) as submitted(instrument_id)
      where not exists (
        select 1 from public.instruments instrument
        where instrument.id = submitted.instrument_id
          and instrument.project_id = target_project
      )
    ) then
    raise exception 'The instrument order must include each project instrument exactly once.';
  end if;

  select coalesce(max(position), -1) + instrument_count + 1
  into position_offset
  from public.instruments
  where project_id = target_project;

  update public.instruments
  set position = position + position_offset
  where project_id = target_project;

  update public.instruments as instrument
  set position = submitted.ordinality - 1
  from unnest(coalesce(ordered_instrument_ids, '{}'::uuid[])) with ordinality
    as submitted(instrument_id, ordinality)
  where instrument.id = submitted.instrument_id
    and instrument.project_id = target_project;
end;
$$;

revoke all on function public.reorder_project_instruments(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_project_instruments(uuid, uuid[]) to authenticated;
