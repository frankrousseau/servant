import { useAuthStore } from "../stores/auth";
import { useRouter } from "vue-router";
import type { AppContext, Entry, UploadResult, ViewerAPI } from "./types";
import { useConfirm } from "../composables/useConfirm";

export function createAppContext(viewer: ViewerAPI): AppContext {
  const auth = useAuthStore();
  const router = useRouter();
  const { ask } = useConfirm();

  function authHeaders(): Record<string, string> {
    const h: Record<string, string> = { "Content-Type": "application/json" };
    if (auth.token) h["Authorization"] = `Bearer ${auth.token}`;
    return h;
  }

  async function apiFetch(path: string, opts: RequestInit = {}): Promise<Response> {
    const res = await fetch(path, {
      ...opts,
      headers: { ...authHeaders(), ...(opts.headers as Record<string, string> || {}) },
    });
    if (res.status === 401) {
      auth.logout();
      throw new Error("Unauthorized");
    }
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.error || `Request failed: ${res.status}`);
    }
    return res;
  }

  async function apiJson<T>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await apiFetch(path, {
      method,
      body: body != null ? JSON.stringify(body) : undefined,
    });
    if (res.status === 204) return undefined as T;
    return res.json();
  }

  return {
    navigate(path: string) { router.push(path); },
    api: {
      entries: {
        async list(filters?: Record<string, string>): Promise<Entry[]> {
          const params = new URLSearchParams(filters);
          const res = await apiJson<{ data: Entry[] }>("GET", `/api/entries?per_page=10000&${params}`);
          return res.data;
        },
        async get(id: string): Promise<Entry> {
          const res = await apiJson<{ data: Entry }>("GET", `/api/entries/${id}`);
          return res.data;
        },
        async create(attrs: Record<string, unknown>): Promise<Entry> {
          const res = await apiJson<{ data: Entry }>("POST", "/api/entries", attrs);
          return res.data;
        },
        async update(id: string, attrs: Record<string, unknown>): Promise<Entry> {
          const res = await apiJson<{ data: Entry }>("PUT", `/api/entries/${id}`, attrs);
          return res.data;
        },
        async delete(id: string): Promise<void> {
          await apiJson<void>("DELETE", `/api/entries/${id}`);
        },
        async stats(): Promise<Record<string, number>> {
          const res = await apiJson<{ data: Record<string, number> }>("GET", "/api/entries/stats");
          return res.data;
        },
      },
      async upload(file: File, app = "files"): Promise<UploadResult> {
        const form = new FormData()
        form.append("file", file)
        form.append("app", app)
        const res = await fetch("/api/uploads", {
          method: "POST",
          headers: { Authorization: `Bearer ${auth.token}` },
          body: form,
        });
        if (!res.ok) {
          const err = await res.json().catch(() => ({}));
          throw new Error(err.error || "Upload failed");
        }
        return res.json();
      },
      fetch: apiFetch,
    },
    confirm: { ask },
    viewer,
  };
}
