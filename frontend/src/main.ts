import { createApp } from "vue";
import pinia from "./stores";
import router from "./router";
import App from "./App.vue";
import { useAuthStore } from "./stores/auth";
import "@fontsource/vt323/index.css";
import "./style.css";

const app = createApp(App);
app.use(pinia);
app.use(router);

// Restore the current user from the persisted token before/while the app mounts
// (token survives reloads, the user object doesn't) — see FE-ARCH-2.
useAuthStore(pinia).hydrate();

app.mount("#app");
