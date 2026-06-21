import type { AppModule, Entry } from "../types";

function escapeHtml(s: string): string {
  const d = document.createElement("div");
  d.textContent = s;
  return d.innerHTML;
}

function getField(e: Entry, k: string): unknown {
  return e.data[k];
}

function getTags(e: Entry): string[] {
  return (e.data.tags as string[]) || [];
}

function getPeople(e: Entry): { id: string; name: string }[] {
  return (e.data.people as { id: string; name: string }[]) || [];
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

const photosApp: AppModule = {
  mount(el, ctx) {
    let allPhotos: Entry[] = [];
    let allContacts: Entry[] = [];
    let albumFilter = "";
    let tagFilter = "";
    let peopleFilter = "";
    let uploading = false;
    let selectionMode = false;
    let peopleSearchActive = false;
    let peopleSearchQuery = "";
    let tagModalActive = false;
    let tagModalQuery = "";
    const selectedIds = new Set<string>();

    function albums(): string[] {
      const set = new Set<string>();
      for (const p of allPhotos) {
        const a = getField(p, "album") as string;
        if (a) set.add(a);
      }
      return Array.from(set).sort();
    }

    function allTags(): string[] {
      const set = new Set<string>();
      for (const p of allPhotos) {
        for (const t of getTags(p)) set.add(t);
      }
      return Array.from(set).sort();
    }

    function allPeople(): { id: string; name: string }[] { // used in template strings
      const map = new Map<string, string>();
      for (const p of allPhotos) {
        for (const person of getPeople(p)) map.set(person.id, person.name);
      }
      return Array.from(map.entries()).map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name));
    }

    function filtered(): Entry[] {
      let list = allPhotos;
      if (albumFilter) list = list.filter((p) => getField(p, "album") === albumFilter);
      if (tagFilter) list = list.filter((p) => getTags(p).includes(tagFilter));
      if (peopleFilter) list = list.filter((p) => getPeople(p).some((pp) => pp.id === peopleFilter));
      return list;
    }

    function render() {
      const photos = filtered();
      const albumList = albums();
      const tags = allTags();
      const selCount = selectedIds.size;

      // Contact search results for people tagging
      const matchingContacts = peopleSearchActive && peopleSearchQuery.length >= 1
        ? allContacts.filter((c) => {
            const name = ((c.data.display_name as string) || c.title || "").toLowerCase();
            return name.includes(peopleSearchQuery.toLowerCase());
          }).slice(0, 8)
        : [];

      const toolbarHtml = selectionMode
        ? renderSelectionToolbar(selCount, matchingContacts)
        : renderNormalToolbar(albumList);

      function renderSelectionToolbar(count: number, contacts: Entry[]): string {
        const removeBtnHtml = tagFilter
          ? '<button class="ph-btn ph-btn--danger" id="ph-remove-tag" ' + (count === 0 ? "disabled" : "") + '>Remove "' + escapeHtml(tagFilter) + '"</button>'
          : "";
        const disabledAttr = count === 0 ? "disabled" : "";

        let peopleHtml = "";
        if (peopleSearchActive) {
          let resultsHtml = "";
          if (contacts.length) {
            resultsHtml = '<div class="ph-people-results">' + contacts.map((c) => {
              const cName = (c.data.display_name as string) || c.title?.split(" — ")[0] || "(unnamed)";
              const cPhoto = c.data.photo as string;
              const initials = cName.split(/\s+/).slice(0, 2).map((w: string) => w[0]?.toUpperCase() || "").join("");
              const avatarHtml = cPhoto
                ? '<img class="ph-people-avatar" src="' + escapeHtml(cPhoto) + '" alt="" />'
                : '<span class="ph-people-avatar ph-people-avatar--init">' + escapeHtml(initials) + '</span>';
              return '<div class="ph-people-result" data-contact-id="' + c.id + '" data-contact-name="' + escapeHtml(cName) + '">' + avatarHtml + '<span>' + escapeHtml(cName) + '</span></div>';
            }).join("") + '</div>';
          } else if (peopleSearchQuery) {
            resultsHtml = '<div class="ph-people-no-results">No contacts found</div>';
          }
          peopleHtml = '<div class="ph-people-search"><input class="ph-people-input" type="text" placeholder="Search contacts..." value="' + escapeHtml(peopleSearchQuery) + '" autofocus />' + resultsHtml + '</div>';
        }

        return '<div class="ph-toolbar">'
          + '<span class="ph-sel-count">' + count + ' selected</span>'
          + '<div class="ph-actions">'
          + '<button class="ph-btn" id="ph-select-all">Select all</button>'
          + '<button class="ph-btn" id="ph-deselect">Deselect</button>'
          + '<button class="ph-btn ph-btn--primary" id="ph-tag" ' + disabledAttr + '>Tag</button>'
          + '<button class="ph-btn" id="ph-tag-people" ' + disabledAttr + '>Tag people</button>'
          + removeBtnHtml
          + '<button class="ph-btn" id="ph-cancel-sel">Cancel</button>'
          + '</div></div>'
          + peopleHtml;
      }

      function renderNormalToolbar(albumList: string[]): string {
        const optionsHtml = albumList.map((a) =>
          '<option value="' + escapeHtml(a) + '"' + (a === albumFilter ? " selected" : "") + '>' + escapeHtml(a) + '</option>'
        ).join("");
        return '<div class="ph-toolbar">'
          + '<div class="ph-filters">'
          + '<select class="ph-album-filter">'
          + '<option value="">All photos (' + allPhotos.length + ')</option>'
          + optionsHtml
          + '</select></div>'
          + '<div class="ph-actions">'
          + '<button class="ph-btn" id="ph-select-mode">Select</button>'
          + '<label class="ph-btn">+ Upload<input type="file" accept="image/*" multiple hidden id="ph-upload" /></label>'
          + '</div></div>';
      }

      const people = allPeople();
      const hasFilters = tags.length > 0 || people.length > 0;
      const tagsBarHtml = hasFilters
        ? `<div class="ph-tags-bar">
            <span class="ph-tag-pill ${!tagFilter && !peopleFilter ? "ph-tag-pill--active" : ""}" data-tag="" data-person="">All</span>
            ${tags.map((t) => `<span class="ph-tag-pill ${t === tagFilter ? "ph-tag-pill--active" : ""}" data-tag="${escapeHtml(t)}">${escapeHtml(t)}</span>`).join("")}
            ${people.length ? '<span class="ph-tag-sep"></span>' : ""}
            ${people.map((p) => `<span class="ph-tag-pill ph-tag-pill--person ${p.id === peopleFilter ? "ph-tag-pill--active" : ""}" data-person="${escapeHtml(p.id)}">${escapeHtml(p.name)}</span>`).join("")}
          </div>`
        : "";

      // Tag modal HTML
      let tagModalHtml = "";
      if (tagModalActive) {
        const existingTags = allTags();
        const filteredSuggestions = tagModalQuery
          ? existingTags.filter((t) => t.toLowerCase().includes(tagModalQuery.toLowerCase()) && t.toLowerCase() !== tagModalQuery.toLowerCase())
          : existingTags;

        // Tags currently on selected photos
        const selectedTagCounts = new Map<string, number>();
        for (const id of selectedIds) {
          const photo = allPhotos.find((p) => p.id === id);
          if (!photo) continue;
          for (const t of getTags(photo)) selectedTagCounts.set(t, (selectedTagCounts.get(t) || 0) + 1);
        }
        const currentTags = Array.from(selectedTagCounts.keys()).sort();

        tagModalHtml = `
          <div class="ph-modal-overlay" id="ph-tag-modal-overlay">
            <div class="ph-modal">
              <h3 class="ph-modal-title">Tags</h3>
              ${currentTags.length ? `
                <div class="ph-modal-section-label">Current tags</div>
                <div class="ph-modal-current-tags">${currentTags.map((t) => `<span class="ph-modal-current-tag" data-tag="${escapeHtml(t)}">${escapeHtml(t)}<span class="ph-modal-tag-remove" data-remove-tag="${escapeHtml(t)}">&times;</span></span>`).join("")}</div>
              ` : ""}
              <div class="ph-modal-section-label">Add a tag</div>
              <input class="ph-modal-input" id="ph-tag-input" type="text" placeholder="Tag name..." value="${escapeHtml(tagModalQuery)}" autofocus />
              ${filteredSuggestions.length ? `<div class="ph-modal-suggestions">${filteredSuggestions.map((t) => `<span class="ph-modal-suggestion" data-tag="${escapeHtml(t)}">${escapeHtml(t)}</span>`).join("")}</div>` : ""}
              <div class="ph-modal-actions">
                <button class="ph-btn" id="ph-tag-cancel">Cancel</button>
                <button class="ph-btn ph-btn--primary" id="ph-tag-confirm" ${!tagModalQuery.trim() ? "disabled" : ""}>Add</button>
              </div>
            </div>
          </div>`;
      }

      el.innerHTML = `
        <div class="ph-layout">
          ${toolbarHtml}
          ${tagsBarHtml}
          ${uploading ? '<div class="ph-uploading">Uploading...</div>' : ""}
          <div class="ph-grid">
            ${photos
              .map((p) => {
                const isSelected = selectedIds.has(p.id);
                const photoTags = getTags(p);
                const photoPeople = getPeople(p);
                const allLabels = [
                  ...photoTags.map((t) => `<span class="ph-thumb-tag">${escapeHtml(t)}</span>`),
                  ...photoPeople.map((pp) => `<span class="ph-thumb-tag ph-thumb-tag--person">${escapeHtml(pp.name)}</span>`),
                ];
                return `
                <div class="ph-thumb ${selectionMode && isSelected ? "ph-thumb--selected" : ""}" data-id="${p.id}">
                  ${selectionMode ? `<span class="ph-check ${isSelected ? "ph-check--on" : ""}"></span>` : ""}
                  <img src="${escapeHtml(getField(p, "path") as string)}" alt="${escapeHtml(p.title || "")}" loading="lazy" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'" />
                  <div class="ph-broken" style="display:none">
                    <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/></svg>
                  </div>
                  ${allLabels.length ? `<div class="ph-thumb-tags">${allLabels.join("")}</div>` : ""}
                </div>`;
              })
              .join("")}
            ${photos.length === 0 ? '<p class="ph-empty">No photos found.</p>' : ""}
          </div>
        </div>
        ${tagModalHtml}
      `;

      // --- Event binding ---

      // Tag & people filter pills
      el.querySelectorAll(".ph-tag-pill").forEach((pill) => {
        pill.addEventListener("click", () => {
          const el = pill as HTMLElement;
          const tag = el.dataset.tag;
          const person = el.dataset.person;
          if (tag !== undefined) { tagFilter = tag; peopleFilter = ""; }
          if (person !== undefined) { peopleFilter = person; tagFilter = ""; }
          if (tag === "" && person === "") { tagFilter = ""; peopleFilter = ""; }
          render();
        });
      });

      // Album filter
      el.querySelector(".ph-album-filter")?.addEventListener("change", (e) => {
        albumFilter = (e.target as HTMLSelectElement).value;
        render();
      });

      // Upload
      async function uploadFiles(files: File[]) {
        const images = files.filter((f) => f.type.startsWith("image/"));
        if (!images.length) return;
        uploading = true;
        render();
        for (const file of images) {
          const result = await ctx.api.upload(file, "photos") as unknown as Record<string, unknown>
          const data: Record<string, unknown> = {
            filename: file.name,
            size: result.size,
            mime_type: result.mime_type,
            path: result.path,
            album: albumFilter || null,
            tags: [],
          };
          if (result.date_taken) data.date_taken = result.date_taken;
          if (result.latitude != null) {
            data.latitude = result.latitude;
            data.longitude = result.longitude;
          }
          if (result.camera) data.camera = result.camera;

          await ctx.api.entries.create({
            kind: "photo",
            source: "photos_app",
            title: file.name,
            occurred_at: (result.date_taken as string) || null,
            data,
          });
        }
        uploading = false;
        await reload();
      }

      el.querySelector("#ph-upload")?.addEventListener("change", (e) => {
        const input = e.target as HTMLInputElement;
        if (input.files?.length) uploadFiles(Array.from(input.files));
      });

      // Drag & drop
      const layout = el.querySelector(".ph-layout");
      if (layout) {
        layout.addEventListener("dragover", (e) => {
          e.preventDefault();
          layout.classList.add("ph-dragover");
        });
        layout.addEventListener("dragleave", () => {
          layout.classList.remove("ph-dragover");
        });
        layout.addEventListener("drop", (e) => {
          e.preventDefault();
          layout.classList.remove("ph-dragover");
          const dt = (e as DragEvent).dataTransfer;
          if (dt?.files.length) uploadFiles(Array.from(dt.files));
        });
      }

      // Thumbnail clicks
      el.querySelectorAll(".ph-thumb").forEach((thumb) => {
        thumb.addEventListener("click", () => {
          const id = (thumb as HTMLElement).dataset.id;
          if (!id) return;
          if (selectionMode) {
            if (selectedIds.has(id)) selectedIds.delete(id);
            else selectedIds.add(id);
            render();
          } else {
            openViewer(id);
          }
        });
      });

      // Selection mode buttons
      el.querySelector("#ph-select-mode")?.addEventListener("click", () => {
        selectionMode = true;
        selectedIds.clear();
        render();
      });
      el.querySelector("#ph-cancel-sel")?.addEventListener("click", () => {
        selectionMode = false;
        selectedIds.clear();
        render();
      });
      el.querySelector("#ph-select-all")?.addEventListener("click", () => {
        for (const p of photos) selectedIds.add(p.id);
        render();
      });
      el.querySelector("#ph-deselect")?.addEventListener("click", () => {
        selectedIds.clear();
        render();
      });

      // Tag people button
      el.querySelector("#ph-tag-people")?.addEventListener("click", () => {
        peopleSearchActive = true;
        peopleSearchQuery = "";
        render();
        // Focus input after render
        (el.querySelector(".ph-people-input") as HTMLInputElement)?.focus();
      });

      // People search input
      const peopleInput = el.querySelector(".ph-people-input") as HTMLInputElement | null;
      if (peopleInput) {
        peopleInput.addEventListener("input", (e) => {
          peopleSearchQuery = (e.target as HTMLInputElement).value;
          render();
          const input = el.querySelector(".ph-people-input") as HTMLInputElement | null;
          if (input) { input.focus(); input.setSelectionRange(peopleSearchQuery.length, peopleSearchQuery.length); }
        });
        peopleInput.addEventListener("keydown", (e) => {
          if ((e as KeyboardEvent).key === "Escape") {
            peopleSearchActive = false;
            peopleSearchQuery = "";
            render();
          }
        });
      }

      // People search result click → tag selected photos with this contact
      el.querySelectorAll(".ph-people-result").forEach((result) => {
        result.addEventListener("click", async () => {
          const contactId = (result as HTMLElement).dataset.contactId!;
          const contactName = (result as HTMLElement).dataset.contactName!;
          for (const id of selectedIds) {
            const photo = allPhotos.find((p) => p.id === id);
            if (!photo) continue;
            const existing = getPeople(photo);
            if (existing.some((pp) => pp.id === contactId)) continue;
            await ctx.api.entries.update(id, {
              data: { ...photo.data, people: [...existing, { id: contactId, name: contactName }] },
            });
          }
          peopleSearchActive = false;
          peopleSearchQuery = "";
          selectedIds.clear();
          selectionMode = false;
          await reload();
        });
      });

      // Tag action – open modal
      async function applyTag(tag: string) {
        for (const id of selectedIds) {
          const photo = allPhotos.find((p) => p.id === id);
          if (!photo) continue;
          const existing = getTags(photo);
          if (existing.includes(tag)) continue;
          await ctx.api.entries.update(id, {
            data: { ...photo.data, tags: [...existing, tag] },
          });
        }
        tagModalActive = false;
        tagModalQuery = "";
        selectedIds.clear();
        selectionMode = false;
        await reload();
      }

      el.querySelector("#ph-tag")?.addEventListener("click", () => {
        tagModalActive = true;
        tagModalQuery = "";
        render();
        (el.querySelector("#ph-tag-input") as HTMLInputElement)?.focus();
      });

      // Tag modal events
      el.querySelector("#ph-tag-modal-overlay")?.addEventListener("click", (e) => {
        if (e.target === e.currentTarget) {
          tagModalActive = false;
          tagModalQuery = "";
          render();
        }
      });
      el.querySelector("#ph-tag-cancel")?.addEventListener("click", () => {
        tagModalActive = false;
        tagModalQuery = "";
        render();
      });
      el.querySelector("#ph-tag-confirm")?.addEventListener("click", () => {
        const val = tagModalQuery.trim();
        if (val) applyTag(val);
      });
      const tagInput = el.querySelector("#ph-tag-input") as HTMLInputElement | null;
      if (tagInput) {
        tagInput.addEventListener("input", (e) => {
          tagModalQuery = (e.target as HTMLInputElement).value;
          render();
          const inp = el.querySelector("#ph-tag-input") as HTMLInputElement | null;
          if (inp) { inp.focus(); inp.setSelectionRange(tagModalQuery.length, tagModalQuery.length); }
        });
        tagInput.addEventListener("keydown", (e) => {
          if ((e as KeyboardEvent).key === "Escape") {
            tagModalActive = false;
            tagModalQuery = "";
            render();
          } else if ((e as KeyboardEvent).key === "Enter") {
            const val = tagModalQuery.trim();
            if (val) applyTag(val);
          }
        });
      }
      el.querySelectorAll(".ph-modal-suggestion").forEach((s) => {
        s.addEventListener("click", () => {
          const tag = (s as HTMLElement).dataset.tag!;
          applyTag(tag);
        });
      });

      // Remove tag from selected photos via modal
      el.querySelectorAll(".ph-modal-tag-remove").forEach((btn) => {
        btn.addEventListener("click", async (e) => {
          e.stopPropagation();
          const tag = (btn as HTMLElement).dataset.removeTag!;
          for (const id of selectedIds) {
            const photo = allPhotos.find((p) => p.id === id);
            if (!photo) continue;
            const existing = getTags(photo);
            if (!existing.includes(tag)) continue;
            await ctx.api.entries.update(id, {
              data: { ...photo.data, tags: existing.filter((t) => t !== tag) },
            });
          }
          // Refresh photos but keep modal open
          const [photos] = await Promise.all([ctx.api.entries.list({ kind: "photo" })]);
          allPhotos = photos.sort((a, b) => new Date(b.inserted_at).getTime() - new Date(a.inserted_at).getTime());
          render();
          (el.querySelector("#ph-tag-input") as HTMLInputElement)?.focus();
        });
      });

      // Remove tag action
      el.querySelector("#ph-remove-tag")?.addEventListener("click", async () => {
        if (!tagFilter) return;
        for (const id of selectedIds) {
          const photo = allPhotos.find((p) => p.id === id);
          if (!photo) continue;
          const existing = getTags(photo);
          await ctx.api.entries.update(id, {
            data: { ...photo.data, tags: existing.filter((t) => t !== tagFilter) },
          });
        }
        selectedIds.clear();
        selectionMode = false;
        await reload();
      });
    }

    function openViewer(photoId: string) {
      const photos = filtered();
      const items = photos.map((p) => {
        const meta: Record<string, string | number | null> = {};
        if (p.data.date_taken) meta["Date taken"] = new Date(p.data.date_taken as string).toLocaleString();
        if (p.data.camera) meta["Camera"] = p.data.camera as string;
        if (p.data.latitude != null) meta["Location"] = `${(p.data.latitude as number).toFixed(5)}, ${(p.data.longitude as number).toFixed(5)}`;
        if (p.data.size) meta["Size"] = formatFileSize(p.data.size as number);
        if (p.data.filename) meta["Filename"] = p.data.filename as string;
        if (p.data.album) meta["Album"] = p.data.album as string;
        const tags = getTags(p);
        if (tags.length) meta["Tags"] = tags.join(", ");
        const photoPeople = getPeople(p);
        if (photoPeople.length) meta["People"] = photoPeople.map((pp) => pp.name).join(", ");
        return {
          id: p.id,
          src: getField(p, "path") as string,
          title: p.title || undefined,
          subtitle: (getField(p, "album") as string) || undefined,
          meta: Object.keys(meta).length ? meta : undefined,
        };
      });
      const idx = photos.findIndex((p) => p.id === photoId);
      ctx.viewer.open(items, Math.max(0, idx));
    }

    ctx.viewer.onDelete(async (id) => {
      await ctx.api.entries.delete(id);
      await reload();
    });

    async function reload() {
      const [photos, contacts] = await Promise.all([
        ctx.api.entries.list({ kind: "photo" }),
        allContacts.length ? Promise.resolve(allContacts) : ctx.api.entries.list({ kind: "contact" }),
      ]);
      allPhotos = photos.sort(
        (a, b) => new Date(b.inserted_at).getTime() - new Date(a.inserted_at).getTime(),
      );
      allContacts = contacts;
      render();
    }

    // Styles
    const style = document.createElement("style");
    style.dataset.app = "photos";
    style.textContent = `
      .ph-layout {
        display: flex;
        flex-direction: column;
        height: calc(100vh - 4rem);
      }
      .ph-toolbar {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 0.75rem 1rem;
        border-bottom: 1px solid var(--border);
        gap: 0.5rem;
      }
      .ph-filters { display: flex; gap: 0.5rem; align-items: center; }
      .ph-album-filter { width: auto; min-width: 180px; }
      .ph-sel-count { font-size: 0.9rem; color: var(--text-muted); }
      .ph-actions { display: flex; gap: 0.375rem; flex-shrink: 0; }
      .ph-btn {
        display: inline-flex;
        align-items: center;
        background: transparent;
        border: 1px solid var(--border);
        color: var(--text-muted);
        padding: 0.4rem 0.75rem;
        border-radius: 8px;
        cursor: pointer;
        font-size: 0.85rem;
        white-space: nowrap;
      }
      .ph-btn:hover { border-color: var(--primary); color: var(--text); }
      .ph-btn:disabled { opacity: 0.4; cursor: not-allowed; }
      .ph-btn:disabled:hover { border-color: var(--border); color: var(--text-muted); }
      .ph-btn--primary {
        background: var(--primary);
        border-color: var(--primary);
        color: #fff;
      }
      .ph-btn--primary:hover { background: var(--primary-hover); border-color: var(--primary-hover); }
      .ph-btn--danger { color: var(--danger); border-color: var(--danger); }
      .ph-btn--danger:hover { background: rgba(240, 108, 108, 0.08); }

      /* Tag bar */
      .ph-tags-bar {
        display: flex;
        gap: 0.375rem;
        padding: 0.5rem 1rem;
        border-bottom: 1px solid var(--border);
        overflow-x: auto;
        flex-shrink: 0;
      }
      .ph-tag-pill {
        padding: 0.2rem 0.6rem;
        border-radius: 20px;
        font-size: 0.8rem;
        background: var(--bg-hover);
        color: var(--text-muted);
        cursor: pointer;
        white-space: nowrap;
        transition: background 0.1s, color 0.1s;
      }
      .ph-tag-pill:hover { color: var(--text); }
      .ph-tag-pill--active {
        background: var(--primary);
        color: #fff;
      }

      /* People search */
      .ph-people-search {
        padding: 0.5rem 1rem;
        border-bottom: 1px solid var(--border);
        position: relative;
      }
      .ph-people-input { width: 100%; }
      .ph-people-results {
        position: absolute;
        top: 100%;
        left: 1rem;
        right: 1rem;
        background: var(--bg-surface);
        border: 1px solid var(--border);
        border-radius: 8px;
        max-height: 240px;
        overflow-y: auto;
        z-index: 10;
        box-shadow: 0 4px 16px rgba(0,0,0,0.3);
      }
      .ph-people-result {
        display: flex;
        align-items: center;
        gap: 0.6rem;
        padding: 0.5rem 0.75rem;
        cursor: pointer;
        transition: background 0.1s;
      }
      .ph-people-result:hover { background: var(--bg-hover); }
      .ph-people-avatar {
        width: 28px;
        height: 28px;
        border-radius: 50%;
        object-fit: cover;
        flex-shrink: 0;
      }
      .ph-people-avatar--init {
        display: flex;
        align-items: center;
        justify-content: center;
        background: rgba(108, 206, 201, 0.15);
        color: #6ccec9;
        font-size: 0.7rem;
        font-weight: 600;
      }
      .ph-people-no-results {
        padding: 0.75rem;
        color: var(--text-muted);
        font-size: 0.85rem;
        text-align: center;
      }
      .ph-tag-sep {
        width: 1px;
        height: 16px;
        background: var(--border);
        flex-shrink: 0;
        align-self: center;
      }
      .ph-tag-pill--person {
        background: rgba(108, 206, 201, 0.15);
        color: #6ccec9;
      }
      .ph-tag-pill--person.ph-tag-pill--active {
        background: #6ccec9;
        color: #000;
      }
      .ph-thumb-tag--person {
        background: rgba(108, 206, 201, 0.7);
      }

      .ph-uploading {
        padding: 0.5rem 1rem;
        font-size: 0.85rem;
        color: var(--primary);
        background: rgba(108, 140, 255, 0.08);
      }
      .ph-grid {
        flex: 1;
        overflow-y: auto;
        padding: 0.75rem;
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
        gap: 0.5rem;
        align-content: start;
      }
      .ph-thumb {
        position: relative;
        aspect-ratio: 1;
        border-radius: 8px;
        overflow: hidden;
        cursor: pointer;
        background: var(--bg-surface);
        transition: transform 0.15s;
      }
      .ph-thumb:hover { transform: scale(1.03); }
      .ph-thumb--selected {
        outline: 3px solid var(--primary);
        outline-offset: -3px;
      }
      .ph-thumb img {
        width: 100%;
        height: 100%;
        object-fit: cover;
        display: block;
      }
      .ph-check {
        position: absolute;
        top: 6px;
        left: 6px;
        width: 22px;
        height: 22px;
        border-radius: 50%;
        border: 2px solid rgba(255,255,255,0.6);
        background: rgba(0,0,0,0.3);
        z-index: 2;
        pointer-events: none;
      }
      .ph-check--on {
        background: var(--primary);
        border-color: var(--primary);
      }
      .ph-check--on::after {
        content: '';
        position: absolute;
        top: 4px;
        left: 6px;
        width: 5px;
        height: 9px;
        border: solid #fff;
        border-width: 0 2px 2px 0;
        transform: rotate(45deg);
      }
      .ph-thumb-tags {
        position: absolute;
        bottom: 4px;
        left: 4px;
        right: 4px;
        display: flex;
        gap: 3px;
        flex-wrap: wrap;
        z-index: 1;
      }
      .ph-thumb-tag {
        font-size: 0.65rem;
        padding: 0.1rem 0.4rem;
        background: rgba(0,0,0,0.6);
        color: #fff;
        border-radius: 4px;
        white-space: nowrap;
      }
      .ph-layout.ph-dragover {
        outline: 2px dashed var(--primary);
        outline-offset: -4px;
        background: rgba(108, 140, 255, 0.05);
      }
      .ph-broken {
        width: 100%;
        height: 100%;
        align-items: center;
        justify-content: center;
        color: var(--text-muted);
        opacity: 0.4;
        background: var(--bg-hover);
      }
      .ph-empty {
        color: var(--text-muted);
        text-align: center;
        padding: 3rem;
        grid-column: 1 / -1; /* span all */
      }

      /* Tag modal */
      .ph-modal-overlay {
        position: fixed;
        inset: 0;
        background: rgba(0, 0, 0, 0.6);
        z-index: 10000;
        display: flex;
        align-items: center;
        justify-content: center;
      }
      .ph-modal {
        background: var(--bg-surface);
        border: 1px solid var(--border);
        border-radius: 12px;
        padding: 1.5rem;
        width: 100%;
        max-width: 360px;
      }
      .ph-modal-title {
        margin: 0 0 1rem;
        font-size: 1.1rem;
      }
      .ph-modal-input {
        width: 100%;
        margin-bottom: 0.75rem;
      }
      .ph-modal-suggestions {
        display: flex;
        flex-wrap: wrap;
        gap: 0.375rem;
        margin-bottom: 1rem;
      }
      .ph-modal-suggestion {
        padding: 0.2rem 0.6rem;
        border-radius: 20px;
        font-size: 0.8rem;
        background: var(--bg-hover);
        color: var(--text-muted);
        cursor: pointer;
        transition: background 0.1s, color 0.1s;
      }
      .ph-modal-suggestion:hover {
        background: var(--primary);
        color: #fff;
      }
      .ph-modal-section-label {
        font-size: 0.75rem;
        color: var(--text-muted);
        text-transform: uppercase;
        letter-spacing: 0.03em;
        margin-bottom: 0.4rem;
      }
      .ph-modal-current-tags {
        display: flex;
        flex-wrap: wrap;
        gap: 0.375rem;
        margin-bottom: 1rem;
      }
      .ph-modal-current-tag {
        display: inline-flex;
        align-items: center;
        gap: 0.3rem;
        padding: 0.2rem 0.5rem;
        border-radius: 20px;
        font-size: 0.8rem;
        background: var(--primary);
        color: #fff;
      }
      .ph-modal-tag-remove {
        cursor: pointer;
        font-size: 1rem;
        line-height: 1;
        opacity: 0.7;
        transition: opacity 0.1s;
      }
      .ph-modal-tag-remove:hover {
        opacity: 1;
      }
      .ph-modal-actions {
        display: flex;
        gap: 0.5rem;
        justify-content: flex-end;
      }
    `;
    document.head.appendChild(style);

    el.innerHTML = '<p style="color: var(--text-muted); padding: 2rem;">Loading photos...</p>';
    reload();
  },

  unmount(el) {
    el.innerHTML = "";
    document.querySelector('style[data-app="photos"]')?.remove();
  },
};

export default photosApp;
