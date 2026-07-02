import { ref, watch, onUnmounted } from "vue";
import { Socket, Channel } from "phoenix";
import { useAuthStore } from "../stores/auth";
import type { Entry } from "../types";

export function useSocket() {
  const auth = useAuthStore();
  let socket: Socket | null = null;
  let channel: Channel | null = null;

  const connected = ref(false);
  const entryChangeCallbacks: Array<(entry: Entry) => void> = [];

  function onEntryChange(cb: (entry: Entry) => void) {
    entryChangeCallbacks.push(cb);
  }

  function connect() {
    if (!auth.token || !auth.user) return;

    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const socketUrl = `${protocol}//${window.location.host}/socket`;

    socket = new Socket(socketUrl, {
      params: { token: auth.token },
    });

    socket.connect();

    channel = socket.channel(`data:${auth.user.id}`, {});
    channel
      .join()
      .receive("ok", () => {
        connected.value = true;
      })
      .receive("error", () => {
        connected.value = false;
      });

    channel.on("entry_change", (payload: { entry: Entry }) => {
      for (const cb of entryChangeCallbacks) {
        cb(payload.entry);
      }
    });
  }

  function disconnect() {
    if (channel) {
      channel.leave();
      channel = null;
    }
    if (socket) {
      socket.disconnect();
      socket = null;
    }
    connected.value = false;
  }

  // Connect only once both the token AND the user are available. On a reload
  // the user is populated asynchronously (auth.hydrate), so we must react to it
  // and not just to the token.
  watch(
    () => auth.isAuthenticated && !!auth.user,
    (ready) => {
      if (ready) {
        connect();
      } else {
        disconnect();
      }
    },
    { immediate: true },
  );

  onUnmounted(() => {
    disconnect();
  });

  return { connected, onEntryChange };
}
