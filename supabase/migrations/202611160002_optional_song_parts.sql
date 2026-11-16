alter table public.song_parts
  add column required boolean not null default true;

comment on column public.song_parts.required is
  'Whether this instrument part is needed for this song.';
