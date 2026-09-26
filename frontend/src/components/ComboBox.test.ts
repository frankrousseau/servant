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

  it('opens its panel inside the modal dialog that holds it', async () => {
    // A modal <dialog> is in the top layer: a panel left in <body> would
    // open behind it, unreachable.
    const dialog = document.createElement('dialog')
    document.body.appendChild(dialog)
    const wrapper = mount(ComboBox, {
      props: { modelValue: '', options: SMALL },
      attachTo: dialog,
      global: { stubs: { teleport: false } }
    })
    await wrapper.find('.cb-control').trigger('click')

    expect(dialog.querySelector('.cb-panel')).not.toBeNull()
    wrapper.unmount()
    dialog.remove()
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

  it('long lists open the choices directly, typing in the control filters', async () => {
    const many = Array.from({ length: 20 }, (_, i) => `Option ${i}`)
    const wrapper = make(many, 'Option 3')
    await wrapper.find('.cb-control').trigger('click')

    // The full list is visible immediately; the control became the filter.
    expect(wrapper.findAll('.cb-option')).toHaveLength(20)
    const filter = wrapper.find('input.cb-filter')
    expect(filter.exists()).toBe(true)

    await filter.setValue('option 12')
    const labels = wrapper.findAll('.cb-option').map(o => o.text())
    expect(labels).toEqual(['Option 12'])

    await wrapper.find('.cb-option').trigger('mousedown')
    expect(wrapper.emitted('update:modelValue')![0]).toEqual(['Option 12'])
    expect(wrapper.find('.cb-panel').exists()).toBe(false)
    expect(wrapper.find('button.cb-control').exists()).toBe(true)
  })
})
