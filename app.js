import { createClient } from "@supabase/supabase-js";

const STORAGE_KEY = "trackboard-board-v1";
const LEGACY_STORAGE_KEY = "roomtone-board-v1";
const IMPORTED_KEY = "trackboard-cloud-imported-v1";
const siteBaseUrl = new URL(import.meta.env.BASE_URL, location.origin);
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseKey = import.meta.env.VITE_SUPABASE_ANON_KEY;
const supabase = supabaseUrl && supabaseKey ? createClient(supabaseUrl, supabaseKey) : null;
const defaultInstruments = ["Drums", "Bass", "Guitar", "Keys", "Lead vocal", "Backing vocals"];
const emptyBoard = { project: "", instruments: [], songs: [] };

const boardHead = document.querySelector("#board-head");
const boardBody = document.querySelector("#board-body");
const emptyState = document.querySelector("#empty-state");
const songDialog = document.querySelector("#song-dialog");
const instrumentDialog = document.querySelector("#instrument-dialog");
const projectDialog = document.querySelector("#project-dialog");
const projectActionsDialog = document.querySelector("#project-actions-dialog");
const recoveryDialog = document.querySelector("#recovery-dialog");
const toast = document.querySelector("#toast");
const authGate = document.querySelector("#auth-gate");
let user = null;
let projects = [];
let currentProject = null;
let board = emptyBoard;
let liveChannel = null;
let refreshTimer;
let toastTimeout;
let authMode = "signin";
let busy = false;
let userInitialization = { id: null, promise: null };
let optionalPartsSupported = true;

function showError(message, error) {
  console.error(message, error);
  showToast(message);
}

function showToast(message) {
  toast.textContent = message;
  toast.classList.add("visible");
  window.clearTimeout(toastTimeout);
  toastTimeout = window.setTimeout(() => toast.classList.remove("visible"), 3200);
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]);
}

function setBusy(nextBusy) {
  busy = nextBusy;
  document.querySelectorAll(".app-shell button").forEach((button) => {
    button.disabled = nextBusy;
  });
}

function showSignedOut(message = "") {
  authGate.hidden = false;
  document.querySelector(".app-shell").inert = true;
  document.querySelector(".app-shell").setAttribute("aria-hidden", "true");
  document.querySelector("#auth-message").textContent = message;
}

function showSignedIn() {
  authGate.hidden = true;
  document.querySelector(".app-shell").inert = false;
  document.querySelector(".app-shell").removeAttribute("aria-hidden");
}

function renderProjects() {
  const nav = document.querySelector("#project-nav-list");
  nav.innerHTML = projects.map((project) => {
    const active = project.id === currentProject?.id;
    return `<button class="nav-item project-nav-item${active ? " active" : ""}" type="button" data-project-id="${project.id}" aria-current="${active ? "page" : "false"}"><span class="nav-icon grid-icon" aria-hidden="true"></span><span class="project-nav-name">${escapeHtml(project.name)}</span>${active ? '<span class="nav-dot"></span>' : ""}</button>`;
  }).join("");
  document.querySelector(".page-content").hidden = !currentProject;
  document.querySelector("#empty-workspace").hidden = Boolean(currentProject);
  if (currentProject) {
    document.querySelector(".breadcrumbs strong").textContent = currentProject.name;
    document.querySelector("#project-title").textContent = currentProject.name;
    document.querySelector("#edit-title").hidden = currentProject.role !== "owner";
    document.querySelector("#project-options").hidden = currentProject.role !== "owner";
    document.querySelector("#project-subtitle").textContent = currentProject.role === "owner" ? "Project owner" : "Shared project member";
  }
}

async function loadProjects(preferredId) {
  const { data, error } = await supabase
    .from("projects")
    .select("id, name, created_by, project_members(role)")
    .order("created_at", { ascending: true });
  if (error) throw error;

  projects = data.map((project) => ({
    ...project,
    role: project.project_members?.[0]?.role ?? "member",
  }));
  const requestedId = preferredId || new URLSearchParams(location.search).get("project");
  currentProject = projects.find((project) => project.id === requestedId)
    || projects.find((project) => project.id === currentProject?.id)
    || projects[0]
    || null;
  renderProjects();
  if (currentProject) {
    await loadBoard();
    subscribeToProject(currentProject.id);
    updateProjectUrl(currentProject.id);
  } else {
    closeLiveChannel();
    board = emptyBoard;
    renderBoard();
  }
}

