import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import TabBar from './TabBar.vue'

const OPTIONS = [
  { value: 'overview', label: 'Overview' },
  { value: 'accounts', label: 'Accounts' },
  { value: 'taxes', label: 'Taxes' }
]

function mountBar(modelValue = 'overview', slots = {}) {
  return mount(TabBar, {
    props: { modelValue, options: OPTIONS, label: 'Finance sections' },
    slots,
    attachTo: document.body
  })
}

describe('TabBar', () => {
  it('renders a labelled tablist with the selected tab as the only Tab stop', () => {
    const wrapper = mountBar('accounts')
    const list = wrapper.find('[role="tablist"]')
    expect(list.attributes('aria-label')).toBe('Finance sections')

    const tabs = wrapper.findAll('[role="tab"]')
    expect(tabs.map(tab => tab.attributes('aria-selected'))).toEqual([
      'false',
      'true',
      'false'
    ])
    expect(tabs.map(tab => tab.attributes('tabindex'))).toEqual([
      '-1',
      '0',
      '-1'
    ])
    wrapper.unmount()
  })

  it('selects on click', async () => {
    const wrapper = mountBar()
    await wrapper.findAll('[role="tab"]')[2].trigger('click')
    expect(wrapper.emitted('update:modelValue')).toEqual([['taxes']])
    wrapper.unmount()
  })

  it('moves with the arrow keys, wrapping, and with Home and End', async () => {
    const wrapper = mountBar()
    const first = wrapper.findAll('[role="tab"]')[0]
    await first.trigger('keydown', { key: 'ArrowRight' })
    await first.trigger('keydown', { key: 'ArrowLeft' })
    await first.trigger('keydown', { key: 'End' })
    await first.trigger('keydown', { key: 'Home' })
    await first.trigger('keydown', { key: 'a' })
    expect(wrapper.emitted('update:modelValue')).toEqual([
      ['accounts'],
      ['taxes'],
      ['taxes'],
      ['overview']
    ])
    wrapper.unmount()
  })

  it('wraps its content in the tabpanel the tabs control', () => {
    const wrapper = mountBar('accounts', { default: '<p>Accounts list</p>' })
    const panel = wrapper.find('[role="tabpanel"]')
    expect(panel.text()).toBe('Accounts list')
    const selected = wrapper.find('[aria-selected="true"]')
    expect(panel.attributes('aria-labelledby')).toBe(selected.attributes('id'))
    expect(selected.attributes('aria-controls')).toBe(panel.attributes('id'))
    wrapper.unmount()
  })

  it('leaves aria-controls out without content', () => {
    const wrapper = mountBar()
    expect(wrapper.find('[role="tabpanel"]').exists()).toBe(false)
    expect(wrapper.find('[role="tab"]').attributes('aria-controls')).toBe(
      undefined
    )
    wrapper.unmount()
  })

  it('focuses the selected tab when asked, and passes its class to the strip', () => {
    const wrapper = mount(TabBar, {
      props: {
        modelValue: 'taxes',
        options: OPTIONS,
        label: 'Finance sections',
        autofocus: true,
        panelClass: 'grow'
      },
      attrs: { class: 'fin-strip' },
      slots: { default: '<p>Taxes</p>' },
      attachTo: document.body
    })
    expect(document.activeElement?.textContent?.trim()).toBe('Taxes')
    expect(wrapper.find('[role="tablist"]').classes()).toContain('fin-strip')
    expect(wrapper.find('[role="tabpanel"]').classes()).toContain('grow')
    wrapper.unmount()
  })
})
