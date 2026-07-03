import { apiJson } from "./apiClient";

export function useApi() {
  return {
    get<T>(path: string, params?: Record<string, string>) {
      return apiJson<T>("GET", path, { params });
    },
    post<T>(path: string, body?: unknown) {
      return apiJson<T>("POST", path, { body });
    },
    put<T>(path: string, body?: unknown) {
      return apiJson<T>("PUT", path, { body });
    },
    del<T>(path: string) {
      return apiJson<T>("DELETE", path);
    },
  };
}