function updateProjectUrl(projectId) {
  const url = new URL(location.href);
  url.searchParams.delete("invite");
  if (projectId) url.searchParams.set("project", projectId);
  else url.searchParams.delete("project");
  history.replaceState({}, "", url);
}

function isMissingRequiredColumn(error) {
  const message = error?.message?.toLowerCase() || "";
  return (error?.code === "42703" || error?.code === "PGRST204")
    && message.includes("required");
}

async function loadBoard() {
  if (!currentProject) return;
  const projectId = currentProject.id;
  const [instrumentResult, songResult] = await Promise.all([
    supabase.from("instruments").select("id, name, position").eq("project_id", projectId).order("position"),
    supabase.from("songs").select("id, name, position").eq("project_id", projectId).order("position"),
  ]);
  if (instrumentResult.error) throw instrumentResult.error;
  if (songResult.error) throw songResult.error;

  const songs = songResult.data;
  let parts = [];
  if (songs.length) {
    let result = await supabase.from("song_parts")
      .select("song_id, instrument_id, done, required")
      .in("song_id", songs.map((song) => song.id));
    if (result.error && isMissingRequiredColumn(result.error)) {
      optionalPartsSupported = false;
      document.querySelector("#schema-warning").hidden = false;
      result = await supabase.from("song_parts")
        .select("song_id, instrument_id, done")
        .in("song_id", songs.map((song) => song.id));
    } else if (result.error) {
      throw result.error;
    } else {
      optionalPartsSupported = true;
      document.querySelector("#schema-warning").hidden = true;
    }
    if (result.error) throw result.error;
    parts = result.data.map((part) => ({ ...part, required: part.required ?? true }));
  } else {
    optionalPartsSupported = true;
    document.querySelector("#schema-warning").hidden = true;
  }
  if (currentProject?.id !== projectId) return;

  const partIndex = new Map(parts.map((part) => [`${part.song_id}:${part.instrument_id}`, {
    done: part.done,
    required: part.required,
  }]));
  board = {
    project: currentProject.name,
    instruments: instrumentResult.data,
    songs: songs.map((song) => ({
      ...song,
      parts: instrumentResult.data.map((instrument) => partIndex.get(`${song.id}:${instrument.id}`) ?? { done: false, required: true }),
    })),
  };
  renderBoard();
}

function renderBoard() {
  const instrumentHeaders = board.instruments.map((instrument, index) =>
    `<th scope="col"><span class="instrument-name">${escapeHtml(instrument.name)}</span><span class="instrument-index">PART ${String(index + 1).padStart(2, "0")}</span></th>`,
  ).join("");
  boardHead.innerHTML = `<tr><th scope="col">SONG</th>${instrumentHeaders}<th scope="col" aria-label="Song actions"></th></tr>`;
  boardBody.innerHTML = board.songs.map((song, songIndex) => {
    const completed = song.parts.filter((part) => part.required && part.done).length;
    const requiredCount = song.parts.filter((part) => part.required).length;
    const isDone = requiredCount > 0 && completed === requiredCount;
    const noPartsRequired = requiredCount === 0;
    const cells = song.parts.map((part, instrumentIndex) => {
      const instrument = board.instruments[instrumentIndex];
      return `<td class="part-cell"><div class="part-controls"><button class="part-toggle${part.required ? "" : " not-required"}" type="button" aria-label="Mark ${escapeHtml(song.name)} — ${escapeHtml(instrument.name)} as ${part.required ? (part.done ? "not done" : "done") : "required"}" aria-pressed="${part.done && part.required}" ${part.required ? "" : "disabled"} data-part-action="done" data-song="${songIndex}" data-instrument="${instrumentIndex}"><span aria-hidden="true">${part.required ? "✓" : "—"}</span></button><button class="not-required-toggle${part.required ? "" : " active"}" type="button" aria-label="Mark ${escapeHtml(song.name)} — ${escapeHtml(instrument.name)} ${part.required ? "not required" : "required"}" aria-pressed="${!part.required}" ${optionalPartsSupported ? "" : "disabled title=\"Run the optional song parts migration in Supabase first.\""} data-part-action="required" data-song="${songIndex}" data-instrument="${instrumentIndex}">N/R</button></div></td>`;
    }).join("");
    const removeButton = currentProject?.role === "owner"
      ? `<button class="remove-song" type="button" aria-label="Remove ${escapeHtml(song.name)}" data-remove-song="${songIndex}">×</button>`
      : "";
    const badge = noPartsRequired ? "NO PARTS" : isDone ? "DONE" : "RECORDING";
    return `<tr><td class="song-cell"><div class="song-title" title="${escapeHtml(song.name)}">${escapeHtml(song.name)}</div><div class="song-meta"><span class="song-index">${String(songIndex + 1).padStart(2, "0")}</span><span>·</span><span>${completed}/${requiredCount} required</span><span class="song-badge${isDone ? " done" : ""}">${badge}</span></div></td>${cells}<td class="part-cell">${removeButton}</td></tr>`;
  }).join("");

  const totalParts = board.songs.reduce((total, song) => total + song.parts.filter((part) => part.required).length, 0);
  const completedParts = board.songs.reduce((total, song) => total + song.parts.filter((part) => part.required && part.done).length, 0);
  const percentage = totalParts ? Math.round((completedParts / totalParts) * 100) : 0;
  document.querySelector("#overall-percent").textContent = `${percentage}%`;
  document.querySelector("#overall-progress").style.width = `${percentage}%`;
  document.querySelector("#song-count").textContent = board.songs.length;
  document.querySelector("#take-count").textContent = `${completedParts}/${totalParts}`;
  document.querySelector("#board-song-count").textContent = `${board.songs.length} ${board.songs.length === 1 ? "song" : "songs"}`;
  document.querySelector("#board-footer-count").textContent = `${completedParts}/${totalParts} required parts done`;
  document.querySelector(".board-scroll").hidden = board.songs.length === 0;
  document.querySelector(".board-footer").hidden = board.songs.length === 0;
  emptyState.hidden = board.songs.length !== 0;
  document.querySelector("#add-song").hidden = false;
  document.querySelector("#manage-instruments").hidden = false;
  renderInstrumentList();
}

