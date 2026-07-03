import { createApp, type App } from "vue";
import type { AppModule } from "../types";
import FilesApp from "./FilesApp.vue";

// Thin adapter: keep the AppModule contract but render a real Vue component.
let instance: App | null = null;

const filesApp: AppModule = {
  mount(el, ctx) {
    instance = createApp(FilesApp, { ctx });
    instance.mount(el);
  },
  unmount() {
    instance?.unmount();
    instance = null;
  },
};

export default filesApp;
