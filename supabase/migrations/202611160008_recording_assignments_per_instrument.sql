alter table public.song_parts
  add column assigned_to text,
  add column due_date date;

update public.song_parts as part
set assigned_to = song.recording_assignee,
    due_date = song.recording_due_date
from public.songs as song
where song.id = part.song_id
  and (song.recording_assignee is not null or song.recording_due_date is not null);

alter table public.songs
  drop column recording_assignee,
  drop column recording_due_date;