function renderInstrumentList() {
  const list = document.querySelector("#instrument-list");
  list.innerHTML = board.instruments.map((instrument, index) =>
    `<span class="instrument-chip">${escapeHtml(instrument.name)}${currentProject?.role === "owner" ? `<button class="remove-instrument" type="button" aria-label="Remove ${escapeHtml(instrument.name)}" data-remove-instrument="${index}">×</button>` : ""}</span>`,
  ).join("");
}

function closeLiveChannel() {
  if (!liveChannel) return;
  supabase.removeChannel(liveChannel);
  liveChannel = null;
}

function subscribeToProject(projectId) {
  closeLiveChannel();
  if (!user) return;
  const channel = supabase.channel(`project:${projectId}`, {
    config: { presence: { key: user.id } },
  });
  channel
    .on("postgres_changes", { event: "*", schema: "public", table: "instruments", filter: `project_id=eq.${projectId}` }, scheduleRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "songs", filter: `project_id=eq.${projectId}` }, scheduleRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "song_parts" }, (payload) => {
      if (payload.new?.song_id && board.songs.some((song) => song.id === payload.new.song_id)) scheduleRefresh();
      if (payload.old?.song_id && board.songs.some((song) => song.id === payload.old.song_id)) scheduleRefresh();
    })
    .on("postgres_changes", { event: "UPDATE", schema: "public", table: "projects", filter: `id=eq.${projectId}` }, () => {
      void loadProjects(projectId).catch((error) => showError("Could not refresh the project.", error));
    })
    .on("presence", { event: "sync" }, () => {
      const activeMembers = Object.keys(channel.presenceState()).length;
      document.querySelector("#presence .presence-count").textContent = `${activeMembers} HERE`;
      document.querySelector("#presence").setAttribute("aria-label", `${activeMembers} project members online`);
    })
    .subscribe((status) => {
      if (status === "SUBSCRIBED") {
        void channel.track({ user_id: user.id, online_at: new Date().toISOString() })
          .then((result) => {
            if (result !== "ok") showError("Could not announce your live session.");
          })
          .catch((error) => showError("Could not announce your live session.", error));
      } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
        showError("Live updates are disconnected. Check your connection.");
      }
    });
  liveChannel = channel;
}

function scheduleRefresh() {
  window.clearTimeout(refreshTimer);
  refreshTimer = window.setTimeout(() => {
    void loadBoard().catch((error) => showError("Could not refresh the shared board.", error));
  }, 120);
}

