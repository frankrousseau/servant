import { createRouter, createWebHistory } from "vue-router";
import { useAuthStore } from "../stores/auth";

// Only the entry views (guest + landing) are eager; the rest are lazy so their
// code (e.g. the connector catalog + its inline SVG logos) stays out of the
// main bundle — FE-PERF-3/4.
import LoginView from "../views/LoginView.vue";
import RegisterView from "../views/RegisterView.vue";
import DashboardView from "../views/DashboardView.vue";

const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: "/login",
      name: "login",
      component: LoginView,
      meta: { guest: true, title: "Sign In" },
    },
    {
      path: "/register",
      name: "register",
      component: RegisterView,
      meta: { guest: true, title: "Register" },
    },
    {
      path: "/",
      name: "dashboard",
      component: DashboardView,
      meta: { auth: true, title: "Dashboard" },
    },
    {
      path: "/data",
      name: "data",
      component: () => import("../views/DataBrowserView.vue"),
      meta: { auth: true, title: "Data Browser" },
    },
    {
      path: "/connectors",
      name: "connectors",
      component: () => import("../views/ConnectorsView.vue"),
      meta: { auth: true, title: "Connectors" },
    },
    {
      path: "/connectors/:id",
      name: "connector-detail",
      component: () => import("../views/ConnectorDetailView.vue"),
      meta: { auth: true, title: "Connector" },
    },
    {
      path: "/settings",
      name: "settings",
      component: () => import("../views/SettingsView.vue"),
      meta: { auth: true, title: "Settings" },
    },
    {
      path: "/apps/:appId",
      name: "app",
      component: () => import("../views/AppView.vue"),
      meta: { auth: true },
    },
    {
      path: "/contacts/:id",
      name: "contact-detail",
      component: () => import("../views/ContactDetailView.vue"),
      meta: { auth: true, title: "Contact" },
    },
    {
      path: "/photos/:id",
      name: "photo-detail",
      component: () => import("../views/PhotoDetailView.vue"),
      meta: { auth: true, title: "Photo" },
    },
  ],
});

router.beforeEach((to) => {
  const auth = useAuthStore();

  if (to.meta.auth && !auth.isAuthenticated) {
    return { name: "login" };
  }

  if (to.meta.guest && auth.isAuthenticated) {
    return { name: "dashboard" };
  }
});

router.afterEach((to) => {
  const section = to.meta.title as string | undefined;
  document.title = section ? `Servant | ${section}` : "Servant";
});

export default router;
