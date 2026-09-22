import { createRouter, createWebHistory } from 'vue-router'

// Only the auth entry views are eager. The dashboard is lazy too: it pulls in
// the connector catalog (hundreds of lines of inline SVG) and the phoenix
// socket lib, which we don't want in the main bundle.
import LoginView from '../views/LoginView.vue'
import RegisterView from '../views/RegisterView.vue'

import { useAuthStore } from '../stores/auth'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/login',
      name: 'login',
      component: LoginView,
      meta: { guest: true, title: 'Sign In' }
    },
    {
      path: '/register',
      name: 'register',
      component: RegisterView,
      meta: { guest: true, title: 'Register' }
    },
    {
      path: '/',
      name: 'dashboard',
      component: () => import('../views/DashboardView.vue'),
      meta: { auth: true, title: 'Dashboard' }
    },
    {
      path: '/data',
      name: 'data',
      component: () => import('../views/DataBrowserView.vue'),
      meta: { auth: true, title: 'Data Browser' }
    },
    {
      path: '/connectors',
      name: 'connectors',
      component: () => import('../views/ConnectorsView.vue'),
      meta: { auth: true, title: 'Connectors' }
    },
    {
      // Fixed PSD2 consent-flow return URL (registered once in the Enable
      // Banking app); the connector config id travels in ?state.
      path: '/connectors/eb-callback',
      name: 'connector-eb-callback',
      component: () => import('../views/EnableBankingCallbackView.vue'),
      meta: { auth: true, title: 'Bank connection' }
    },
    {
      path: '/connectors/:id',
      name: 'connector-detail',
      component: () => import('../views/ConnectorDetailView.vue'),
      meta: { auth: true, title: 'Connector' }
    },
    {
      path: '/agents',
      name: 'agents',
      component: () => import('../views/AgentsView.vue'),
      meta: { auth: true, title: 'Agents' }
    },
    {
      path: '/audit',
      name: 'audit',
      component: () => import('../views/AuditView.vue'),
      meta: { auth: true, title: 'Audit' }
    },
    {
      path: '/settings',
      name: 'settings',
      component: () => import('../views/SettingsView.vue'),
      meta: { auth: true, title: 'Settings' }
    },
    {
      path: '/profile',
      name: 'profile',
      component: () => import('../views/ProfileView.vue'),
      meta: { auth: true, title: 'Profile' }
    },
    {
      path: '/apps/:appId',
      name: 'app',
      component: () => import('../views/AppView.vue'),
      meta: { auth: true }
    },
    {
      // The contact page merged into the Contacts app; keep the permalink.
      path: '/contacts/:id',
      redirect: to => ({
        path: '/apps/contacts',
        query: { selected: to.params.id }
      })
    },
    {
      path: '/photos/:id',
      name: 'photo-detail',
      component: () => import('../views/PhotoDetailView.vue'),
      meta: { auth: true, title: 'Photo' }
    },
    {
      // Public photo feed behind a share link: no session needed, the token
      // in the URL is the credential (see Servant.PhotoShares).
      path: '/share/:token',
      name: 'shared-feed',
      component: () => import('../views/SharedFeedView.vue'),
      meta: { public: true, title: 'Shared photos' }
    }
  ]
})

router.beforeEach(to => {
  const auth = useAuthStore()

  if (to.meta.auth && !auth.isAuthenticated) {
    return { name: 'login' }
  }

  if (to.meta.guest && auth.isAuthenticated) {
    return { name: 'dashboard' }
  }
})

router.afterEach(to => {
  const section = to.meta.title as string | undefined
  document.title = section ? `Servant | ${section}` : 'Servant'
})

export default router