async function importLegacyBoardIfNeeded() {
  if (localStorage.getItem(IMPORTED_KEY)) return false;
  const saved = localStorage.getItem(STORAGE_KEY) || localStorage.getItem(LEGACY_STORAGE_KEY);
  if (!saved) return false;
  try {
    const legacy = JSON.parse(saved);
    if (typeof legacy.project !== "string" || !Array.isArray(legacy.instruments) || !Array.isArray(legacy.songs)) return false;
    const { data, error } = await supabase.rpc("import_legacy_board", { board_data: legacy });
    if (error) throw error;
    localStorage.setItem(IMPORTED_KEY, "true");
    showToast("Your saved board has been moved to your account.");
    return Boolean(data);
  } catch (error) {
    showError("Could not import your saved board. Your local copy is still safe.", error);
    return false;
  }
}

async function acceptInviteFromUrl() {
  const url = new URL(location.href);
  const token = url.searchParams.get("invite");
  if (!token) return null;
  const { data, error } = await supabase.rpc("join_project_with_invite", { invite_token: token });
  if (error) {
    url.searchParams.delete("invite");
    history.replaceState({}, "", url);
    throw error;
  }
  showToast("You’ve joined the shared project.");
  return data;
}

function initializeUser(nextUser) {
  const id = nextUser?.id ?? null;
  if (userInitialization.promise && userInitialization.id === id) return userInitialization.promise;
  const promise = runUserInitialization(nextUser);
  userInitialization = { id, promise };
  return promise;
}

async function runUserInitialization(nextUser) {
  user = nextUser;
  if (!user) {
    closeLiveChannel();
    projects = [];
    currentProject = null;
    renderProjects();
    showSignedOut();
    return;
  }

  document.querySelector("#user-email").textContent = user.email || "Band member";
  showSignedIn();
  try {
    const invitedProject = await acceptInviteFromUrl();
    if (projects.length === 0) await importLegacyBoardIfNeeded();
    await loadProjects(invitedProject);
  } catch (error) {
    showError(error.message || "Could not load your projects.", error);
  }
}

async function authenticate(event) {
  event.preventDefault();
  if (busy) return;
  const email = document.querySelector("#auth-email").value.trim();
  const password = document.querySelector("#auth-password").value;
  const message = document.querySelector("#auth-message");
  message.textContent = "";
  if (!supabase) {
    document.querySelector("#auth-setup-error").hidden = false;
    return;
  }
  if (password.length < 8) {
    message.textContent = "Use a password with at least 8 characters.";
    return;
  }
  setBusy(true);
  try {
    const result = authMode === "signup"
      ? await supabase.auth.signUp({ email, password, options: { emailRedirectTo: location.href } })
      : await supabase.auth.signInWithPassword({ email, password });
    if (result.error) throw result.error;
    if (authMode === "signup" && !result.data.session) {
      message.textContent = "Check your email to confirm your account, then come back here to sign in.";
    } else if (result.data.user) {
      await initializeUser(result.data.user);
    }
  } catch (error) {
    message.textContent = error.message || "Could not sign in. Please try again.";
  } finally {
    setBusy(false);
  }
}

function setAuthMode(mode) {
  authMode = mode;
  const signingUp = mode === "signup";
  document.querySelector("#auth-title").textContent = signingUp ? "Create your account" : "Sign in to Trackboard";
  document.querySelector("#auth-submit").textContent = signingUp ? "Create account" : "Sign in";
  document.querySelector("#auth-password").autocomplete = signingUp ? "new-password" : "current-password";
  document.querySelector("#auth-mode-toggle").textContent = signingUp
    ? "Already have an account? Sign in"
    : "New here? Create an account";
  document.querySelector("#forgot-password").hidden = signingUp;
  document.querySelector("#auth-message").textContent = "";
}

async function createProject(name) {
  const { data, error } = await supabase.rpc("create_project", { project_name: name });
  if (error) throw error;
  await loadProjects(data);
  showToast(`${name} is ready for the band.`);
}

async function renameProject() {
  if (!currentProject || currentProject.role !== "owner") return;
  const name = window.prompt("Rename this project:", currentProject.name)?.trim();
  if (!name || name === currentProject.name) return;
  const { error } = await supabase.from("projects").update({ name: name.slice(0, 60) }).eq("id", currentProject.id);
  if (error) throw error;
  await loadProjects(currentProject.id);
  showToast("Project renamed.");
}

