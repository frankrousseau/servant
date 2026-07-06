import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import AutocompleteInput from './AutocompleteInput.vue'

const OPTIONS = ['Voyages', 'Maison', 'Travail']

function make(modelValue = '') {
  return mount(AutocompleteInput, {
    props: { modelValue, options: OPTIONS, placeholder: 'Folder' }
  })
}

describe('AutocompleteInput', () => {
  it('shows all options on focus and filters while typing', async () => {
    const wrapper = make()
    await wrapper.find('input').trigger('focus')
    expect(wrapper.findAll('.ac-option')).toHaveLength(3)

    await wrapper.find('input').setValue('voy')
    expect(wrapper.emitted('update:modelValue')![0]).toEqual(['voy'])
    await wrapper.setProps({ modelValue: 'voy' })
    const options = wrapper.findAll('.ac-option')
    expect(options).toHaveLength(1)
    expect(options[0].text()).toBe('Voyages')
  })

  it('selects an option with the mouse', async () => {
    const wrapper = make()
    await wrapper.find('input').trigger('focus')
    await wrapper.findAll('.ac-option')[1].trigger('mousedown')

    expect(wrapper.emitted('update:modelValue')![0]).toEqual(['Maison'])
    expect(wrapper.emitted('select')![0]).toEqual(['Maison'])
    expect(wrapper.find('.ac-list').exists()).toBe(false)
  })

  it('navigates with arrows and selects with Enter', async () => {
    const wrapper = make()
    const input = wrapper.find('input')
    await input.trigger('focus')
    await input.trigger('keydown', { key: 'ArrowDown' })
    await input.trigger('keydown', { key: 'ArrowDown' })
    expect(wrapper.findAll('.ac-option')[1].classes()).toContain(
      'ac-option--active'
    )

    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('select')![0]).toEqual(['Maison'])
  })

  it('commits free text with Enter', async () => {
    const wrapper = make('New folder')
    const input = wrapper.find('input')
    await input.trigger('focus')
    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('select')![0]).toEqual(['New folder'])
  })

  it('closes the list on Escape', async () => {
    const wrapper = make()
    const input = wrapper.find('input')
    await input.trigger('focus')
    expect(wrapper.find('.ac-list').exists()).toBe(true)

    await input.trigger('keydown', { key: 'Escape' })
    expect(wrapper.find('.ac-list').exists()).toBe(false)
  })
})
