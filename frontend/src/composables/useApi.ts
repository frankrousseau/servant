import { useAuthStore } from "../stores/auth";

interface RequestOptions {
  body?: unknown;
  params?: Record<string, string>;
}

async function request<T>(
  method: string,
  path: string,
  options: RequestOptions = {},
): Promise<T> {
  const auth = useAuthStore();

  const url = new URL(path, window.location.origin);
  if (options.params) {
    for (const [key, value] of Object.entries(options.params)) {
      url.searchParams.set(key, value);
    }
  }

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };

  if (auth.token) {
    headers["Authorization"] = `Bearer ${auth.token}`;
  }

  const res = await fetch(url.toString(), {
    method,
    headers,
    body: options.body != null ? JSON.stringify(options.body) : undefined,
  });

  if (res.status === 401) {
    auth.logout();
    throw new Error("Unauthorized");
  }

  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.error || `Request failed: ${res.status}`);
  }

  if (res.status === 204) {
    return undefined as T;
  }

  return res.json();
}

export function useApi() {
  return {
    get<T>(path: string, params?: Record<string, string>) {
      return request<T>("GET", path, { params });
    },
    post<T>(path: string, body?: unknown) {
      return request<T>("POST", path, { body });
    },
    put<T>(path: string, body?: unknown) {
      return request<T>("PUT", path, { body });
    },
    del<T>(path: string) {
      return request<T>("DELETE", path);
    },
  };
}
