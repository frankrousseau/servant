import type { AppModule, Entry } from "../types";

import { escapeHtml } from "../escapeHtml";

// Returns the URL only if it uses a safe scheme, else null — blocks stored XSS
// from vCard fields like `URL:javascript:...` rendered into an href.
function safeUrl(url: string): string | null {
  try {
    const scheme = new URL(url, window.location.origin).protocol;
    return ["http:", "https:", "mailto:", "tel:"].includes(scheme) ? url : null;
  } catch {
    return null;
  }
}

function f(entry: Entry, key: string): string {
  const val = (entry.data[key] as string) || "";
  const cleaned = val.trim().replace(/^;+|;+$/g, "").trim();
  return cleaned;
}

function cleanName(raw: string): string {
  return raw
    .replace(/^["'«»\u201c\u201d\u2018\u2019]+|["'«»\u201c\u201d\u2018\u2019]+$/g, "")
    .trim();
}

function contactName(c: Entry): string {
  const name = f(c, "display_name") || c.title?.split(" \u2014 ")[0] || "";
  const cleaned = cleanName(name);
  return cleaned || "(unnamed)";
}

function isUnnamed(c: Entry): boolean {
  return contactName(c) === "(unnamed)";
}

function getInitials(name: string): string {
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() || "")
    .join("");
}

function getEmails(entry: Entry): { value: string; type: string }[] {
  return (entry.data.emails as { value: string; type: string }[]) || [];
}

function getPhones(entry: Entry): { value: string; type: string }[] {
  return (entry.data.phones as { value: string; type: string }[]) || [];
}

const contactApp: AppModule = {
  mount(el, ctx) {
    let allContacts: Entry[] = [];
    let searchQuery = "";
    let selectedId: string | null = new URLSearchParams(
      window.location.search,
    ).get("selected");
    let modalOpen = false;

    function filtered(): Entry[] {
      if (!searchQuery) return allContacts;
      const q = searchQuery.toLowerCase();
      return allContacts.filter((c) => {
        const name = contactName(c).toLowerCase();
        const org = f(c, "org").toLowerCase();
        const email = getEmails(c)
          .map((e) => e.value.toLowerCase())
          .join(" ");
        const phone = getPhones(c)
          .map((p) => p.value)
          .join(" ");
        return (
          name.includes(q) ||
          org.includes(q) ||
          email.includes(q) ||
          phone.includes(q)
        );
      });
    }

    function selected(): Entry | null {
      return allContacts.find((c) => c.id === selectedId) || null;
    }

    // Tracked so it's removed on *any* close path (Escape, overlay, Cancel,
    // re-render), not only when Escape is pressed — avoids a keydown leak.
    let onKey: ((e: KeyboardEvent) => void) | null = null;

    function openCreateModal() {
      modalOpen = true;
      renderModal();
    }

    function closeCreateModal() {
      modalOpen = false;
      if (onKey) {
        document.removeEventListener("keydown", onKey);
        onKey = null;
      }
      const overlay = document.querySelector(".ct-modal-overlay");
      if (overlay) overlay.remove();
    }

    function renderModal() {
      // Remove existing modal if any
      document.querySelector(".ct-modal-overlay")?.remove();
      if (!modalOpen) return;

      const overlay = document.createElement("div");
      overlay.className = "ct-modal-overlay";
      overlay.innerHTML =
        '<div class="ct-modal">'
        + '<h2 class="ct-modal-title">New Contact</h2>'
        + '<form class="ct-modal-form">'
        + '<div class="ct-modal-grid">'
        + '<div class="ct-modal-field"><label>Name *</label><input name="display_name" required /></div>'
        + '<div class="ct-modal-field"><label>Organization</label><input name="org" /></div>'
        + '<div class="ct-modal-field"><label>Title</label><input name="title" placeholder="e.g. Software Engineer" /></div>'
        + '</div>'
        + '<div class="ct-modal-section-label">Contact</div>'
        + '<div class="ct-modal-row"><input name="email" type="email" placeholder="Email" class="ct-modal-flex" /><input name="email_type" placeholder="Type" class="ct-modal-type" /></div>'
        + '<div class="ct-modal-row"><input name="phone" type="tel" placeholder="Phone" class="ct-modal-flex" /><input name="phone_type" placeholder="Type" class="ct-modal-type" /></div>'
        + '<div class="ct-modal-section-label">Details</div>'
        + '<div class="ct-modal-field"><label>Address</label><input name="address" /></div>'
        + '<div class="ct-modal-grid">'
        + '<div class="ct-modal-field"><label>Birthday</label><input name="birthday" type="date" /></div>'
        + '<div class="ct-modal-field"><label>Website</label><input name="url" type="url" placeholder="https://..." /></div>'
        + '</div>'
        + '<div class="ct-modal-field"><label>Note</label><textarea name="note" rows="2"></textarea></div>'
        + '<p class="ct-modal-error" style="display:none"></p>'
        + '<div class="ct-modal-actions">'
        + '<button type="button" class="ct-modal-btn ct-modal-btn--cancel">Cancel</button>'
        + '<button type="submit" class="ct-modal-btn ct-modal-btn--primary">Create</button>'
        + '</div>'
        + '</form>'
        + '</div>';

      document.body.appendChild(overlay);

      // Close on overlay click
      overlay.addEventListener("click", (e) => {
        if (e.target === overlay) closeCreateModal();
      });

      // Close on Escape (cleanup handled by closeCreateModal)
      onKey = (e: KeyboardEvent) => {
        if (e.key === "Escape") closeCreateModal();
      };
      document.addEventListener("keydown", onKey);

      // Cancel button
      overlay.querySelector(".ct-modal-btn--cancel")!.addEventListener("click", closeCreateModal);

      // Focus first input
      (overlay.querySelector('input[name="display_name"]') as HTMLInputElement)?.focus();

      // Submit
      const form = overlay.querySelector(".ct-modal-form") as HTMLFormElement;
      form.addEventListener("submit", async (e) => {
        e.preventDefault();
        const fd = new FormData(form);
        const displayName = (fd.get("display_name") as string || "").trim();
        if (!displayName) return;

        const submitBtn = form.querySelector('button[type="submit"]') as HTMLButtonElement;
        const errorEl = form.querySelector(".ct-modal-error") as HTMLElement;
        submitBtn.disabled = true;
        submitBtn.textContent = "Creating...";
        errorEl.style.display = "none";

        const emails: { value: string; type: string }[] = [];
        const emailVal = (fd.get("email") as string || "").trim();
        if (emailVal) emails.push({ value: emailVal, type: (fd.get("email_type") as string || "").trim() });

        const phones: { value: string; type: string }[] = [];
        const phoneVal = (fd.get("phone") as string || "").trim();
        if (phoneVal) phones.push({ value: phoneVal, type: (fd.get("phone_type") as string || "").trim() });

        const titleParts = [displayName, fd.get("org"), fd.get("title"), emailVal].filter(Boolean);

        try {
          const created = await ctx.api.entries.create({
            kind: "contact",
            source: "manual",
            title: titleParts.join(" — "),
            data: {
              display_name: displayName,
              org: (fd.get("org") as string || "").trim() || null,
              title: (fd.get("title") as string || "").trim() || null,
              emails,
              phones,
              address: (fd.get("address") as string || "").trim() || null,
              birthday: (fd.get("birthday") as string || "").trim() || null,
              url: (fd.get("url") as string || "").trim() || null,
              note: (fd.get("note") as string || "").trim() || null,
            },
          });
          closeCreateModal();
          allContacts.push(created);
          allContacts.sort((a, b) => {
            const aUn = isUnnamed(a);
            const bUn = isUnnamed(b);
            if (aUn !== bUn) return aUn ? 1 : -1;
            return contactName(a).toLowerCase().localeCompare(contactName(b).toLowerCase());
          });
          selectedId = created.id;
          history.replaceState(null, "", "/apps/contacts?selected=" + created.id);
          render();
        } catch (err: any) {
          errorEl.textContent = err.message || "Failed to create contact";
          errorEl.style.display = "block";
          submitBtn.disabled = false;
          submitBtn.textContent = "Create";
        }
      });
    }

    function render() {
      const contacts = filtered();
      const sel = selected();

      // Build card list
      const cardsHtml = contacts
        .map((c) => {
          const name = contactName(c);
          const org = f(c, "org");
          const email = getEmails(c)[0]?.value || "";
          const photo = f(c, "photo");
          const avatarHtml = photo
            ? '<span class="ct-avatar ct-avatar--photo"><img src="'
              + escapeHtml(photo)
              + '" alt="" loading="lazy" /></span>'
            : '<span class="ct-avatar">'
              + escapeHtml(getInitials(name))
              + "</span>";
          const activeCls = c.id === selectedId ? " ct-card--active" : "";
          return (
            '<div class="ct-card'
            + activeCls
            + '" data-id="'
            + c.id
            + '">'
            + avatarHtml
            + '<div class="ct-card-body">'
            + '<span class="ct-name">'
            + escapeHtml(name)
            + "</span>"
            + '<span class="ct-sub">'
            + escapeHtml(org || email)
            + "</span>"
            + "</div></div>"
          );
        })
        .join("");

      const emptyHtml =
        contacts.length === 0
          ? '<p class="ct-empty">No contacts found.</p>'
          : "";

      const detailHtml = sel
        ? renderDetail(sel)
        : '<p class="ct-placeholder">Select a contact to view details</p>';

      el.innerHTML =
        '<div class="ct-layout">'
        + '<div class="ct-list-col">'
        + '<div class="ct-search-wrap">'
        + '<input class="ct-search" type="text" placeholder="Search contacts..." value="'
        + escapeHtml(searchQuery)
        + '" />'
        + '<span class="ct-count">'
        + contacts.length
        + "</span>"
        + '<button class="ct-add-contact-btn" title="New contact">'
        + '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>'
        + '</button>'
        + "</div>"
        + '<div class="ct-list">'
        + cardsHtml
        + emptyHtml
        + "</div>"
        + "</div>"
        + '<div class="ct-detail-col">'
        + detailHtml
        + "</div>"
        + "</div>";

      // Search
      const searchInput = el.querySelector(
        ".ct-search",
      ) as HTMLInputElement | null;
      if (searchInput) {
        searchInput.addEventListener("input", (e) => {
          searchQuery = (e.target as HTMLInputElement).value;
          selectedId = null;
          history.replaceState(null, "", "/apps/contacts");
          render();
          const input = el.querySelector(
            ".ct-search",
          ) as HTMLInputElement | null;
          if (input) {
            input.focus();
            input.setSelectionRange(searchQuery.length, searchQuery.length);
          }
        });
      }

      // Card clicks
      el.querySelectorAll(".ct-card").forEach((card) => {
        card.addEventListener("click", () => {
          selectedId = (card as HTMLElement).dataset.id || null;
          const url = selectedId
            ? "/apps/contacts?selected=" + selectedId
            : "/apps/contacts";
          history.replaceState(null, "", url);
          render();
        });
      });

      // Add contact button
      const addBtn = el.querySelector(".ct-add-contact-btn");
      if (addBtn) {
        addBtn.addEventListener("click", openCreateModal);
      }

    }

    function renderDetail(c: Entry): string {
      const name = contactName(c);
      const org = f(c, "org");
      const title = f(c, "title");
      const emails = getEmails(c);
      const phones = getPhones(c);
      const address = f(c, "address");
      const birthday = f(c, "birthday");
      const note = f(c, "note");
      const url = f(c, "url");
      const photo = f(c, "photo");
      const sourceName = f(c, "source_name");

      const avatarHtml = photo
        ? '<span class="ct-avatar ct-avatar--lg ct-avatar--photo"><img src="'
          + escapeHtml(photo)
          + '" alt="" loading="lazy" /></span>'
        : '<span class="ct-avatar ct-avatar--lg">'
          + escapeHtml(getInitials(name))
          + "</span>";

      // Contact info rows
      const emailRows = emails
        .map(
          (e) =>
            '<div class="ct-info-row">'
            + '<svg class="ct-info-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="20" height="16" x="2" y="4" rx="2"/><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"/></svg>'
            + '<div class="ct-info-body">'
            + '<a class="ct-link" href="mailto:'
            + escapeHtml(e.value)
            + '">'
            + escapeHtml(e.value)
            + "</a>"
            + (e.type
              ? '<span class="ct-info-type">' + escapeHtml(e.type) + "</span>"
              : "")
            + "</div></div>",
        )
        .join("");

      const phoneRows = phones
        .map(
          (p) =>
            '<div class="ct-info-row">'
            + '<svg class="ct-info-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/></svg>'
            + '<div class="ct-info-body">'
            + '<a class="ct-link" href="tel:'
            + escapeHtml(p.value)
            + '">'
            + escapeHtml(p.value)
            + "</a>"
            + (p.type
              ? '<span class="ct-info-type">' + escapeHtml(p.type) + "</span>"
              : "")
            + "</div></div>",
        )
        .join("");

      const contactRows = emailRows + phoneRows;

      // Personal details
      const detailRows: string[] = [];
      if (address)
        detailRows.push(
          '<div class="ct-meta-row"><span class="ct-meta-key">Address</span><span>'
            + escapeHtml(address)
            + "</span></div>",
        );
      if (birthday)
        detailRows.push(
          '<div class="ct-meta-row"><span class="ct-meta-key">Birthday</span><span>'
            + escapeHtml(birthday)
            + "</span></div>",
        );
      if (url) {
        const safe = safeUrl(url);
        const label = escapeHtml(url);
        const value = safe
          ? '<a class="ct-link" href="'
            + escapeHtml(safe)
            + '" target="_blank" rel="noopener">'
            + label
            + "</a>"
          : label;
        detailRows.push(
          '<div class="ct-meta-row"><span class="ct-meta-key">Website</span><span>'
            + value
            + "</span></div>",
        );
      }
      if (note)
        detailRows.push(
          '<div class="ct-meta-row"><span class="ct-meta-key">Note</span><span class="ct-note">'
            + escapeHtml(note)
            + "</span></div>",
        );

      // Audit / meta
      const auditRows: string[] = [];
      auditRows.push(
        '<div class="ct-meta-row"><span class="ct-meta-key">Source</span><span>'
          + escapeHtml(sourceName || c.source)
          + "</span></div>",
      );
      auditRows.push(
        '<div class="ct-meta-row"><span class="ct-meta-key">Added</span><span>'
          + new Date(c.inserted_at).toLocaleDateString()
          + "</span></div>",
      );
      if (c.external_id)
        auditRows.push(
          '<div class="ct-meta-row"><span class="ct-meta-key">ID</span><span class="ct-mono">'
            + escapeHtml(c.external_id)
            + "</span></div>",
        );

      const titleOrgSub = title || org
        ? '<span class="ct-detail-sub">'
          + escapeHtml([title, org].filter(Boolean).join(" \u00b7 "))
          + "</span>"
        : "";

      const contactInfoSection =
        '<div class="ct-section-card">'
        + '<h3 class="ct-section-title">Contact Info</h3>'
        + contactRows
        + (!emails.length && !phones.length
          ? '<span class="ct-muted">No contact info</span>'
          : "")
        + "</div>";

      const detailsSection = detailRows.length
        ? '<div class="ct-section-card">'
          + '<h3 class="ct-section-title">Details</h3>'
          + '<div class="ct-meta-list">'
          + detailRows.join("")
          + "</div></div>"
        : "";

      const auditSection =
        '<div class="ct-section-card ct-section-card--muted">'
        + '<h3 class="ct-section-title">Info</h3>'
        + '<div class="ct-meta-list">'
        + auditRows.join("")
        + "</div></div>";

      return (
        '<div class="ct-detail">'
        + '<div class="ct-detail-header">'
        + avatarHtml
        + "<div>"
        + '<h2 class="ct-detail-name">'
        + escapeHtml(name)
        + "</h2>"
        + titleOrgSub
        + "</div></div>"
        + contactInfoSection
        + detailsSection
        + auditSection
        + '<div class="ct-detail-footer">'
        + '<button class="ct-footer-btn" data-href="/contacts/'
        + c.id
        + '?edit=1">Edit</button>'
        + '<button class="ct-footer-btn ct-footer-btn--link" data-href="/contacts/'
        + c.id
        + '">Open full page</button>'
        + "</div></div>"
      );
    }

    // Delegated navigation for [data-href] buttons
    el.addEventListener("click", (e) => {
      const target = (e.target as HTMLElement).closest("[data-href]") as HTMLElement | null;
      if (target) {
        e.preventDefault();
        ctx.navigate(target.dataset.href!);
      }
    });

    // Styles
    const style = document.createElement("style");
    style.dataset.app = "contacts";
    style.textContent = [
      ".ct-layout { display: flex; height: calc(100vh - 4rem); }",
      ".ct-list-col { width: 360px; flex-shrink: 0; display: flex; flex-direction: column; border-right: 1px solid var(--border); }",
      ".ct-detail-col { flex: 1; overflow-y: auto; padding: 1.5rem; }",
      ".ct-search-wrap { padding: 0.75rem; display: flex; align-items: center; gap: 0.5rem; border-bottom: 1px solid var(--border); }",
      ".ct-search { flex: 1; }",
      ".ct-count { font-size: 0.8rem; color: var(--text-muted); white-space: nowrap; }",
      ".ct-list { flex: 1; overflow-y: auto; padding: 0.375rem; }",
      ".ct-card { display: flex; align-items: center; gap: 0.75rem; padding: 0.6rem 0.75rem; border-radius: 8px; cursor: pointer; transition: background 0.1s; }",
      ".ct-card:hover { background: var(--bg-hover); }",
      ".ct-card--active { background: var(--bg-hover); }",
      ".ct-avatar { width: 36px; height: 36px; border-radius: 50%; background: rgba(108, 206, 201, 0.15); color: #6ccec9; display: flex; align-items: center; justify-content: center; font-size: 0.8rem; font-weight: 600; flex-shrink: 0; }",
      ".ct-avatar--lg { width: 56px; height: 56px; font-size: 1.2rem; }",
      ".ct-card-body { min-width: 0; display: flex; flex-direction: column; }",
      ".ct-name { font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }",
      ".ct-sub { font-size: 0.85rem; color: var(--text-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }",
      ".ct-empty, .ct-placeholder { color: var(--text-muted); text-align: center; padding: 3rem 1rem; }",
      ".ct-detail-header { display: flex; align-items: center; gap: 1rem; margin-bottom: 1.25rem; }",
      ".ct-detail-name { margin: 0; font-size: 1.25rem; }",
      ".ct-detail-sub { font-size: 0.9rem; color: var(--text-muted); }",
      ".ct-avatar--photo { padding: 0; background: none; }",
      ".ct-avatar--photo img { width: 100%; height: 100%; object-fit: cover; display: block; border-radius: 50%; }",
      ".ct-section-card { background: var(--bg-surface); border: 1px solid var(--border); border-radius: 10px; padding: 1rem; margin-bottom: 0.75rem; }",
      ".ct-section-card--muted { background: transparent; border-color: var(--border); opacity: 0.7; }",
      ".ct-section-title { margin: 0 0 0.6rem; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); }",
      ".ct-info-row { display: flex; align-items: flex-start; gap: 0.6rem; padding: 0.45rem 0; border-bottom: 1px solid var(--border); }",
      ".ct-info-row:last-of-type { border-bottom: none; }",
      ".ct-info-icon { color: var(--text-muted); margin-top: 0.15rem; flex-shrink: 0; }",
      ".ct-info-body { display: flex; flex-direction: column; }",
      ".ct-info-type { font-size: 0.75rem; color: var(--text-muted); text-transform: capitalize; }",
      ".ct-meta-list { display: flex; flex-direction: column; }",
      ".ct-meta-row { display: flex; justify-content: space-between; align-items: baseline; gap: 1rem; padding: 0.4rem 0; border-bottom: 1px solid var(--border); font-size: 0.9rem; }",
      ".ct-meta-row:last-child { border-bottom: none; }",
      ".ct-meta-key { color: var(--text-muted); flex-shrink: 0; }",
      ".ct-link { color: var(--primary); text-decoration: none; word-break: break-all; }",
      ".ct-link:hover { text-decoration: underline; }",
      ".ct-muted { color: var(--text-muted); font-size: 0.9rem; }",
      ".ct-note { white-space: pre-wrap; font-size: 0.9rem; color: var(--text-muted); }",
      ".ct-mono { font-family: monospace; font-size: 0.85rem; }",
      ".ct-detail-footer { margin-top: 0.5rem; padding-top: 0.75rem; border-top: 1px solid var(--border); display: flex; gap: 1rem; }",
      ".ct-footer-btn { font-size: 0.85rem; color: var(--text-muted); background: transparent; border: 1px solid var(--border); padding: 0.4rem 0.75rem; border-radius: 8px; cursor: pointer; }",
      ".ct-footer-btn:hover { border-color: var(--primary); color: var(--text); }",
      ".ct-footer-btn--link { border: none; color: var(--primary); padding: 0.4rem 0; }",
      ".ct-footer-btn--link:hover { text-decoration: underline; background: none; color: var(--primary); }",
      ".ct-add-contact-btn { display: flex; align-items: center; justify-content: center; width: 32px; height: 32px; border-radius: 8px; border: 1px solid var(--border); background: transparent; color: var(--text-muted); cursor: pointer; flex-shrink: 0; padding: 0; }",
      ".ct-add-contact-btn:hover { border-color: var(--primary); color: var(--primary); }",
      ".ct-modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.6); z-index: 10000; display: flex; align-items: center; justify-content: center; }",
      ".ct-modal { background: var(--bg-surface); border: 1px solid var(--border); border-radius: 12px; padding: 1.5rem; width: 100%; max-width: 520px; max-height: 90vh; overflow-y: auto; }",
      ".ct-modal-title { margin: 0 0 1.25rem; font-size: 1.15rem; }",
      ".ct-modal-form { display: flex; flex-direction: column; gap: 0.5rem; }",
      ".ct-modal-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }",
      ".ct-modal-grid:has(:nth-child(3)) { grid-template-columns: 1fr 1fr 1fr; }",
      ".ct-modal-field { display: flex; flex-direction: column; gap: 0.25rem; }",
      ".ct-modal-field label { font-size: 0.8rem; color: var(--text-muted); }",
      ".ct-modal-section-label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); margin-top: 0.5rem; }",
      ".ct-modal-row { display: flex; gap: 0.375rem; }",
      ".ct-modal-flex { flex: 1; }",
      ".ct-modal-type { width: 90px; }",
      ".ct-modal-error { color: var(--danger); font-size: 0.85rem; margin: 0; }",
      ".ct-modal-actions { display: flex; justify-content: flex-end; gap: 0.5rem; margin-top: 0.75rem; }",
      ".ct-modal-btn { padding: 0.5rem 1rem; border-radius: 8px; font-size: 0.9rem; font-weight: 500; cursor: pointer; }",
      ".ct-modal-btn--cancel { background: transparent; border: 1px solid var(--border); color: var(--text); }",
      ".ct-modal-btn--cancel:hover { border-color: var(--text-muted); }",
      ".ct-modal-btn--primary { background: var(--primary); border: 1px solid var(--primary); color: #fff; }",
      ".ct-modal-btn--primary:hover { background: var(--primary-hover); border-color: var(--primary-hover); }",
      ".ct-modal-btn--primary:disabled { opacity: 0.6; cursor: not-allowed; }",
      ".ct-modal input, .ct-modal textarea { color-scheme: dark; }",
    ].join("\n");
    document.head.appendChild(style);

    // Load and render
    el.innerHTML =
      '<p style="color: var(--text-muted); padding: 2rem;">Loading contacts...</p>';

    ctx.api.entries.list({ kind: "contact" }).then((entries) => {
      allContacts = entries.sort((a, b) => {
        const aUn = isUnnamed(a);
        const bUn = isUnnamed(b);
        if (aUn !== bUn) return aUn ? 1 : -1;
        return contactName(a)
          .toLowerCase()
          .localeCompare(contactName(b).toLowerCase());
      });
      render();
    });
  },

  unmount(el) {
    el.innerHTML = "";
    document.querySelector(".ct-modal-overlay")?.remove();
    document.querySelector('style[data-app="contacts"]')?.remove();
  },
};

export default contactApp;
