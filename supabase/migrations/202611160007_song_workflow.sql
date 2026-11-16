alter table public.songs
  add column recording_assignee text,
  add column recording_due_date date,
  add column mix_assignee text,
  add column mix_due_date date,
  add column master_assignee text,
  add column master_due_date date,
  add column notes text,
  add column reference_url text,
  add column mix_feedback text,
  add column master_feedback text;

alter table public.songs drop constraint if exists songs_mix_status_check;
update public.songs set mix_status = 'approved' where mix_status = 'done';
alter table public.songs add constraint songs_mix_status_check
  check (mix_status in ('not_started', 'in_progress', 'ready_for_review', 'changes_requested', 'approved'));
alter table public.songs drop constraint if exists songs_master_status_check;
update public.songs set master_status = 'approved' where master_status = 'done';
alter table public.songs add constraint songs_master_status_check
  check (master_status in ('not_started', 'in_progress', 'ready_for_review', 'changes_requested', 'approved'));

grant update (
  recording_assignee, recording_due_date,
  mix_assignee, mix_due_date, master_assignee, master_due_date,
  notes, reference_url, mix_feedback, master_feedback
) on public.songs to authenticated;
