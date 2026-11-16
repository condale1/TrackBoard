# Trackboard

Trackboard is a shared recording-progress board for bands. Projects, songs, instruments, and completed parts are stored in Supabase; signed-in project members see changes live.

## Run locally

1. Create a Supabase project.
2. In the Supabase SQL Editor, run the migrations in order: [`202611160001_trackboard.sql`](./supabase/migrations/202611160001_trackboard.sql), [`202611160002_optional_song_parts.sql`](./supabase/migrations/202611160002_optional_song_parts.sql), [`202611160003_reorder_instruments.sql`](./supabase/migrations/202611160003_reorder_instruments.sql), [`202611160004_bands.sql`](./supabase/migrations/202611160004_bands.sql), [`202611160005_release_date.sql`](./supabase/migrations/202611160005_release_date.sql), [`202611160006_mix_master_status.sql`](./supabase/migrations/202611160006_mix_master_status.sql), [`202611160007_song_workflow.sql`](./supabase/migrations/202611160007_song_workflow.sql), [`202611160008_recording_assignments_per_instrument.sql`](./supabase/migrations/202611160008_recording_assignments_per_instrument.sql), [`202611160009_instrument_assignments.sql`](./supabase/migrations/202611160009_instrument_assignments.sql), and [`202611160010_release_checklist_artwork.sql`](./supabase/migrations/202611160010_release_checklist_artwork.sql).
3. In Supabase Authentication settings, enable email/password sign-in and anonymous sign-ins, set the site URL, and add your local URL (for example `http://localhost:5173/**`) to the allowed redirect URLs. Anonymous sign-ins power the temporary guest testing option.
4. Copy `.env.example` to `.env` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` using the project URL and publishable/anon key from Supabase API settings. Never put a service-role key in the browser app.
5. Run `npm install`, then `npm run dev`.

The app requires a Supabase project; it does not silently fall back to device-only storage when the backend is unavailable.

## Deploy to GitHub Pages

1. Push this project to a GitHub repository using the `main` branch.
2. In the repository settings, add Actions secrets named `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`. Use the Supabase project URL and publishable/anon key; never use the service-role key.
3. Under **Settings → Pages**, set the source to **GitHub Actions**.
4. In Supabase Authentication settings, set the site URL to `https://YOUR-USERNAME.github.io/YOUR-REPOSITORY/` and add that URL with `**` to the allowed redirect URLs.
5. Push to `main` or run **Deploy Trackboard to GitHub Pages** from the repository's Actions tab. The workflow builds and publishes the site.

The GitHub Actions workflow uses a relative Vite asset base, so it works for GitHub project pages hosted below `/<repository>/`.

## Sharing and access

Create an account or use **Continue as guest** for temporary testing, then create or join a band from the band selector and create projects inside it. Guest access requires anonymous sign-ins to be enabled in Supabase Authentication settings. Guest sessions are associated with the current browser and can be lost if its data is cleared. Use **Invite to band** to make a reusable invite link that expires after 30 days. Members of a band can see all its projects; anyone with the invite link can join, so share it only with bandmates.

Supabase Row Level Security policies restrict access to band members. Members can track parts, assign a person to an instrument for all songs, set per-song instrument due dates, update mix/master task details and review states, add song notes and reference links, manage the release checklist and artwork, and add songs or instruments; band owners can rename bands and manage projects, songs, instruments, and project release dates. Instrument and mix/master task assignees are free-text names for now. Release artwork is stored in a private Supabase Storage bucket and served to band members with signed URLs. Invite tokens are only returned by the membership-checked invite RPC, and invite acceptance is performed by a database function after authentication. Migration `202611160004_bands.sql` places each existing project into its own band, preserving its current members; you can rename those bands or create a new band and projects from the selector. Configure your production site's URL and authentication redirect allow-list in Supabase before deployment.

## Existing local boards

On the first sign-in to an account with no projects, a board saved by the earlier browser-only version is imported from that browser's local storage (`trackboard-board-v1` or `roomtone-board-v1`). The original local copy is retained as a backup.