async function deleteProject() {
  if (!currentProject || currentProject.role !== "owner") return;
  if (!window.confirm(`Permanently delete “${currentProject.name}” and all its songs and progress? This cannot be undone.`)) return;
  const removedId = currentProject.id;
  const { error } = await supabase.from("projects").delete().eq("id", removedId);
  if (error) throw error;
  closeLiveChannel();
  projects = projects.filter((project) => project.id !== removedId);
  currentProject = projects[0] || null;
  renderProjects();
  if (currentProject) {
    await loadBoard();
    subscribeToProject(currentProject.id);
  } else {
    board = emptyBoard;
    renderBoard();
  }
  updateProjectUrl(currentProject?.id);
  showToast("Project deleted.");
}

async function shareProject() {
  if (!currentProject) return;
  const { data: token, error } = await supabase.rpc("create_project_invite", { target_project: currentProject.id });
  if (error) throw error;
  const inviteUrl = new URL(location.href);
  inviteUrl.searchParams.delete("project");
  inviteUrl.searchParams.set("invite", token);
  try {
    await navigator.clipboard.writeText(inviteUrl.toString());
    showToast("Invite link copied. Anyone with it can join for 30 days.");
  } catch (error) {
    console.error("Could not copy the invite link.", error);
    window.prompt("Copy this invite link:", inviteUrl.toString());
  }
}

