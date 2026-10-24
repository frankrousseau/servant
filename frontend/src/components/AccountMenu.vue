<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { onClickOutside } from '@vueuse/core'
import {
  Activity,
  ChevronsUpDown,
  CircleUserRound,
  Database,
  LogOut,
  Settings,
  Wrench
} from 'lucide-vue-next'

import { agentsEnabled } from '../apps/registry'
import { useAuthStore } from '../stores/auth'

// The sidebar footer: who is signed in, and behind it the pages visited
// rarely enough that they should not cost a sidebar row each. A disclosure
// rather than an ARIA menu: plain links in tab order, the list placed after
// the trigger in the DOM (shown above it) so Tab walks straight into it.
// On the folded sidebar (`rail`) the trigger is the avatar alone.
defineProps<{ rail: boolean }>()

const auth = useAuthStore()
const route = useRoute()
const router = useRouter()

const open = ref(false)
const root = ref<HTMLElement | null>(null)
const trigger = ref<HTMLButtonElement | null>(null)

const name = computed(() => auth.user?.display_name || auth.user?.username)
const initial = computed(() => (name.value ?? '?').charAt(0).toUpperCase())

const links = computed(() => [
  { to: '/profile', label: 'Profile', icon: CircleUserRound },
  { to: '/settings', label: 'Settings', icon: Settings },
  { to: '/data', label: 'Data', icon: Database },
  ...(agentsEnabled(auth.user?.enabled_apps)
    ? [{ to: '/agents', label: 'Agents', icon: Wrench }]
    : []),
  ...(auth.user?.admin
    ? [{ to: '/audit', label: 'Audit', icon: Activity }]
    : [])
])

// Lit while one of the pages behind it is on screen, so the sidebar still
// says where the user is with the list folded away.
const current = computed(() =>
  links.value.some(link => route.path.startsWith(link.to))
)

watch(() => route.fullPath, close)
onClickOutside(root, close)

function close() {
  open.value = false
}

// Escape folds the list and stops there: in the phone drawer, the same key
// would otherwise close the whole drawer.
function onEscape(event: KeyboardEvent) {
  if (!open.value) return
  event.stopPropagation()
  close()
  trigger.value?.focus()
}

function signOut() {
  auth.logout()
  router.push('/login')
}
</script>

<template>
  <div
    ref="root"
    class="account"
    :class="{ 'account--rail': rail }"
    @keydown.escape="onEscape"
  >
    <button
      ref="trigger"
      type="button"
      class="account-trigger"
      :class="{ 'account-trigger--current': current }"
      :aria-label="`Account: ${name}`"
      aria-controls="account-menu"
      :aria-expanded="open"
      :data-tip="name"
      @click="open = !open"
    >
      <img
        v-if="auth.user?.avatar_path"
        :src="auth.user.avatar_path"
        alt=""
        class="account-avatar"
      />
      <span v-else class="account-avatar account-avatar--initial">{{
        initial
      }}</span>
      <span class="account-name">{{ name }}</span>
      <ChevronsUpDown :size="16" class="account-chevron" />
    </button>
    <ul v-show="open" id="account-menu" class="account-menu">
      <li v-for="link in links" :key="link.to">
        <router-link :to="link.to" class="account-link">
          <component :is="link.icon" :size="18" />{{ link.label }}
        </router-link>
      </li>
      <li class="account-menu-end">
        <button type="button" class="account-signout" @click="signOut">
          <LogOut :size="18" />Sign out
        </button>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.account {
  position: relative;
  padding: 0.75rem;
  border-top: 1px solid var(--border);
}

/* ----- Trigger ----- */

.account-trigger {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  width: 100%;
  min-height: 44px;
  padding: 0.4rem 0.5rem;
  background: transparent;
  color: var(--text-muted);
  text-align: left;
  transition: color 0.15s;
}

.account-trigger:hover,
.account-trigger[aria-expanded='true'] {
  background: transparent;
  color: var(--text);
}

.account-trigger--current {
  color: var(--text);
}

.account-avatar {
  flex-shrink: 0;
  width: 28px;
  height: 28px;
  border-radius: 50%;
  object-fit: cover;
  border: 1px solid rgba(var(--primary-rgb), 0.5);
}

.account-avatar--initial {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: rgba(var(--primary-rgb), 0.15);
  color: var(--primary);
  font-family: var(--font-display);
  font-size: 0.875rem;
}

.account-name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.account-chevron {
  flex-shrink: 0;
}

/* ----- Menu ----- */

/* Opens upward, over the bottom of the nav: the footer sits at the very
   bottom of the sidebar, there is no room below it. A raised panel (the
   hover tone, a primary-tinted edge, a deep shadow) so it reads as
   floating over the links rather than as more sidebar. */
.account-menu {
  position: absolute;
  left: 0.75rem;
  right: 0.75rem;
  bottom: calc(100% + 0.25rem);
  z-index: 10;
  list-style: none;
  padding: 0.35rem 0;
  background: var(--bg-hover);
  border: 1px solid rgba(var(--primary-rgb), 0.35);
  border-radius: var(--radius);
  box-shadow:
    0 12px 32px rgba(0, 0, 0, 0.55),
    0 2px 6px rgba(0, 0, 0, 0.3);
}

.account-link,
.account-signout {
  display: flex;
  align-items: center;
  gap: 0.65rem;
  width: 100%;
  padding: 0.55rem 1rem;
  color: var(--text-muted);
  font-size: 1rem;
  text-decoration: none;
  transition: color 0.15s;
}

.account-link:hover,
.account-link[aria-current='page'],
.account-link.router-link-active {
  color: var(--text);
  text-decoration: none;
}

.account-menu-end {
  margin-top: 0.35rem;
  padding-top: 0.35rem;
  border-top: 1px solid var(--border);
}

.account-signout {
  background: none;
  border: none;
  border-radius: 0;
  line-height: inherit;
}

.account-signout:hover {
  background: none;
  color: var(--danger);
}

/* ----- Rail ----- */

/* The avatar alone (its name is the trigger's aria-label and the rail's
   tip), and a menu wider than the rail, reaching over the page */
.account--rail .account-trigger {
  justify-content: center;
  padding-inline: 0;
}

.account--rail .account-name,
.account--rail .account-chevron {
  display: none;
}

.account--rail .account-menu {
  right: auto;
  width: 13rem;
}
</style>
