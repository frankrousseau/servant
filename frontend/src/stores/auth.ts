import { defineStore } from "pinia";
import { ref, computed } from "vue";
import type { User } from "../types";

export const useAuthStore = defineStore("auth", () => {
  const token = ref<string | null>(localStorage.getItem("auth_token"));
  const user = ref<User | null>(null);

  const isAuthenticated = computed(() => !!token.value);

  function setAuth(newToken: string, newUser: User) {
    token.value = newToken;
    user.value = newUser;
    localStorage.setItem("auth_token", newToken);
  }

  function clearAuth() {
    token.value = null;
    user.value = null;
    localStorage.removeItem("auth_token");
  }

  async function login(username: string, password: string) {
    const res = await fetch("/api/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password }),
    });

    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.error || "Login failed");
    }

    const data = await res.json();
    setAuth(data.token, data.user);
  }

  async function register(
    username: string,
    password: string,
    display_name: string,
  ) {
    const res = await fetch("/api/auth/register", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password, display_name }),
    });

    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.error || "Registration failed");
    }

    const data = await res.json();
    setAuth(data.token, data.user);
  }

  function logout() {
    // Clear the HttpOnly file-auth cookie server-side (BE-SEC-1), then locally.
    fetch("/api/auth/logout", { method: "POST" }).catch(() => {});
    clearAuth();
  }

  // On a page reload the token is restored from localStorage but `user` is not.
  // Fetch it so realtime (useSocket needs auth.user) and user-dependent UI work
  // again after a refresh. Clears auth on an expired/invalid token.
  async function hydrate() {
    if (!token.value || user.value) return;

    try {
      const res = await fetch("/api/auth/me", {
        headers: { Authorization: `Bearer ${token.value}` },
      });

      if (res.ok) {
        const data = await res.json();
        user.value = data.data;
      } else if (res.status === 401) {
        clearAuth();
      }
    } catch {
      // Network error — keep the token and retry on the next boot.
    }
  }

  return { token, user, isAuthenticated, login, register, logout, hydrate };
});
