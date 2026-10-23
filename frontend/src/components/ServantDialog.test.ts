import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import flatpickr from 'flatpickr'

import ServantDialog from './ServantDialog.vue'

import { pickerPlacement } from '../lib/dialog'

function mountDialog(props: Record<string, unknown> = {}, slots = {}) {
  return mount(ServantDialog, {
    props: { open: true, title: 'Edit event', ...props },
    slots: { default: '<input class="field" />', ...slots }
  })
}

describe('ServantDialog', () => {
  it('opens modal with its title wired to aria-labelledby', () => {
    const wrapper = mountDialog()
    const dialog = wrapper.find('dialog')
    expect(dialog.attributes('open')).toBeDefined()
    const titleId = dialog.attributes('aria-labelledby')
    expect(titleId).toBeTruthy()
    expect(wrapper.find(`#${titleId}`).text()).toBe('Edit event')
  })

  it('renders nothing while closed', () => {
    expect(mountDialog({ open: false }).find('dialog').exists()).toBe(false)
  })

  it('closes from the icon button, the text button and Escape', async () => {
    const wrapper = mountDialog()
    await wrapper.find('.servant-dialog-x').trigger('click')
    await wrapper.find('.servant-dialog-cancel').trigger('click')
    const cancel = new Event('cancel', { cancelable: true })
    wrapper.find('dialog').element.dispatchEvent(cancel)

    expect(cancel.defaultPrevented).toBe(true)
    expect(wrapper.emitted('update:open')).toEqual([[false], [false], [false]])
    expect(wrapper.emitted('close')).toHaveLength(3)
  })

  it('closes on a backdrop click, not on a drag that starts inside', async () => {
    const wrapper = mountDialog()
    const dialog = wrapper.find('dialog')

    await wrapper.find('.field').trigger('pointerdown')
    await dialog.trigger('click')
    expect(wrapper.emitted('update:open')).toBeUndefined()

    await wrapper.find('.field').trigger('click')
    expect(wrapper.emitted('update:open')).toBeUndefined()

    await dialog.trigger('pointerdown')
    await dialog.trigger('click')
    expect(wrapper.emitted('update:open')).toEqual([[false]])
  })

  it('labels the text button Close alone, Cancel next to actions', () => {
    expect(mountDialog().find('.servant-dialog-cancel').text()).toBe('Close')

    const withActions = mountDialog({}, { actions: '<button>Save</button>' })
    expect(withActions.find('.servant-dialog-cancel').text()).toBe('Cancel')
    expect(withActions.find('.servant-dialog-actions').text()).toContain('Save')

    const custom = mountDialog({ closeLabel: 'Discard' })
    expect(custom.find('.servant-dialog-cancel').text()).toBe('Discard')
  })

  it('mounts date pickers inside the dialog, over the modal', () => {
    const wrapper = mountDialog({}, { default: '<input class="date" />' })
    const input = wrapper.find('.date').element as HTMLInputElement

    const picker = flatpickr(
      input,
      pickerPlacement(input)
    ) as flatpickr.Instance
    expect(picker.calendarContainer.closest('dialog')).not.toBeNull()
    picker.destroy()
  })
})
