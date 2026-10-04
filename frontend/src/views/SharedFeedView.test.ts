import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

import SharedFeedView from './SharedFeedView.vue'

import type { SharedFeed } from '../types'

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { token: 'tok123' } })
}))

// The viewer resolves <router-link> at render time even when its v-if is off.
const mountOptions = { global: { stubs: { RouterLink: true } } }

const feed: SharedFeed = {
  name: null,
  tags: ['beach', 'family'],
  match: 'all',
  photos: [
    {
      id: 'p1',
      title: 'Low tide',
      occurred_at: '2026-07-14T10:00:00Z',
      mime_type: 'image/jpeg',
      video: false,
      thumb: '/share/tok123/files/u/apps/photos/a_thumb.jpg',
      src: '/share/tok123/files/u/apps/photos/a_display.jpg',
      full: '/share/tok123/files/u/apps/photos/a.jpg',
      note: 'Low tide at the lighthouse, just before the storm'
    },
    {
      id: 'p2',
      title: null,
      occurred_at: null,
      mime_type: 'video/mp4',
      video: true,
      thumb: null,
      src: '/share/tok123/files/u/apps/photos/clip.mp4',
      full: null,
      note: null
    }
  ]
}

function mockFetch(status: number, body?: unknown) {
  const fetchMock = vi.fn(async () => ({
    ok: status >= 200 && status < 300,
    status,
    json: async () => body
  }))
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

describe('SharedFeedView', () => {
  beforeEach(() => vi.restoreAllMocks())
  afterEach(() => vi.unstubAllGlobals())

  it('renders the feed from the token in the URL', async () => {
    const fetchMock = mockFetch(200, feed)
    const wrapper = mount(SharedFeedView, mountOptions)
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/shares/tok123',
      expect.anything()
    )
    // No name: the tags are the title of the page. For an "all" feed, the
    // tag line joins them with +.
    expect(wrapper.find('.shared-title').text()).toBe('#beach #family')
    expect(wrapper.find('.shared-tags').text()).toBe('#beach + #family')
    expect(wrapper.find('.shared-count').text()).toContain('2 items')

    const thumbs = wrapper.findAll('.shared-thumb')
    expect(thumbs).toHaveLength(2)
    expect(thumbs[0].find('img').attributes('src')).toBe(feed.photos[0].thumb)
    expect(thumbs[0].find('img').attributes('alt')).toBe('Low tide')
    // A video without a captured frame shows a play tile, never a <video>.
    expect(thumbs[1].find('img').exists()).toBe(false)
    expect(thumbs[1].find('video').exists()).toBe(false)
    expect(thumbs[1].find('.shared-thumb-tile').exists()).toBe(true)
  })

  it('opens the read-only viewer on a thumbnail', async () => {
    mockFetch(200, feed)
    const wrapper = mount(SharedFeedView, mountOptions)
    await flushPromises()

    await wrapper.findAll('.shared-thumb')[0].trigger('click')
    const viewer = wrapper.find('.mv-overlay')
    expect(viewer.exists()).toBe(true)
    expect(viewer.find('.mv-image').attributes('src')).toBe(feed.photos[0].src)
    expect(viewer.find('[aria-label="Delete"]').exists()).toBe(false)
    expect(viewer.find('[aria-label="Permalink"]').exists()).toBe(false)
    expect(viewer.find('[aria-label="Download original"]').exists()).toBe(true)
    // The note of the owner shows as a caption. A visitor cannot edit it.
    expect(viewer.find('.mv-caption').text()).toBe(feed.photos[0].note)
    expect(viewer.find('.mv-note-input').exists()).toBe(false)
  })

  it('tells a visitor when the link is gone', async () => {
    mockFetch(404, { error: 'Not found' })
    const wrapper = mount(SharedFeedView, mountOptions)
    await flushPromises()

    expect(wrapper.find('.shared-state').text()).toContain(
      'no longer available'
    )
    expect(wrapper.findAll('.shared-thumb')).toHaveLength(0)
  })

  it('has an empty state for a feed with no photos yet', async () => {
    mockFetch(200, { ...feed, name: 'Summer', photos: [] })
    const wrapper = mount(SharedFeedView, mountOptions)
    await flushPromises()

    expect(wrapper.find('.shared-title').text()).toBe('Summer')
    expect(wrapper.find('.shared-state').text()).toContain('No photos')
  })
})
