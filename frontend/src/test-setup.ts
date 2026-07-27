import { config } from '@vue/test-utils'

// Teleported content (ComboBox panel, modals) renders in place during tests
// so wrapper.find keeps seeing it.
config.global.stubs = { teleport: true }
