import { createApp, type App } from "vue";
import type { AppModule } from "../types";
import CalendarApp from "./CalendarApp.vue";

// Thin adapter: keep the AppModule contract but render a real Vue component.
let instance: App | null = null;

const calendarApp: AppModule = {
  mount(el, ctx) {
    instance = createApp(CalendarApp, { ctx });
    instance.mount(el);
  },
  unmount() {
    instance?.unmount();
    instance = null;
  },
};

export default calendarApp;
