import { describe, it, expect, beforeEach, vi } from 'vitest'
import { mount, RouterLinkStub } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'

import AppSidebar from './AppSidebar.vue'

import { useAuthStore } from '../stores/auth'

import type { User } from '../types'

vi.mock('vue-router', () => ({
  useRoute: () => ({ name: 'app', path: '/apps/notes', params: {} }),
  useRouter: () => ({ push: vi.fn() })
}))

function mountSidebar(
  props: Partial<{ drawer: boolean; open: boolean; collapsed: boolean }> = {}
) {
  return mount(AppSidebar, {
    props: { drawer: false, open: false, collapsed: false, ...props },
    global: { stubs: { RouterLink: RouterLinkStub } },
    attachTo: document.body
  })
}

describe('AppSidebar', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    useAuthStore().user = {
      id: 'u1',
      username: 'demo',
      display_name: 'Demo',
      email: null,
      avatar_path: null,
      timezone: 'UTC',
      enabled_apps: ['notes', 'photos'],
      preferences: {}
    } as unknown as User
  })

  it('folds to a rail from its toggle, the names kept in the DOM', async () => {
    const expanded = mountSidebar()
    const toggle = expanded.find('.sidebar-collapse')
    expect(toggle.attributes('aria-label')).toBe('Collapse sidebar')
    await toggle.trigger('click')
    expect(expanded.emitted('toggleCollapsed')).toHaveLength(1)
    expanded.unmount()

    const rail = mountSidebar({ collapsed: true })
    expect(rail.find('nav').classes()).toContain('sidebar--rail')
    expect(rail.find('.sidebar-collapse').attributes('aria-label')).toBe(
      'Expand sidebar'
    )
    expect(rail.find('[data-tip="Notes"]').text()).toBe('Notes')
    rail.unmount()
  })

  it('names a rail icon in a tip on keyboard focus, and only on the rail', async () => {
    const rail = mountSidebar({ collapsed: true })
    const notes = rail.find('[data-tip="Notes"]')
    await notes.trigger('focusin')
    expect(rail.find('.sidebar-tip').text()).toBe('Notes')
    await notes.trigger('focusout')
    expect(rail.find('.sidebar-tip').exists()).toBe(false)
    rail.unmount()

    const expanded = mountSidebar()
    await expanded.find('[data-tip="Notes"]').trigger('focusin')
    expect(expanded.find('.sidebar-tip').exists()).toBe(false)
    expanded.unmount()
  })

  it('gives the drawer a close button instead of search and collapse', async () => {
    const drawer = mountSidebar({ drawer: true, open: true })
    expect(drawer.find('.sidebar-search').exists()).toBe(false)
    expect(drawer.find('.sidebar-collapse').exists()).toBe(false)
    await drawer.find('[aria-label="Close menu"]').trigger('click')
    expect(drawer.emitted('close')).toHaveLength(1)
    drawer.unmount()
  })
})