document.querySelector("#auth-form").addEventListener("submit", authenticate);
document.querySelector("#auth-mode-toggle").addEventListener("click", () => setAuthMode(authMode === "signin" ? "signup" : "signin"));
document.querySelector("#sign-out").addEventListener("click", async () => {
  try {
    const { error } = await supabase.auth.signOut();
    if (error) throw error;
  } catch (error) {
    showError("Could not sign out.", error);
  }
});
document.querySelector("#forgot-password").addEventListener("click", async () => {
  const email = document.querySelector("#auth-email").value.trim();
  const message = document.querySelector("#auth-message");
  if (!email) {
    message.textContent = "Enter your email address first.";
    document.querySelector("#auth-email").focus();
    return;
  }
  try {
    const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: siteBaseUrl.href });
    if (error) throw error;
    message.textContent = "Password reset instructions are on their way. Check your email.";
  } catch (error) {
    message.textContent = error.message || "Could not send password reset instructions.";
  }
});
document.querySelector("#recovery-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const password = document.querySelector("#recovery-password").value;
  try {
    const { error } = await supabase.auth.updateUser({ password });
    if (error) throw error;
    recoveryDialog.close();
    showToast("Your password has been updated.");
  } catch (error) {
    showError("Could not update your password.", error);
  }
});
document.querySelector("#new-project-shortcut").addEventListener("click", () => {
  projectDialog.showModal();
  document.querySelector("#project-name").focus();
});
document.querySelector("#empty-create-project").addEventListener("click", () => {
  projectDialog.showModal();
  document.querySelector("#project-name").focus();
});
document.querySelector("#project-nav-list").addEventListener("click", async (event) => {
  const button = event.target.closest("[data-project-id]");
  if (!button || button.dataset.projectId === currentProject?.id) return;
  const selected = projects.find((project) => project.id === button.dataset.projectId);
  if (!selected) return;
  currentProject = selected;
  renderProjects();
  try {
    await loadBoard();
    subscribeToProject(currentProject.id);
    updateProjectUrl(currentProject.id);
  } catch (error) {
    showError("Could not open this project.", error);
  }
});
document.querySelector("#project-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = document.querySelector("#project-name");
  const name = input.value.trim();
  if (!name || busy) return;
  setBusy(true);
  try {
    await createProject(name);
    projectDialog.close();
    input.value = "";
  } catch (error) {
    showError("Could not create the project.", error);
  } finally {
    setBusy(false);
  }
});
document.querySelector("#edit-title").addEventListener("click", () => {
  void renameProject().catch((error) => showError("Could not rename the project.", error));
});
document.querySelector("#project-options").addEventListener("click", () => projectActionsDialog.showModal());
document.querySelector("#rename-project-action").addEventListener("click", () => {
  projectActionsDialog.close();
  void renameProject().catch((error) => showError("Could not rename the project.", error));
});
document.querySelector("#delete-project-action").addEventListener("click", () => {
  projectActionsDialog.close();
  void deleteProject().catch((error) => showError("Could not delete the project.", error));
});
document.querySelector("#share-button").addEventListener("click", () => {
  void shareProject().catch((error) => showError("Could not create an invite link.", error));
});
document.querySelector("#add-song").addEventListener("click", () => {
  songDialog.showModal();
  document.querySelector("#song-name").focus();
});
document.querySelector("#empty-add-song").addEventListener("click", () => {
  songDialog.showModal();
  document.querySelector("#song-name").focus();
});
document.querySelector("#manage-instruments").addEventListener("click", () => instrumentDialog.showModal());
document.querySelector("#song-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = document.querySelector("#song-name");
  const name = input.value.trim();
  if (!name || !currentProject) return;
  try {
    const { error } = await supabase.rpc("add_song", { target_project: currentProject.id, song_name: name });
    if (error) throw error;
    await loadBoard();
    songDialog.close();
    input.value = "";
    showToast(`“${name}” added to the board.`);
  } catch (error) {
    showError("Could not add the song.", error);
  }
});
document.querySelector("#instrument-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = document.querySelector("#instrument-name");
  const name = input.value.trim();
  if (!name || !currentProject) return;
  if (board.instruments.some((instrument) => instrument.name.toLowerCase() === name.toLowerCase())) {
    showToast("That instrument is already on the board.");
    input.focus();
    return;
  }
  try {
    const { error } = await supabase.rpc("add_instrument", { target_project: currentProject.id, instrument_name: name });
    if (error) throw error;
    await loadBoard();
    input.value = "";
    input.focus();
  } catch (error) {
    showError("Could not add the instrument.", error);
  }
});
boardBody.addEventListener("click", async (event) => {
  const toggle = event.target.closest("[data-part-action]");
  if (toggle && currentProject) {
    const song = board.songs[Number(toggle.dataset.song)];
    const instrumentIndex = Number(toggle.dataset.instrument);
    const instrument = board.instruments[instrumentIndex];
    const part = song.parts[instrumentIndex];
    const update = toggle.dataset.partAction === "done"
      ? { done: !part.done }
      : { required: !part.required, done: false };
    try {
      const { error } = await supabase.from("song_parts").update({
        ...update, updated_by: user.id, updated_at: new Date().toISOString(),
      }).eq("song_id", song.id).eq("instrument_id", instrument.id);
      if (error) throw error;
      await loadBoard();
    } catch (error) {
      showError("Could not update this part.", error);
    }
    return;
  }
  const remove = event.target.closest("[data-remove-song]");
  if (!remove || !currentProject) return;
  const song = board.songs[Number(remove.dataset.removeSong)];
  if (!window.confirm(`Remove “${song.name}” from this board?`)) return;
  try {
    const { error } = await supabase.from("songs").delete().eq("id", song.id);
    if (error) throw error;
    await loadBoard();
    showToast("Song removed from the board.");
  } catch (error) {
    showError("Could not remove the song.", error);
  }
});
document.querySelector("#instrument-list").addEventListener("click", async (event) => {
  const remove = event.target.closest("[data-remove-instrument]");
  if (!remove || !currentProject) return;
  const instrument = board.instruments[Number(remove.dataset.removeInstrument)];
  if (!window.confirm(`Remove “${instrument.name}” and its progress from every song?`)) return;
  try {
    const { error } = await supabase.from("instruments").delete().eq("id", instrument.id);
    if (error) throw error;
    await loadBoard();
    showToast(`${instrument.name} removed from the board.`);
  } catch (error) {
    showError("Could not remove the instrument.", error);
  }
});
document.querySelectorAll("[data-close]").forEach((button) => {
  button.addEventListener("click", () => button.closest("dialog").close());
});

async function start() {
  if (!supabase) {
    showSignedOut();
    document.querySelector("#auth-setup-error").hidden = false;
    document.querySelector("#auth-password-field").hidden = true;
    document.querySelector("#auth-mode-toggle").hidden = true;
    document.querySelector("#auth-submit").disabled = true;
    return;
  }

  supabase.auth.onAuthStateChange((event, session) => {
    window.setTimeout(() => {
      void initializeUser(session?.user || null);
      if (event === "PASSWORD_RECOVERY" && !recoveryDialog.open) recoveryDialog.showModal();
    }, 0);
  });
  const { data, error } = await supabase.auth.getSession();
  if (error) {
    showError("Could not restore your sign-in session.", error);
    showSignedOut();
    return;
  }
  if (data.session) await initializeUser(data.session.user);
  else showSignedOut();
}

void start();
