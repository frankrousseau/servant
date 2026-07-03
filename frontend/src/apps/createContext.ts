import { useAuthStore } from "../stores/auth";
import { useRouter } from "vue-router";
import type { AppContext, Entry, UploadResult, ViewerAPI } from "./types";
import { useConfirm } from "../composables/useConfirm";
import { apiFetch, apiJson } from "../composables/apiClient";

export function createAppContext(viewer: ViewerAPI): AppContext {
  const auth = useAuthStore();
  const router = useRouter();
  const { ask } = useConfirm();

  return {
    navigate(path: string) {
      router.push(path);
    },
    api: {
      entries: {
        async list(filters?: Record<string, string>): Promise<Entry[]> {
          // Page through the results instead of a single hardcoded per_page=10000
          // request: that cap silently dropped entries beyond 10k and sent one
          // huge payload. Bounded pages, no cap.
          const perPage = 1000;
          const all: Entry[] = [];
          let page = 1;
          let totalPages = 1;
          do {
            const res = await apiJson<{ data: Entry[]; meta: { total_pages: number } }>(
              "GET",
              "/api/entries",
              { params: { ...(filters || {}), per_page: String(perPage), page: String(page) } },
            );
            all.push(...res.data);
            totalPages = res.meta?.total_pages ?? page;
            page++;
          } while (page <= totalPages);
          return all;
        },
        async get(id: string): Promise<Entry> {
          const res = await apiJson<{ data: Entry }>("GET", `/api/entries/${id}`);
          return res.data;
        },
        async create(attrs: Record<string, unknown>): Promise<Entry> {
          const res = await apiJson<{ data: Entry }>("POST", "/api/entries", { body: attrs });
          return res.data;
        },
        async update(id: string, attrs: Record<string, unknown>): Promise<Entry> {
          const res = await apiJson<{ data: Entry }>("PUT", `/api/entries/${id}`, { body: attrs });
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
      // Multipart upload keeps its own fetch: the browser must set the
      // multipart Content-Type boundary, so it can't go through apiFetch.
      async upload(file: File, app = "files"): Promise<UploadResult> {
        const form = new FormData();
        form.append("file", file);
        form.append("app", app);
        const res = await fetch("/api/uploads", {
          method: "POST",
          headers: auth.token ? { Authorization: `Bearer ${auth.token}` } : {},
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
