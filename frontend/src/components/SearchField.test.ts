import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import SearchField from './SearchField.vue'

function mountField(props: Record<string, unknown> = {}) {
  return mount(SearchField, {
    props: { modelValue: '', label: 'Search notes', ...props },
    attachTo: document.body
  })
}

describe('SearchField', () => {
  it('labels the field and derives the placeholder from the label', () => {
    const wrapper = mountField()
    const input = wrapper.find('input')
    expect(input.attributes('aria-label')).toBe('Search notes')
    expect(input.attributes('placeholder')).toBe('Search notes...')
    wrapper.unmount()
  })

  it('emits what is typed', async () => {
    const wrapper = mountField()
    await wrapper.find('input').setValue('budget')
    expect(wrapper.emitted('update:modelValue')).toEqual([['budget']])
    wrapper.unmount()
  })

  it('clears from the button, which only shows on a filled field', async () => {
    const empty = mountField()
    expect(empty.find('.search-field-clear').exists()).toBe(false)
    empty.unmount()

    const wrapper = mountField({ modelValue: 'budget' })
    await wrapper.find('.search-field-clear').trigger('click')
    expect(wrapper.emitted('update:modelValue')).toEqual([['']])
    expect(document.activeElement).toBe(wrapper.find('input').element)
    wrapper.unmount()
  })

  it('clears on Escape, and lets Escape through on an empty field', async () => {
    const wrapper = mountField({ modelValue: 'budget' })
    const filled = new KeyboardEvent('keydown', {
      key: 'Escape',
      bubbles: true,
      cancelable: true
    })
    wrapper.find('input').element.dispatchEvent(filled)
    expect(filled.defaultPrevented).toBe(true)
    expect(wrapper.emitted('update:modelValue')).toEqual([['']])

    await wrapper.setProps({ modelValue: '' })
    const empty = new KeyboardEvent('keydown', {
      key: 'Escape',
      bubbles: true,
      cancelable: true
    })
    wrapper.find('input').element.dispatchEvent(empty)
    expect(empty.defaultPrevented).toBe(false)
    expect(wrapper.emitted('update:modelValue')).toHaveLength(1)
    wrapper.unmount()
  })

  it('takes the landing focus when asked', () => {
    const wrapper = mountField({ autofocus: true })
    expect(document.activeElement).toBe(wrapper.find('input').element)
    wrapper.unmount()
  })
})
