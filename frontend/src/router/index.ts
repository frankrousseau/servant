import { createRouter, createWebHistory } from "vue-router";
import { useAuthStore } from "../stores/auth";

import LoginView from "../views/LoginView.vue";
import RegisterView from "../views/RegisterView.vue";
import DashboardView from "../views/DashboardView.vue";
import DataBrowserView from "../views/DataBrowserView.vue";
import ConnectorsView from "../views/ConnectorsView.vue";
import ConnectorDetailView from "../views/ConnectorDetailView.vue";
import SettingsView from "../views/SettingsView.vue";
import AppView from "../views/AppView.vue";

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
      component: DataBrowserView,
      meta: { auth: true, title: "Data Browser" },
    },
    {
      path: "/connectors",
      name: "connectors",
      component: ConnectorsView,
      meta: { auth: true, title: "Connectors" },
    },
    {
      path: "/connectors/:id",
      name: "connector-detail",
      component: ConnectorDetailView,
      meta: { auth: true, title: "Connector" },
    },
    {
      path: "/settings",
      name: "settings",
      component: SettingsView,
      meta: { auth: true, title: "Settings" },
    },
    {
      path: "/apps/:appId",
      name: "app",
      component: AppView,
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
