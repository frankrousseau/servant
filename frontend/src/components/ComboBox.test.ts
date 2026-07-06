import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import ComboBox from './ComboBox.vue'

const SMALL = [
  { value: '', label: 'Never' },
  { value: 'weekly', label: 'Every week' },
  { value: 'yearly', label: 'Every year' }
]

function make(options: unknown = SMALL, modelValue = '') {
  return mount(ComboBox, {
    props: { modelValue, options: options as never, placeholder: 'Pick…' }
  })
}

describe('ComboBox', () => {
  it('shows the current label and opens on click', async () => {
    const wrapper = make(SMALL, 'weekly')
    expect(wrapper.find('.cb-value').text()).toBe('Every week')

    await wrapper.find('.cb-control').trigger('click')
    const labels = wrapper.findAll('.cb-option').map(o => o.text())
    expect(labels).toEqual(['Never', 'Every week', 'Every year'])
    expect(wrapper.find('.cb-option--selected').text()).toBe('Every week')
  })

  it('selects with the mouse and closes', async () => {
    const wrapper = make()
    await wrapper.find('.cb-control').trigger('click')
    await wrapper.findAll('.cb-option')[2].trigger('mousedown')

    expect(wrapper.emitted('update:modelValue')![0]).toEqual(['yearly'])
    expect(wrapper.find('.cb-panel').exists()).toBe(false)
  })

  it('navigates with arrows and selects with Enter', async () => {
    const wrapper = make(SMALL, '')
    const control = wrapper.find('.cb-control')
    await control.trigger('keydown', { key: 'ArrowDown' }) // opens on current
    await control.trigger('keydown', { key: 'ArrowDown' })
    await control.trigger('keydown', { key: 'Enter' })

    expect(wrapper.emitted('update:modelValue')![0]).toEqual(['weekly'])
  })

  it('closes on Escape without selecting', async () => {
    const wrapper = make()
    await wrapper.find('.cb-control').trigger('click')
    await wrapper.find('.cb').trigger('keydown', { key: 'Escape' })

    expect(wrapper.find('.cb-panel').exists()).toBe(false)
    expect(wrapper.emitted('update:modelValue')).toBeUndefined()
  })

  it('accepts plain string options', async () => {
    const wrapper = make(['EUR', 'USD'], 'EUR')
    expect(wrapper.find('.cb-value').text()).toBe('EUR')
    await wrapper.find('.cb-control').trigger('click')
    expect(wrapper.findAll('.cb-option').map(o => o.text())).toEqual([
      'EUR',
      'USD'
    ])
  })

  it('shows a filter box on long lists and filters options', async () => {
    const many = Array.from({ length: 20 }, (_, i) => `Option ${i}`)
    const wrapper = make(many, 'Option 3')
    await wrapper.find('.cb-control').trigger('click')

    const search = wrapper.find('.cb-search')
    expect(search.exists()).toBe(true)
    await search.setValue('option 1')
    const labels = wrapper.findAll('.cb-option').map(o => o.text())
    expect(labels).toEqual([
      'Option 1',
      'Option 10',
      'Option 11',
      'Option 12',
      'Option 13',
      'Option 14',
      'Option 15',
      'Option 16',
      'Option 17',
      'Option 18',
      'Option 19'
    ])
  })
})
